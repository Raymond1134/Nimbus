// SafetySupervisor.swift — Nimbus
// Enforces all safety constraints from spec §8.
// Every Virtual Stick velocity passes through clamp() before being sent.

import Foundation

final class SafetySupervisor {

    // MARK: - Configurable Limits (spec §8)

    /// Maximum speed for any virtual-stick velocity axis (m/s).
    var maxSpeedMps: Double     = 2.0

    /// Hard altitude ceiling AGL (m). SDK's own limit should also be set.
    var maxAltitudeM: Double    = 30.0

    /// Minimum standoff from any grounded target (m).
    var minStandoffM: Double    = 2.0

    /// Search radius limit (m from home point) — informational; not yet wired to GPS fence.
    var geofenceRadiusM: Double = 50.0

    /// Dead-man switch interval (s). DJISDKBridge sends zero-velocity if no
    /// command arrives within this window.
    var deadManIntervalSec: Double = 0.3

    // MARK: - Velocity Clamp

    func clamp(_ v: Double) -> Double {
        Swift.max(-maxSpeedMps, Swift.min(maxSpeedMps, v))
    }

    func clamp(_ v: Float) -> Float {
        Float(clamp(Double(v)))
    }

    /// Clamp yaw angular rate to ±maxDps deg/s.
    func clampYawDps(_ v: Double, maxDps: Double = 45) -> Double {
        Swift.max(-maxDps, Swift.min(maxDps, v))
    }

    // MARK: - FlightTarget Validation

    enum ValidationResult {
        case approved
        case rejected(String)
    }

    func validate(_ target: FlightTarget, telemetry: TelemetrySnapshot) -> ValidationResult {
        if target.standoffM < minStandoffM {
            return .rejected(
                "Standoff \(String(format: "%.1f", target.standoffM))m is below "
                + "minimum \(String(format: "%.1f", minStandoffM))m"
            )
        }
        if telemetry.altitudeM >= maxAltitudeM {
            return .rejected(
                "Already at altitude ceiling \(Int(telemetry.altitudeM))m "
                + "(limit \(Int(maxAltitudeM))m)"
            )
        }
        return .approved
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
