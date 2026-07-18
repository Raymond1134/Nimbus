import CoreMotion
import Combine
import Foundation

/// Translates AirPods head orientation into drone flight and gimbal commands.
///
/// Coordinate system (degrees after calibration):
///   pitch  +  → chin up       (nod yes)
///   pitch  −  → chin down
///   yaw    +  → head right    (shake no)
///   yaw    −  → head left
///   roll   +  → right ear down (head tilt)
///   roll   −  → left ear down
///
/// Supported: AirPods Pro (1st/2nd gen), AirPods 3rd gen, AirPods Max
@available(iOS 14.0, *)
final class HeadTrackingManager: NSObject, ObservableObject {
    static let shared = HeadTrackingManager()

    // MARK: - Status
    @Published var isAvailable  = false
    @Published var isConnected  = false
    @Published var isTracking   = false

    // MARK: - Raw head angles (degrees, absolute)
    @Published var headPitch: Double = 0
    @Published var headYaw:   Double = 0
    @Published var headRoll:  Double = 0

    // MARK: - Relative angles after alignment (degrees)
    @Published var relPitch: Double = 0
    @Published var relYaw:   Double = 0
    @Published var relRoll:  Double = 0

    // MARK: - Axis routing
    /// true  → head pitch tilts the gimbal camera
    /// false → head pitch flies the drone forward/back
    @Published var pitchToGimbal: Bool = true
    /// Whether head yaw rotates the drone
    @Published var yawToDrone: Bool = true
    /// Whether head roll strafes the drone (can feel unusual — off by default)
    @Published var rollToDrone: Bool = false

    // MARK: - Tuning
    /// Multiplier on all axes (0.25 – 2.0)
    @Published var sensitivity: Double = 1.0
    /// Angles (°) ignored around centre to filter head sway
    @Published var deadZoneDeg: Double = 4.0
    /// Head pitch range (°) that maps to ±full drone speed or ±full gimbal range
    @Published var pitchMaxDeg: Double = 30.0
    /// Head yaw range (°) that maps to ±full drone yaw rate
    @Published var yawMaxDeg:   Double = 45.0

    // MARK: - Private
    private let motionManager = CMHeadphoneMotionManager()
    private let updateQueue   = OperationQueue()

    /// Calibration reference — set via align()
    private var refPitch: Double = 0
    private var refYaw:   Double = 0
    private var refRoll:  Double = 0

    /// Throttle gimbal updates (gimbal doesn't need 50 Hz)
    private var lastGimbalSend: Date = .distantPast

    /// Authorization status for headphone motion
    @Published var authStatus: String = "Unknown"

    private override init() {
        super.init()
        updateQueue.name = "com.nimbus.headtracking"
        updateQueue.maxConcurrentOperationCount = 1
        isAvailable = motionManager.isDeviceMotionAvailable
        motionManager.delegate = self
        // Must call this separately to receive connect/disconnect delegate callbacks
        motionManager.startConnectionStatusUpdates()
        refreshAuthStatus()
    }

    private func refreshAuthStatus() {
        switch CMHeadphoneMotionManager.authorizationStatus() {
        case .authorized:            authStatus = "Authorized"
        case .denied:                authStatus = "Denied — enable in Settings → Privacy → Motion"
        case .restricted:            authStatus = "Restricted"
        case .notDetermined:         authStatus = "Not yet requested"
        @unknown default:            authStatus = "Unknown"
        }
    }

    // MARK: - Start / Stop

    func startTracking() {
        guard isAvailable else { return }
        refreshAuthStatus()
        motionManager.startDeviceMotionUpdates(to: updateQueue) { [weak self] motion, error in
            guard let self else { return }
            if let motion {
                // Infer connection from data arriving — covers models that
                // don't trigger headphoneMotionManagerDidConnect (e.g. AirPods 4 ANC)
                if !self.isConnected {
                    DispatchQueue.main.async { self.isConnected = true }
                }
                self.handleMotion(motion)
            }
        }
        DispatchQueue.main.async { self.isTracking = true }
    }

    func stopTracking() {
        motionManager.stopDeviceMotionUpdates()
        DispatchQueue.main.async {
            self.isTracking = false
            // Zero out sticks so drone hovers
            let fc = FlightControlManager.shared
            fc.leftX  = 0
            fc.rightX = 0
            fc.rightY = 0
        }
    }

    // MARK: - Alignment
    /// Call this while holding your head in the desired neutral orientation.
    /// All subsequent motion is measured relative to this snapshot.
    func align() {
        refPitch = headPitch
        refYaw   = headYaw
        refRoll  = headRoll
        // Reset relative values immediately so the UI snaps to zero
        DispatchQueue.main.async {
            self.relPitch = 0
            self.relYaw   = 0
            self.relRoll  = 0
        }
    }

    // MARK: - Motion handling

    private func handleMotion(_ motion: CMDeviceMotion) {
        let toDeg  = 180.0 / Double.pi
        let pitch  = motion.attitude.pitch * toDeg
        let yaw    = motion.attitude.yaw   * toDeg
        let roll   = motion.attitude.roll  * toDeg

        // Compute relative angles
        var rp = pitch - refPitch
        var ry = yaw   - refYaw
        var rr = roll  - refRoll

        // Wrap yaw to –180…+180
        if ry >  180 { ry -= 360 }
        if ry < -180 { ry += 360 }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.headPitch = pitch
            self.headYaw   = yaw
            self.headRoll  = roll
            self.relPitch  = rp
            self.relYaw    = ry
            self.relRoll   = rr

            if self.isTracking {
                self.applyToDrone(rp: rp, ry: ry, rr: rr)
            }
        }
    }

    private func applyToDrone(rp: Double, ry: Double, rr: Double) {
        let fc = FlightControlManager.shared
        guard fc.isVirtualStickEnabled else { return }

        func deadZone(_ v: Double) -> Double {
            guard abs(v) > deadZoneDeg else { return 0 }
            return v - (v > 0 ? deadZoneDeg : -deadZoneDeg)
        }
        func norm(_ v: Double, fullScale: Double) -> Float {
            Float(Swift.max(-1, Swift.min(1, deadZone(v) / fullScale * sensitivity)))
        }

        // ── Yaw: head turns rotate the drone ───────────────────────────────
        if yawToDrone {
            fc.leftX = norm(ry, fullScale: yawMaxDeg)   // +yaw → drone rotates right
        }

        // ── Roll: head tilt strafes the drone ──────────────────────────────
        if rollToDrone {
            fc.rightX = norm(rr, fullScale: pitchMaxDeg) // +roll → strafe right
        }

        // ── Pitch: either fly or tilt gimbal ──────────────────────────────
        if pitchToGimbal {
            // Throttle to 10 Hz so we don't spam the gimbal
            let now = Date()
            guard now.timeIntervalSince(lastGimbalSend) > 0.1 else { return }
            lastGimbalSend = now
            // Nod down → camera looks down.  Nod up → camera looks up.
            // AirPods pitch + = chin up; gimbal pitch + = up, - = down.
            // Map head pitch ±pitchMaxDeg to gimbal ±90° (clamped to -90…+20)
            let scale   = 90.0 / pitchMaxDeg
            let gimbal  = max(-90, min(20, rp * scale * sensitivity))
            FlightControlManager.shared.setGimbalPitch(gimbal)
        } else {
            // Nod forward (chin down, rp < 0) → fly forward (drone pitch +)
            fc.rightY = norm(-rp, fullScale: pitchMaxDeg)
        }
    }

    private func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double {
        max(lo, min(hi, v))
    }
}

// MARK: - CMHeadphoneMotionManagerDelegate

@available(iOS 14.0, *)
extension HeadTrackingManager: CMHeadphoneMotionManagerDelegate {
    func headphoneMotionManagerDidConnect(_ manager: CMHeadphoneMotionManager) {
        DispatchQueue.main.async { self.isConnected = true }
    }

    func headphoneMotionManagerDidDisconnect(_ manager: CMHeadphoneMotionManager) {
        DispatchQueue.main.async {
            self.isConnected = false
            self.stopTracking()
        }
    }
}
