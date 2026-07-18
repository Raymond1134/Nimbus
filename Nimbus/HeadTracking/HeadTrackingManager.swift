// HeadTrackingManager.swift — Nimbus
// Streams AirPods head attitude via CMHeadphoneMotionManager.
// Spec §3 component 6.
//
// Calibration: at session start pass the phone compass heading so that
// relative AirPods yaw is mapped to a true-north world frame.  During
// push-to-talk the attitude is frozen so the grounding image stays stable.

import CoreMotion

@Observable
final class HeadTrackingManager {

    var currentAttitude = HeadAttitude.zero
    var isAvailable    = false
    var isCalibrated   = false

    private let motionManager    = CMHeadphoneMotionManager()
    private var calibYawOffset   = 0.0  // sensor raw yaw at calibration
    private var compassNorthDeg  = 0.0  // phone compass heading at calibration

    private var isFrozen         = false
    private var frozenAttitude: HeadAttitude?

    // MARK: - Session

    /// Start head tracking. `compassHeadingDeg` is from `CLLocationManager`
    /// (or 0 if unavailable — tracking still works but without true-north mapping).
    func start(compassHeadingDeg: Double = 0) {
        guard motionManager.isDeviceMotionAvailable else {
            print("HeadTrackingManager: CMHeadphoneMotionManager not available (AirPods not connected?).")
            isAvailable = false
            return
        }
        compassNorthDeg = compassHeadingDeg
        isAvailable     = true

        motionManager.startDeviceMotionUpdates(to: .main) { [weak self] motion, error in
            guard let self, let motion, !self.isFrozen else { return }
            self.handleMotion(motion)
        }
    }

    func stop() {
        motionManager.stopDeviceMotionUpdates()
        isAvailable  = false
        isCalibrated = false
    }

    // MARK: - Calibration

    /// Record the current raw sensor yaw as the zero reference.
    /// Should be called once after start(), ideally when the drone is in front of the user.
    func calibrate() {
        guard let d = motionManager.deviceMotion else { return }
        calibYawOffset = d.attitude.yaw * 180 / .pi
        isCalibrated   = true
        print("HeadTrackingManager: calibrated. sensorOffset=\(calibYawOffset)° compass=\(compassNorthDeg)°")
    }

    // MARK: - Frame Lock (spec §5 step 2)

    /// Freeze the yaw-follow so the drone holds its view while the user speaks.
    func freeze() {
        isFrozen       = true
        frozenAttitude = currentAttitude
    }

    /// Resume yaw-follow after command has been dispatched.
    func unfreeze() {
        isFrozen       = false
        frozenAttitude = nil
    }

    /// The attitude value the Orchestrator should use for drone yaw commands.
    var effectiveAttitude: HeadAttitude {
        frozenAttitude ?? currentAttitude
    }

    // MARK: - Private

    private func handleMotion(_ motion: CMDeviceMotion) {
        let rawYaw     = motion.attitude.yaw * 180 / .pi
        let relative   = rawYaw - calibYawOffset
        let worldYaw   = (compassNorthDeg + relative).truncatingRemainder(dividingBy: 360)
        currentAttitude = HeadAttitude(
            yawDeg:   worldYaw,
            pitchDeg: motion.attitude.pitch * 180 / .pi,
            rollDeg:  motion.attitude.roll  * 180 / .pi
        )
    }
}
