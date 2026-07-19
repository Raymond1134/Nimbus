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
    /// Frame captured by the most recent photo op — shown in the UI.
    var lastCapturedPhoto: UIImage?
    /// True while an SDK Hotpoint (POI orbit) mission is running.
    private(set) var isHotpointActive = false

    // MARK: - Private

    private weak var flightController: DJIFlightController?
    private var deadManTimer: Timer?
    private let safety = SafetySupervisor()
    private var lastGimbalCommandAt = Date.distantPast
    /// Counter for VS heartbeat logging (logs once per 100 sendVelocity calls in DEBUG).
    @ObservationIgnored private var vsHeartbeatCounter = 0
    @ObservationIgnored private lazy var liveFeedManager = DJILiveVideoFeedManager(bridge: self)

    // Health monitoring (single repeating timer; timestamp-based).
    @ObservationIgnored private var healthMonitorTimer: Timer?
    @ObservationIgnored private var lastTelemetryAt = Date.distantPast
    @ObservationIgnored private var lastStallSignalAt = Date.distantPast
    /// True while the app is backgrounded — health checks are ignored so that
    /// time spent suspended never counts as a telemetry/video stall.
    @ObservationIgnored private var isHealthMonitoringSuspended = false
    @ObservationIgnored private var lastVideoPacketAt = Date.distantPast
    @ObservationIgnored private var feedStartupAt = Date.distantPast
    @ObservationIgnored private var lastFeedRecoveryAt = Date.distantPast
    @ObservationIgnored private var lastControlAuthorityAssertAt = Date.distantPast
    @ObservationIgnored private var isAssertingControlAuthority = false
    @ObservationIgnored private var isVirtualStickControlSuspended = false

    private override init() { super.init() }

    // MARK: - Product Connection (called by DJIManager)

    /// Idempotent: calling this again for the flight controller we are already
    /// set up with only re-arms delegates and refreshes health monitoring —
    /// it never restarts Virtual Stick config or the video feed on a live link.
    func onProductConnected(_ product: DJIBaseProduct?) {
        guard let aircraft = product as? DJIAircraft,
              let fc       = aircraft.flightController else {
            print("DJISDKBridge: connected product is not a supported aircraft.")
            return
        }

        let sameController = (fc === flightController) && isAircraftConnected
        flightController = fc
        fc.delegate      = self          // always re-arm (recovers silently dropped delegates)

        if sameController {
            resumeHealthMonitoring()
            print("DJISDKBridge: connection confirmed — existing setup kept.")
            return
        }

        isAircraftConnected = true
        // Deferred init: wait 1.5 s for the DJI SDK to fully initialise the
        // flight controller after a (re)connect before enabling Virtual Stick
        // and indoor-stabilisation features.
        Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(1.5))
            guard let fc = self.flightController else { return }
            self.configureVirtualStick(fc)
            self.enableIndoorStabilisation(fc, aircraft: aircraft)
        }
        Task { @MainActor [weak self] in
            self?.liveFeedManager.onAircraftConnectionChanged(connected: true)
        }
        startHealthMonitor()
        print("DJISDKBridge: aircraft '\(aircraft.model ?? "unknown")' connected — Virtual Stick init deferred 1.5 s.")
    }

    private func waitForLandingCompletion(timeout: Double) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !telemetry.isFlying { return true }
            if telemetry.isLandingConfirmationNeeded {
                _ = await confirmLanding()
            }
            try? await Task.sleep(for: .seconds(0.2))
        }
        print("DJISDKBridge: landing timeout waiting for touchdown.")
        return false
    }

    private func confirmLanding() async -> Bool {
        guard let fc = flightController else { return false }
        return await withCheckedContinuation { cont in
            fc.confirmLanding { error in
                if let error {
                    print("DJISDKBridge: confirmLanding error: \(error.localizedDescription)")
                    cont.resume(returning: false)
                } else {
                    cont.resume(returning: true)
                }
            }
        }
    }

    func onProductDisconnected() {
        stopDeadMan()
        stopHealthMonitor()
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
        applyVirtualStickControlModes(fc)
    }

    private func applyVirtualStickControlModes(_ fc: DJIFlightController) {
        // BODY-frame velocity control with Aircraft Heading orientation mode:
        // - pitch + = forward, pitch − = backward
        // - roll  + = right,   roll  − = left
        //
        // Movement actions are implemented as "yaw first, then pitch forward"
        // in higher-level behaviors/executor logic.
        fc.rollPitchCoordinateSystem = DJIVirtualStickFlightCoordinateSystem.body
        fc.rollPitchControlMode      = DJIVirtualStickRollPitchControlMode.velocity
        fc.yawControlMode            = DJIVirtualStickYawControlMode.angularVelocity
        fc.verticalControlMode       = DJIVirtualStickVerticalControlMode.velocity
        fc.setFlightOrientationMode(.aircraftHeading) { error in
            if let error {
                print("DJISDKBridge: Aircraft Heading orientation enable error: \(error.localizedDescription)")
            } else {
                print("DJISDKBridge: Aircraft Heading orientation enabled.")
            }
        }
    }

    /// Reasserts Virtual Stick + control modes, recovering from RC/physical
    /// input authority takeovers that can silently disable SDK command control.
    private func assertControlAuthorityIfNeeded(force: Bool = false) {
        if isVirtualStickControlSuspended { return }
        guard let fc = flightController else { return }
        if isAssertingControlAuthority { return }
        let now = Date()
        if !force, now.timeIntervalSince(lastControlAuthorityAssertAt) < 2.0 { return }
        isAssertingControlAuthority = true
        fc.setVirtualStickModeEnabled(true) { [weak self] error in
            guard let self else { return }
            if let error {
                print("DJISDKBridge: VS authority reassert error: \(error.localizedDescription)")
            } else {
                self.applyVirtualStickControlModes(fc)
            }
            self.lastControlAuthorityAssertAt = Date()
            self.isAssertingControlAuthority = false
        }
    }

    /// Async enable/disable of Virtual Stick. Hotpoint missions and VS are
    /// mutually exclusive, so the orbit path toggles this around the mission.
    private func setVirtualStickEnabled(_ enabled: Bool) async {
        guard let fc = flightController else { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            fc.setVirtualStickModeEnabled(enabled) { error in
                if let error {
                    print("DJISDKBridge: VS \(enabled ? "enable" : "disable") error: \(error.localizedDescription)")
                }
                cont.resume()
            }
        }
        if enabled { applyVirtualStickControlModes(fc) }
    }

    /// Re-apply Virtual Stick configuration after a reconnect has settled.
    /// Call from DJIManager once a successful reconnect is confirmed.
    func recheckVirtualStick() {
        guard let fc = flightController,
              let aircraft = DJISDKManager.product() as? DJIAircraft else { return }
        print("DJISDKBridge: recheckVirtualStick() — re-applying VS configuration.")
        configureVirtualStick(fc)
        enableIndoorStabilisation(fc, aircraft: aircraft)
    }

    /// Call this right before starting a movement action to maximize the chance
    /// the SDK owns control even after manual/physical stick interference.
    func prepareForActionControl() async {
        isVirtualStickControlSuspended = false
        assertControlAuthorityIfNeeded(force: true)
        try? await Task.sleep(for: .seconds(0.12))
    }

    // MARK: - Indoor Stabilisation (no-GPS / cramped-space mode)

    /// Enable the SDK's downward-vision position hold and collision avoidance.
    /// Both are software features — they don't change the physical sensor suite,
    /// but tell the flight controller to use the optical-flow / TOF data it
    /// already has to replace GPS position hold.
    ///
    /// Called automatically on every connect/reconnect after the VS init delay.
    private func enableIndoorStabilisation(_ fc: DJIFlightController,
                                           aircraft: DJIAircraft) {
        // 0) Disable novice mode so the aircraft uses its full flight envelope.
        fc.setNoviceModeEnabled(false) { error in
            if let error {
                print("DJISDKBridge: novice-mode disable error: \(error.localizedDescription)")
            } else {
                print("DJISDKBridge: Novice mode disabled — full flight envelope active.")
            }
        }

        // 1) Vision-assisted positioning: optical-flow / downward-camera position
        //    hold without GPS. This is the primary indoor stability mechanism.
        fc.setVisionAssistedPositioningEnabled(true) { error in
            if let error {
                print("DJISDKBridge: VPS enable error: \(error.localizedDescription)")
            } else {
                print("DJISDKBridge: Vision-assisted positioning enabled.")
            }
        }

        // 2) Collision avoidance (obstacle sensors): active braking in cramped
        //    spaces. flightAssistant lives on DJIFlightController, not DJIAircraft.
        //    Some airframes may not have forward sensors; the SDK no-ops silently
        //    on unsupported hardware.
        fc.flightAssistant?.setCollisionAvoidanceEnabled(true) { error in
            if let error {
                print("DJISDKBridge: collision avoidance enable error: \(error.localizedDescription)")
            } else {
                print("DJISDKBridge: Collision avoidance enabled.")
            }
        }
    }

    // MARK: - Health Monitoring
    // One repeating 2 s timer compares timestamps instead of re-arming one-shot
    // timers on every telemetry packet. It is fully suspended while the app is
    // backgrounded and gets fresh baselines on resume, so time spent suspended
    // never masquerades as a stall.

    /// Pause health checks (app going to background). The connection, video
    /// feed, and decoder are left completely untouched.
    func suspendHealthMonitoring() {
        isHealthMonitoringSuspended = true
    }

    /// Resume health checks with fresh baselines (app returning to foreground,
    /// or a connection re-confirmation). Grace period included by design: all
    /// timestamps reset to now.
    func resumeHealthMonitoring() {
        isHealthMonitoringSuspended = false
        guard isAircraftConnected else { return }
        let now = Date()
        lastTelemetryAt    = now
        lastVideoPacketAt  = now
        feedStartupAt      = now
        lastStallSignalAt  = .distantPast
        lastFeedRecoveryAt = .distantPast
        if healthMonitorTimer == nil { startHealthMonitor() }
    }

    private func startHealthMonitor() {
        stopHealthMonitor()
        let now = Date()
        lastTelemetryAt    = now
        lastVideoPacketAt  = now
        feedStartupAt      = now
        lastStallSignalAt  = .distantPast
        lastFeedRecoveryAt = .distantPast
        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.evaluateConnectionHealth()
        }
        RunLoop.main.add(timer, forMode: .common)
        healthMonitorTimer = timer
    }

    private func stopHealthMonitor() {
        healthMonitorTimer?.invalidate()
        healthMonitorTimer  = nil
        lastTelemetryAt     = .distantPast
        lastVideoPacketAt   = .distantPast
        feedStartupAt       = .distantPast
        lastStallSignalAt   = .distantPast
        lastFeedRecoveryAt  = .distantPast
    }

    private func evaluateConnectionHealth() {
        guard isAircraftConnected, !isHealthMonitoringSuspended else { return }
        let now = Date()

        // 1) Telemetry: a silent flight controller is only a *signal* —
        //    DJIManager verifies against SDK ground truth before acting, and a
        //    live link is kept (delegates re-armed) rather than torn down.
        let telemetryAge = now.timeIntervalSince(lastTelemetryAt)
        if telemetryAge > 6.0, now.timeIntervalSince(lastStallSignalAt) > 6.0 {
            print("DJISDKBridge: telemetry silent \(String(format: "%.1f", telemetryAge))s — requesting link verification.")
            lastStallSignalAt = now
            NotificationCenter.default.post(name: .djiTelemetryStalled, object: nil)
        }

        // 2) Video feed: escalation is limited to restarting the feed listener
        //    — never the connection.
        let canRecover = now.timeIntervalSince(lastFeedRecoveryAt) > 3.0
        if !hasLiveVideoData {
            // Connected but no packets yet: recover the feed startup path.
            if now.timeIntervalSince(feedStartupAt) > 5.0, canRecover {
                print("DJISDKBridge: no video packets since startup — restarting feed.")
                Task { @MainActor [weak self] in
                    self?.liveFeedManager.recoverFromVideoStall()
                }
                lastFeedRecoveryAt = now
            }
        } else {
            let packetAge = now.timeIntervalSince(lastVideoPacketAt)
            if packetAge > 3.0, canRecover {
                print("DJISDKBridge: video packet stall (\(String(format: "%.1f", packetAge))s) — restarting feed.")
                Task { @MainActor [weak self] in
                    self?.liveFeedManager.recoverFromVideoStall()
                }
                lastVideoPacketAt  = now
                lastFeedRecoveryAt = now
            }
        }
    }

    // MARK: - Virtual Stick Commands

    /// Send a velocity command. Values are safety-clamped before transmission.
    func sendVelocity(pitch:    Float = 0,
                      roll:     Float = 0,
                      yaw:      Float = 0,
                      throttle: Float = 0) {
        if isVirtualStickControlSuspended { return }
        guard let fc = flightController else { return }
        assertControlAuthorityIfNeeded()

        var data = DJIVirtualStickFlightControlData()
        data.pitch            = safety.clamp(pitch)
        data.roll             = safety.clamp(roll)
        data.yaw              = Float(safety.clampYawDps(Double(yaw)))  // capped at safety.maxYawDps
        data.verticalThrottle = safety.clamp(throttle)

        fc.send(data, withCompletion: nil)
        resetDeadMan()

        #if DEBUG
        vsHeartbeatCounter += 1
        if vsHeartbeatCounter % 100 == 0 {
            print("DJISDKBridge: VS heartbeat — \(vsHeartbeatCounter) cmds sent (p:\(data.pitch) r:\(data.roll) y:\(data.yaw) t:\(data.verticalThrottle)).")
        }
        #endif
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

    // MARK: - Takeoff / Landing (async wrappers)

    /// Auto-takeoff to ~1.2 m hover. Returns true on success.
    @discardableResult
    func takeOff() async -> Bool {
        guard let fc = flightController else { return false }
        isVirtualStickControlSuspended = false
        assertControlAuthorityIfNeeded(force: true)
        return await withCheckedContinuation { cont in
            fc.startTakeoff { error in
                if let error {
                    print("DJISDKBridge: takeoff error: \(error.localizedDescription)")
                    cont.resume(returning: false)
                } else {
                    cont.resume(returning: true)
                }
            }
        }
    }

    /// Auto-land and wait until touchdown. Returns true only when the aircraft
    /// has actually finished landing (or was already not flying).
    ///
    /// Virtual Stick must be disabled before the SDK will accept the landing
    /// command (error -1008 otherwise). We disable VS, land, then rely on the
    /// next reconnect/recheckVirtualStick call to re-enable it if needed.
    @discardableResult
    func startLanding() async -> Bool {
        guard let fc = flightController else { return false }
        isVirtualStickControlSuspended = true
        stopDeadMan()
        if !telemetry.isFlying { return true }
        // Disable Virtual Stick — SDK rejects startLanding while VS is active.
        await setVirtualStickEnabled(false)
        // Brief settle so the flight controller acknowledges the mode change.
        try? await Task.sleep(for: .seconds(0.3))
        let didStart = await withCheckedContinuation { cont in
            fc.startLanding { error in
                if let error {
                    print("DJISDKBridge: landing error: \(error.localizedDescription)")
                    self.isVirtualStickControlSuspended = false
                    cont.resume(returning: false)
                } else {
                    cont.resume(returning: true)
                }
            }
        }
        return didStart
    }

    // MARK: - Camera Photo Capture

    /// Take a single still photo. Switches the camera into shoot-photo mode,
    /// fires the shutter, and resumes. Live H264 feed keeps running.
    @discardableResult
    func capturePhoto() async -> Bool {
        guard let camera = (DJISDKManager.product() as? DJIAircraft)?.camera else {
            print("DJISDKBridge: capturePhoto — no camera.")
            return false
        }
        // 1) Ensure shoot-photo mode with one retry.
        var modeOK = await setCameraMode(camera, mode: .shootPhoto)
        if !modeOK {
            try? await Task.sleep(for: .seconds(0.4))
            modeOK = await setCameraMode(camera, mode: .shootPhoto)
        }
        if modeOK { try? await Task.sleep(for: .seconds(0.5)) }

        // 2) Fire the shutter with one retry.
        var shotOK = await shootPhoto(camera)
        if !shotOK {
            try? await Task.sleep(for: .seconds(0.5))
            shotOK = await shootPhoto(camera)
        }

        // 3) Restore video mode so the live stream stays stable after snapshots.
        _ = await setCameraMode(camera, mode: .recordVideo)
        try? await Task.sleep(for: .seconds(0.4))

        // Give the camera a beat to store the photo and resume stable streaming.
        try? await Task.sleep(for: .seconds(0.8))
        print("DJISDKBridge: capturePhoto \(shotOK ? "ok" : "failed").")
        return shotOK
    }

    /// Photo op used by missions: grabs the live frame for UI display + camera
    /// roll, then fires the SDK shutter (full-res still goes to the drone's SD
    /// card as usual).
    @discardableResult
    func capturePhotoAndSave() async -> Bool {
        // Snapshot the frame BEFORE the mode switch — the live feed can hiccup
        // while the camera flips into shoot-photo mode.
        let frame = cameraFrame
        let ok = await capturePhoto()
        if let frame {
            await MainActor.run {
                self.lastCapturedPhoto = frame
                if ActionTuning.shared.photoSaveToCameraRoll {
                    UIImageWriteToSavedPhotosAlbum(frame, nil, nil, nil)
                }
            }
        }
        return ok
    }

    // MARK: - Hotpoint Orbit (SDK POI mission)

    /// Start an SDK-native Hotpoint mission circling `center`.
    /// Virtual Stick is disabled for the duration (they are mutually
    /// exclusive); call `stopHotpointOrbit()` to end and restore VS.
    @discardableResult
    func startHotpointOrbit(center: GPSCoordinate,
                            radiusM: Double,
                            angularVelocityDps: Double,
                            clockwise: Bool = true) async -> Bool {
        guard let op = DJISDKManager.missionControl()?.hotpointMissionOperator() else {
            print("DJISDKBridge: hotpoint operator unavailable.")
            return false
        }
        let mission = DJIHotpointMission()
        mission.hotpoint = center.clLocationCoordinate2D
        mission.altitude = Float(max(5.0, telemetry.altitudeM))     // SDK minimum 5 m
        mission.radius = Float(max(5.0, radiusM))                   // SDK minimum 5 m
        mission.angularVelocity = Float(clockwise ? abs(angularVelocityDps)
                                                  : -abs(angularVelocityDps))
        mission.startPoint = .nearest
        mission.heading = .towardHotpoint

        await setVirtualStickEnabled(false)
        let ok: Bool = await withCheckedContinuation { cont in
            op.start(mission) { error in
                if let error {
                    print("DJISDKBridge: hotpoint start error: \(error.localizedDescription)")
                }
                cont.resume(returning: error == nil)
            }
        }
        if ok {
            isHotpointActive = true
        } else {
            await setVirtualStickEnabled(true)   // restore control path
        }
        return ok
    }

    /// Stop a running Hotpoint mission and re-enable Virtual Stick.
    func stopHotpointOrbit() async {
        guard isHotpointActive else { return }
        if let op = DJISDKManager.missionControl()?.hotpointMissionOperator() {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                op.stopMission { error in
                    if let error {
                        print("DJISDKBridge: hotpoint stop error: \(error.localizedDescription)")
                    }
                    cont.resume()
                }
            }
        }
        isHotpointActive = false
        await setVirtualStickEnabled(true)
    }

    // MARK: - Gimbal

    /// Rotate the gimbal to an absolute pitch angle (0 = level, -90 = straight down).
    func pointGimbal(pitchDeg: Double, durationS: Double = 0.5) {
        guard let gimbal = (DJISDKManager.product() as? DJIAircraft)?.gimbal else { return }
        let clamped = max(-90.0, min(15.0, pitchDeg))
        let rotation = DJIGimbalRotation(
            pitchValue: NSNumber(value: clamped),
            rollValue: nil,
            yawValue: nil,
            time: durationS,
            mode: .absoluteAngle,
            ignore: true
        )
        gimbal.rotate(with: rotation, completion: nil)
    }

    // MARK: - Dead-Man's Switch (spec §8)
    // If no fresh command arrives within 300 ms, hover automatically.

    private func resetDeadMan() {
        deadManTimer?.invalidate()
        // sendVelocity() can be called from any thread; always arm the
        // dead-man timer on the main run loop so it reliably fires.
        let timer = Timer(
            timeInterval: safety.deadManIntervalSec,
            repeats: false
        ) { [weak self] _ in
            self?.sendHover()
        }
        RunLoop.main.add(timer, forMode: .common)
        deadManTimer = timer
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

    @MainActor
    func requestVideoFeedRecovery() {
        liveFeedManager.recoverFromVideoStall()
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

    private func setCameraMode(_ camera: DJICamera, mode: DJICameraMode) async -> Bool {
        await withCheckedContinuation { cont in
            camera.setMode(mode) { error in
                if let error {
                    print("DJISDKBridge: setMode(\(mode.rawValue)) error: \(error.localizedDescription)")
                }
                cont.resume(returning: error == nil)
            }
        }
    }

    private func shootPhoto(_ camera: DJICamera) async -> Bool {
        await withCheckedContinuation { cont in
            camera.startShootPhoto { error in
                if let error {
                    print("DJISDKBridge: startShootPhoto error: \(error.localizedDescription)")
                }
                cont.resume(returning: error == nil)
            }
        }
    }

    func markVideoPacketReceived() {
        lastVideoPacketAt = Date()
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

    func recoverFromVideoStall() {
        guard isFeedRunning else { return }
        activeFeed?.remove(self)
        activeFeed?.add(self, with: nil)
        if let hostView = previewHostView {
            attachPreview(to: hostView)
        }
    }

    // MARK: - Preview lifecycle

    /// Point the previewer at `view`.  Starts the decoder on the first call;
    /// subsequent calls (e.g. after a tab switch) just update the render target.
    private func attachPreview(to view: UIView) {
        #if canImport(DJIWidget)
        DJIVideoPreviewer.instance()?.setView(view)
        if !previewerStarted {
            // Use VideoToolbox hardware H264 decode instead of FFmpeg software decode.
            // This eliminates the continuous "missing picture in access unit" / SEI-truncated
            // stderr spam from DJIWidget's bundled FFmpeg, reduces CPU usage, and lowers
            // decode latency. FFmpeg is still available as an internal fallback if hw decode
            // fails for a given frame format.
            DJIVideoPreviewer.instance()?.enableHardwareDecode = true
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
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.capturePreviewSnapshot() }
        }
        RunLoop.main.add(timer, forMode: .common)
        snapshotTimer = timer
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
            self?.bridge?.markVideoPacketReceived()
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
            isLandingConfirmationNeeded: state.isLandingConfirmationNeeded,
            currentLocation: currentLocation,
            homeLocation:   homeLocation,
            isVisionPositioningActive: state.isVisionPositioningSensorBeingUsed
        )
        Task { @MainActor [weak self] in
            self?.telemetry = snap
            self?.lastTelemetryAt = Date()
            if !state.isFlying {
                self?.isVirtualStickControlSuspended = false
            }
        }
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let djiTelemetryStalled = Notification.Name("DJITelemetryStalled")
}
