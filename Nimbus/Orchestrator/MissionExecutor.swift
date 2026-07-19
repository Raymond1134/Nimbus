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
    /// All per-action adjustable parameters live in ActionTuning.swift.
    private var tuning: ActionTuning { .shared }

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
        if bridge.isHotpointActive {
            Task { await bridge.stopHotpointOrbit() }
        }
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
                // Cardinal move relative to the USER's facing direction.
                return await runCardinalFlyTo(direction: direction,
                                              distanceM: step.distanceM)
            } else if step.found && step.box2d.count == 4 {
                // Visual approach: rotate to the bbox center, fly to it
                // horizontally + vertically, stop when the bbox gets too big
                // (see FlightBehaviors.tickApproach + ActionTuning fly_to).
                behaviors.approach(box: step.box2d,
                                   standoffM: safety.minStandoffM,
                                   maxSeconds: tuning.flyToMaxSeconds)
                return await waitForBehavior(timeout: tuning.flyToMaxSeconds + 5)
            } else {
                if looksLikePersonTarget(step.target),
                   let frame = bridge.cameraFrame?.cgImage,
                   let person = FlightBehaviors.detectPersonBox(in: frame) {
                    let localBox = [
                        Int((1.0 - person.maxY) * 1000.0),
                        Int(person.minX * 1000.0),
                        Int((1.0 - person.minY) * 1000.0),
                        Int(person.maxX * 1000.0),
                    ]
                    log("Gemini target missing; using onboard person detection fallback.")
                    behaviors.approach(box: localBox,
                                       standoffM: safety.minStandoffM,
                                       maxSeconds: tuning.flyToMaxSeconds)
                    return await waitForBehavior(timeout: tuning.flyToMaxSeconds + 5)
                }
                say("I can't see \(step.target ?? "that").")
                return true  // soft failure — don't abort the mission
            }

        case "change_altitude":
            let delta = step.deltaM ?? 0.5
            behaviors.changeAltitude(deltaM: delta, maxSeconds: tuning.altitudeMaxSeconds)
            return await waitForBehavior(timeout: tuning.altitudeMaxSeconds + 5)

        case "rotate":
            let deg = step.degrees ?? tuning.rotateDefaultDegrees
            let signed = step.direction == "left" ? -deg : deg
            behaviors.rotateBy(yawDeg: signed)
            return await waitForBehavior(timeout: 30)

        case "orbit":
            // fly_to leg first when a target is grounded, then circle it.
            if step.found && step.box2d.count == 4 {
                behaviors.approach(box: step.box2d,
                                   standoffM: tuning.orbitApproachStandoffM,
                                   maxSeconds: 20)
                guard await waitForBehavior(timeout: 25) else { return false }
                if cancelRequested { return false }
            }
            let revs = step.revolutions ?? tuning.orbitDefaultRevolutions
            return await runOrbit(revolutions: revs)

        case "hover":
            // Vanilla hover: zero-velocity Virtual Stick — the SDK's own
            // GPS/VIO position hold does the stabilizing.
            let dur = step.seconds ?? tuning.hoverDefaultSeconds
            behaviors.stop()
            try? await Task.sleep(for: .seconds(dur))
            return true

        case "look_at":
            if step.found && step.box2d.count == 4 {
                // Rotate the aircraft to face the bbox center horizontally…
                let xCenter = Double(step.box2d[1] + step.box2d[3]) / 2.0 / 1000.0
                let yawDelta = (xCenter - 0.5) * tuning.lookAtHorizontalFovDeg
                if abs(yawDelta) > tuning.rotateStopToleranceDeg {
                    behaviors.rotateBy(yawDeg: yawDelta)
                    guard await waitForBehavior(timeout: 15) else { return false }
                }
                // …then pitch the gimbal to center it vertically.
                pointGimbalAt(box: step.box2d)
            } else {
                bridge.pointGimbal(pitchDeg: -30)
            }
            try? await Task.sleep(for: .seconds(1.0))
            return true

        case "photo":
            // Point gimbal forward, shoot, display in UI + save to camera roll.
            behaviors.stop()
            bridge.pointGimbal(pitchDeg: tuning.photoGimbalPitchDeg)
            try? await Task.sleep(for: .seconds(tuning.photoSettleSeconds))
            return await bridge.capturePhotoAndSave()

        case "selfie":
            return await runSelfie()

        case "panorama":
            return await runPanorama()

        case "follow":
            // Fly up + gimbal down, chase the tracked box's near-center point
            // (top-down overhead mode; see FlightBehaviors.tickFollowPerson).
            let dur = step.seconds ?? tuning.followDefaultSeconds
            let seed = step.found && step.box2d.count == 4 ? visionRect(from: step.box2d) : nil
            behaviors.followPerson(maxSeconds: dur, overheadMode: true, seedBox: seed)
            return await waitForBehavior(timeout: dur + 8)

        case "return":
            // Fly back to the operator and settle overhead.
            behaviors.followPerson(maxSeconds: tuning.returnMaxSeconds, overheadMode: true)
            return await waitForBehavior(timeout: tuning.returnMaxSeconds + 5)

        case "abort":
            // Spec: stop everything and hold in place. (Orchestrator decides
            // whether to resume the overhead hold via ActionTuning.)
            if bridge.isHotpointActive {
                Task { await bridge.stopHotpointOrbit() }
            }
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

    /// Cardinal fly_to (spec): the direction is relative to the USER's facing
    /// direction from AirPods head tracking, not the drone's. E.g. user facing
    /// 110° CW, "fly left" → rotate the drone to 20°, then fly forward.
    private func runCardinalFlyTo(direction: String, distanceM: Double?) async -> Bool {
        let dist  = max(0.3, distanceM ?? tuning.flyToCardinalDefaultDistanceM)
        let speed = tuning.flyToCardinalSpeedMps
        let dur   = dist / Double(speed)

        let offsets: [String: Double] = ["forward": 0, "right": 90, "back": 180, "left": -90]
        let head = behaviors.headTracking
        if head.isTracking, let offset = offsets[direction] {
            let targetHeading = head.effectiveAttitude.yawDeg + offset
            log("Cardinal fly_to \(direction): user yaw \(Int(head.effectiveAttitude.yawDeg))° → heading \(Int(targetHeading))°.")
            behaviors.rotateToHeading(targetHeading)
            guard await waitForBehavior(timeout: 30) else { return false }
            if cancelRequested { return false }
            behaviors.timedVelocity(pitch: speed, duration: dur)
            return await waitForBehavior(timeout: dur + 5)
        }

        // Fallback (no AirPods heading): body-frame nudge.
        log("Cardinal fly_to \(direction): no head tracking — body-frame fallback.")
        switch direction {
        case "forward": behaviors.timedVelocity(pitch:  speed, duration: dur)
        case "back":    behaviors.timedVelocity(pitch: -speed, duration: dur)
        case "left":    behaviors.timedVelocity(roll:  -speed, duration: dur)
        case "right":   behaviors.timedVelocity(roll:   speed, duration: dur)
        default:        behaviors.timedVelocity(pitch:  speed, duration: dur)
        }
        return await waitForBehavior(timeout: dur + 5)
    }

    /// Orbit (spec): circle the target at a fixed radius. Prefers the DJI
    /// Hotpoint (POI) SDK mission — the aircraft flies the circle natively —
    /// and falls back to the Virtual-Stick circle when GPS/altitude rule it out.
    private func runOrbit(revolutions: Double) async -> Bool {
        let secondsPerRev = 360.0 / max(1.0, tuning.orbitAngularVelocityDps)
        let duration = max(1.0, revolutions * secondsPerRev)

        if tuning.orbitUseSDKHotpoint,
           bridge.telemetry.isGPSValid,
           let current = bridge.telemetry.currentLocation,
           bridge.telemetry.altitudeM >= 5.0 {
            // The point of interest sits directly ahead of the nose (we just
            // finished the fly_to leg facing the target).
            let center = projectedCoordinate(from: current,
                                             headingDeg: bridge.telemetry.headingDeg,
                                             distanceM: tuning.orbitRadiusM)
            if await bridge.startHotpointOrbit(center: center,
                                               radiusM: tuning.orbitRadiusM,
                                               angularVelocityDps: tuning.orbitAngularVelocityDps) {
                log("Orbit: SDK hotpoint mission, \(String(format: "%.1f", revolutions)) rev (~\(Int(duration))s).")
                let deadline = Date().addingTimeInterval(duration)
                while Date() < deadline && !cancelRequested {
                    try? await Task.sleep(for: .seconds(0.2))
                }
                await bridge.stopHotpointOrbit()
                return !cancelRequested
            }
            log("Orbit: hotpoint start failed — falling back to Virtual Stick.")
        } else {
            log("Orbit: hotpoint unavailable (GPS/altitude) — Virtual Stick orbit.")
        }

        behaviors.orbit(radiusM: tuning.orbitRadiusM,
                        angularVelocityDps: tuning.orbitAngularVelocityDps,
                        durationSec: duration)
        return await waitForBehavior(timeout: duration + 8)
    }

    /// Selfie (spec): fly forward past the operator, turn around 180°, point
    /// the gimbal forward, and shoot.
    private func runSelfie() async -> Bool {
        // 1) Fly forward.
        behaviors.timedVelocity(pitch: tuning.selfieForwardSpeedMps,
                                duration: tuning.selfieForwardSeconds)
        guard await waitForBehavior(timeout: tuning.selfieForwardSeconds + 5) else { return false }
        if cancelRequested { return false }

        // 2) Turn around.
        behaviors.rotateBy(yawDeg: 180)
        guard await waitForBehavior(timeout: 20) else { return false }
        if cancelRequested { return false }

        // 3) Gimbal forward, then center the detected person in frame.
        bridge.pointGimbal(pitchDeg: tuning.photoGimbalPitchDeg)
        try? await Task.sleep(for: .seconds(0.6))
        await centerPersonInFrame()
        if cancelRequested { return false }

        // 4) Settle, shoot (UI display + camera roll).
        try? await Task.sleep(for: .seconds(tuning.selfieSettleSeconds))
        return await bridge.capturePhotoAndSave()
    }

    /// Best-effort framing: yaw the aircraft until the detected person is
    /// horizontally centered, then trim gimbal pitch to center vertically.
    /// Soft-fails silently when no person is visible (the shot still fires).
    private func centerPersonInFrame(maxAttempts: Int = 4) async {
        for attempt in 0..<maxAttempts {
            if cancelRequested { return }
            guard let frame = bridge.cameraFrame?.cgImage,
                  let person = FlightBehaviors.detectPersonBox(in: frame) else {
                if attempt == 0 { log("Centering: no person detected yet — waiting.") }
                try? await Task.sleep(for: .seconds(0.5))
                continue
            }

            // Horizontal: rotate the aircraft toward the person.
            let yawDelta = (Double(person.midX) - 0.5) * tuning.lookAtHorizontalFovDeg
            if abs(yawDelta) > tuning.rotateStopToleranceDeg {
                log("Centering: person at x=\(String(format: "%.2f", person.midX)) — yaw \(Int(yawDelta))°.")
                behaviors.rotateBy(yawDeg: yawDelta)
                guard await waitForBehavior(timeout: 10) else { return }
                continue   // re-detect after the turn
            }

            // Vertical: gimbal pitch offset from level.
            // Vision Y origin is bottom-left, so midY < 0.5 = person low in frame.
            let vertErr = 0.5 - Double(person.midY)       // + = person below center
            let pitch = tuning.photoGimbalPitchDeg - vertErr * tuning.lookAtMaxDownPitchDeg
            bridge.pointGimbal(pitchDeg: max(-85, min(30, pitch)))
            log("Centering: person centered (gimbal \(Int(pitch))°).")
            return
        }
        log("Centering: gave up after \(maxAttempts) attempts — shooting anyway.")
    }

    /// Panorama (spec): in place, gimbal forward, shoot in 45° increments
    /// through a full circle (8 shots), saving each to the camera roll.
    private func runPanorama() async -> Bool {
        bridge.pointGimbal(pitchDeg: tuning.panoramaGimbalPitchDeg)
        try? await Task.sleep(for: .seconds(1.0))
        for _ in 0..<max(1, tuning.panoramaSegments) {
            if cancelRequested { return false }
            _ = await bridge.capturePhotoAndSave()
            behaviors.rotateBy(yawDeg: tuning.panoramaStepDeg)
            guard await waitForBehavior(timeout: 20) else { return false }
            try? await Task.sleep(for: .seconds(tuning.panoramaSettleSeconds))
        }
        return true
    }

    // MARK: - Helpers

    /// Point the gimbal so the box center moves toward the frame center
    /// (pitch only — yaw is handled by rotating the aircraft).
    private func pointGimbalAt(box: [Int]) {
        guard box.count == 4 else { return }
        let yCenter = Double(box[0] + box[2]) / 2.0 / 1000.0   // 0 top … 1 bottom
        // Map image-vertical position to a pitch between 0 (top) and
        // -lookAtMaxDownPitchDeg (bottom).
        let pitch = -Double(yCenter) * tuning.lookAtMaxDownPitchDeg
        bridge.pointGimbal(pitchDeg: pitch)
    }

    /// Project a GPS coordinate `distanceM` ahead of `origin` along `headingDeg`.
    private func projectedCoordinate(from origin: GPSCoordinate,
                                     headingDeg: Double,
                                     distanceM: Double) -> GPSCoordinate {
        let earthR = 6_371_000.0
        let bearing = headingDeg * .pi / 180
        let lat1 = origin.latitude * .pi / 180
        let lon1 = origin.longitude * .pi / 180
        let dR = distanceM / earthR
        let lat2 = asin(sin(lat1) * cos(dR) + cos(lat1) * sin(dR) * cos(bearing))
        let lon2 = lon1 + atan2(sin(bearing) * sin(dR) * cos(lat1),
                                cos(dR) - sin(lat1) * sin(lat2))
        return GPSCoordinate(latitude: lat2 * 180 / .pi,
                             longitude: lon2 * 180 / .pi,
                             altitudeM: origin.altitudeM)
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

    private func looksLikePersonTarget(_ target: String?) -> Bool {
        guard let text = target?.lowercased() else { return false }
        return text.contains("person")
            || text.contains("operator")
            || text.contains("man")
            || text.contains("woman")
            || text.contains("boy")
            || text.contains("girl")
            || text.contains("human")
    }
}
