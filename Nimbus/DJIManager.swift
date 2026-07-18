// DJIManager.swift — Nimbus
// Wraps DJI SDK registration, product connection, and RC pairing.
// Routes aircraft connect/disconnect into DJISDKBridge.shared.

import Foundation
import Observation

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

    // MARK: - Connection Watchdog

    /// Timestamp of the last productConnected or productDisconnected event.
    /// Expose to the UI debug panel to surface stale-connection age.
    var lastConnectionEvent = Date()

    /// Seconds elapsed since the last productConnected or productDisconnected event.
    var secondsSinceLastEvent: Double {
        Date().timeIntervalSince(lastConnectionEvent)
    }

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
    /// Set before calling disconnectFromProduct() so the auto-reconnect logic
    /// knows not to immediately reconnect after an explicit user-initiated teardown.
    private var userRequestedDisconnect = false
    /// Counts consecutive reconnect attempts; reset to 0 on successful connect.
    private var reconnectAttempt = 0

    private override init() {
        super.init()
        // Listen for the telemetry-stall signal from DJISDKBridge and force a
        // fresh reconnect cycle when the flight-controller goes silent.
        NotificationCenter.default.addObserver(
            forName: .djiTelemetryStalled,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            print("DJIManager: received djiTelemetryStalled — forcing reconnect.")
            self?.forceReconnect()
        }
    }

    // MARK: - Registration

    func registerApp() {
        DJISDKManager.registerApp(with: self)
    }

    // MARK: - Connect / Disconnect

    /// Initiate the app → RC → aircraft connection (USB or bridge).
    /// Safe to call any time after registration; retries are harmless.
    func startConnectionToProduct() {
        guard isRegistered else { return }
        isConnecting = true
        DJISDKManager.startConnectionToProduct()
        print("DJIManager: startConnectionToProduct() called.")
    }

    /// Tear down the active product connection.
    /// After an explicit disconnect, auto-reconnect is suppressed until the
    /// next `startConnectionToProduct()` call.
    func disconnectFromProduct() {
        userRequestedDisconnect = true
        DJISDKManager.stopConnectionToProduct()
        isConnecting = false
        print("DJIManager: disconnectFromProduct() called.")
    }

    /// Force a fresh reconnect cycle — stops any in-progress connection, resets
    /// the backoff counter, and starts a new connection scan.
    /// Safe to call from the UI debug panel or from the telemetry-stall watchdog.
    func forceReconnect() {
        print("DJIManager: forceReconnect() — stopping connection, resetting backoff counter.")
        DJISDKManager.stopConnectionToProduct()
        reconnectAttempt = 0
        userRequestedDisconnect = false
        if isRegistered {
            startConnectionToProduct()
        } else {
            registerApp()
        }
    }

    // MARK: - RC Pairing

    /// Put the RC into linking mode so it can pair with a new aircraft.
    /// The drone must be powered on and within range.
    func startPairing() {
        guard let rc = remoteController else {
            pairingStatus = "No RC detected — connect to aircraft first."
            return
        }
        rc.startPairing { [weak self] (error: Error?) in
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
        rc.stopPairing { [weak self] (error: Error?) in
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
        lastConnectionEvent = Date()
        if let product {
            let modelName = product.model ?? "unknown"

            // ── RC-only product (e.g. Smart Controller without a linked drone) ──
            // Some DJI RCs enumerate as a standalone DJIRemoteController product
            // before the drone link is established. Mark RC as present immediately
            // so the UI can show RC-connected state before the full aircraft link fires.
            if let rc = product as? DJIRemoteController {
                remoteController = rc
                rc.delegate      = self
                isRCConnected    = true
                isConnecting     = false
                print("DJIManager: RC-only product detected (\(modelName)) — awaiting drone link.")
                return
            }

            // ── Full aircraft + RC ──
            reconnectAttempt = 0   // reset backoff on successful connect
            print("DJIManager: product connected — model: \(modelName).")
            DJISDKBridge.shared.onProductConnected(product)
            isConnecting = false
            userRequestedDisconnect = false  // clear any previous explicit-disconnect flag

            // Wire AirLink delegate for uplink signal quality updates.
            product.airLink?.delegate = self

            // Wire RC delegate and mark RC present.
            if let aircraft = product as? DJIAircraft,
               let rc = aircraft.remoteController {
                remoteController = rc
                rc.delegate      = self
                isRCConnected    = true
                print("DJIManager: RC connected to aircraft \(modelName).")
            }

        } else {
            print("DJIManager: product disconnected — scheduling auto-reconnect (attempt #\(reconnectAttempt + 1)).")
            DJISDKBridge.shared.onProductDisconnected()
            remoteController = nil
            isRCConnected    = false
            rcSignalPercent  = -1
            isPairing        = false
            isConnecting     = false

            // Auto-reconnect — mirrors the DJI app which never requires the user
            // to manually press Connect after an unexpected drop.
            scheduleReconnect()
        }
    }

    /// Schedules a reconnect attempt with exponential backoff (2 s, 4 s, 8 s … capped at 30 s).
    /// Calls `stopConnectionToProduct()` before each retry to flush stale DJI SDK state
    /// that accumulates when DJI Fly is power-cycled or closed.
    private func scheduleReconnect() {
        guard !userRequestedDisconnect else {
            print("DJIManager: skipping auto-reconnect (user-initiated disconnect).")
            return
        }
        let delay = min(2.0 * pow(2.0, Double(reconnectAttempt)), 30.0)
        reconnectAttempt += 1
        print("DJIManager: scheduling reconnect attempt #\(reconnectAttempt) in \(String(format: "%.1f", delay)) s.")
        Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(delay))
            guard self.isRegistered,
                  !DJISDKBridge.shared.isAircraftConnected,
                  !self.userRequestedDisconnect else { return }
            print("DJIManager: auto-reconnecting (attempt #\(self.reconnectAttempt))…")
            // Stop first to flush any stale SDK state from DJI Fly.
            DJISDKManager.stopConnectionToProduct()
            self.startConnectionToProduct()
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
                // Kick off the connection scan.  productConnected(_:) will fire
                // when the RC↔drone link (existing or newly established) is detected.
                self.startConnectionToProduct()
            }
            self.showRegistrationAlert = true
        }
    }

    /// Called when the RC↔drone link is fully established (pre-existing pair or new).
    /// This is the primary signal — fires reliably for both already-paired and newly-paired RCs.
    func productConnected(_ product: DJIBaseProduct?) {
        Task { @MainActor in
            self.handleProductChange(product)
        }
    }

    /// Called when the product disconnects (RC unplugged, drone powered off, etc.).
    func productDisconnected() {
        Task { @MainActor in
            self.handleProductChange(nil)
        }
    }

    /// Safety-net fallback for product-change events not captured by the pair above.
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
            if pct < 20, DJISDKBridge.shared.isAircraftConnected {
                print("DJIManager: WARNING — RC uplink signal low: \(pct)%")
            }
        }
    }
}
