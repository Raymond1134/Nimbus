import Foundation
import Combine
import CoreLocation

/// Wraps DJI Waypoint Mission SDK endpoints needed for autonomous point-to-point navigation.
///
/// NOTE: Waypoint missions require:
///   - DJI SDK 4.14+ for Mini 2 support
///   - Drone in GPS mode with ≥6 satellites
///   - Valid home point set
final class WaypointManager: NSObject, ObservableObject {
    static let shared = WaypointManager()

    // MARK: - State
    @Published var missionState = "Idle"
    @Published var currentWaypointIndex = 0
    @Published var totalWaypoints = 0

    private var missionOperator: DJIWaypointMissionOperator? {
        DJISDKManager.missionControl()?.waypointMissionOperator()
    }

    private override init() {
        super.init()
    }

    /// Call once after SDK registration to subscribe to mission execution events.
    func setupListeners() {
        missionOperator?.addListener(toExecutionEvent: self, with: .main) { [weak self] event in
            if let progress = event.progress {
                self?.currentWaypointIndex = progress.targetWaypointIndex
                self?.missionState = "Flying to waypoint \(progress.targetWaypointIndex + 1)"
            }
        }
        missionOperator?.addListener(toFinished: self, with: .main) { [weak self] error in
            DispatchQueue.main.async {
                self?.missionState = error == nil ? "Mission Complete" : "Mission Error: \(error!.localizedDescription)"
            }
        }
    }

    // MARK: - Fly to Single GPS Point
    // Primary endpoint for the point-navigation system.

    func flyTo(
        coordinate: CLLocationCoordinate2D,
        altitude: Float,
        speed: Float = 5.0,
        completion: @escaping (Error?) -> Void
    ) {
        executeWaypointMission(
            waypoints: [(coordinate: coordinate, altitude: altitude)],
            speed: speed,
            finishedAction: .noAction,
            completion: completion
        )
    }

    // MARK: - Multi-Point Route

    func executeRoute(
        waypoints: [(coordinate: CLLocationCoordinate2D, altitude: Float)],
        speed: Float = 5.0,
        finishedAction: DJIWaypointMissionFinishedAction = .goHome,
        completion: @escaping (Error?) -> Void
    ) {
        executeWaypointMission(
            waypoints: waypoints,
            speed: speed,
            finishedAction: finishedAction,
            completion: completion
        )
    }

    // MARK: - Core Mission Builder

    private func executeWaypointMission(
        waypoints: [(coordinate: CLLocationCoordinate2D, altitude: Float)],
        speed: Float,
        finishedAction: DJIWaypointMissionFinishedAction,
        completion: @escaping (Error?) -> Void
    ) {
        let mission = DJIMutableWaypointMission()
        mission.maxFlightSpeed    = 10
        mission.autoFlightSpeed   = speed
        mission.finishedAction    = finishedAction
        mission.headingMode       = .auto
        mission.flightPathMode    = .normal
        mission.rotateGimbalPitch = true  // tilt camera toward next waypoint
        mission.exitMissionOnRCSignalLost = true  // safety: abort if RC disconnects

        for wp in waypoints {
            let waypoint = DJIWaypoint(coordinate: wp.coordinate)
            waypoint.altitude          = wp.altitude
            waypoint.cornerRadiusInMeters = 0.2
            waypoint.turnMode          = .clockwise
            mission.add(waypoint)
        }

        totalWaypoints = waypoints.count

        // Validate locally before uploading
        if let loadError = missionOperator?.load(mission) {
            completion(loadError)
            return
        }

        missionState = "Uploading…"
        missionOperator?.uploadMission(completion: { [weak self] error in
            if let error = error {
                DispatchQueue.main.async { self?.missionState = "Upload Failed" }
                completion(error)
                return
            }
            DispatchQueue.main.async { self?.missionState = "Starting…" }
            self?.missionOperator?.startMission(completion: { error in
                DispatchQueue.main.async {
                    self?.missionState = error == nil ? "Running" : "Start Failed"
                }
                completion(error)
            })
        })
    }

    // MARK: - Mission Control

    func pause(completion: @escaping (Error?) -> Void) {
        missionOperator?.pauseMission(completion: { [weak self] error in
            DispatchQueue.main.async {
                self?.missionState = error == nil ? "Paused" : "Pause Failed"
            }
            completion(error)
        })
    }

    func resume(completion: @escaping (Error?) -> Void) {
        missionOperator?.resumeMission(completion: { [weak self] error in
            DispatchQueue.main.async {
                self?.missionState = error == nil ? "Running" : "Resume Failed"
            }
            completion(error)
        })
    }

    func stop(completion: @escaping (Error?) -> Void) {
        missionOperator?.stopMission(completion: { [weak self] error in
            DispatchQueue.main.async {
                self?.missionState = error == nil ? "Stopped" : "Stop Failed"
            }
            completion(error)
        })
    }

    // MARK: - Current Mission State Query

    var currentSDKState: DJIWaypointMissionState {
        missionOperator?.currentState ?? .unknown
    }
}
