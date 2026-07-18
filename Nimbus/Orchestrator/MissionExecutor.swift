// MissionExecutor.swift — Nimbus
// Executes a Gemini MissionPlan (ordered InstructionSteps) on Virtual Stick.
//
// Voice → STT → backend /voice_command → MissionPlan → MissionExecutor.
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
    /// Step currently being executed (for UI).
    private(set) var currentStep: InstructionStep?

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
    func run(plan: MissionPlan) async -> MissionResult {
        guard !isRunning else { return .failed("A mission is already running") }
        isRunning = true
        cancelRequested = false
        defer {
            isRunning = false
            currentStep = nil
        }

        if plan.blocked {
            log("Plan blocked: \(plan.blockReason)")
            say("I can't see that from here.")
            return .failed(plan.blockReason)
        }

        for step in plan.steps {
            if cancelRequested { return .cancelled }
            currentStep = step
            log("Step \(step.id): \(step.op)\(step.target.map { " → \($0)" } ?? "")")

            let ok = await execute(step: step)
            if cancelRequested { return .cancelled }
            if !ok {
                log("Step \(step.id) (\(step.op)) failed — aborting mission.")
                behaviors.stop()
                return .failed("Step \(step.op) failed")
            }
        }
        log("Mission complete (\(plan.steps.count) steps).")
        return .completed
    }

    // MARK: - Step Dispatch

    private func execute(step: InstructionStep) async -> Bool {
        var step = step

        // Re-ground against a fresh frame when the planner deferred grounding.
        if step.needsGrounding, requiresBox(step.op) {
            step = await reground(step) ?? step
            if step.needsGrounding || step.box2d.isEmpty {
                log("Target '\(step.target ?? "?")' not found in frame.")
                say("I can't find \(step.target ?? "that").")
                return false
            }
        }

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
            // "return" objective → go back overhead of the operator.
            if step.notes.contains("return_home") || step.target == "operator" {
                return await returnOverhead()
            }
            if step.box2d.count == 4 {
                behaviors.approach(box: step.box2d,
                                   standoffM: max(safety.minStandoffM, step.standoffM),
                                   maxSeconds: 45)
                return await waitForBehavior(timeout: 50)
            }
            // No visual target: relative move (direction + distance).
            let dist = step.distanceM ?? 3.0
            let speed: Float = 1.0
            let dur = min(10.0, dist / Double(speed))
            switch step.direction {
            case "back":  behaviors.timedVelocity(pitch: -speed, duration: dur)
            case "left":  behaviors.timedVelocity(roll: -speed, duration: dur)
            case "right": behaviors.timedVelocity(roll: speed, duration: dur)
            default:      behaviors.timedVelocity(pitch: speed, duration: dur)
            }
            return await waitForBehavior(timeout: dur + 5)

        case "fly_above":
            if step.box2d.count == 4 {
                behaviors.approach(box: step.box2d,
                                   standoffM: max(safety.minStandoffM, step.standoffM),
                                   maxSeconds: 40)
                guard await waitForBehavior(timeout: 45) else { return false }
                if cancelRequested { return false }
            }
            // Climb and look straight down over the target.
            behaviors.changeAltitude(deltaM: 3.0)
            bridge.pointGimbal(pitchDeg: -85)
            return await waitForBehavior(timeout: 25)

        case "fly_higher":
            behaviors.changeAltitude(deltaM: abs(step.altitudeDeltaM ?? 2.0))
            return await waitForBehavior(timeout: 25)

        case "fly_lower":
            behaviors.changeAltitude(deltaM: -abs(step.altitudeDeltaM ?? 2.0))
            return await waitForBehavior(timeout: 25)

        case "rotate":
            var deg = step.yawDeg ?? 90
            if deg == 0 { deg = step.direction == "left" ? -90 : 90 }
            behaviors.rotateBy(yawDeg: deg)
            return await waitForBehavior(timeout: 35)

        case "orbit":
            // Face the target first when we have a box, then circle.
            let revs = max(0.5, step.revolutions ?? 1.0)
            let secondsPerRev = 18.0
            behaviors.orbit(radiusM: step.radiusM ?? 5.0,
                            durationSec: step.durationS ?? (revs * secondsPerRev))
            return await waitForBehavior(timeout: (step.durationS ?? revs * secondsPerRev) + 8)

        case "hover":
            let dur = step.durationS ?? 5.0
            behaviors.stop()
            try? await Task.sleep(for: .seconds(dur))
            return true

        case "look_at":
            if step.box2d.count == 4 {
                pointGimbalAt(box: step.box2d)
            } else {
                bridge.pointGimbal(pitchDeg: step.gimbalPitchDeg ?? -30)
            }
            try? await Task.sleep(for: .seconds(1.0))
            return true

        case "photo":
            behaviors.stop()
            try? await Task.sleep(for: .seconds(0.8))   // settle for a sharp shot
            return await bridge.capturePhoto()

        case "selfie":
            return await runSelfie(step: step)

        case "panorama":
            return await runPanorama()

        case "follow":
            let seed = step.box2d.count == 4 ? visionRect(from: step.box2d) : nil
            behaviors.followPerson(maxSeconds: step.durationS ?? 10.0,
                                   overheadMode: false,
                                   seedBox: seed)
            return await waitForBehavior(timeout: (step.durationS ?? 10.0) + 8)

        case "abort":
            behaviors.stop()
            cancelRequested = true
            return true

        case "say":
            if let text = step.text { say(text) }
            return true

        default:
            log("Unknown op '\(step.op)' — skipping.")
            return true
        }
    }

    // MARK: - Composite Behaviors

    /// Selfie: aim the camera at the operator, back away + climb for a wide
    /// framing, settle, then shoot.
    private func runSelfie(step: InstructionStep) async -> Bool {
        // 1) Aim gimbal at the person (grounded box if available, else slightly down).
        if step.box2d.count == 4 {
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

    /// Return to the operator: re-acquire the person and settle overhead.
    /// Runs the overhead-follow controller briefly, which climbs/centers the
    /// drone above the operator's head, then hands control back.
    private func returnOverhead() async -> Bool {
        bridge.pointGimbal(pitchDeg: -85)
        behaviors.followPerson(maxSeconds: 12.0, overheadMode: true)
        return await waitForBehavior(timeout: 18)
    }

    // MARK: - Helpers

    private func requiresBox(_ op: String) -> Bool {
        ["fly_to", "fly_above", "orbit", "look_at", "follow"].contains(op)
    }

    /// Ask the backend to re-ground a step against a fresh frame.
    private func reground(_ step: InstructionStep) async -> InstructionStep? {
        // "operator"/return steps never need backend grounding.
        if step.notes.contains("return_home") || step.target == "operator" { return step }
        log("Re-grounding '\(step.target ?? "?")' against fresh frame…")
        let frame = bridge.captureFrameJPEG()
        return try? await BackendClient.resolveStep(step: step, imageData: frame)
    }

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
