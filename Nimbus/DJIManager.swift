// DJIManager.swift — Nimbus
// Wraps DJI SDK registration and product connection events.
// Routes aircraft connect/disconnect into DJISDKBridge.shared.

import Foundation

/// Uses @Observable (not ObservableObject) so that reads via an @Observable Orchestrator
/// are tracked correctly by SwiftUI views.
@Observable
final class DJIManager: NSObject {

    static let shared = DJIManager()

    var isRegistered          = false
    var registrationMessage   = ""
    var showRegistrationAlert = false

    private override init() { super.init() }

    func registerApp() {
        DJISDKManager.registerApp(with: self)
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
                // Pick up any aircraft already attached at registration time
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

    // MARK: - Private

    private func handleProductChange(_ product: DJIBaseProduct?) {
        if let product {
            print("DJI product connected: \(product.model ?? "unknown")")
            DJISDKBridge.shared.onProductConnected(product)
        } else {
            print("DJI product disconnected.")
            DJISDKBridge.shared.onProductDisconnected()
        }
    }
}
