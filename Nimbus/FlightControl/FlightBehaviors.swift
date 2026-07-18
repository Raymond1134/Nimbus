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

    private var behaviorTimer: Timer?
    private var activeMode = Mode.none

    private(set) var isExecuting = false

    /// Fires on the main actor when a behavior reaches its completion condition.
    var onBehaviorComplete: (() -> Void)?
    /// Fires on the main actor with the active follow tracking box (Vision-normalized).
    var onFollowTargetBoxUpdated: ((CGRect?) -> Void)?

    // Per-behavior state
    private var approachBox      = [Int]()
    private var approachStandoff = 3.0
    private var approachMaxSec   = 45.0
    private var approachStart    = Date.distantPast

    private var orbitAngDps      = 12.0
    private var orbitPitchMps: Float = 1.0
    private var orbitMaxSec      = 30.0
    private var orbitStart       = Date.distantPast

    private var followMaxSec     = 60.0
    private var followStart      = Date.distantPast
    private var followStartHeadYaw = 0.0
    private var followStartHeading = 0.0
    private var followOverheadMode = true
    private var followHeadTopTargetY = 0.50
    private let followYawOffsetDeg = 180.0
    private var followTargetAltitudeM: Double = 4.0
    private var followFilteredLatErr = 0.0
    private var followFilteredFwdErr = 0.0
    private let followErrorFilterAlpha = 0.25
    private var followTrackRequest: VNTrackObjectRequest?
    private let followTrackMinConfidence: Float = 0.30
    private let followYawFirstThresholdDeg = 5.0

    private var navTarget: GPSCoordinate?
    private var navToleranceM = 1.5
    private var navMaxSec = 120.0
    private var navStart = Date.distantPast
    private var hoverHoldUntil = Date.distantPast
    private var pendingCompletionAfterHover = false
    private let hoverStabilizationDurationSec = 1.0

    enum Mode { case none, approach, orbit, hover, followPerson, navigateToSpot }

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

    /// Fly in a horizontal circle (CW). Radius now affects the linear speed.
    func orbit(radiusM: Double = 5.0, durationSec: Double = 30.0) {
        let safeRadius = max(0.5, radiusM)
        orbitAngDps = 360.0 / max(1.0, durationSec)
        let angularRadPerSec = orbitAngDps * .pi / 180.0
        orbitPitchMps = safety.clamp(Float(safeRadius * angularRadPerSec))
        orbitMaxSec = durationSec
        orbitStart = Date()
        startTimer(mode: .orbit)
    }

    /// Follow a generic tracked head-region box from the live camera frame.
    func followPerson(maxSeconds: Double = 60.0,
                      overheadMode: Bool = true) {
        followMaxSec = maxSeconds
        followStart = Date()
        followOverheadMode = overheadMode
        followHeadTopTargetY = overheadMode ? 0.50 : 0.62
        // Absolute altitude target (AGL), not a relative climb increment.
        followTargetAltitudeM = 4.0
        followStartHeadYaw = headTracking.effectiveAttitude.yawDeg
        followStartHeading = bridge.telemetry.headingDeg
        followFilteredLatErr = 0
        followFilteredFwdErr = 0
        followTrackRequest = nil
        Task { @MainActor [weak self] in self?.onFollowTargetBoxUpdated?(nil) }
        startTimer(mode: .followPerson)
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
        navTarget = nil
        hoverHoldUntil = Date.distantPast
        pendingCompletionAfterHover = false
        followTrackRequest = nil
        Task { @MainActor [weak self] in self?.onFollowTargetBoxUpdated?(nil) }
    }

    private func startStabilizedHoverHold(notifyCompletion: Bool) {
        stopBehavior()
        pendingCompletionAfterHover = notifyCompletion
        hoverHoldUntil = Date().addingTimeInterval(hoverStabilizationDurationSec)
        activeMode = .hover
        isExecuting = true
        bridge.sendHover()
        behaviorTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    private func tick() {
        switch activeMode {
        case .approach:      tickApproach()
        case .orbit:         tickOrbit()
        case .hover:         tickHoverHold()
        case .followPerson:  tickFollowPerson()
        case .navigateToSpot: tickNavigateToSpot()
        case .none:          break
        }
    }

    private func tickHoverHold() {
        bridge.sendHover()
        if Date() < hoverHoldUntil { return }
        let shouldNotifyCompletion = pendingCompletionAfterHover
        stopBehavior()
        if shouldNotifyCompletion {
            Task { @MainActor [weak self] in self?.onBehaviorComplete?() }
        }
    }

    // MARK: - Approach (visual servo)
    //
    // Drives toward the target using bbox area as a distance proxy and
    // bbox center as a lateral error signal.
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

        let targetArea = 0.04
        let areaErr    = targetArea - bboxArea
        let latErr     = (xCenter - 500) / 500
        let vertErr    = (yCenter - 500) / 500

        if abs(areaErr) < 0.005 {
            startStabilizedHoverHold(notifyCompletion: true)
            return
        }

        let kFwd: Double = 2.5
        let kYaw: Double = 30.0
        let kVert: Double = 1.0

        let fwd      = Float(areaErr * kFwd)
        let yawRate  = Float(latErr * kYaw)
        let throttle = Float(-vertErr * kVert)

        bridge.sendVelocity(pitch: fwd, roll: 0, yaw: yawRate, throttle: throttle)
    }

    // MARK: - Orbit

    private func tickOrbit() {
        if Date().timeIntervalSince(orbitStart) > orbitMaxSec {
            startStabilizedHoverHold(notifyCompletion: true)
            return
        }
        // Constant yaw + forward velocity; orbit radius is set by v / ω.
        bridge.sendVelocity(pitch: orbitPitchMps, roll: 0, yaw: Float(orbitAngDps), throttle: 0)
    }

    // MARK: - Person Follow

    private func tickFollowPerson() {
        if Date().timeIntervalSince(followStart) > followMaxSec {
            startStabilizedHoverHold(notifyCompletion: true)
            return
        }

        guard let image = bridge.cameraFrame,
              let cgImage = image.cgImage else {
            bridge.sendHover()
            return
        }

        guard let personBox = trackedHeadBox(in: cgImage) else {
            // Lost tracking: hover in place immediately.
            Task { @MainActor [weak self] in self?.onFollowTargetBoxUpdated?(nil) }
            bridge.sendHover()
            return
        }
        Task { @MainActor [weak self] in self?.onFollowTargetBoxUpdated?(personBox) }

        let frameCenter = CGPoint(x: 0.5, y: 0.5)
        let recursiveTarget = recursiveNearestPoint(on: personBox, toward: frameCenter, depth: 3)
        let correctedTarget = undistorted(normalizedPoint: recursiveTarget)
        let headTopY = Double(personBox.maxY)
        // Follow controller:
        // - roll/pitch keep subject centered in frame
        // - yaw follows AirPods heading so drone faces same direction as user
        let latErr = Double(correctedTarget.x - frameCenter.x)   // right-left screen error
        let fwdErr = Double(frameCenter.y - correctedTarget.y)   // forward-back screen error (head-centric)
        followFilteredLatErr += (latErr - followFilteredLatErr) * followErrorFilterAlpha
        followFilteredFwdErr += (fwdErr - followFilteredFwdErr) * followErrorFilterAlpha

        let kLat: Double = 2.2
        let kCenterPitch: Double = 2.0
        let kAlt: Double = 0.7
        let kYaw: Double = 1.6


        let currentHeading = bridge.telemetry.headingDeg
        let desiredHeading = followStartHeading + (headTracking.effectiveAttitude.yawDeg - followStartHeadYaw) + followYawOffsetDeg
        let yawError = shortestAngleDelta(target: desiredHeading, current: currentHeading)
        let yawRate = Float(yawError * kYaw)
        // Yaw-first sequencing for stability:
        // if heading is still off, rotate first and defer translational corrections.
        let applyTranslation = abs(yawError) < followYawFirstThresholdDeg
        let roll = applyTranslation ? Float(followFilteredLatErr * kLat) : 0
        let pitch = applyTranslation ? Float(followFilteredFwdErr * kCenterPitch) : 0
        let altError = followTargetAltitudeM - bridge.telemetry.altitudeM
        let throttle = Float(altError * kAlt)
        // Enforce straight-down gimbal in follow mode.
        bridge.trackHeadTopWithGimbal(headTopY: CGFloat(headTopY),
                                      targetY: CGFloat(followHeadTopTargetY),
                                      airpodsPitchDeg: CGFloat(headTracking.effectiveAttitude.pitchDeg),
                                      strictDown: true)

        bridge.sendVelocity(pitch: pitch, roll: roll, yaw: yawRate, throttle: throttle)
    }
    private func trackedHeadBox(in cgImage: CGImage) -> CGRect? {
        if followTrackRequest == nil {
            // Seed around the center where the operator can place their head at follow start.
            let seed = CGRect(x: 0.42, y: 0.42, width: 0.16, height: 0.16)
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
        let k1 = -0.18
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

        let headingRad = bridge.telemetry.headingDeg * .pi / 180.0
        let bearingRad = bearingDeg * .pi / 180.0
        let north = cos(bearingRad) * distanceM
        let east = sin(bearingRad) * distanceM
        let forward = north * cos(headingRad) + east * sin(headingRad)
        let right = -north * sin(headingRad) + east * cos(headingRad)

        let kPos: Double = 0.08
        let pitch = Float(forward * kPos)
        let roll = Float(right * kPos)

        var throttle: Float = 0
        if let targetAlt = target.altitudeM,
           let currentAlt = current.altitudeM {
            let altError = targetAlt - currentAlt
            throttle = Float(altError * 0.3)
        }

        bridge.sendVelocity(pitch: pitch, roll: roll, yaw: 0, throttle: throttle)
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
}
