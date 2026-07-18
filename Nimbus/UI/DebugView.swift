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
        }
    }

    // MARK: - Backend

    private var backendSection: some View {
        Section("Backend") {
            row("URL",       BackendClient.baseURL.absoluteString)
            row("Reachable", orc.isBackendReachable ? "✓ Yes" : "✗ No",
                color: orc.isBackendReachable ? .green : .red)
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
}


#Preview {
    DebugView()
        .environment(Orchestrator())
}
