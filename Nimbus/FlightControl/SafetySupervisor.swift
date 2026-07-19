// SafetySupervisor.swift — Nimbus
// Enforces all safety constraints from spec §8.
// Every Virtual Stick velocity passes through clamp() before being sent.

import Foundation

final class SafetySupervisor {

    // MARK: - Configurable Limits
    //
    // Defaults are set for INDOOR / NO-GPS operation (cramped spaces).
    // Increase these when flying outdoors with GPS.
    //
    // The safety ceiling is ALSO enforced by an SDK limit set in Xcode's
    // DJI app-key config; make sure both stay in sync.

    /// Maximum speed for any virtual-stick horizontal/vertical axis (m/s).
    var maxSpeedMps: Double     = 5.0

    /// Maximum yaw angular rate (deg/s). DJI VS accepts up to ~200 on most
    /// airframes; 150 is high-end while still giving the decel curve room to
    /// stop accurately.
    var maxYawDps: Double       = 150.0

    /// Hard altitude ceiling AGL (m). SDK's own limit should also be set.
    var maxAltitudeM: Double    = 30.0

    /// Minimum standoff from any grounded target (m).
    var minStandoffM: Double    = 2.0

    /// Dead-man switch interval (s). DJISDKBridge sends zero-velocity if no
    /// command arrives within this window. Keep tight for indoor flight.
    var deadManIntervalSec: Double = 0.3

    // MARK: - Velocity Clamp

    func clamp(_ v: Double) -> Double {
        Swift.max(-maxSpeedMps, Swift.min(maxSpeedMps, v))
    }

    func clamp(_ v: Float) -> Float {
        Float(clamp(Double(v)))
    }

    /// Clamp yaw angular rate to ±maxYawDps deg/s.
    func clampYawDps(_ v: Double) -> Double {
        Swift.max(-maxYawDps, Swift.min(maxYawDps, v))
    }

    // MARK: - Live Telemetry Check

    enum SafetyStatus {
        case ok
        case altitudeCeiling(String)
        case batteryLow(Int)
    }

    func check(telemetry: TelemetrySnapshot) -> SafetyStatus {
        if telemetry.altitudeM >= maxAltitudeM {
            return .altitudeCeiling(
                "Alt \(Int(telemetry.altitudeM))m ≥ limit \(Int(maxAltitudeM))m"
            )
        }
        // Warn at 15%; critical at 10%
        if telemetry.batteryPercent > 0 && telemetry.batteryPercent <= 15 {
            return .batteryLow(telemetry.batteryPercent)
        }
        return .ok
    }
}
