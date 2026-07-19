// FlightBehaviors.swift — Nimbus
// Closed-loop Virtual Stick flight behavior library. Spec §3 component 8.
//
// All behaviors run at 10 Hz via a Timer. Every sendVelocity() call goes
// through SafetySupervisor clamp inside DJISDKBridge.

import Foundation
import UIKit
import Vision

final class FlightBehaviors {

    let bridge: DJISDKBridge
    let safety: SafetySupervisor
    let headTracking: HeadTrackingManager
    /// All per-action adjustable parameters live in ActionTuning.swift.
    private var tuning: ActionTuning { .shared }

    private var behaviorTimer: Timer?
    private var activeMode = Mode.none

    private(set) var isExecuting = false
    private var lastPitchCommand: Float = 0
    private var lastRollCommand: Float = 0
    private var lastYawCommand: Float = 0
    private var lastThrottleCommand: Float = 0

    /// Fires on the main actor when a behavior reaches its completion condition.
    var onBehaviorComplete: (() -> Void)?
    /// Fires on the main actor with the active follow tracking box (Vision-normalized).
    var onFollowTargetBoxUpdated: ((CGRect?) -> Void)?

    // Per-behavior state
    private var approachBox      = [Int]()
    private var approachStandoff = 3.0
    private var approachMaxSec   = 45.0
    private var approachStart    = Date.distantPast

    private var orbitTangentialMps: Float = 1.0
    private var orbitMaxSec      = 30.0
    private var orbitStart       = Date.distantPast

    private var followMaxSec     = 60.0
    private var followStart      = Date.distantPast
    private var followStartHeadYaw = 0.0
    private var followStartHeading = 0.0
    private var followOverheadMode = true
    private var followHeadTopTargetY = 0.50
    // 0° = drone faces the same direction as the user (desired for overhead follow).
    // Change to 180° if you want the drone to face *toward* the user instead.
    private let followYawOffsetDeg = 0.0
    private var followTargetAltitudeM: Double = 4.0
    /// Alpha-beta filter state: smoothed chase-point position and screen velocity.
    private var followTrackedPoint: CGPoint?
    private var followTrackedVel = CGVector(dx: 0, dy: 0)
    private var followTrackRequest: VNTrackObjectRequest?
    private let followTrackMinConfidence: Float = 0.30
    private var followLostTicks = 0
    /// Optional explicit tracker seed (Vision-normalized) set at follow start.
    private var followSeedBox: CGRect?

    private var navTarget: GPSCoordinate?
    private var navToleranceM = 1.5
    private var navMaxSec = 120.0
    private var navStart = Date.distantPast
    private var hoverHoldUntil = Date.distantPast
    private var pendingCompletionAfterHover = false
    private let hoverStabilizationDurationSec = 1.0

    // rotate-by-angle state
    private var rotateTargetHeading = 0.0
    private var rotateStart = Date.distantPast
    private var rotateMaxSec = 30.0

    // altitude-change state
    private var altitudeTargetM = 0.0
    private var altitudeStart = Date.distantPast
    private var altitudeMaxSec = 20.0

    // timed open-loop velocity state
    private var timedPitch: Float = 0
    private var timedRoll: Float = 0
    private var timedThrottle: Float = 0
    private var timedUntil = Date.distantPast
    private var isHeadingControlSuppressed = false


    enum Mode { case none, approach, orbit, hover, followPerson, navigateToSpot,
                     rotateBy, altitudeChange, timedVelocity, headingHold }

    init(bridge: DJISDKBridge, safety: SafetySupervisor, headTracking: HeadTrackingManager) {
        self.bridge = bridge
        self.safety = safety
        self.headTracking = headTracking
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

    /// Fly a horizontal circle (CW) at `angularVelocityDps` for `durationSec`.
    /// Linear speed = ω · r; multiple revolutions = longer duration.
    /// (Virtual-Stick fallback — the SDK Hotpoint mission is preferred; see
    /// MissionExecutor.runOrbit.)
    func orbit(radiusM: Double = 5.0,
               angularVelocityDps: Double = 15.0,
               durationSec: Double = 30.0) {
        let safeRadius = max(0.5, radiusM)
        let orbitAngDps = max(1.0, angularVelocityDps)
        let angularRadPerSec = orbitAngDps * .pi / 180.0
        orbitTangentialMps = safety.clamp(Float(safeRadius * angularRadPerSec))
        orbitMaxSec = durationSec
        orbitStart = Date()
        startTimer(mode: .orbit)
    }

    /// Follow a generic tracked head-region box from the live camera frame.
    /// - Parameter seedBox: optional Vision-normalized box (origin bottom-left)
    ///   to seed the tracker with (e.g. a Gemini-grounded target or a detected
    ///   person). When nil, the tracker auto-seeds from person detection, then
    ///   falls back to the frame center.
    func followPerson(maxSeconds: Double = 60.0,
                      overheadMode: Bool = true,
                      seedBox: CGRect? = nil) {
        followMaxSec = maxSeconds
        followStart = Date()
        followOverheadMode = overheadMode
        followHeadTopTargetY = overheadMode ? 0.50 : 0.62
        followStartHeadYaw = headTracking.effectiveAttitude.yawDeg
        followStartHeading = bridge.telemetry.headingDeg
        resetFollowTargetFilter()
        followTrackRequest = nil
        followLostTicks = 0
        followSeedBox = seedBox
        // "Fly up": absolute altitude target (AGL) from tuning, never below the
        // current altitude baseline, capped under the safety ceiling.
        let ceiling = safety.maxAltitudeM - 1.0
        let baseline = max(tuning.followAltitudeM, bridge.telemetry.altitudeM)
        followTargetAltitudeM = min(ceiling, baseline)
        Task { @MainActor [weak self] in self?.onFollowTargetBoxUpdated?(nil) }
        startTimer(mode: .followPerson)
    }

    /// Yaw in place by a signed angle (+ = clockwise). Closed loop on absolute
    /// heading error to a target heading (robust to telemetry jitter/sign quirks).
    func rotateBy(yawDeg: Double, maxSeconds: Double = 30.0) {
        let clamped = max(-720.0, min(720.0, yawDeg))
        rotateTargetHeading = normalizedHeading(bridge.telemetry.headingDeg + clamped)
        rotateStart = Date()
        rotateMaxSec = maxSeconds
        startTimer(mode: .rotateBy)
    }

    /// Yaw in place to an absolute compass heading (deg, 0 = north). Takes the
    /// shortest way around. Used by user-relative cardinal fly_to moves.
    func rotateToHeading(_ headingDeg: Double, maxSeconds: Double = 30.0) {
        let delta = shortestAngleDelta(target: headingDeg,
                                       current: bridge.telemetry.headingDeg)
        rotateBy(yawDeg: delta, maxSeconds: maxSeconds)
    }

    /// Climb (+) or descend (−) by a relative altitude in meters.
    func changeAltitude(deltaM: Double, maxSeconds: Double = 20.0) {
        let ceiling = safety.maxAltitudeM - 1.0
        altitudeTargetM = max(1.2, min(ceiling, bridge.telemetry.altitudeM + deltaM))
        altitudeStart = Date()
        altitudeMaxSec = maxSeconds
        startTimer(mode: .altitudeChange)
    }

    /// Open-loop body-frame velocity for a fixed duration (e.g. "fly forward 3 s",
    /// selfie back-away). All axes are safety-clamped in the bridge.
    func timedVelocity(pitch: Float = 0, roll: Float = 0, throttle: Float = 0,
                       duration: Double) {
        timedPitch = pitch
        timedRoll = roll
        timedThrottle = throttle
        timedUntil = Date().addingTimeInterval(max(0.1, duration))
        startTimer(mode: .timedVelocity)
    }

    /// Fly to a GPS coordinate using the aircraft's current heading and GPS telemetry.
    func goToCoordinate(_ coordinate: GPSCoordinate,
                        toleranceM: Double = 1.5,
                        maxSeconds: Double = 120.0) {
        navTarget = coordinate
        navToleranceM = toleranceM
        navMaxSec = maxSeconds
        navStart = Date()
        startTimer(mode: .navigateToSpot)
    }

    func hover() {
        startStabilizedHoverHold(notifyCompletion: false)
    }

    func stop() {
        startStabilizedHoverHold(notifyCompletion: false)
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

    /// Temporarily disable yaw heading-tracking output while preserving
    /// position hold (used by press-and-hold heading calibration).
    func setHeadingControlSuppressed(_ suppressed: Bool) {
        isHeadingControlSuppressed = suppressed
    }

    // MARK: - Control Loop

    private func startTimer(mode: Mode) {
        stopBehavior()
        activeMode  = mode
        isExecuting = true
        // Always attach to the main run loop — behaviors may be started from
        // background Tasks (voice pipeline) where a scheduled timer would
        // otherwise never fire.
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        behaviorTimer = timer
    }

    private func stopBehavior() {
        behaviorTimer?.invalidate()
        behaviorTimer = nil
        activeMode    = .none
        isExecuting   = false
        lastPitchCommand = 0
        lastRollCommand = 0
        lastYawCommand = 0
        lastThrottleCommand = 0
        navTarget = nil
        hoverHoldUntil = Date.distantPast
        pendingCompletionAfterHover = false
        followTrackRequest = nil
        resetFollowTargetFilter()
        Task { @MainActor [weak self] in self?.onFollowTargetBoxUpdated?(nil) }
    }

    private func startStabilizedHoverHold(notifyCompletion: Bool) {
        stopBehavior()
        pendingCompletionAfterHover = notifyCompletion
        hoverHoldUntil = Date().addingTimeInterval(hoverStabilizationDurationSec)
        activeMode = .hover
        isExecuting = true
        sendSmoothedVelocity(pitch: 0, roll: 0, yaw: 0, throttle: 0)
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        behaviorTimer = timer
    }

    private func tick() {
        switch activeMode {
        case .approach:      tickApproach()
        case .orbit:         tickOrbit()
        case .hover:         tickHoverHold()
        case .followPerson:  tickFollowPerson()
        case .navigateToSpot: tickNavigateToSpot()
        case .rotateBy:      tickRotateBy()
        case .altitudeChange: tickAltitudeChange()
        case .timedVelocity: tickTimedVelocity()
        case .headingHold:   tickHeadingHoldMode()
        case .none:          break
        }
    }

    // MARK: - Rotate By Angle

    private func tickRotateBy() {
        if Date().timeIntervalSince(rotateStart) > rotateMaxSec {
            startStabilizedHoverHold(notifyCompletion: true)
            return
        }
        let heading = bridge.telemetry.headingDeg
        let yawError = shortestAngleDelta(target: rotateTargetHeading, current: heading)
        let remainingDeg = abs(yawError)

        if remainingDeg <= tuning.rotateStopToleranceDeg {
            startStabilizedHoverHold(notifyCompletion: true)
            return
        }
        // Slow down near the end for a clean stop.
        let rate = min(tuning.rotateMaxRateDps,
                       max(tuning.rotateMinRateDps,
                           remainingDeg * tuning.rotateRateGain))
        let yawSign = yawError >= 0 ? 1.0 : -1.0
        sendSmoothedVelocity(pitch: 0, roll: 0, yaw: Float(rate * yawSign), throttle: 0)
    }

    // MARK: - Altitude Change

    private func tickAltitudeChange() {
        if Date().timeIntervalSince(altitudeStart) > altitudeMaxSec {
            startStabilizedHoverHold(notifyCompletion: true)
            return
        }
        let err = altitudeTargetM - bridge.telemetry.altitudeM
        if abs(err) < tuning.altitudeToleranceM {
            startStabilizedHoverHold(notifyCompletion: true)
            return
        }
        sendSmoothedVelocity(pitch: 0, roll: 0, yaw: 0, throttle: Float(err * tuning.altitudeGain))
    }

    // MARK: - Timed Velocity

    private func tickTimedVelocity() {
        if Date() >= timedUntil {
            startStabilizedHoverHold(notifyCompletion: true)
            return
        }
        // Body-frame commands: pitch is forward/back, roll is right/left.
        sendSmoothedVelocity(pitch: timedPitch, roll: timedRoll, yaw: 0, throttle: timedThrottle)
    }

    private func tickHoverHold() {
        // Keep tracking the user's heading even during stabilisation hover.
        let yaw: Float = isHeadingControlSuppressed ? 0 : headTrackingYawCorrection()
        sendSmoothedVelocity(pitch: 0, roll: 0, yaw: yaw, throttle: 0)
        if Date() < hoverHoldUntil { return }
        let shouldNotifyCompletion = pendingCompletionAfterHover
        stopBehavior()
        if shouldNotifyCompletion {
            Task { @MainActor [weak self] in self?.onBehaviorComplete?() }
        }
    }

    // MARK: - Approach (visual servo — fly_to)
    //
    // Body-frame control: pitch drives forward/back toward the target after yaw
    // alignment, so no world-frame decomposition is needed.
    //
    // box is [ymin, xmin, ymax, xmax] in 0–1000 coordinates.

    private func tickApproach() {
        if Date().timeIntervalSince(approachStart) > approachMaxSec {
            startStabilizedHoverHold(notifyCompletion: true)
            return
        }

        guard approachBox.count == 4 else { bridge.sendHover(); return }

        let ymin = Double(approachBox[0]);  let xmin = Double(approachBox[1])
        let ymax = Double(approachBox[2]);  let xmax = Double(approachBox[3])

        let xCenter  = (xmin + xmax) / 2
        let yCenter  = (ymin + ymax) / 2
        let bboxArea = max(0, (xmax - xmin)) * max(0, (ymax - ymin)) / 1_000_000

        // Too close: bbox fills too much of the frame → stop.
        if bboxArea >= tuning.flyToStopAreaFraction {
            startStabilizedHoverHold(notifyCompletion: true)
            return
        }

        let latErr  = (xCenter - 500) / 500          // −1 … +1 horizontal
        let vertErr = (yCenter - 500) / 500          // −1 … +1 vertical (down +)
        let areaErr = tuning.flyToStopAreaFraction - bboxArea

        // Rotate-first: while the target is far off-center horizontally, only
        // yaw toward it; translate once roughly aligned.
        let approxYawErrDeg = latErr * tuning.lookAtHorizontalFovDeg / 2
        let aligned = abs(approxYawErrDeg) < tuning.flyToYawAlignThresholdDeg

        let yawRate  = Float(latErr * tuning.flyToYawGainDps)
        let fwdMag   = aligned ? Double(areaErr) * tuning.flyToForwardGain : 0
        let throttle = aligned ? Float(-vertErr * tuning.flyToVerticalGain) : 0

        sendSmoothedVelocity(pitch: Float(fwdMag), roll: 0, yaw: yawRate, throttle: throttle)
    }

    // MARK: - Orbit

    private func tickOrbit() {
        if Date().timeIntervalSince(orbitStart) > orbitMaxSec {
            startStabilizedHoverHold(notifyCompletion: true)
            return
        }
        // Virtual-stick orbit primitive:
        // roll commands generate lateral arc motion while pitch stays near zero.
        sendSmoothedVelocity(pitch: 0, roll: orbitTangentialMps, yaw: 0, throttle: 0)
    }

    // MARK: - Person Follow

    private func tickFollowPerson() {
        if Date().timeIntervalSince(followStart) > followMaxSec {
            startStabilizedHoverHold(notifyCompletion: true)
            return
        }

        // Yaw ALWAYS follows the user's AirPods heading — computed up front so
        // rotation stays in sync with the person on every tick, including while
        // the camera feed or visual tracker is momentarily unavailable.
        let currentHeading = bridge.telemetry.headingDeg
        // Use the AirPods absolute world heading directly — no incremental delta
        // accumulation, which was drifting and computing the wrong offset.
        let desiredHeading = headTracking.effectiveAttitude.yawDeg + followYawOffsetDeg
        let yawError = shortestAngleDelta(target: desiredHeading, current: currentHeading)
        let yawRate = Float(yawError * tuning.followYawGain)

        guard let image = bridge.cameraFrame,
              let cgImage = image.cgImage else {
            followLostTicks += 1
            resetFollowTargetFilter()
            // Camera feed unavailable: keep rotating with the user; after >1 s
            // add a slow yaw scan for re-acquisition.
            let scanYaw: Float = followLostTicks > 10 ? 12 : 0
            sendSmoothedVelocity(pitch: 0, roll: 0, yaw: yawRate + scanYaw, throttle: 0)
            return
        }

        let frameCenter = CGPoint(x: 0.5, y: 0.5)
        var trackedBox: CGRect?
        var chasePoint: CGPoint?

        if let personBox = trackedHeadBox(in: cgImage) {
            followLostTicks = 0
            trackedBox = personBox
            let recursiveTarget = recursiveNearestPoint(on: personBox, toward: frameCenter, depth: 3)
            let correctedTarget = undistorted(normalizedPoint: recursiveTarget)
            chasePoint = updateFollowTargetFilter(measurement: correctedTarget)
            // Enforce straight-down gimbal in follow mode.
            bridge.trackHeadTopWithGimbal(headTopY: personBox.maxY,
                                          targetY: CGFloat(followHeadTopTargetY),
                                          airpodsPitchDeg: CGFloat(headTracking.effectiveAttitude.pitchDeg),
                                          strictDown: true)
        } else {
            // Tracker dropout: coast briefly along the predicted path instead of
            // stopping dead — bridges occlusions / missed frames smoothly.
            followLostTicks += 1
            if followLostTicks <= tuning.followCoastMaxTicks {
                chasePoint = coastFollowPrediction()
            }
        }

        Task { @MainActor [weak self] in self?.onFollowTargetBoxUpdated?(trackedBox) }

        guard let chasePoint else {
            // Target fully lost: hover in place but keep rotating with the user;
            // after a longer loss add a slow yaw scan to help re-acquire.
            resetFollowTargetFilter()
            let scanYaw: Float = followLostTicks > 8 ? 10 : 0
            sendSmoothedVelocity(pitch: 0, roll: 0, yaw: yawRate + scanYaw, throttle: 0)
            return
        }

        // Follow controller:
        // - roll/pitch chase the predicted (smoothed + look-ahead) target point
        // - velocity feed-forward matches the person's pace to remove lag
        // - yaw follows AirPods heading so drone faces same direction as user
        let latErr = Double(chasePoint.x - frameCenter.x)   // right-left screen error
        let fwdErr = Double(frameCenter.y - chasePoint.y)   // forward-back screen error (head-centric)

        // Yaw-first sequencing for stability:
        // if heading is still off, rotate first and defer translational corrections.
        let applyTranslation = abs(yawError) < tuning.followYawFirstThresholdDeg
        // Screen errors are body-frame (right / forward). Feed-forward adds the
        // target's estimated screen velocity so a walking person is matched
        // instead of perpetually chased.
        let ff = tuning.followVelocityFeedForwardGain
        let bodyRight = applyTranslation
            ? latErr * tuning.followLateralGain + Double(followTrackedVel.dx) * ff
            : 0
        let bodyFwd = applyTranslation
            ? fwdErr * tuning.followForwardGain - Double(followTrackedVel.dy) * ff
            : 0
        let pitch = Float(bodyFwd)
        let roll = Float(bodyRight)
        let altError = followTargetAltitudeM - bridge.telemetry.altitudeM
        let throttle = Float(altError * tuning.followAltitudeGain)

        sendSmoothedVelocity(pitch: pitch, roll: roll, yaw: yawRate, throttle: throttle)
    }

    // MARK: - Predictive Target Filter (alpha-beta / g-h)

    /// Fuse a new tracker measurement into the position + velocity estimate and
    /// return the look-ahead chase point. Runs at the 10 Hz behavior tick.
    private func updateFollowTargetFilter(measurement: CGPoint) -> CGPoint {
        let dt: CGFloat = 0.1
        guard let pos = followTrackedPoint else {
            followTrackedPoint = measurement
            followTrackedVel = CGVector(dx: 0, dy: 0)
            return measurement
        }
        // Predict forward one tick, then correct with the measurement residual.
        let predicted = CGPoint(x: pos.x + followTrackedVel.dx * dt,
                                y: pos.y + followTrackedVel.dy * dt)
        let rx = measurement.x - predicted.x
        let ry = measurement.y - predicted.y
        let alpha = CGFloat(tuning.followPosFilterAlpha)
        let beta  = CGFloat(tuning.followVelFilterBeta)
        let newPos = CGPoint(x: predicted.x + alpha * rx,
                             y: predicted.y + alpha * ry)
        followTrackedVel = CGVector(dx: followTrackedVel.dx + (beta / dt) * rx,
                                    dy: followTrackedVel.dy + (beta / dt) * ry)
        followTrackedPoint = newPos
        return lookaheadChasePoint(from: newPos)
    }

    /// Advance the estimate one blind tick while the tracker is lost (velocity
    /// decays each tick so a stale prediction can never run away).
    private func coastFollowPrediction() -> CGPoint? {
        guard let pos = followTrackedPoint else { return nil }
        let dt: CGFloat = 0.1
        let decay = CGFloat(tuning.followCoastVelocityDecay)
        followTrackedVel = CGVector(dx: followTrackedVel.dx * decay,
                                    dy: followTrackedVel.dy * decay)
        let next = CGPoint(x: min(max(pos.x + followTrackedVel.dx * dt, 0), 1),
                           y: min(max(pos.y + followTrackedVel.dy * dt, 0), 1))
        followTrackedPoint = next
        return lookaheadChasePoint(from: next)
    }

    /// Project the smoothed position a short time into the future so the
    /// controller leads a moving target instead of lagging behind it.
    private func lookaheadChasePoint(from pos: CGPoint) -> CGPoint {
        let t = CGFloat(tuning.followPredictionLookaheadSec)
        let p = CGPoint(x: pos.x + followTrackedVel.dx * t,
                        y: pos.y + followTrackedVel.dy * t)
        return CGPoint(x: min(max(p.x, 0), 1), y: min(max(p.y, 0), 1))
    }

    private func resetFollowTargetFilter() {
        followTrackedPoint = nil
        followTrackedVel = CGVector(dx: 0, dy: 0)
    }
    private func trackedHeadBox(in cgImage: CGImage) -> CGRect? {
        if followTrackRequest == nil {
            // Seed priority:
            //   1. explicit seed box (e.g. Gemini-grounded target / follow subject)
            //   2. head region from body-pose keypoints (best for overhead view)
            //   3. detected person nearest the frame center (the operator)
            //   4. fixed center region (operator stands under the drone)
            let seed: CGRect
            if let explicit = followSeedBox {
                seed = explicit
                followSeedBox = nil
            } else if let head = Self.detectHeadBox(in: cgImage) {
                seed = head
            } else if let person = Self.detectPersonBox(in: cgImage) {
                seed = person
            } else {
                seed = CGRect(x: 0.42, y: 0.42, width: 0.16, height: 0.16)
            }
            let initial = VNDetectedObjectObservation(boundingBox: seed)
            let request = VNTrackObjectRequest(detectedObjectObservation: initial)
            request.trackingLevel = .accurate
            followTrackRequest = request
        }
        guard let request = followTrackRequest else { return nil }
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try? handler.perform([request])
        guard let tracked = (request.results as? [VNDetectedObjectObservation])?.first,
              tracked.confidence >= followTrackMinConfidence else {
            followTrackRequest = nil
            return nil
        }
        request.inputObservation = tracked
        return tracked.boundingBox
    }

    /// Locate the operator's head using body-pose keypoints (nose / eyes /
    /// ears). Unlike face detection, pose keypoints keep working from steep
    /// overhead camera angles, so this gives a "top of the head" region the
    /// follow tracker can lock onto. Multiple people are disambiguated with
    /// the same operator heuristic as `detectPersonBox` (bigger + central).
    /// Returns a Vision-normalized box (origin bottom-left) or nil.
    static func detectHeadBox(in cgImage: CGImage) -> CGRect? {
        let request = VNDetectHumanBodyPoseRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try? handler.perform([request])

        var best: CGRect?
        var bestScore = -Double.infinity

        for obs in request.results ?? [] {
            guard let joints = try? obs.recognizedPoints(.face) else { continue }
            let headPoints = joints.values.filter { $0.confidence >= 0.3 }
            guard !headPoints.isEmpty else { continue }

            let xs = headPoints.map { $0.location.x }
            let ys = headPoints.map { $0.location.y }
            guard let minX = xs.min(), let maxX = xs.max(),
                  let minY = ys.min(), let maxY = ys.max() else { continue }

            // Pad the keypoint cluster into a box; extend extra upward since
            // the keypoints stop at the eyes/ears and we want the crown.
            let span = max(maxX - minX, maxY - minY, 0.03)
            let box = CGRect(x: minX - span * 0.5,
                             y: minY - span * 0.25,
                             width: (maxX - minX) + span,
                             height: (maxY - minY) + span * 1.25)
                .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            guard !box.isEmpty else { continue }

            let dx = Double(box.midX - 0.5)
            let dy = Double(box.midY - 0.5)
            let score = Double(box.width * box.height)
                      - (dx * dx + dy * dy).squareRoot() * 0.15
            if score > bestScore {
                bestScore = score
                best = box
            }
        }
        return best
    }

    /// Detect humans in the frame and pick the operator: the person whose box
    /// is nearest the frame center, weighted by size (bigger = closer = more
    /// likely the operator standing under/near the drone).
    /// Returns a Vision-normalized box (origin bottom-left) or nil.
    static func detectPersonBox(in cgImage: CGImage) -> CGRect? {
        let request = VNDetectHumanRectanglesRequest()
        if #available(iOS 15.0, *) {
            request.upperBodyOnly = false
        }
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try? handler.perform([request])
        let people = (request.results ?? []).filter { $0.confidence >= 0.3 }
        guard !people.isEmpty else { return nil }

        func score(_ box: CGRect) -> Double {
            let dx = Double(box.midX - 0.5)
            let dy = Double(box.midY - 0.5)
            let centerDist = (dx * dx + dy * dy).squareRoot()   // 0 (center) … ~0.71
            let area = Double(box.width * box.height)           // bigger = closer
            return area - centerDist * 0.15
        }
        return people.max { score($0.boundingBox) < score($1.boundingBox) }?.boundingBox
    }

    private func recursiveNearestPoint(on rect: CGRect, toward center: CGPoint, depth: Int) -> CGPoint {
        guard depth > 0 else { return nearestPoint(on: rect, to: center) }
        let nearest = nearestPoint(on: rect, to: center)
        let nextWidth = rect.width * 0.5
        let nextHeight = rect.height * 0.5
        let clampedX = min(max(nearest.x - nextWidth / 2, rect.minX), rect.maxX - nextWidth)
        let clampedY = min(max(nearest.y - nextHeight / 2, rect.minY), rect.maxY - nextHeight)
        let nestedRect = CGRect(x: clampedX, y: clampedY, width: nextWidth, height: nextHeight)
        return recursiveNearestPoint(on: nestedRect, toward: center, depth: depth - 1)
    }

    private func nearestPoint(on rect: CGRect, to point: CGPoint) -> CGPoint {
        let x = min(max(point.x, rect.minX), rect.maxX)
        let y = min(max(point.y, rect.minY), rect.maxY)
        return CGPoint(x: x, y: y)
    }

    private func undistorted(normalizedPoint point: CGPoint) -> CGPoint {
        // Radial lens compensation in normalized image space.
        let dx = Double(point.x - 0.5)
        let dy = Double(point.y - 0.5)
        let r2 = dx * dx + dy * dy
        let k1 = tuning.followLensK1
        let scale = 1.0 + (k1 * r2)
        let correctedX = 0.5 + (dx * scale)
        let correctedY = 0.5 + (dy * scale)
        return CGPoint(x: min(max(correctedX, 0), 1), y: min(max(correctedY, 0), 1))
    }

    // MARK: - GPS Navigation / Remembered Spot

    private func tickNavigateToSpot() {
        guard let target = navTarget else { bridge.sendHover(); return }

        if Date().timeIntervalSince(navStart) > navMaxSec {
            startStabilizedHoverHold(notifyCompletion: true)
            return
        }

        guard let current = bridge.telemetry.currentLocation else {
            bridge.sendHover()
            return
        }

        let (distanceM, bearingDeg) = distanceAndBearing(from: current, to: target)
        if distanceM <= navToleranceM {
            startStabilizedHoverHold(notifyCompletion: true)
            return
        }

        // Body-frame VS with yaw-first forward-only motion.
        let headingErrorDeg = shortestAngleDelta(target: bearingDeg, current: bridge.telemetry.headingDeg)
        let headingAligned = abs(headingErrorDeg) < 8.0
        let yawRate = Float(max(-40.0, min(40.0, headingErrorDeg * 1.4)))

        // Yaw first, then move with forward pitch only to avoid awkward
        // side-slip movement while turning.
        let pitch: Float
        if headingAligned {
            pitch = Float(min(2.0, max(0.3, distanceM * 0.12)))
        } else {
            pitch = 0
        }
        let roll: Float = 0

        var throttle: Float = 0
        if let targetAlt = target.altitudeM,
           let currentAlt = current.altitudeM {
            let altError = targetAlt - currentAlt
            throttle = Float(altError * 0.3)
        }
        sendSmoothedVelocity(pitch: pitch, roll: roll, yaw: yawRate, throttle: throttle)
    }

    // MARK: - Heading Hold Mode

    /// Enter the persistent heading-hold state: hold position and continuously
    /// align yaw to the user's AirPods heading. Unlike stop() there is no
    /// stabilisation hover — the mode starts immediately. isExecuting is left
    /// false so MissionExecutor.waitForBehavior returns immediately and missions
    /// can interrupt at any time via startTimer().
    func headingHold() {
        stopBehavior()
        activeMode = .headingHold
        // isExecuting stays false — heading hold is a passive background state.
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        behaviorTimer = timer
    }

    private func tickHeadingHoldMode() {
        // Always send even when yaw == 0 to keep VS mode alive (FC holds X/Y/Z).
        let yaw: Float = isHeadingControlSuppressed ? 0 : headTrackingYawCorrection()
        sendSmoothedVelocity(pitch: 0, roll: 0, yaw: yaw, throttle: 0)
    }

    /// Proportional yaw correction toward the user's AirPods heading.
    /// Returns 0 when AirPods are not tracking or error is within the dead zone.
    private func headTrackingYawCorrection() -> Float {
        guard headTracking.isTracking else { return 0 }
        // Use currentAttitude (live) not effectiveAttitude (may be frozen for
        // grounding). Heading hold should track the real head direction even
        // while the attitude is frozen for command capture.
        let desired = headTracking.currentAttitude.yawDeg
        let error = shortestAngleDelta(target: desired, current: bridge.telemetry.headingDeg)
        guard abs(error) > tuning.headingHoldDeadZoneDeg else { return 0 }
        let dir: Double = error > 0 ? 1 : -1
        let rate = min(tuning.rotateMaxRateDps,
                       max(tuning.rotateMinRateDps, abs(error) * tuning.headingHoldGain))
        return Float(rate * dir)
    }


    private func distanceAndBearing(from current: GPSCoordinate, to target: GPSCoordinate) -> (distanceM: Double, bearingDeg: Double) {
        let lat1 = current.latitude * .pi / 180.0
        let lat2 = target.latitude * .pi / 180.0
        let dLat = (target.latitude - current.latitude) * .pi / 180.0
        let dLon = (target.longitude - current.longitude) * .pi / 180.0
        let a = pow(sin(dLat / 2), 2) + cos(lat1) * cos(lat2) * pow(sin(dLon / 2), 2)
        let c = 2 * atan2(sqrt(a), sqrt(1 - a))
        let distanceM = 6_371_000.0 * c
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        let bearing = atan2(y, x) * 180.0 / .pi
        return (distanceM, (bearing + 360).truncatingRemainder(dividingBy: 360))
    }

    private func shortestAngleDelta(target: Double, current: Double) -> Double {
        let delta = (target - current + 540).truncatingRemainder(dividingBy: 360) - 180
        return delta
    }

    private func normalizedHeading(_ heading: Double) -> Double {
        let normalized = heading.truncatingRemainder(dividingBy: 360)
        return normalized >= 0 ? normalized : normalized + 360
    }

    private func sendSmoothedVelocity(pitch: Float,
                                      roll: Float,
                                      yaw: Float,
                                      throttle: Float) {
        // Slew rates are tunable in ActionTuning (slewLinear / slewYaw).
        let nextPitch    = slewLimit(current: lastPitchCommand,    target: pitch,    maxDelta: tuning.slewLinear)
        let nextRoll     = slewLimit(current: lastRollCommand,     target: roll,     maxDelta: tuning.slewLinear)
        let nextYaw      = slewLimit(current: lastYawCommand,      target: yaw,      maxDelta: tuning.slewYaw)
        let nextThrottle = slewLimit(current: lastThrottleCommand, target: throttle, maxDelta: tuning.slewLinear)
        lastPitchCommand = nextPitch
        lastRollCommand = nextRoll
        lastYawCommand = nextYaw
        lastThrottleCommand = nextThrottle
        bridge.sendVelocity(pitch: nextPitch, roll: nextRoll, yaw: nextYaw, throttle: nextThrottle)
    }

    private func slewLimit(current: Float, target: Float, maxDelta: Float) -> Float {
        let delta = target - current
        if delta > maxDelta { return current + maxDelta }
        if delta < -maxDelta { return current - maxDelta }
        return target
    }
}
