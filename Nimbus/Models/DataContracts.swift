// DataContracts.swift — Nimbus
// Shared data types across all components (spec §4).
// Every type here is Sendable or a struct to be safe across actor boundaries.

import Foundation
import CoreGraphics
import CoreLocation
import SwiftUI

// MARK: - App State (spec §5)

enum AppState: Equatable {
    case idle
    case listening
    case processing
    case executing(verb: String, target: String?)
    case error(message: String)

    static func == (lhs: AppState, rhs: AppState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.listening, .listening), (.processing, .processing):
            return true
        case let (.executing(v1, t1), .executing(v2, t2)):
            return v1 == v2 && t1 == t2
        case let (.error(m1), .error(m2)):
            return m1 == m2
        default:
            return false
        }
    }

    var displayTitle: String {
        switch self {
        case .idle:                   return "IDLE"
        case .listening:              return "LISTENING"
        case .processing:             return "PROCESSING"
        case .executing(let v, _):    return v
        case .error:                  return "ERROR"
        }
    }

    var displayColor: Color {
        switch self {
        case .idle:       return .blue
        case .listening:  return .red
        case .processing: return .orange
        case .executing:  return .green
        case .error:      return .red
        }
    }

    var isActive: Bool {
        switch self {
        case .listening, .processing, .executing: return true
        default: return false
        }
    }
}

// MARK: - Transcript (Voice Capture → Intent Parser, spec §4)

struct TranscriptEvent: Codable, Sendable {
    let text: String
    let timestamp: Double
    let isFinal: Bool

    enum CodingKeys: String, CodingKey {
        case text, timestamp
        case isFinal = "is_final"
    }
}

// MARK: - Nimbus Backend Types

/// One instruction step from the Nimbus backend.
struct NimbusStep: Codable, Sendable, Identifiable {
    var id: Int = 0          // set by Orchestrator after decode
    let op: String           // the instruction op name
    let target: String?      // fly_to(visual), orbit, look_at, follow
    let box2d: [Int]         // [ymin,xmin,ymax,xmax] 0-1000; [] if not found
    let found: Bool          // true = target visible in frame
    let distanceM: Double?   // Gemini distance estimate in meters
    let confidence: Double   // Gemini annotation confidence 0-1
    let deltaM: Double?      // change_altitude: signed meters (+up / -down)
    let direction: String?   // rotate: "left"|"right"; fly_to relative: "forward"|"back"|"left"|"right"
    let degrees: Double?     // rotate
    let revolutions: Double? // orbit
    let seconds: Double?     // hover, follow
    let text: String?        // say

    enum CodingKeys: String, CodingKey {
        case op, target, found, direction, degrees, revolutions, seconds, text, confidence
        case box2d        = "box_2d"
        case distanceM    = "distance_m"
        case deltaM       = "delta_m"
    }
}

/// Full response from POST /voice_command.
struct NimbusResponse: Codable, Sendable {
    let steps: [NimbusStep]
    let confidence: Double
    let transcript: String
}

// MARK: - Object Detection (spec §4)

struct DetectedObject: Identifiable, Sendable {
    let id: String
    let label: String
    let confidence: Float
    /// Normalised 0–1 in Vision coordinate space (origin bottom-left).
    let bbox: CGRect
}

// MARK: - Telemetry Snapshot (Flight Controller → Safety / Spatial Audio)

struct TelemetrySnapshot: Sendable {
    let altitudeM: Double
    let headingDeg: Double
    let velocityX: Double      // m/s east
    let velocityY: Double      // m/s north
    let velocityZ: Double      // m/s up
    let batteryPercent: Int
    let isGPSValid: Bool
    let satelliteCount: Int
    let isFlying: Bool
    let currentLocation: GPSCoordinate?
    let homeLocation: GPSCoordinate?

    static let zero = TelemetrySnapshot(
        altitudeM: 0, headingDeg: 0,
        velocityX: 0, velocityY: 0, velocityZ: 0,
        batteryPercent: 0, isGPSValid: false, satelliteCount: 0,
        isFlying: false, currentLocation: nil, homeLocation: nil
    )
}

// MARK: - GPS Coordinate

struct GPSCoordinate: Codable, Sendable, Equatable {
    let latitude: Double
    let longitude: Double
    let altitudeM: Double?

    init(latitude: Double, longitude: Double, altitudeM: Double? = nil) {
        self.latitude = latitude
        self.longitude = longitude
        self.altitudeM = altitudeM
    }

    var clLocationCoordinate2D: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

struct RememberedSpot: Codable, Sendable, Equatable {
    let name: String
    let coordinate: GPSCoordinate
    let capturedAt: Date
}

// MARK: - Head Attitude

struct HeadAttitude: Sendable {
    let yawDeg: Double
    let pitchDeg: Double
    let rollDeg: Double

    static let zero = HeadAttitude(yawDeg: 0, pitchDeg: 0, rollDeg: 0)
}

// MARK: - Log Entry

struct LogEntry: Identifiable, Sendable {
    let id = UUID()
    let timestamp: Date
    let message: String
    let level: Level

    enum Level: Sendable { case info, warning, error }

    var formatted: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return "\(f.string(from: timestamp))  \(message)"
    }
}
