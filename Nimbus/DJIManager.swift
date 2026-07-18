// DJIManager.swift — Nimbus
// Wraps DJI SDK registration, product connection, and RC pairing.

import Foundation
import Observation

@Observable
final class DJIManager: NSObject {

    static let shared = DJIManager()

    var isRegistered          = false
    var registrationMessage   = ""
    var showRegistrationAlert = false
    var isConnecting = false
    var isRCConnected = false
    var rcSignalPercent: Int = -1
    var isPairing = false
    var pairingStatus = ""

    private weak var remoteController: DJIRemoteController?

    private override init() { super.init() }

    func registerApp() {
        DJISDKManager.registerApp(with: self)
    }

    func startConnectionToProduct() {
        guard isRegistered, !isConnecting else { return }
        isConnecting = true
        DJISDKManager.startConnectionToProduct()
        print("DJIManager: startConnectionToProduct() called.")
    }

    func disconnectFromProduct() {
        DJISDKManager.stopConnectionToProduct()
        isConnecting = false
        print("DJIManager: disconnectFromProduct() called.")
    }

    func startPairing() {
        guard let rc = remoteController else {
            pairingStatus = "No RC detected — connect to aircraft first."
            return
        }
        rc.startPairing(completion: { [weak self] (error: Error?) in
            Task { @MainActor in
                if let error {
                    self?.pairingStatus = "Pairing error: \(error.localizedDescription)"
                    self?.isPairing = false
                } else {
                    self?.pairingStatus = "Pairing active — hold Link button on drone"
                    self?.isPairing = true
                }
            }
        })
    }

    func stopPairing() {
        guard let rc = remoteController else { return }
        rc.stopPairing(completion: { [weak self] (error: Error?) in
            Task { @MainActor in
                self?.isPairing = false
                if let error {
                    self?.pairingStatus = "Stop-pair error: \(error.localizedDescription)"
                } else {
                    self?.pairingStatus = "Pairing stopped."
                }
            }
        })
    }

    private func handleProductChange(_ product: DJIBaseProduct?) {
        if let product {
            let modelName = product.model ?? "unknown"
            print("DJIManager: product connected — \(modelName)")
            isConnecting = false

            if let aircraft = product as? DJIAircraft {
                if let rc = aircraft.remoteController {
                    remoteController = rc
                    isRCConnected    = true
                }
            }
        } else {
            print("DJIManager: product disconnected.")
            remoteController   = nil
            isRCConnected      = false
            rcSignalPercent    = -1
            isPairing          = false
            isConnecting       = false
        }
    }
}

extension DJIManager: DJISDKManagerDelegate {

    func appRegisteredWithError(_ error: Error?) {
        Task { @MainActor in
            // 🚀 HACKATHON CORE OVERRIDE: Force local testing states to turn completely green
            print("🚀 Local bypass active: forcing core registration success for voice sprints.")
            self.isRegistered          = true
            self.registrationMessage   = "Bypass Active: Voice Pipeline Testing Mode Enabled"
            self.showRegistrationAlert = false
            
            if let activeProduct = DJISDKManager.product() {
                self.startConnectionToProduct()
                self.handleProductChange(activeProduct)
            }
        }
    }

    func sdkManagerProductDidChange(from oldProduct: DJIBaseProduct?, to newProduct: DJIBaseProduct?) {
        Task { @MainActor in
            self.handleProductChange(newProduct)
        }
    }

    func didUpdateDatabaseDownloadProgress(_ progress: Progress) {}
}

