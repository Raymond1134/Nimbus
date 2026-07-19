// ActionTuning.swift — Nimbus
// ─────────────────────────────────────────────────────────────────────────────
// SINGLE SOURCE OF TRUTH for every adjustable mission-action parameter.
//
// Each op the MissionExecutor can run (takeoff, land, fly_to, change_altitude,
// rotate, orbit, hover, look_at, photo, selfie, panorama, follow, return,
// abort) reads its knobs from here. Tune values in this file — no need to dig
// through the executor or behavior loops.
//
// Where the actual control code lives:
//   • Step dispatch / composites:  Nimbus/Orchestrator/MissionExecutor.swift
//   • Closed-loop primitives:      Nimbus/FlightControl/FlightBehaviors.swift
//   • SDK calls (takeoff/land/photo/gimbal/hotpoint): Nimbus/FlightControl/DJISDKBridge.swift
//   • Global safety clamps:        Nimbus/FlightControl/SafetySupervisor.swift
// ─────────────────────────────────────────────────────────────────────────────

import Foundation

final class ActionTuning {

    static let shared = ActionTuning()
    private init() {}

    // =========================================================================
    // PERFORMANCE PROFILE
    //
    // Hard ceiling: SafetySupervisor.maxSpeedMps (horizontal, 5 m/s) and
    // SafetySupervisor.maxYawDps (150 deg/s). Every command is clamped there
    // before hitting the DJI SDK.
    // =========================================================================

    // MARK: - Acceleration ramps (sendSmoothedVelocity slew limits)
    //
    // These control how fast the drone reaches its target speed, not the top
    // speed itself. Units: m/s per timer tick (10 Hz) = m/s² × 0.1.

    /// Linear acceleration ramp per tick (m/s · tick⁻¹).
    /// 0.8 → 8 m/s² — snappy starts/stops without jerk.
    var slewLinear: Float       = 0.8

    /// Yaw acceleration ramp per tick (deg/s · tick⁻¹).
    /// 30 → 300 deg/s² — very fast engagement without oscillation.
    var slewYaw: Float          = 30.0

    // MARK: - fly_to (visual approach / cardinal move)

    /// Stop when target bbox occupies ≥ this fraction of the frame.
    /// 0.20 → gets within ~arm’s reach before stopping.
    var flyToStopAreaFraction   = 0.20
    /// Forward speed gain vs. remaining area error.
    var flyToForwardGain        = 3.5
    /// Yaw rate gain (deg/s per unit of normalised horizontal error).
    var flyToYawGainDps         = 45.0
    /// Vertical speed gain vs. normalised vertical bbox-center error.
    var flyToVerticalGain       = 1.5
    /// Rotate-first threshold (deg): suppress translation while yaw error > this.
    var flyToYawAlignThresholdDeg = 10.0
    /// Hard time limit for a visual approach.
    var flyToMaxSeconds         = 25.0
    /// Cardinal moves: 3 m/s cruise, 3 m default distance (meaningful, visible move).
    var flyToCardinalSpeedMps: Float = 3.0
    var flyToCardinalDefaultDistanceM = 3.0
    /// Stop tolerance for closed-loop distance moves (meters).
    var flyToCardinalDistanceToleranceM = 0.20
    /// Timeout budget for closed-loop cardinal motion (seconds per meter).
    /// Keeps commands bounded if telemetry is noisy or propulsion is constrained.
    var flyToCardinalMaxSecondsPerMeter = 2.5

    // MARK: - change_altitude

    /// Done when within this many meters of the target altitude.
    var altitudeToleranceM      = 0.3
    /// Vertical velocity gain vs. altitude error (m/s per m).
    /// 1.5 → altitude snaps quickly to the commanded level.
    var altitudeGain            = 1.5
    var altitudeMaxSeconds      = 20.0

    // MARK: - rotate

    var rotateDefaultDegrees    = 90.0
    /// Max yaw rate for the closed-loop turn (deg/s).
    /// 120 is below the 150 safety cap, giving the decel curve room to stop
    /// accurately. Raise toward 150 if you want faster spins.
    var rotateMaxRateDps        = 120.0
    var rotateMinRateDps        = 8.0
    /// Rate ramps down as (remaining° × gain), clamped to max/min above.
    var rotateRateGain          = 1.5
    /// Done when remaining angle drops below this (deg).
    var rotateStopToleranceDeg  = 2.0

    // MARK: - orbit

    /// No GPS indoors — always use the Virtual-Stick circle fallback.
    var orbitUseSDKHotpoint     = false
    /// 3 m radius — visible arc without needing a huge space.
    var orbitRadiusM            = 3.0
    /// 25 deg/s ≈ 14.4 s per revolution — dynamic and cinematic.
    var orbitAngularVelocityDps = 25.0
    var orbitDefaultRevolutions = 1.0
    /// Standoff for the approach leg before orbiting.
    var orbitApproachStandoffM  = 0.8

    // MARK: - hover

    var hoverDefaultSeconds     = 5.0

    // MARK: - look_at

    /// Camera horizontal FOV used to convert bbox offset → yaw angle.
    var lookAtHorizontalFovDeg  = 78.0
    /// Gimbal pitch when the target is at the very bottom of the frame (deg).
    var lookAtMaxDownPitchDeg   = 60.0

    // MARK: - photo

    /// "Forward" gimbal pitch for photo/selfie/panorama (0 = level).
    var photoGimbalPitchDeg     = 0.0
    /// Settle time after pointing the gimbal, before firing the shutter.
    var photoSettleSeconds      = 0.6
    /// Save a copy of the captured frame to the iPhone camera roll.
    var photoSaveToCameraRoll   = true

    // MARK: - selfie

    /// Fly forward at speed for this many seconds before the 180° turn.
    /// 2 m/s × 3 s = 6 m travel — a proper dronie arc.
    var selfieForwardSpeedMps: Float = 2.0
    var selfieForwardSeconds    = 3.0
    /// Settle time after the turn, before the shot.
    var selfieSettleSeconds     = 1.0

    // MARK: - panorama

    /// 8 shots × 45° = full circle.
    var panoramaSegments        = 8
    var panoramaStepDeg         = 45.0
    var panoramaGimbalPitchDeg  = 0.0
    /// Settle time after each rotation. 0.8 s is enough with VPS active.
    var panoramaSettleSeconds   = 0.8

    // MARK: - follow

    var followDefaultSeconds    = 30.0
    /// Overhead follow altitude AGL (m). 3.5 m gives a cinematic top-down.
    var followAltitudeM         = 3.5
    /// Screen-error → velocity gains.
    var followLateralGain       = 3.0
    var followForwardGain       = 2.5
    var followAltitudeGain      = 1.0
    var followYawGain           = 2.0
    /// Low-pass filter alpha (0–1, higher = snappier tracking).
    var followErrorFilterAlpha  = 0.40
    /// Yaw-first: translation deferred while heading error exceeds this (deg).
    var followYawFirstThresholdDeg = 5.0
    /// Radial lens-distortion coefficient for the bbox chase point (barrel < 0).
    var followLensK1            = -0.18

    // Predictive target filter (alpha-beta / g-h filter on the chase point).
    //
    // The tracker measurement is smoothed into a position + velocity estimate;
    // the controller chases a short look-ahead prediction of where the person
    // WILL be, which removes lag without amplifying jitter.

    /// Position correction gain (0–1). Higher = trust new measurements more.
    var followPosFilterAlpha    = 0.35
    /// Velocity correction gain (0–1). Higher = velocity estimate adapts faster.
    var followVelFilterBeta     = 0.10
    /// Seconds of look-ahead prediction applied to the chase point.
    var followPredictionLookaheadSec = 0.25
    /// Feed-forward: fraction of the target's screen velocity added to the
    /// body velocity command so the drone matches a moving person's pace.
    var followVelocityFeedForwardGain = 0.6
    /// Ticks (10 Hz) to keep flying on the predicted path after the visual
    /// tracker drops out, before falling back to hover + re-acquisition scan.
    var followCoastMaxTicks     = 6
    /// Per-tick velocity decay while coasting blind (keeps coast conservative).
    var followCoastVelocityDecay = 0.85

    // MARK: - headingHold (background yaw alignment to user's AirPods heading)

    /// Heading errors smaller than this are ignored to prevent constant micro-jitter.
    var headingHoldDeadZoneDeg  = 2.0
    /// Proportional rate gain: rate = |error| × gain, clamped to rotate min/max.
    var headingHoldGain         = 3.0

    // MARK: - return

    var returnMaxSeconds        = 60.0

    // MARK: - abort

    /// false = stop + hold in place (spec default).
    /// true  = stop, then resume the session’s overhead hold.
    var abortResumesOverheadHold = false
}
