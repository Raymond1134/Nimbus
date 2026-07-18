// OperationalView.swift — Nimbus
// Primary product UI.  This is what the operator sees during a flight session:
// drone camera feed (or placeholder), status bar, state pill, and PTT button.
// Tab 1 of ContentView.

import SwiftUI

struct OperationalView: View {

    @Environment(Orchestrator.self) private var orc
    @State private var isPressing = false

    var body: some View {
        ZStack(alignment: .bottom) {
            cameraBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                statusBar
                Spacer()
                stateIndicator
                Spacer()
                controlsArea
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Camera / Placeholder

    @ViewBuilder
    private var cameraBackground: some View {
        if let frame = orc.bridge.cameraFrame {
            Image(uiImage: frame)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            Rectangle()
                .fill(LinearGradient(
                    colors: [Color(white: 0.08), Color(white: 0.03)],
                    startPoint: .top, endPoint: .bottom
                ))
                .overlay(noFeedPlaceholder)
        }
    }

    private var noFeedPlaceholder: some View {
        VStack(spacing: 10) {
            Image(systemName: orc.bridge.isAircraftConnected
                  ? "camera.fill"
                  : "airplane.circle.fill")
                .font(.system(size: 60, weight: .thin))
                .foregroundStyle(.white.opacity(0.18))
            Text(orc.bridge.isAircraftConnected
                 ? "Awaiting camera feed…"
                 : "Aircraft not connected")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.30))
        }
    }

    // MARK: - Status Bar

    private var statusBar: some View {
        HStack(spacing: 10) {
            connectionPill

            Spacer()

            // Backend reachability dot
            Circle()
                .fill(orc.isBackendReachable ? Color.green : Color.red)
                .frame(width: 7, height: 7)
                .help(orc.isBackendReachable ? "Backend reachable" : "Backend unreachable")

            if orc.bridge.isAircraftConnected {
                let t = orc.bridge.telemetry
                statBadge(icon: "battery.75",   text: "\(t.batteryPercent)%",
                          warn: (1..<20).contains(t.batteryPercent))
                statBadge(icon: "arrow.up",      text: "\(Int(t.altitudeM))m")
                statBadge(icon: "location.fill", text: t.isGPSValid ? "\(t.satelliteCount)sat" : "No GPS",
                          warn: !t.isGPSValid)
            }

            Image(systemName: "airpodspro")
                .font(.caption2)
                .foregroundStyle(orc.headTracking.isAvailable ? Color.green : Color.white.opacity(0.3))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.ultraThinMaterial)
    }

    private var connectionPill: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(orc.bridge.isAircraftConnected ? Color.green : Color.red)
                .frame(width: 6, height: 6)
            Text(orc.bridge.isAircraftConnected ? "Drone Connected" : "No Aircraft")
                .font(.caption2.weight(.medium))
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Color.white.opacity(0.10))
        .clipShape(Capsule())
    }

    private func statBadge(icon: String, text: String, warn: Bool = false) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon).font(.caption2)
            Text(text).font(.caption2.monospacedDigit())
        }
        .foregroundStyle(warn ? Color.red : Color.white.opacity(0.85))
    }

    // MARK: - State Indicator

    private var stateIndicator: some View {
        VStack(spacing: 10) {
            Text(orc.appState.displayTitle)
                .font(.system(.title2, design: .monospaced, weight: .bold))
                .foregroundStyle(orc.appState.displayColor)
                .padding(.horizontal, 26).padding(.vertical, 10)
                .background(orc.appState.displayColor.opacity(0.15))
                .clipShape(Capsule())
                .animation(.easeInOut(duration: 0.2), value: orc.appState.displayTitle)

            if case .executing(_, let tgt) = orc.appState, let tgt {
                Text("→ \(tgt)")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white.opacity(0.85))
            }

            if !orc.lastTranscript.isEmpty {
                Text("\"\(orc.lastTranscript)\"")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.50))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
        }
        .shadow(color: .black.opacity(0.5), radius: 6)
    }

    // MARK: - Controls

    private var controlsArea: some View {
        VStack(spacing: 18) {
            // Abort — visible only when a command is running
            if orc.appState.isActive {
                Button { orc.abort() } label: {
                    Label("ABORT", systemImage: "xmark.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 28).padding(.vertical, 11)
                        .background(Color.red.opacity(0.85))
                        .clipShape(Capsule())
                }
                .transition(.scale.combined(with: .opacity))
            }

            // Push-to-talk
            VStack(spacing: 8) {
                ZStack {
                    if isPressing {
                        Circle()
                            .stroke(Color.red.opacity(0.35), lineWidth: 3)
                            .frame(width: 106, height: 106)
                            .scaleEffect(isPressing ? 1.3 : 1)
                            .animation(
                                .easeOut(duration: 0.7).repeatForever(autoreverses: true),
                                value: isPressing
                            )
                    }
                    Circle()
                        .fill(isPressing ? Color.red : Color.blue)
                        .frame(width: 82, height: 82)
                        .shadow(color: (isPressing ? Color.red : Color.blue).opacity(0.55),
                                radius: 16)
                    Image(systemName: isPressing ? "mic.fill" : "mic.circle")
                        .font(.system(size: 32, weight: .medium))
                        .foregroundStyle(.white)
                }
                .animation(.easeInOut(duration: 0.15), value: isPressing)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in
                            guard !isPressing else { return }
                            isPressing = true
                            orc.onPushToTalkPressed()
                        }
                        .onEnded { _ in
                            isPressing = false
                            orc.handleVoiceRelease()
                        }
                )

                Text(isPressing ? "Release to send" : "Hold to speak")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.45))
            }
        }
        .padding(.bottom, 46)
        .frame(maxWidth: .infinity)
        .background(
            LinearGradient(
                colors: [.clear, .black.opacity(0.72)],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea(edges: .bottom)
        )
    }
}

// MARK: - Range helper for battery badge

private func contains(_ range: Range<Int>, _ value: Int) -> Bool {
    range.contains(value)
}

private extension Int {
    func `in`(_ range: Range<Int>) -> Bool { range.contains(self) }
}

#Preview {
    OperationalView()
        .environment(Orchestrator())
}
