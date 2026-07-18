// DJIManager.swift — Nimbus
// Wraps DJI SDK registration, product connection, and RC pairing.
// Routes aircraft connect/disconnect into DJISDKBridge.shared.

import Foundation

/// Uses @Observable (not ObservableObject) so that reads via an @Observable Orchestrator
/// are tracked correctly by SwiftUI views.
@Observable
final class DJIManager: NSObject {

    static let shared = DJIManager()

    // MARK: - SDK Registration State

    var isRegistered          = false
    var registrationMessage   = ""
    var showRegistrationAlert = false

    // MARK: - Connection State

    /// True while `startConnectionToProduct()` is pending.
    var isConnecting = false

    // MARK: - RC State

    /// True when the remote controller is physically connected to the phone.
    var isRCConnected = false
    /// RC uplink signal quality 0–100.  -1 when no RC is detected.
    var rcSignalPercent: Int = -1

    // MARK: - Pairing State

    /// True while the RC is actively broadcasting in pairing / linking mode.
    var isPairing = false
    /// Human-readable summary of the last pairing event.
    var pairingStatus = ""

    // MARK: - Private

    private weak var remoteController: DJIRemoteController?

    private override init() { super.init() }

    // MARK: - Registration

    func registerApp() {
        DJISDKManager.registerApp(with: self)
    }

    // MARK: - Connect / Disconnect

    /// Initiate the app → RC → aircraft connection (USB or bridge).
    /// Safe to call repeatedly; ignored if already connecting or not registered.
    func startConnectionToProduct() {
        guard isRegistered, !isConnecting else { return }
        isConnecting = true
        DJISDKManager.startConnectionToProduct()
        print("DJIManager: startConnectionToProduct() called.")
    }

    /// Tear down the active product connection.
    func disconnectFromProduct() {
        DJISDKManager.stopConnectionToProduct()
        isConnecting = false
        print("DJIManager: disconnectFromProduct() called.")
    }

    // MARK: - RC Pairing

    /// Put the RC into linking mode so it can pair with a new aircraft.
    /// The drone must be powered on and within range.
    func startPairing() {
        guard let rc = remoteController else {
            pairingStatus = "No RC detected — connect to aircraft first."
            return
        }
        rc.startPairingWithCompletion { [weak self] (error: Error?) in
            Task { @MainActor in
                if let error {
                    self?.pairingStatus = "Pairing error: \(error.localizedDescription)"
                    self?.isPairing = false
                } else {
                    self?.pairingStatus = "Pairing active — hold Link button on drone"
                    self?.isPairing = true
                }
            }
        }
    }

    /// Exit RC pairing mode.
    func stopPairing() {
        guard let rc = remoteController else { return }
        rc.stopPairingWithCompletion { [weak self] (error: Error?) in
            Task { @MainActor in
                self?.isPairing = false
                if let error {
                    self?.pairingStatus = "Stop-pair error: \(error.localizedDescription)"
                } else {
                    self?.pairingStatus = "Pairing stopped."
                }
            }
        }
    }

    // MARK: - Private helpers

    private func handleProductChange(_ product: DJIBaseProduct?) {
        if let product {
            let modelName = product.model ?? "unknown"
            print("DJIManager: product connected — \(modelName)")
            DJISDKBridge.shared.onProductConnected(product)
            isConnecting = false

            // Wire AirLink delegate for uplink signal quality updates.
            product.airLink?.delegate = self

            // Wire RC delegate and mark RC present.
            if let aircraft = product as? DJIAircraft {
                if let rc = aircraft.remoteController {
                    remoteController = rc
                    rc.delegate      = self
                    isRCConnected    = true
                }
            }
        } else {
            print("DJIManager: product disconnected.")
            DJISDKBridge.shared.onProductDisconnected()
            remoteController   = nil
            isRCConnected      = false
            rcSignalPercent    = -1
            isPairing          = false
            isConnecting       = false
        }
    }
}

// MARK: - DJISDKManagerDelegate

extension DJIManager: DJISDKManagerDelegate {

    func appRegisteredWithError(_ error: Error?) {
        Task { @MainActor in
            if let error {
                print("DJI registration failed: \(error.localizedDescription)")
                self.registrationMessage   = "Registration failed — check App Key and network."
                self.isRegistered          = false
            } else {
                print("DJI registration succeeded.")
                self.registrationMessage   = "DJI SDK registered successfully."
                self.isRegistered          = true
                // Auto-connect and pick up any already-attached aircraft.
                self.startConnectionToProduct()
                self.handleProductChange(DJISDKManager.product())
            }
            self.showRegistrationAlert = true
        }
    }

    /// Called whenever an aircraft is physically connected or disconnected.
    func sdkManagerProductDidChange(from oldProduct: DJIBaseProduct?,
                                    to newProduct: DJIBaseProduct?) {
        Task { @MainActor in
            self.handleProductChange(newProduct)
        }
    }

    func didUpdateDatabaseDownloadProgress(_ progress: Progress) {
        let pct = Int(progress.fractionCompleted * 100)
        print("DJI fly-safe DB: \(pct)%")
    }
}

// MARK: - DJIRemoteControllerDelegate

/// Conform to receive optional RC callbacks (e.g. battery on Smart Controller).
extension DJIManager: DJIRemoteControllerDelegate { }

// MARK: - DJIAirLinkDelegate

/// Uplink = RC → aircraft link.  Updates every ~0.5 s while connected.
extension DJIManager: DJIAirLinkDelegate {

    func airLink(_ airLink: DJIAirLink,
                 didUpdateUplinkSignalQuality quality: UInt) {
        let pct = Int(quality)
        Task { @MainActor in
            self.rcSignalPercent = pct
        }
    }
}
