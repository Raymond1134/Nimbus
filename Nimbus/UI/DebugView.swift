// DebugView.swift — Nimbus
// Developer / debug panel.  Tab 2 of ContentView.
// Exposes raw subsystem state for testing and tuning without connecting a real drone.

import SwiftUI

struct DebugView: View {

    @Environment(Orchestrator.self) private var orc

    // Standalone STT test (doesn't go through the Orchestrator state machine)
    @State private var sttResult   = "Hold the button below to test STT in isolation…"
    @State private var isSttTest   = false
    @State private var testPipeline = VoiceCommandPipeline()

    var body: some View {
        NavigationStack {
            List {
                djiSection
                rcSection
                manualFlightControlSection
                backendSection
                lastCommandSection
                logSection
                sttTestSection
            }
            .navigationTitle("Debug")
            .navigationBarTitleDisplayMode(.inline)
            .listStyle(.insetGrouped)
        }
    }

    // MARK: - DJI Status

    private var djiSection: some View {
        Section("DJI SDK") {
            row("Registered",  orc.djiManager.isRegistered ? "✓ Yes" : "✗ No",
                color: orc.djiManager.isRegistered ? .green : .red)
            row("Aircraft",    orc.bridge.isAircraftConnected ? "Connected" : "Disconnected",
                color: orc.bridge.isAircraftConnected ? .green : .secondary)

            if orc.bridge.isAircraftConnected {
                let t = orc.bridge.telemetry
                row("Altitude",   "\(String(format: "%.1f", t.altitudeM)) m")
                row("Heading",    "\(String(format: "%.1f", t.headingDeg))°")
                row("Battery",    "\(t.batteryPercent) %",
                    color: (1..<20).contains(t.batteryPercent) ? .red : .primary)
                row("GPS",        t.isGPSValid ? "\(t.satelliteCount) sat" : "No fix",
                    color: t.isGPSValid ? .primary : .orange)
                row("Vel X/Y/Z",  "\(String(format: "%.2f / %.2f / %.2f", t.velocityX, t.velocityY, t.velocityZ)) m/s")
            }
            Divider()
            row("AirPods Available", orc.headTracking.isAvailable ? "✓ Yes" : "✗ No",
                color: orc.headTracking.isAvailable ? .green : .secondary)
            row("AirPods Tracking", orc.headTracking.isTracking ? "✓ Active" : "✗ Inactive",
                color: orc.headTracking.isTracking ? .green : .orange)
            row("AirPods Calibrated", orc.headTracking.isCalibrated ? "✓ Yes" : "✗ No",
                color: orc.headTracking.isCalibrated ? .green : .orange)
            row("Head Yaw/Pitch/Roll",
                String(format: "%.1f / %.1f / %.1f°",
                       orc.headTracking.effectiveAttitude.yawDeg,
                       orc.headTracking.effectiveAttitude.pitchDeg,
                       orc.headTracking.effectiveAttitude.rollDeg))
            if orc.bridge.isAircraftConnected {
                let yawDelta = shortestAngleDelta(target: orc.headTracking.effectiveAttitude.yawDeg,
                                                  current: orc.bridge.telemetry.headingDeg)
                row("Drone-Head Yaw Δ", String(format: "%.1f°", yawDelta),
                    color: abs(yawDelta) < 15 ? .green : .orange)
            }

            // Connection controls
            if orc.djiManager.isConnecting {
                HStack(spacing: 8) {
                    ProgressView().progressViewStyle(.circular).scaleEffect(0.75)
                    Text("Connecting…").font(.subheadline).foregroundStyle(.secondary)
                }
            } else {
                Button("Connect to Product") {
                    orc.djiManager.startConnectionToProduct()
                }
                .font(.subheadline)
                .disabled(!orc.djiManager.isRegistered || orc.bridge.isAircraftConnected)

                Button("Disconnect") {
                    orc.djiManager.disconnectFromProduct()
                }
                .font(.subheadline)
                .foregroundStyle(.red)
                .disabled(!orc.bridge.isAircraftConnected)
            }
        }
    }

    // MARK: - RC Status

    private var rcSection: some View {
        Section("Remote Controller") {
            row("RC Connected",
                orc.djiManager.isRCConnected ? "✓ Yes" : "✗ No",
                color: orc.djiManager.isRCConnected ? .green : .secondary)

            if orc.djiManager.isRCConnected {
                let sig = orc.djiManager.rcSignalPercent
                row("Uplink Signal",
                    sig >= 0 ? "\(sig)%" : "—",
                    color: sig < 25 ? .red : sig < 50 ? .orange : .primary)
            }

            if !orc.djiManager.pairingStatus.isEmpty {
                row("Pair Status", orc.djiManager.pairingStatus,
                    color: orc.djiManager.isPairing ? .orange : .secondary)
            }

            if orc.djiManager.isPairing {
                Button("Stop Pairing") { orc.djiManager.stopPairing() }
                    .font(.subheadline)
                    .foregroundStyle(.red)
            } else {
                Button("Pair RC with Drone") { orc.djiManager.startPairing() }
                    .font(.subheadline)
                    .disabled(!orc.djiManager.isRCConnected)
            }
        }
    }

    // MARK: - Manual Flight Control

    private var manualFlightControlSection: some View {
        Section("Manual Flight Control (DEBUG)") {
            NavigationLink(destination: ManualFlightControlView()) {
                HStack {
                    Label("Flight Control Panel", systemImage: "joystick.fill")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(!orc.bridge.isAircraftConnected)

            if !orc.bridge.isAircraftConnected {
                Text("Connect aircraft to enable manual controls")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Backend

    private var backendSection: some View {
        Section("Backend") {
            row("URL",       BackendClient.baseURL.absoluteString)
            row("Reachable", orc.isBackendReachable ? "✓ Yes" : "✗ No",
                color: orc.isBackendReachable ? .green : .red)
            row("Object Detector", orc.detector.isModelAvailable ? "YOLO loaded" : "YOLO missing (follow still works)")
            Button("Re-check health") {
                Task { await orc.checkBackendHealth() }
            }
            .font(.subheadline)
        }
    }

    // MARK: - Last Command

    private var lastCommandSection: some View {
        Section("Last Command") {
            if orc.lastTranscript.isEmpty {
                Text("No command yet.").foregroundStyle(.secondary).font(.caption)
            } else {
                row("Transcript", orc.lastTranscript)

                if let i = orc.lastIntent {
                    Divider()
                    row("Intent",     i.intent)
                    row("Target",     i.target ?? "—")
                    row("Confidence", "\(Int(i.confidence * 100))%")
                }

                if let r = orc.lastResponse {
                    Divider()
                    row("Grounding",  r.found ? "Found ✓" : "Not found",
                        color: r.found ? .green : .secondary)
                    if r.found {
                        row("Label",     r.label)
                        row("Box2D",     r.box2d.map(String.init).joined(separator: " "))
                        row("Gnd conf.", String(format: "%.2f", r.groundingConfidence))
                    }
                }
            }
        }
    }

    // MARK: - Log

    private var logSection: some View {
        Section("Log (newest first)") {
            if orc.logMessages.isEmpty {
                Text("No messages yet.").foregroundStyle(.secondary).font(.caption)
            } else {
                ForEach(orc.logMessages.reversed()) { entry in
                    Text(entry.formatted)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(
                            entry.level == .error   ? Color.red    :
                            entry.level == .warning ? Color.orange :
                            Color.primary
                        )
                        .lineLimit(4)
                }
            }
        }
    }

    // MARK: - Standalone STT Test

    private var sttTestSection: some View {
        Section("STT (standalone test)") {
            HStack {
                Spacer()
                Image(systemName: isSttTest ? "mic.fill" : "mic.circle")
                    .font(.system(size: 44))
                    .foregroundStyle(isSttTest ? Color.red : Color.blue)
                    .scaleEffect(isSttTest ? 1.1 : 1)
                    .animation(.easeInOut(duration: 0.2), value: isSttTest)
                Spacer()
            }
            .padding(.vertical, 6)

            Text(sttResult)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(6)

            Text("HOLD TO TALK (test — no drone control)")
                .font(.headline)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(isSttTest ? Color.red : Color.blue)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in
                            guard !isSttTest else { return }
                            isSttTest = true
                            sttResult = "Recording…"
                            testPipeline.onPressStartTalking()
                        }
                        .onEnded { _ in
                            isSttTest = false
                            sttResult = "Sending to ElevenLabs…"
                            runSttTest()
                        }
                )
        }
    }

    private func runSttTest() {
        guard let url = testPipeline.recorder.stopRecording() else {
            sttResult = "Error: no recording file."
            return
        }
        Task {
            do {
                let text = try await ElevenLabsSTT.transcribe(fileURL: url)
                sttResult = "Transcribed: \"\(text)\""
            } catch {
                sttResult = "STT error: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Helper

    @ViewBuilder
    private func row(_ label: String, _ value: String, color: Color = .primary) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(color)
                .multilineTextAlignment(.trailing)
                .lineLimit(3)
        }
    }

    private func shortestAngleDelta(target: Double, current: Double) -> Double {
        (target - current + 540).truncatingRemainder(dividingBy: 360) - 180
    }
}


#Preview {
    DebugView()
        .environment(Orchestrator())
}
