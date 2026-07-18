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
    @Published var maxSpeed:   Double = 5.0   // m/s  pitch & roll  (0.5 – 10)
    @Published var maxVertical: Double = 3.0  // m/s  throttle      (0.5 – 4)
    @Published var maxYawRate:  Double = 80.0 // °/s  yaw           (10 – 100)

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
        fc.rollPitchControlMode    = .velocity
        fc.yawControlMode          = .angularVelocity
        fc.verticalControlMode     = .velocity
        fc.rollPitchCoordinateSystem = .body

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
        data.pitch           = rightY  * Float(maxSpeed)    // forward/back
        data.roll            = rightX  * Float(maxSpeed)    // left/right
        data.yaw             = leftX   * Float(maxYawRate)  // rotate
        data.verticalThrottle = leftY  * Float(maxVertical) // up/down
        flightController?.send(data, withCompletion: nil)
    }

    // MARK: - Flight Commands

    func takeOff(completion: @escaping (Error?) -> Void) {
        flightController?.startTakeoff(completion: completion)
    }

    func land(completion: @escaping (Error?) -> Void) {
        flightController?.startLanding(completion: completion)
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
