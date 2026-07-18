// MissionExecutor.swift — Nimbus
// Executes ordered NimbusSteps on Virtual Stick.
//
// Voice → STT → backend /voice_command → NimbusResponse → MissionExecutor.
// Each op maps onto a FlightBehaviors primitive or a DJISDKBridge action.
// Steps run strictly in order; the executor awaits each behavior's completion
// by polling FlightBehaviors.isExecuting (behaviors end via their own
// closed-loop completion conditions or timeouts).
//
// Cancellation: `cancel()` (user abort / new command) stops the active
// behavior and abandons the remaining steps.

import Foundation
import CoreGraphics

final class MissionExecutor {

    enum MissionResult {
        case completed
        case cancelled
        case failed(String)
    }

    private let bridge: DJISDKBridge
    private let behaviors: FlightBehaviors
    private let safety: SafetySupervisor
    private let log: (String) -> Void
    private let say: (String) -> Void

    private(set) var isRunning = false
    private var cancelRequested = false
    /// Op name of the step currently being executed (for UI).
    private(set) var currentOp: String?
    /// Called when an "abort" step fires; Orchestrator should resume overhead hold.
    var onAbortRequested: (() -> Void)?

    init(bridge: DJISDKBridge,
         behaviors: FlightBehaviors,
         safety: SafetySupervisor,
         log: @escaping (String) -> Void,
         say: @escaping (String) -> Void) {
        self.bridge = bridge
        self.behaviors = behaviors
        self.safety = safety
        self.log = log
        self.say = say
    }

    // MARK: - Public

    func cancel() {
        guard isRunning else { return }
        cancelRequested = true
        behaviors.stop()
        log("Mission cancelled.")
    }

    /// Execute all steps in order. Returns when the mission finishes,
    /// fails, or is cancelled.
    func run(steps: [NimbusStep]) async -> MissionResult {
        guard !isRunning else { return .failed("A mission is already running") }
        isRunning = true
        cancelRequested = false
        defer {
            isRunning = false
            currentOp = nil
        }

        for index in steps.indices {
            if cancelRequested { return .cancelled }
            var step = steps[index]
            step.id = index
            currentOp = step.op
            log("Step \(index): \(step.op)\(step.target.map { " → \($0)" } ?? "")")

            let ok = await execute(step: step)
            if cancelRequested { return .cancelled }
            if !ok {
                log("Step \(index) (\(step.op)) failed — aborting mission.")
                behaviors.stop()
                return .failed("Step \(step.op) failed")
            }
        }
        log("Mission complete (\(steps.count) steps).")
        return .completed
    }

    // MARK: - Step Dispatch

    private func execute(step: NimbusStep) async -> Bool {
        switch step.op {

        case "takeoff":
            if bridge.telemetry.isFlying { return true }
            let ok = await bridge.takeOff()
            if ok { await waitUntilFlying(timeout: 12) }
            return ok

        case "land":
            behaviors.stop()
            return await bridge.startLanding()

        case "fly_to":
            if let direction = step.direction {
                // Relative nudge: convert direction + distance to a timed velocity.
                let dist = step.distanceM ?? 0.5
                let speed: Float = 0.8
                let dur = dist / Double(speed)
                switch direction {
                case "forward": behaviors.timedVelocity(pitch:  speed, duration: dur)
                case "back":    behaviors.timedVelocity(pitch: -speed, duration: dur)
                case "left":    behaviors.timedVelocity(roll:  -speed, duration: dur)
                case "right":   behaviors.timedVelocity(roll:   speed, duration: dur)
                default:        behaviors.timedVelocity(pitch:  speed, duration: dur)
                }
                return await waitForBehavior(timeout: dur + 5)
            } else if step.found && step.box2d.count == 4 {
                let standoff = max(safety.minStandoffM,
                                   step.distanceM.map { $0 * 0.3 } ?? 3.0)
                behaviors.approach(box: step.box2d, standoffM: standoff, maxSeconds: 40)
                return await waitForBehavior(timeout: 45)
            } else {
                say("I can't see \(step.target ?? "that").")
                return true  // soft failure — don't abort the mission
            }

        case "change_altitude":
            let delta = step.deltaM ?? 0.5
            behaviors.changeAltitude(deltaM: delta)
            return await waitForBehavior(timeout: 20)

        case "rotate":
            let deg = step.degrees ?? 90
            let signed = step.direction == "left" ? -deg : deg
            behaviors.rotateBy(yawDeg: signed)
            return await waitForBehavior(timeout: 30)

        case "orbit":
            if step.found && step.box2d.count == 4 {
                behaviors.approach(box: step.box2d, standoffM: 3, maxSeconds: 20)
                guard await waitForBehavior(timeout: 25) else { return false }
                if cancelRequested { return false }
            }
            let revs = step.revolutions ?? 1.0
            let orbitDur = revs * 18.0
            behaviors.orbit(radiusM: 5, durationSec: orbitDur)
            return await waitForBehavior(timeout: orbitDur + 8)

        case "hover":
            let dur = step.seconds ?? 5.0
            behaviors.stop()
            try? await Task.sleep(for: .seconds(dur))
            return true

        case "look_at":
            if step.found && step.box2d.count == 4 {
                pointGimbalAt(box: step.box2d)
            } else {
                bridge.pointGimbal(pitchDeg: -30)
            }
            try? await Task.sleep(for: .seconds(1.0))
            return true

        case "photo":
            behaviors.stop()
            try? await Task.sleep(for: .seconds(0.6))
            return await bridge.capturePhoto()

        case "selfie":
            return await runSelfie(step: step)

        case "panorama":
            return await runPanorama()

        case "follow":
            let dur = step.seconds ?? 30.0
            let seed = step.found && step.box2d.count == 4 ? visionRect(from: step.box2d) : nil
            behaviors.followPerson(maxSeconds: dur, overheadMode: false, seedBox: seed)
            return await waitForBehavior(timeout: dur + 8)

        case "return":
            behaviors.followPerson(maxSeconds: 60, overheadMode: true)
            return await waitForBehavior(timeout: 65)

        case "abort":
            behaviors.stop()
            cancelRequested = true
            Task { @MainActor in self.onAbortRequested?() }
            return true

        case "say":
            if let t = step.text { say(t) }
            return true

        default:
            log("Unknown op '\(step.op)' — skipping.")
            return true
        }
    }

    // MARK: - Composite Behaviors

    /// Selfie: aim the camera at the operator, back away + climb for a wide
    /// framing, settle, then shoot.
    private func runSelfie(step: NimbusStep) async -> Bool {
        // 1) Aim gimbal at the person (grounded box if available, else slightly down).
        if step.found && step.box2d.count == 4 {
            pointGimbalAt(box: step.box2d)
        } else if let frame = bridge.cameraFrame?.cgImage,
                  let person = FlightBehaviors.detectPersonBox(in: frame) {
            // Vision Y is bottom-left; convert center to a gimbal pitch hint.
            let pitch = -20.0 - (0.5 - Double(person.midY)) * 40.0
            bridge.pointGimbal(pitchDeg: pitch)
        } else {
            bridge.pointGimbal(pitchDeg: -25)
        }
        try? await Task.sleep(for: .seconds(1.0))
        if cancelRequested { return false }

        // 2) Back away and climb a little for the classic dronie framing.
        behaviors.timedVelocity(pitch: -1.2, throttle: 0.5, duration: 3.0)
        guard await waitForBehavior(timeout: 8) else { return false }
        if cancelRequested { return false }

        // 3) Re-aim at the person and shoot.
        if let frame = bridge.cameraFrame?.cgImage,
           let person = FlightBehaviors.detectPersonBox(in: frame) {
            let pitch = -20.0 - (0.5 - Double(person.midY)) * 40.0
            bridge.pointGimbal(pitchDeg: pitch)
        }
        try? await Task.sleep(for: .seconds(1.2))
        return await bridge.capturePhoto()
    }

    /// 360° panorama: level the gimbal, then 4 × (rotate 90° + photo).
    private func runPanorama() async -> Bool {
        bridge.pointGimbal(pitchDeg: -10)
        try? await Task.sleep(for: .seconds(1.0))
        for i in 0..<4 {
            if cancelRequested { return false }
            _ = await bridge.capturePhoto()
            if i < 3 {
                behaviors.rotateBy(yawDeg: 90)
                guard await waitForBehavior(timeout: 20) else { return false }
            }
        }
        // Face the original heading again.
        behaviors.rotateBy(yawDeg: 90)
        return await waitForBehavior(timeout: 20)
    }

    // MARK: - Helpers

    /// Point the gimbal so the box center moves toward the frame center
    /// (pitch only — yaw is handled by rotating the aircraft).
    private func pointGimbalAt(box: [Int]) {
        guard box.count == 4 else { return }
        let yCenter = Double(box[0] + box[2]) / 2.0 / 1000.0   // 0 top … 1 bottom
        // Map image-vertical position to a pitch between 0 (top) and -60 (bottom).
        let pitch = -Double(yCenter) * 60.0
        bridge.pointGimbal(pitchDeg: pitch)
    }

    private func visionRect(from box: [Int]) -> CGRect? {
        guard box.count == 4 else { return nil }
        let xMin = CGFloat(box[1]) / 1000
        let yMin = 1.0 - CGFloat(box[2]) / 1000
        let w = CGFloat(box[3] - box[1]) / 1000
        let h = CGFloat(box[2] - box[0]) / 1000
        return CGRect(x: xMin, y: yMin, width: w, height: h)
    }

    /// Await the active FlightBehaviors loop reaching its completion condition.
    private func waitForBehavior(timeout: Double) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        // Give the behavior a tick to start.
        try? await Task.sleep(for: .seconds(0.3))
        while behaviors.isExecuting {
            if cancelRequested { return false }
            if Date() > deadline {
                behaviors.stop()
                log("Behavior timed out after \(Int(timeout))s.")
                return false
            }
            try? await Task.sleep(for: .seconds(0.1))
        }
        return !cancelRequested
    }

    private func waitUntilFlying(timeout: Double) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !bridge.telemetry.isFlying && Date() < deadline {
            try? await Task.sleep(for: .seconds(0.25))
        }
        // Let the auto-takeoff climb finish.
        try? await Task.sleep(for: .seconds(1.5))
    }
}
