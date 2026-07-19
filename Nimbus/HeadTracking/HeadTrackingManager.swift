// HeadTrackingManager.swift — Nimbus
// Streams AirPods head attitude via CMHeadphoneMotionManager.
// Spec §3 component 6.
//
// Connection model:
//   isAvailable   = AirPods with motion support are physically connected now
//   isTracking    = motion data is actively streaming
//   isCalibrated  = user has set a zero-reference pose
//
// Calibration: at session start pass the phone compass heading so that
// relative AirPods yaw is mapped to a true-north world frame.  During
// push-to-talk the attitude is frozen so the grounding image stays stable.

import CoreMotion
import Observation

/// NSObject inheritance is required to conform to CMHeadphoneMotionManagerDelegate
/// (which extends NSObjectProtocol).  @Observable still works fine.
@Observable
final class HeadTrackingManager: NSObject {

    // MARK: - Public state

    /// True when AirPods Pro / Max with head-motion support are physically connected.
    var isAvailable  = false
    /// True while device-motion data is streaming from the AirPods.
    var isTracking   = false
    var isCalibrated = false
    var currentAttitude = HeadAttitude.zero

    // MARK: - Private

    private let motionManager   = CMHeadphoneMotionManager()
    private var calibYawOffset  = 0.0
    private var compassNorthDeg = 0.0
    private var isFrozen        = false
    private var frozenAttitude: HeadAttitude?
    private let yawQuantizationStepDeg = 12.0

    // MARK: - Init

    override init() {
        super.init()
        // Wire delegate BEFORE startConnectionStatusUpdates so we don't miss
        // an already-connected device callback on the first run-loop turn.
        motionManager.delegate = self
        motionManager.startConnectionStatusUpdates()
        // Reflect initial state synchronously in case AirPods are already connected.
        isAvailable = motionManager.isDeviceMotionAvailable
    }

    // MARK: - Session

    /// Begin streaming motion data.  No-op if AirPods are not yet connected;
    /// call again from `headphoneMotionManagerDidConnect` when they arrive.
    func start(compassHeadingDeg: Double = 0) {
        guard motionManager.isDeviceMotionAvailable else {
            print("HeadTrackingManager: AirPods not connected — start() deferred.")
            return
        }
        compassNorthDeg = compassHeadingDeg
        motionManager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let self, let motion, !self.isFrozen else { return }
            // Auto-calibrate on the very first frame — no explicit calibrate() call needed.
            if !self.isCalibrated {
                self.calibYawOffset = motion.attitude.yaw * 180 / .pi
                self.isCalibrated   = true
                print("HeadTrackingManager: auto-calibrated on first frame.")
            }
            self.handleMotion(motion)
        }
        isTracking = true
        print("HeadTrackingManager: tracking started.")
    }

    func stop() {
        motionManager.stopDeviceMotionUpdates()
        isTracking   = false
        isCalibrated = false
        currentAttitude = .zero
        print("HeadTrackingManager: tracking stopped.")
    }

    // MARK: - Calibration

    /// Record the current raw sensor yaw as the zero reference.
    /// Call once after start(), ideally when the drone is in front of the user.
    func calibrate() {
        calibrate(toCompassHeadingDeg: compassNorthDeg)
    }

    /// Record the current raw sensor yaw as zero and remap world heading to a
    /// supplied compass heading anchor (typically the drone's current heading
    /// at alignment-release time).
    func calibrate(toCompassHeadingDeg headingDeg: Double) {
        guard let d = motionManager.deviceMotion else { return }
        compassNorthDeg = headingDeg
        calibYawOffset = d.attitude.yaw * 180 / .pi
        isCalibrated   = true
        print("HeadTrackingManager: calibrated. sensorOffset=\(calibYawOffset)° compass=\(compassNorthDeg)°")
    }

    // MARK: - Frame Lock (spec §5 step 2)

    /// Freeze the attitude snapshot so the grounding image stays stable during PTT.
    func freeze() {
        isFrozen       = true
        frozenAttitude = currentAttitude
    }

    /// Resume live attitude after command has been dispatched.
    func unfreeze() {
        isFrozen       = false
        frozenAttitude = nil
    }

    /// The attitude the Orchestrator should use for grounding / yaw commands.
    var effectiveAttitude: HeadAttitude {
        frozenAttitude ?? currentAttitude
    }

    // MARK: - Private

    private func handleMotion(_ motion: CMDeviceMotion) {
        let rawYaw   = motion.attitude.yaw * 180 / .pi
        // CMHeadphoneMotionManager uses CCW-positive yaw (right-hand rule).
        // Negate to match compass convention (CW-positive) used everywhere else.
        let relative = calibYawOffset - rawYaw
        let raw = (compassNorthDeg + relative).truncatingRemainder(dividingBy: 360)
        let worldYaw = raw < 0 ? raw + 360 : raw   // normalise to [0, 360)
        let quantizedYaw = quantizedHeading(worldYaw, stepDeg: yawQuantizationStepDeg)
        currentAttitude = HeadAttitude(
            yawDeg:   quantizedYaw,
            pitchDeg: motion.attitude.pitch * 180 / .pi,
            rollDeg:  motion.attitude.roll  * 180 / .pi
        )
    }

    private func quantizedHeading(_ headingDeg: Double, stepDeg: Double) -> Double {
        guard stepDeg > 0 else { return headingDeg }
        let snapped = (headingDeg / stepDeg).rounded() * stepDeg
        let normalized = snapped.truncatingRemainder(dividingBy: 360)
        return normalized >= 0 ? normalized : normalized + 360
    }
}

// MARK: - CMHeadphoneMotionManagerDelegate

extension HeadTrackingManager: CMHeadphoneMotionManagerDelegate {

    func headphoneMotionManagerDidConnect(_ manager: CMHeadphoneMotionManager) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isAvailable = true
            print("HeadTrackingManager: AirPods connected.")
            // Auto-resume tracking if it was running before disconnection.
            if !self.isTracking {
                self.start(compassHeadingDeg: self.compassNorthDeg)
            }
        }
    }

    func headphoneMotionManagerDidDisconnect(_ manager: CMHeadphoneMotionManager) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isAvailable    = false
            self.isTracking     = false
            self.isCalibrated   = false
            self.currentAttitude = .zero
            print("HeadTrackingManager: AirPods disconnected.")
        }
    }
}
