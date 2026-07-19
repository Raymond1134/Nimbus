// DJIManager.swift — Nimbus
// Ground-up connection state machine for the DJI Mobile SDK.
//
// Design principles:
//   1. Single source of truth — `connectionPhase` is always reconciled against
//      what the SDK actually reports (DJISDKManager.product()), never inferred
//      from delegate-event bookkeeping alone.
//   2. Trust the connection — SDK events are *hints* that trigger verification
//      against ground truth, not immediate teardown commands. A healthy link is
//      never torn down because of a transient event or a quiet moment.
//   3. App-lifecycle aware — backgrounding the app pauses health monitoring but
//      NEVER touches the connection. On foreground we verify the link against
//      the SDK and simply keep it if the aircraft is still there.

import Foundation
import UIKit
import Observation

/// Uses @Observable (not ObservableObject) so that reads via an @Observable Orchestrator
/// are tracked correctly by SwiftUI views.
@Observable
final class DJIManager: NSObject {

    static let shared = DJIManager()

    // MARK: - Connection State Machine

    enum ConnectionPhase: Equatable, CustomStringConvertible {
        case unregistered      // SDK not registered yet
        case registering       // registerApp() in flight
        case disconnected      // registered, no aircraft link, no scan running
        case connecting        // product scan / reconnect loop in progress
        case connected         // verified aircraft link

        var description: String {
            switch self {
            case .unregistered: return "unregistered"
            case .registering:  return "registering"
            case .disconnected: return "disconnected"
            case .connecting:   return "connecting"
            case .connected:    return "connected"
            }
        }
    }

    /// Single source of truth for the app ↔ aircraft link.
    private(set) var connectionPhase: ConnectionPhase = .unregistered

    // Compatibility accessors — existing UI reads these.
    var isRegistered: Bool {
        switch connectionPhase {
        case .unregistered, .registering: return false
        default:                          return true
        }
    }
    var isConnecting: Bool { connectionPhase == .connecting }

    // MARK: - SDK Registration State

    var registrationMessage   = ""
    var showRegistrationAlert = false

    // MARK: - Diagnostics

    /// Timestamp of the last connection-related event (UI debug panel).
    var lastConnectionEvent = Date()

    /// Seconds elapsed since the last connection-related event.
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
    /// Set by disconnectFromProduct() so auto-reconnect stays off until the
    /// user explicitly reconnects.
    private var userRequestedDisconnect = false
    /// The single reconnect/scan loop. Only one may run at a time.
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?
    /// Pending disconnect verification (debounce for transient nil-product events).
    @ObservationIgnored private var disconnectVerifyTask: Task<Void, Never>?
    /// False while the app is backgrounded. Watchdog reactions and scan
    /// attempts are deferred until the app is active again.
    private var isAppActive = true

    private override init() {
        super.init()

        // Telemetry-stall signal from DJISDKBridge → verify before acting.
        NotificationCenter.default.addObserver(
            forName: .djiTelemetryStalled, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.handleTelemetryStall() }
        }

        // App lifecycle: never disconnect on background; verify on foreground.
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.handleAppBackground() }
        }
        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.handleAppForeground() }
        }
    }

    // MARK: - Ground Truth

    /// The aircraft the SDK currently holds, if any.
    private var sdkAircraft: DJIAircraft? {
        DJISDKManager.product() as? DJIAircraft
    }

    /// True when the SDK reports a live aircraft with a connected flight
    /// controller RIGHT NOW. This is the ground truth every decision is
    /// verified against.
    private var sdkReportsAircraftLink: Bool {
        guard let fc = sdkAircraft?.flightController else { return false }
        return fc.isConnected
    }

    // MARK: - Registration

    func registerApp() {
        guard connectionPhase == .unregistered else { return }
        connectionPhase = .registering
        DJISDKManager.registerApp(with: self)
    }

    // MARK: - Public Connect / Disconnect

    /// Start (or re-verify) the app → RC → aircraft connection.
    /// Safe to call any time after registration; idempotent.
    @MainActor
    func startConnectionToProduct() {
        guard isRegistered else { return }
        userRequestedDisconnect = false
        if sdkReportsAircraftLink {
            // Already connected at the SDK level — just reconcile state.
            reconcileConnected(source: "manual-connect")
            return
        }
        startReconnectLoop(reason: "manual connect")
    }

    /// Explicit user-initiated teardown. Auto-reconnect stays off until the
    /// next startConnectionToProduct() call.
    @MainActor
    func disconnectFromProduct() {
        print("DJIManager: user disconnect — auto-reconnect suppressed until Connect.")
        userRequestedDisconnect = true
        cancelReconnectLoop()
        cancelDisconnectVerification()
        DJISDKManager.stopConnectionToProduct()
        if connectionPhase == .connected {
            DJISDKBridge.shared.onProductDisconnected()
        }
        clearRCState()
        connectionPhase = .disconnected
        lastConnectionEvent = Date()
    }

    /// Full teardown + fresh scan. The nuclear option — only for the debug
    /// panel or when a verified-dead connection needs a hard reset.
    @MainActor
    func forceReconnect() {
        guard isRegistered else {
            registerApp()
            return
        }
        print("DJIManager: forceReconnect() — full teardown + fresh scan.")
        userRequestedDisconnect = false
        cancelReconnectLoop()
        cancelDisconnectVerification()
        if connectionPhase == .connected {
            DJISDKBridge.shared.onProductDisconnected()
        }
        clearRCState()
        connectionPhase = .disconnected
        lastConnectionEvent = Date()
        DJISDKManager.stopConnectionToProduct()
        startReconnectLoop(reason: "force reconnect")
    }

    // MARK: - Connection Event Handling (verified)

    /// Central handler for every SDK product event. Product events are treated
    /// as hints: a non-nil product confirms the link; a nil product schedules a
    /// verification instead of tearing down immediately.
    @MainActor
    private func handleProductEvent(_ product: DJIBaseProduct?, source: String) {
        lastConnectionEvent = Date()

        if let aircraft = product as? DJIAircraft {
            if aircraft.flightController != nil {
                // ── Full aircraft link ──
                reconcileConnected(source: source)
            } else {
                // ── RC-only: the SDK enumerates a placeholder aircraft with no
                // flight controller while the RC is connected but the drone
                // link isn't up yet. ──
                cancelDisconnectVerification()
                if let rc = aircraft.remoteController { attachRC(rc) }
                if connectionPhase != .connected { connectionPhase = .connecting }
                print("DJIManager[\(source)]: RC detected — awaiting drone link.")
            }
            return
        }

        // ── nil product → POSSIBLE disconnect. Verify before believing it. ──
        guard connectionPhase == .connected else {
            // Weren't connected anyway — keep/restart the scan if allowed.
            startReconnectLoop(reason: "\(source) event while \(connectionPhase)")
            return
        }
        scheduleDisconnectVerification(after: 1.0, source: source)
    }

    /// Reconcile app state with a live SDK aircraft link. Idempotent — safe to
    /// call on every connect event, foreground verification, or manual connect.
    @MainActor
    private func reconcileConnected(source: String) {
        guard let aircraft = sdkAircraft, aircraft.flightController != nil else { return }
        userRequestedDisconnect = false
        cancelReconnectLoop()
        cancelDisconnectVerification()

        let wasConnected = (connectionPhase == .connected)
        connectionPhase = .connected
        lastConnectionEvent = Date()

        // Bridge setup is idempotent: for an already-configured flight
        // controller it only re-arms delegates and refreshes monitoring.
        DJISDKBridge.shared.onProductConnected(aircraft)
        aircraft.airLink?.delegate = self
        if let rc = aircraft.remoteController {
            attachRC(rc)
        }
        print("DJIManager[\(source)]: aircraft link \(wasConnected ? "confirmed" : "established") — model: \(aircraft.model ?? "unknown").")
    }

    /// A disconnect hint arrived while connected. Wait briefly, then check
    /// ground truth — only tear down if the SDK really lost the aircraft.
    @MainActor
    private func scheduleDisconnectVerification(after delay: Double, source: String) {
        cancelDisconnectVerification()
        print("DJIManager[\(source)]: disconnect hint — verifying in \(String(format: "%.1f", delay))s before acting.")
        disconnectVerifyTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            self.disconnectVerifyTask = nil
            if self.sdkReportsAircraftLink {
                print("DJIManager[\(source)]: disconnect was transient — link verified alive, keeping connection.")
                self.reconcileConnected(source: "\(source)-verify")
            } else {
                print("DJIManager[\(source)]: disconnect verified — aircraft link lost.")
                self.commitDisconnect()
            }
        }
    }

    /// Verified loss of the aircraft link: tear down and start the scan loop.
    @MainActor
    private func commitDisconnect() {
        guard connectionPhase == .connected else { return }
        DJISDKBridge.shared.onProductDisconnected()
        clearRCState()
        connectionPhase = .disconnected
        lastConnectionEvent = Date()
        startReconnectLoop(reason: "verified link loss")
    }

    // MARK: - Telemetry Stall (verify, don't panic)

    /// The bridge reported a silent flight controller. Verify against ground
    /// truth: if the SDK still holds a live link, re-arm delegates and keep the
    /// connection. Only a verified-dead link triggers teardown/reconnect.
    @MainActor
    private func handleTelemetryStall() {
        guard isAppActive, connectionPhase == .connected else { return }
        if sdkReportsAircraftLink {
            print("DJIManager: telemetry quiet but SDK link is alive — re-arming delegates, keeping connection.")
            reconcileConnected(source: "stall-recheck")
        } else {
            print("DJIManager: telemetry stall confirmed — SDK reports no link.")
            commitDisconnect()
        }
    }

    // MARK: - App Lifecycle

    @MainActor
    private func handleAppBackground() {
        isAppActive = false
        DJISDKBridge.shared.suspendHealthMonitoring()
        cancelDisconnectVerification()
        // Deliberately do NOT touch the connection. iOS may keep the accessory
        // session alive, and the SDK will tell us if it actually drops.
        print("DJIManager: app backgrounded — health monitoring paused, connection untouched.")
    }

    @MainActor
    private func handleAppForeground() {
        isAppActive = true
        DJISDKBridge.shared.resumeHealthMonitoring()
        guard isRegistered else { return }

        if sdkReportsAircraftLink {
            // The link survived the background stint — trust it.
            print("DJIManager: app foregrounded — SDK link verified alive.")
            reconcileConnected(source: "foreground")
        } else if connectionPhase == .connected {
            // The accessory session may still be re-enumerating after resume.
            // Give it a generous grace window before declaring the link dead.
            scheduleDisconnectVerification(after: 3.0, source: "foreground")
        } else if !userRequestedDisconnect {
            startReconnectLoop(reason: "foreground")
        }
    }

    // MARK: - Reconnect Loop

    /// Single scan/reconnect loop with capped exponential backoff. No-ops if a
    /// loop is already running, the user disconnected, or we're connected.
    @MainActor
    private func startReconnectLoop(reason: String) {
        guard reconnectTask == nil else { return }
        guard isRegistered, !userRequestedDisconnect, connectionPhase != .connected else { return }
        connectionPhase = .connecting
        print("DJIManager: connection scan started (\(reason)).")

        reconnectTask = Task { @MainActor [weak self] in
            var attempt = 0
            while !Task.isCancelled {
                guard let self else { return }
                guard self.isRegistered,
                      !self.userRequestedDisconnect,
                      self.connectionPhase != .connected else { break }

                if self.sdkReportsAircraftLink {
                    // The SDK reconnected on its own — reconcile and stop scanning.
                    self.reconcileConnected(source: "scan-verify")
                    break
                }

                if self.isAppActive {
                    attempt += 1
                    print("DJIManager: connection scan attempt #\(attempt).")
                    DJISDKManager.startConnectionToProduct()
                }

                let delay = min(2.0 * pow(2.0, Double(min(attempt, 4))), 30.0)
                try? await Task.sleep(for: .seconds(delay))
            }
            if !Task.isCancelled { self?.reconnectTask = nil }
        }
    }

    @MainActor
    private func cancelReconnectLoop() {
        reconnectTask?.cancel()
        reconnectTask = nil
    }

    @MainActor
    private func cancelDisconnectVerification() {
        disconnectVerifyTask?.cancel()
        disconnectVerifyTask = nil
    }

    // MARK: - RC Helpers

    @MainActor
    private func attachRC(_ rc: DJIRemoteController) {
        remoteController = rc
        rc.delegate      = self
        isRCConnected    = true
    }

    @MainActor
    private func clearRCState() {
        remoteController = nil
        isRCConnected    = false
        rcSignalPercent  = -1
        isPairing        = false
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
            guard let self else { return }
            Task { @MainActor in
                if let error {
                    self.pairingStatus = "Pairing error: \(error.localizedDescription)"
                    self.isPairing = false
                } else {
                    self.pairingStatus = "Pairing active — hold Link button on drone"
                    self.isPairing = true
                }
            }
        }
    }

    /// Exit RC pairing mode.
    func stopPairing() {
        guard let rc = remoteController else { return }
        rc.stopPairing { [weak self] (error: Error?) in
            guard let self else { return }
            Task { @MainActor in
                self.isPairing = false
                if let error {
                    self.pairingStatus = "Stop-pair error: \(error.localizedDescription)"
                } else {
                    self.pairingStatus = "Pairing stopped."
                }
            }
        }
    }
}

// MARK: - DJISDKManagerDelegate

extension DJIManager: DJISDKManagerDelegate {

    func appRegisteredWithError(_ error: Error?) {
        Task { @MainActor in
            if let error {
                print("DJI registration failed: \(error.localizedDescription)")
                self.registrationMessage = "Registration failed — check App Key and network."
                self.connectionPhase     = .unregistered
            } else {
                print("DJI registration succeeded.")
                self.registrationMessage = "DJI SDK registered successfully."
                self.connectionPhase     = .disconnected
                // Kick off the connection scan. Product events will reconcile
                // state when the RC↔drone link is detected.
                self.startReconnectLoop(reason: "registration complete")
            }
            self.showRegistrationAlert = true
        }
    }

    /// Called when the RC↔drone link is established (pre-existing pair or new).
    func productConnected(_ product: DJIBaseProduct?) {
        Task { @MainActor in
            self.handleProductEvent(product, source: "productConnected")
        }
    }

    /// Called when the SDK believes the product disconnected. Treated as a
    /// hint — verified against ground truth before any teardown.
    func productDisconnected() {
        Task { @MainActor in
            self.handleProductEvent(nil, source: "productDisconnected")
        }
    }

    /// Safety-net fallback for product-change events not captured by the pair above.
    func sdkManagerProductDidChange(from oldProduct: DJIBaseProduct?,
                                    to newProduct: DJIBaseProduct?) {
        Task { @MainActor in
            self.handleProductEvent(newProduct, source: "productDidChange")
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
