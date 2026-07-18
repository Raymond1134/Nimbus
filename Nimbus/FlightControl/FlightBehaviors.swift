// FlightBehaviors.swift — Nimbus
// Closed-loop Virtual Stick flight behavior library. Spec §3 component 8.
//
// All behaviors run at 10 Hz via a Timer.  Every sendVelocity() call goes
// through SafetySupervisor clamp inside DJISDKBridge.

import Foundation

final class FlightBehaviors {

    let bridge: DJISDKBridge
    let safety: SafetySupervisor

    private var behaviorTimer: Timer?
    private var activeMode = Mode.none

    private(set) var isExecuting = false

    /// Fires on the main actor when a behavior reaches its completion condition.
    var onBehaviorComplete: (() -> Void)?

    // Per-behavior state
    private var approachBox      = [Int]()
    private var approachStandoff = 3.0
    private var approachMaxSec   = 45.0
    private var approachStart    = Date.distantPast

    private var orbitAngDps  = 12.0   // degrees/second
    private var orbitMaxSec  = 30.0
    private var orbitStart   = Date.distantPast

    enum Mode { case none, approach, orbit, hover }

    init(bridge: DJISDKBridge, safety: SafetySupervisor) {
        self.bridge  = bridge
        self.safety  = safety
    }

    // MARK: - Public Commands

    /// Visual-servoing approach toward the grounding bbox until standoff reached.
    func approach(box: [Int], standoffM: Double = 3.0, maxSeconds: Double = 45.0) {
        approachBox      = box
        approachStandoff = standoffM
        approachMaxSec   = maxSeconds
        approachStart    = Date()
        startTimer(mode: .approach)
    }

    /// Fly in a horizontal circle (CW). One full orbit in `durationSec` seconds.
    func orbit(radiusM: Double = 5.0, durationSec: Double = 30.0) {
        orbitAngDps  = 360.0 / durationSec
        orbitMaxSec  = durationSec
        orbitStart   = Date()
        startTimer(mode: .orbit)
    }

    func hover() {
        stopBehavior()
        bridge.sendHover()
    }

    func stop() {
        stopBehavior()
        bridge.sendHover()
    }

    func land() {
        stopBehavior()
        guard let aircraft = DJISDKManager.product() as? DJIAircraft else { return }
        aircraft.flightController?.startLanding(completion: nil)
    }

    func returnToHome() {
        stopBehavior()
        guard let aircraft = DJISDKManager.product() as? DJIAircraft else { return }
        aircraft.flightController?.startGoHome(completion: nil)
    }

    // MARK: - Control Loop

    private func startTimer(mode: Mode) {
        stopBehavior()
        activeMode  = mode
        isExecuting = true
        behaviorTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    private func stopBehavior() {
        behaviorTimer?.invalidate()
        behaviorTimer = nil
        activeMode    = .none
        isExecuting   = false
    }

    private func tick() {
        switch activeMode {
        case .approach: tickApproach()
        case .orbit:    tickOrbit()
        case .hover:    bridge.sendHover()
        case .none:     break
        }
    }

    // MARK: - Approach (visual servo)
    //
    // Drives toward the target using bbox area as a distance proxy and
    // bbox center as a lateral error signal.
    //
    // box is [ymin, xmin, ymax, xmax] in 0–1000 coordinates.

    private func tickApproach() {
        // Timeout
        if Date().timeIntervalSince(approachStart) > approachMaxSec {
            stopBehavior()
            Task { @MainActor [weak self] in self?.onBehaviorComplete?() }
            return
        }

        guard approachBox.count == 4 else { bridge.sendHover(); return }

        let ymin = Double(approachBox[0]);  let xmin = Double(approachBox[1])
        let ymax = Double(approachBox[2]);  let xmax = Double(approachBox[3])

        let xCenter  = (xmin + xmax) / 2        // 500 = horizontally centred
        let yCenter  = (ymin + ymax) / 2        // 500 = vertically centred
        let bboxArea = (xmax - xmin) * (ymax - ymin) / 1_000_000   // 0..1

        // Target bbox area ≈ 4 % of image ≈ 3 m standoff (tune to taste)
        let targetArea = 0.04
        let areaErr    = targetArea - bboxArea           // + = too far, – = too close
        let latErr     = (xCenter - 500) / 500          // –1..+1 (+ = right)
        let vertErr    = (yCenter - 500) / 500          // –1..+1 (+ = below centre)

        // Reached standoff?
        if abs(areaErr) < 0.005 {
            stopBehavior()
            Task { @MainActor [weak self] in self?.onBehaviorComplete?() }
            return
        }

        // P-controllers (gains tunable)
        let kFwd: Double = 2.5   // m/s per unit area error
        let kYaw: Double = 30.0  // deg/s per unit lateral error
        let kVert: Double = 1.0

        let fwd      = Float(areaErr  * kFwd)
        let yawRate  = Float(latErr   * kYaw)
        let throttle = Float(-vertErr * kVert)

        bridge.sendVelocity(pitch: fwd, roll: 0, yaw: yawRate, throttle: throttle)
    }

    // MARK: - Orbit (constant yaw + lateral roll)

    private func tickOrbit() {
        if Date().timeIntervalSince(orbitStart) > orbitMaxSec {
            stopBehavior()
            Task { @MainActor [weak self] in self?.onBehaviorComplete?() }
            return
        }
        // Constant yaw + slight roll to maintain circular path
        bridge.sendVelocity(pitch: 0, roll: 1.0, yaw: Float(orbitAngDps), throttle: 0)
    }
}
