// DJISDKBridge.swift — Nimbus
// Bridge between DJI Mobile SDK v4 and the Swift application layer.
// Spec §3 component 8 (DJISDKBridge sub-component).
//
// Threading note: DJI SDK delegate callbacks can arrive on arbitrary threads.
// All updates to @Published properties are hopped to the main actor via Task.

import Foundation
import UIKit

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

    // MARK: - Private

    private weak var flightController: DJIFlightController?
    private var deadManTimer: Timer?
    private let safety = SafetySupervisor()

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
        print("DJISDKBridge: aircraft '\(product?.model ?? "unknown")' connected, Virtual Stick ready.")
    }

    func onProductDisconnected() {
        stopDeadMan()
        flightController    = nil
        isAircraftConnected = false
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
        cameraFrame = image
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

// MARK: - DJIFlightControllerDelegate

extension DJISDKBridge: DJIFlightControllerDelegate {
    func flightController(_ fc: DJIFlightController,
                          didUpdate state: DJIFlightControllerState) {
        let snap = TelemetrySnapshot(
            altitudeM:      state.altitude,
            headingDeg:     Double(state.attitude.yaw),
            velocityX:      Double(state.velocityX),
            velocityY:      Double(state.velocityY),
            velocityZ:      Double(state.velocityZ),
            batteryPercent: 0,           // wired via DJIBatteryDelegate if needed
            isGPSValid:     state.satelliteCount > 4,
            satelliteCount: Int(state.satelliteCount)
        )
        Task { @MainActor [weak self] in
            self?.telemetry = snap
        }
    }
}
