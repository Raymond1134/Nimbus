// DJISDKBridge.swift — Nimbus
// Bridge between DJI Mobile SDK v4 and the Swift application layer.
// Spec §3 component 8 (DJISDKBridge sub-component).
//
// Threading note: DJI SDK delegate callbacks can arrive on arbitrary threads.
// All updates to @Published properties are hopped to the main actor via Task.

import Foundation
import UIKit
import CoreLocation
import Observation
import SwiftUI

#if canImport(DJIWidget)
import DJIWidget
#endif

/// Single shared instance — created at app start, owned by Orchestrator.
/// Uses @Observable so SwiftUI views that read nested properties (e.g. bridge.telemetry)
/// via an @Observable Orchestrator receive the correct re-render signals.
@Observable
final class DJISDKBridge: NSObject {

    static let shared = DJISDKBridge()

    // MARK: - State

    var isAircraftConnected = false
    var telemetry           = TelemetrySnapshot.zero
    /// Latest decoded camera frame (set by the video decode pipeline).
    var cameraFrame: UIImage?
    /// True once at least one live H264 packet has been received from DJI feed.
    var hasLiveVideoData = false

    // MARK: - Private

    private weak var flightController: DJIFlightController?
    private var deadManTimer: Timer?
    private let safety = SafetySupervisor()
    private var lastGimbalCommandAt = Date.distantPast
    @ObservationIgnored private lazy var liveFeedManager = DJILiveVideoFeedManager(bridge: self)

    private override init() { super.init() }

    // MARK: - Product Connection (called by DJIManager)

    func onProductConnected(_ product: DJIBaseProduct?) {
        guard let aircraft = product as? DJIAircraft,
              let fc       = aircraft.flightController else {
            print("DJISDKBridge: connected product is not a supported aircraft.")
            return
        }
        flightController      = fc
        fc.delegate           = self
        isAircraftConnected   = true
        configureVirtualStick(fc)
        Task { @MainActor [weak self] in
            self?.liveFeedManager.onAircraftConnectionChanged(connected: true)
        }
        print("DJISDKBridge: aircraft '\(product?.model ?? "unknown")' connected, Virtual Stick ready.")
    }

    func onProductDisconnected() {
        stopDeadMan()
        flightController    = nil
        isAircraftConnected = false
        cameraFrame         = nil
        hasLiveVideoData    = false
        Task { @MainActor [weak self] in
            self?.liveFeedManager.onAircraftConnectionChanged(connected: false)
        }
        print("DJISDKBridge: aircraft disconnected.")
    }

    // MARK: - Virtual Stick Configuration

    private func configureVirtualStick(_ fc: DJIFlightController) {
        fc.setVirtualStickModeEnabled(true) { error in
            if let error {
                print("DJISDKBridge: VS enable error: \(error.localizedDescription)")
            } else {
                print("DJISDKBridge: Virtual Stick enabled.")
            }
        }
        // Body-frame velocity control (spec §2):
        // pitch  = forward (+) / backward (–)  m/s
        // roll   = right  (+) / left     (–)  m/s
        // yaw    = clockwise (+)               deg/s
        // throttle = up (+) / down (–)         m/s
        fc.rollPitchCoordinateSystem = DJIVirtualStickFlightCoordinateSystem.body
        fc.rollPitchControlMode      = DJIVirtualStickRollPitchControlMode.velocity
        fc.yawControlMode            = DJIVirtualStickYawControlMode.angularVelocity
        fc.verticalControlMode       = DJIVirtualStickVerticalControlMode.velocity
    }

    // MARK: - Virtual Stick Commands

    /// Send a velocity command. Values are safety-clamped before transmission.
    func sendVelocity(pitch:    Float = 0,
                      roll:     Float = 0,
                      yaw:      Float = 0,
                      throttle: Float = 0) {
        guard let fc = flightController else { return }

        var data = DJIVirtualStickFlightControlData()
        data.pitch            = safety.clamp(pitch)
        data.roll             = safety.clamp(roll)
        data.yaw              = Float(safety.clampYawDps(Double(yaw)))
        data.verticalThrottle = safety.clamp(throttle)

        fc.send(data, withCompletion: nil)
        resetDeadMan()
    }

    /// Zero all axes — hover in place.
    func sendHover() {
        sendVelocity()
    }

    /// Immediately tilt the gimbal down to prepare top-down tracking before detections lock in.
    func pointGimbalDownImmediately(airpodsPitchDeg: CGFloat = 0,
                                    strictDown: Bool = false) {
        guard let aircraft = DJISDKManager.product() as? DJIAircraft,
              let gimbal = aircraft.gimbal else { return }

        let downwardBasePitchDeg: Float = strictDown ? -85 : -72
        let airpodsPitchOffset = strictDown ? 0 : Float(airpodsPitchDeg) * 0.2
        let desiredPitch = max(-85, min(0, downwardBasePitchDeg + airpodsPitchOffset))

        let rotation = DJIGimbalRotation(
            pitchValue: NSNumber(value: desiredPitch),
            rollValue: nil,
            yawValue: nil,
            time: 0.1,
            mode: .absoluteAngle,
            ignore: true
        )
        gimbal.rotate(with: rotation, completion: nil)
    }

    /// Bias the gimbal downward while keeping the tracked head-top near a target screen Y.
    /// - Parameters:
    ///   - headTopY: Normalized Vision Y (0...1, origin at bottom-left).
    ///   - targetY: Desired normalized Y for the top of the head.
    ///   - airpodsPitchDeg: Current AirPods pitch in degrees used to mirror user pitch while maintaining top-down framing.
    func trackHeadTopWithGimbal(headTopY: CGFloat,
                                targetY: CGFloat = 0.62,
                                airpodsPitchDeg: CGFloat = 0,
                                strictDown: Bool = false) {
        guard let aircraft = DJISDKManager.product() as? DJIAircraft,
              let gimbal = aircraft.gimbal else { return }

        // Avoid saturating the gimbal command channel at the 10 Hz behavior loop rate.
        if Date().timeIntervalSince(lastGimbalCommandAt) < 0.2 { return }
        lastGimbalCommandAt = Date()

        let yError = Float(targetY - headTopY)
        let downwardBasePitchDeg: Float = strictDown ? -85 : -70
        let pitchGainDegPerNorm: Float = strictDown ? 0 : 12
        let airpodsPitchOffset = strictDown ? 0 : Float(airpodsPitchDeg) * 0.25
        let desiredPitch = max(-85, min(0, downwardBasePitchDeg + (yError * pitchGainDegPerNorm) + airpodsPitchOffset))

        let rotation = DJIGimbalRotation(
            pitchValue: NSNumber(value: desiredPitch),
            rollValue: nil,
            yawValue: nil,
            time: 0.2,
            mode: .absoluteAngle,
            ignore: true
        )
        gimbal.rotate(with: rotation, completion: nil)
    }

    // MARK: - Dead-Man's Switch (spec §8)
    // If no fresh command arrives within 300 ms, hover automatically.

    private func resetDeadMan() {
        deadManTimer?.invalidate()
        deadManTimer = Timer.scheduledTimer(
            withTimeInterval: safety.deadManIntervalSec,
            repeats: false
        ) { [weak self] _ in
            self?.sendHover()
        }
    }

    private func stopDeadMan() {
        deadManTimer?.invalidate()
        deadManTimer = nil
    }

    // MARK: - Camera Frame

    /// Called from the DJI video decode pipeline to surface the latest frame.
    func updateCameraFrame(_ image: UIImage) {
        if Thread.isMainThread {
            cameraFrame = image
        } else {
            Task { @MainActor [weak self] in
                self?.cameraFrame = image
            }
        }
    }

    @MainActor
    func attachCameraPreviewHost(_ view: UIView) {
        liveFeedManager.attach(to: view)
    }

    @MainActor
    func detachCameraPreviewHost(_ view: UIView?) {
        liveFeedManager.detach(from: view)
    }

    /// Return the latest camera frame as JPEG, or a tiny placeholder so that
    /// backend calls always have valid image bytes.
    func captureFrameJPEG() -> Data {
        if let frame = cameraFrame,
           let data  = frame.jpegData(compressionQuality: 0.75) {
            return data
        }
        return makePlaceholderJPEG()
    }

    private func makePlaceholderJPEG() -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4))
        let img = renderer.image { ctx in
            UIColor.darkGray.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
        return img.jpegData(compressionQuality: 0.5) ?? Data()
    }
}

/// Owns DJI live-video setup/teardown so stream listeners are not duplicated
/// and previewer state survives SwiftUI view lifecycle churn.
///
/// Design (mirrors the DJI app):
///   - The H264 DATA FEED starts as soon as the aircraft connects and runs
///     until it disconnects — it is NOT tied to SwiftUI view mount/unmount.
///   - The VISUAL PREVIEW (DJIVideoPreviewer render target) is attached/
///     detached independently when a host UIView appears or disappears.
///     Detaching the view does NOT stop the decoder or the feed.
///   - `stopFeed()` is the only path that fully tears everything down; it
///     is called only from `onAircraftConnectionChanged(connected: false)`.
@MainActor
final class DJILiveVideoFeedManager: NSObject {

    private weak var previewHostView: UIView?
    private weak var activeFeed: DJIVideoFeed?
    private weak var bridge: DJISDKBridge?
    private var snapshotTimer: Timer?

    /// True once the H264 video-feed listener is registered.
    private var isFeedRunning = false
    /// True once DJIVideoPreviewer.start() has been called for this feed session.
    /// Reset only on full stopFeed() so repeated view re-mounts don't call start() again.
    private var previewerStarted = false

    init(bridge: DJISDKBridge) {
        self.bridge = bridge
        super.init()
    }

    // MARK: - View lifecycle (called by SwiftUI UIViewRepresentable)

    /// Register a host view for the live preview.
    /// If the data feed is already running this just re-attaches the render target
    /// without restarting the decoder — survives tab switching and view re-mounts.
    func attach(to hostView: UIView) {
        previewHostView = hostView
        if isFeedRunning {
            attachPreview(to: hostView)
        }
        // If the feed isn't running yet (aircraft not connected), the preview
        // will be attached automatically when onAircraftConnectionChanged(true) fires.
    }

    /// Remove the render target.
    /// The data feed and snapshot timer keep running — frame capture for AI
    /// continues even while the camera preview is off-screen.
    func detach(from hostView: UIView?) {
        if let hostView, previewHostView !== hostView { return }
        detachPreview()          // remove visual render target only
        previewHostView = nil    // feed is NOT stopped
    }

    // MARK: - Aircraft connection events (called by DJISDKBridge)

    func onAircraftConnectionChanged(connected: Bool) {
        if connected {
            startFeed()
        } else {
            stopFeed()
        }
    }

    // MARK: - Feed lifecycle

    /// Start the H264 data feed.  Safe to call multiple times; no-ops if already running.
    private func startFeed() {
        guard !isFeedRunning else { return }
        guard DJISDKManager.product() != nil else { return }

        let primary = DJISDKManager.videoFeeder()?.primaryVideoFeed
        primary?.remove(self)
        primary?.add(self, with: nil)
        activeFeed = primary
        isFeedRunning = true
        startSnapshotTimer()

        // Attach preview immediately if a host view is already waiting.
        if let hostView = previewHostView {
            attachPreview(to: hostView)
        }
    }

    /// Full teardown — called only when the aircraft disconnects.
    private func stopFeed() {
        detachPreview()
        activeFeed?.remove(self)
        activeFeed = nil
        stopSnapshotTimer()
        previewerStarted = false
        isFeedRunning = false
    }

    // MARK: - Preview lifecycle

    /// Point the previewer at `view`.  Starts the decoder on the first call;
    /// subsequent calls (e.g. after a tab switch) just update the render target.
    private func attachPreview(to view: UIView) {
        #if canImport(DJIWidget)
        DJIVideoPreviewer.instance()?.setView(view)
        if !previewerStarted {
            DJIVideoPreviewer.instance()?.start()
            previewerStarted = true
        }
        #endif
    }

    /// Remove the render target without stopping the decoder.
    /// The decoder keeps running so it can resume instantly on re-attach.
    private func detachPreview() {
        #if canImport(DJIWidget)
        DJIVideoPreviewer.instance()?.unSetView()
        #endif
        // Note: previewerStarted intentionally NOT reset here —
        // the decoder stays live for the duration of the aircraft connection.
    }

    // MARK: - Snapshot timer

    private func startSnapshotTimer() {
        stopSnapshotTimer()
        snapshotTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.capturePreviewSnapshot()
        }
    }

    private func stopSnapshotTimer() {
        snapshotTimer?.invalidate()
        snapshotTimer = nil
    }

    private func capturePreviewSnapshot() {
        #if canImport(DJIWidget)
        DJIVideoPreviewer.instance()?.snapshotPreview { [weak self] snapshot in
            guard let snapshot else { return }
            self?.bridge?.updateCameraFrame(snapshot)
        }
        #endif
    }
}

extension DJILiveVideoFeedManager: DJIVideoFeedListener {
    nonisolated func videoFeed(_ videoFeed: DJIVideoFeed, didUpdateVideoData videoData: Data) {
        Task { @MainActor [weak self] in
            self?.bridge?.hasLiveVideoData = true
        }
        #if canImport(DJIWidget)
        videoData.withUnsafeBytes { rawBuffer in
            guard let ptr = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
            DJIVideoPreviewer.instance()?.push(UnsafeMutablePointer(mutating: ptr), length: Int32(videoData.count))
        }
        #endif
    }
}

struct DJICameraPreviewView: UIViewRepresentable {
    let bridge: DJISDKBridge

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .black
        Task { @MainActor in
            bridge.attachCameraPreviewHost(view)
        }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        Task { @MainActor in
            bridge.attachCameraPreviewHost(uiView)
        }
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: ()) {
        Task { @MainActor in
            DJISDKBridge.shared.detachCameraPreviewHost(uiView)
        }
    }
}

// MARK: - DJIFlightControllerDelegate

extension DJISDKBridge: DJIFlightControllerDelegate {
    func flightController(_ fc: DJIFlightController,
                          didUpdate state: DJIFlightControllerState) {
        let currentLocation = state.aircraftLocation.map {
            GPSCoordinate(latitude: $0.coordinate.latitude,
                          longitude: $0.coordinate.longitude,
                          altitudeM: $0.altitude)
        }
        let homeLocation = state.homeLocation.map {
            GPSCoordinate(latitude: $0.coordinate.latitude,
                          longitude: $0.coordinate.longitude,
                          altitudeM: $0.altitude)
        }
        let snap = TelemetrySnapshot(
            altitudeM:      state.altitude,
            headingDeg:     Double(state.attitude.yaw),
            velocityX:      Double(state.velocityX),
            velocityY:      Double(state.velocityY),
            velocityZ:      Double(state.velocityZ),
            batteryPercent: 0,           // wired via DJIBatteryDelegate if needed
            isGPSValid:     state.satelliteCount > 4,
            satelliteCount: Int(state.satelliteCount),
            isFlying:       state.isFlying,
            currentLocation: currentLocation,
            homeLocation:   homeLocation
        )
        Task { @MainActor [weak self] in
            self?.telemetry = snap
        }
    }
}
