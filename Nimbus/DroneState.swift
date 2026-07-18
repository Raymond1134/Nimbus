import Foundation
import Combine
import CoreLocation

/// Published drone telemetry consumed by SwiftUI views.
/// Populated by DJI delegate callbacks set up on product connection.
final class DroneState: NSObject, ObservableObject {
    static let shared = DroneState()

    // MARK: - Connection
    @Published var isConnected = false
    @Published var productName = ""

    // MARK: - Battery
    @Published var batteryPercent = 0

    // MARK: - Flight State
    @Published var isFlying = false
    @Published var flightMode = "N/A"
    @Published var altitudeMeters: Float = 0
    @Published var velocityX: Float = 0   // m/s north
    @Published var velocityY: Float = 0   // m/s east
    @Published var velocityZ: Float = 0   // m/s up

    // MARK: - GPS
    @Published var coordinate = CLLocationCoordinate2D()
    @Published var gpsSatellites = 0
    @Published var homeCoordinate: CLLocationCoordinate2D?

    // MARK: - Gimbal
    @Published var gimbalPitchDegrees: Float = 0

    private override init() { super.init() }

    /// Call after product connects to receive delegate updates.
    func setupListeners() {
        guard let aircraft = DJISDKManager.product() as? DJIAircraft else { return }
        aircraft.flightController?.delegate = self
        aircraft.battery?.delegate = self
        aircraft.gimbal?.delegate = self
    }

    /// Call on product disconnect to release delegates.
    func teardownListeners() {
        guard let aircraft = DJISDKManager.product() as? DJIAircraft else { return }
        aircraft.flightController?.delegate = nil
        aircraft.battery?.delegate = nil
        aircraft.gimbal?.delegate = nil
    }
}

// MARK: - DJIFlightControllerDelegate

extension DroneState: DJIFlightControllerDelegate {
    func flightController(_ fc: DJIFlightController, didUpdate state: DJIFlightControllerState) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isFlying         = state.isFlying
            self.flightMode       = state.flightModeString
            self.altitudeMeters   = Float(state.altitude)
            self.velocityX        = Float(state.velocityX)
            self.velocityY        = Float(state.velocityY)
            self.velocityZ        = Float(state.velocityZ)
            self.gpsSatellites    = Int(state.satelliteCount)
            if let loc = state.aircraftLocation {
                self.coordinate = loc.coordinate
            }
            if let home = state.homeLocation {
                self.homeCoordinate = home.coordinate
            }
        }
    }
}

// MARK: - DJIBatteryDelegate

extension DroneState: DJIBatteryDelegate {
    func battery(_ battery: DJIBattery, didUpdate state: DJIBatteryState) {
        DispatchQueue.main.async { [weak self] in
            self?.batteryPercent = Int(state.chargeRemainingInPercent)
        }
    }
}

// MARK: - DJIGimbalDelegate

extension DroneState: DJIGimbalDelegate {
    func gimbal(_ gimbal: DJIGimbal, didUpdate state: DJIGimbalState) {
        DispatchQueue.main.async { [weak self] in
            self?.gimbalPitchDegrees = Float(state.attitudeInDegrees.pitch)
        }
    }
}
