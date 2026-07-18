import Foundation
import Combine
import CoreLocation

/// Manages virtual stick commands, gimbal control, basic flight actions, and RC pairing.
///
/// Stick layout (Mode 2):
///   Left  X → Yaw   (rotate, deg/s)
///   Left  Y → Throttle (up/down, m/s)
///   Right X → Roll   (strafe, m/s)
///   Right Y → Pitch  (forward/back, m/s)
final class FlightControlManager: NSObject, ObservableObject {
    static let shared = FlightControlManager()

    // MARK: - Normalised stick values (-1 … 1) — bound directly to JoystickView
    @Published var leftX:  Float = 0   // Yaw
    @Published var leftY:  Float = 0   // Throttle
    @Published var rightX: Float = 0   // Roll
    @Published var rightY: Float = 0   // Pitch

    // MARK: - Speed settings (Double so SwiftUI Slider binds natively)
    // Limits matched to Mini 2 firmware 01.00.0500 hardware caps
    @Published var maxSpeed:    Double = 5.0   // m/s  pitch & roll  (0.5 – 10)
    @Published var maxVertical: Double = 3.0   // m/s  throttle      (0.5 – 4, Mini 2 max ascent 5, descent 3)
    @Published var maxYawRate:  Double = 80.0  // °/s  yaw           (10 – 100, Mini 2 max 100)
    let absoluteMaxSpeed:    Double = 10.0  // Mini 2 velocity mode hard cap
    let absoluteMaxVertical: Double = 4.0   // Mini 2 ascent hard cap
    let absoluteMaxYaw:      Double = 100.0 // Mini 2 yaw rate hard cap

    // MARK: - State
    @Published var isVirtualStickEnabled = false
    @Published var statusMessage = ""

    // MARK: - Private
    private var sendTimer: Timer?

    private var flightController: DJIFlightController? {
        (DJISDKManager.product() as? DJIAircraft)?.flightController
    }
    private var gimbal: DJIGimbal? {
        DJISDKManager.product()?.gimbal
    }
    private var remoteController: DJIRemoteController? {
        (DJISDKManager.product() as? DJIAircraft)?.remoteController
    }

    private override init() { super.init() }

    // MARK: - Connection helpers

    func startConnection() {
        DJISDKManager.startConnectionToProduct()
        statusMessage = "Connecting to product…"
    }

    func stopConnection() {
        DJISDKManager.stopConnectionToProduct()
        statusMessage = "Disconnected."
    }

    // MARK: - RC Pairing
    // Hold the RC pairing/link button for 3 s before calling this.

    func pairRemoteController(completion: @escaping (String) -> Void) {
        guard let rc = remoteController else {
            completion("No remote controller found. Ensure RC is connected via USB.")
            return
        }
        rc.startPairing(completion: { error in
            DispatchQueue.main.async {
                if let error = error {
                    completion("Pairing failed: \(error.localizedDescription)")
                } else {
                    completion("Pairing started — hold the RC Link button until the LED flashes.")
                }
            }
        })
    }

    // MARK: - Virtual Sticks

    func enableVirtualSticks(completion: @escaping (Error?) -> Void) {
        guard let fc = flightController else {
            completion(makeError("No flight controller connected."))
            return
        }
        // Body-frame velocity control: pitch = forward, roll = right
        fc.rollPitchControlMode      = .velocity
        fc.yawControlMode            = .angularVelocity
        fc.verticalControlMode       = .velocity
        fc.rollPitchCoordinateSystem = .body
        // Advanced mode reduces input latency on Mini 2 firmware 01.00.0500
        fc.isVirtualStickAdvancedModeEnabled = true

        fc.setVirtualStickModeEnabled(true, withCompletion: { [weak self] error in
            DispatchQueue.main.async {
                if error == nil {
                    self?.isVirtualStickEnabled = true
                    self?.startSendLoop()
                }
                completion(error)
            }
        })
    }

    func disableVirtualSticks(completion: @escaping (Error?) -> Void) {
        stopSendLoop()
        flightController?.setVirtualStickModeEnabled(false, withCompletion: { [weak self] error in
            DispatchQueue.main.async {
                if error == nil { self?.isVirtualStickEnabled = false }
                completion(error)
            }
        })
    }

    private func startSendLoop() {
        sendTimer?.invalidate()
        // DJI requires 5–25 Hz; 20 Hz (50 ms) is ideal
        sendTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.sendStickValues()
        }
    }

    private func stopSendLoop() {
        sendTimer?.invalidate()
        sendTimer = nil
        sendNeutral()
    }

    private func sendNeutral() {
        var data = DJIVirtualStickFlightControlData()
        data.pitch = 0; data.roll = 0; data.yaw = 0; data.verticalThrottle = 0
        flightController?.send(data, withCompletion: nil)
    }

    private func sendStickValues() {
        var data = DJIVirtualStickFlightControlData()
        // Clamp to Mini 2 hardware limits regardless of slider value
        data.pitch            = rightY * Float(min(maxSpeed,    absoluteMaxSpeed))
        data.roll             = rightX * Float(min(maxSpeed,    absoluteMaxSpeed))
        data.yaw              = leftX  * Float(min(maxYawRate,  absoluteMaxYaw))
        data.verticalThrottle = leftY  * Float(min(maxVertical, absoluteMaxVertical))
        flightController?.send(data, withCompletion: nil)
    }

    // MARK: - Flight Commands

    /// Takeoff using virtual sticks only — bypasses GPS requirement.
    /// Ramps throttle up over ~2 s then holds hover. Requires VS to already be enabled.
    /// Best for indoors / optical flow environments.
    func manualTakeoff(targetAltitude: Float = 1.2, completion: @escaping (Error?) -> Void) {
        guard let fc = flightController else {
            completion(makeError("No flight controller."))
            return
        }
        if !isVirtualStickEnabled {
            enableVirtualSticks { [weak self] error in
                if let error { completion(error); return }
                self?.rampThrottle(fc: fc, completion: completion)
            }
        } else {
            rampThrottle(fc: fc, completion: completion)
        }
    }

    // MARK: - Motor arm / disarm

    func armMotors(completion: @escaping (Error?) -> Void) {
        flightController?.turnOnMotors(completion: completion)
    }

    func disarmMotors(completion: @escaping (Error?) -> Void) {
        flightController?.turnOffMotors(completion: completion)
    }

    private func rampThrottle(fc: DJIFlightController, completion: @escaping (Error?) -> Void) {
        // 1. Attempt to arm motors — Mini 2 on 01.00.0500 may reject this
        // and auto-arm when VS throttle rises, so treat error as non-fatal.
        fc.turnOnMotors { [weak self] _ in
            guard let self else { return }

            // 2. Brief settle after arming (or after the rejected call)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.startSendLoop()

                // 3. Ramp throttle 0 → 0.7 over ~2 s (40 × 50 ms steps)
                let steps = 40
                var step  = 0
                Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] timer in
                    guard let self else { timer.invalidate(); return }
                    step += 1
                    self.leftY = min(0.7, Float(step) / Float(steps) * 0.7)
                    if step >= steps {
                        timer.invalidate()
                        // 4. Reduce to hover throttle and let optical flow stabilise
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                            self.leftY = 0
                            completion(nil)
                        }
                    }
                }
            }
        }
    }

    /// Land by slowly descending via virtual sticks, then disarming motors.
    /// Monitors altitude; cuts motors when < 0.4 m or after 20 s timeout.
    func vsLand(completion: @escaping (Error?) -> Void) {
        guard flightController != nil else {
            completion(makeError("No flight controller."))
            return
        }
        let doLand = { [weak self] in
            guard let self else { return }
            self.startSendLoop()
            self.leftY = -0.3   // slow descent ~0.9 m/s
            let start = Date()
            Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] timer in
                guard let self else { timer.invalidate(); return }
                let alt     = DroneState.shared.altitudeMeters
                let elapsed = Date().timeIntervalSince(start)
                if alt < 0.4 || elapsed > 20 {
                    timer.invalidate()
                    self.leftY = 0
                    self.stopSendLoop()
                    self.flightController?.turnOffMotors { error in
                        DispatchQueue.main.async {
                            self.isVirtualStickEnabled = false
                            completion(error)
                        }
                    }
                }
            }
        }
        if isVirtualStickEnabled {
            doLand()
        } else {
            enableVirtualSticks { error in
                if let error { completion(error); return }
                doLand()
            }
        }
    }

    func returnToHome(completion: @escaping (Error?) -> Void) {
        flightController?.startGoHome(completion: completion)
    }

    func cancelReturnToHome(completion: @escaping (Error?) -> Void) {
        flightController?.cancelGoHome(completion: completion)
    }

    /// Update the home point (used as RTH destination).
    func setHomeLocation(_ coordinate: CLLocationCoordinate2D, completion: @escaping (Error?) -> Void) {
        let loc = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        flightController?.setHomeLocation(loc, withCompletion: completion)
    }

    // MARK: - Gimbal
    // Mini 2 pitch range: -90° (nadir) to +20° (upward)

    func setGimbalPitch(_ degrees: Double) {
        let pitchNumber = NSNumber(value: degrees)
        let rotation = DJIGimbalRotation(
            pitchValue: pitchNumber,
            rollValue:  nil,  // don't change roll
            yawValue:   nil,  // don't change yaw
            time: 0.3,
            mode: .absoluteAngle,
            ignore: false
        )
        gimbal?.rotate(with: rotation, completion: nil)
    }

    // MARK: - Helpers

    private func makeError(_ message: String) -> NSError {
        NSError(domain: "FlightControlManager", code: -1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }
}
