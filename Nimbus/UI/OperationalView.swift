// OperationalView.swift — Nimbus
// Primary product UI.  This is what the operator sees during a flight session:
// drone camera feed (or placeholder), status bar, state pill, and PTT button.
// Tab 1 of ContentView.

import Combine
import SwiftUI

struct OperationalView: View {

    @Environment(Orchestrator.self) private var orc
    @State private var isPressing = false
    @State private var overlayDetections: [DetectedObject] = []
    private let overlayTimer = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()

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
        .onAppear {
            orc.detector.onDetectionsUpdated = { detections in
                overlayDetections = detections
            }
        }
        .onDisappear {
            orc.detector.onDetectionsUpdated = nil
        }
        .onReceive(overlayTimer) { _ in
            processCurrentFrameForOverlays()
        }
    }

    // MARK: - Camera / Placeholder

    @ViewBuilder
    private var cameraBackground: some View {
        if orc.bridge.isAircraftConnected {
            ZStack {
                DJICameraPreviewView(bridge: orc.bridge)
                    .ignoresSafeArea()
                GeometryReader { geo in
                    ZStack {
                        ForEach(Array(overlayDetections.enumerated()), id: \.element.id) { _, det in
                            detectionBox(det.bbox,
                                         in: geo.size,
                                         color: .yellow,
                                         label: det.label)
                        }
                        if let followBox = orc.followTargetBox {
                            detectionBox(followBox,
                                         in: geo.size,
                                         color: .cyan,
                                         label: "head_track")
                        }
                    }
                }
                if !orc.bridge.hasLiveVideoData {
                    noFeedPlaceholder
                }
                VStack {
                    HStack {
                        videoDebugBadge
                        Spacer()
                    }
                    Spacer()
                }
                .padding(.top, 56)
                .padding(.horizontal, 12)
            }
        } else {
            Rectangle()
                .fill(LinearGradient(
                    colors: [Color(white: 0.08), Color(white: 0.03)],
                    startPoint: .top, endPoint: .bottom
                ))
                .overlay(noFeedPlaceholder)
        }
    }

    private var videoDebugBadge: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("VIDEO DEBUG")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
            Text("pkts: \(orc.bridge.hasLiveVideoData ? "yes" : "no")")
                .font(.system(size: 10, design: .monospaced))
            Text("frame: \(orc.bridge.cameraFrame != nil ? "yes" : "no")")
                .font(.system(size: 10, design: .monospaced))
        }
        .foregroundStyle(.white.opacity(0.9))
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.black.opacity(0.45))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func detectionBox(_ bbox: CGRect, in size: CGSize, color: Color, label: String) -> some View {
        let rect = visionRectToViewRect(bbox, in: size)
        ZStack(alignment: .topLeading) {
            Rectangle()
                .stroke(color, lineWidth: 2)
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
            Text(label)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(color.opacity(0.85))
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .position(x: rect.minX + 34, y: max(12, rect.minY - 10))
        }
    }

    private func visionRectToViewRect(_ bbox: CGRect, in size: CGSize) -> CGRect {
        let x = bbox.minX * size.width
        let y = (1 - bbox.maxY) * size.height
        let w = bbox.width * size.width
        let h = bbox.height * size.height
        return CGRect(x: x, y: y, width: w, height: h)
    }

    private func processCurrentFrameForOverlays() {
        guard let cgImage = orc.bridge.cameraFrame?.cgImage else { return }

        orc.detector.process(cgImage: cgImage)
    }

    private var noFeedPlaceholder: some View {
        VStack(spacing: 20) {
            Image(systemName: orc.bridge.isAircraftConnected ? "camera.fill" : "airplane.circle")
                .font(.system(size: 56, weight: .thin))
                .foregroundStyle(.white.opacity(0.22))

            if orc.bridge.isAircraftConnected {
                Text("Awaiting camera feed…")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.35))
            } else {
                connectionPanel
            }
        }
    }

    // MARK: - Connection Panel (shown when no aircraft is connected)

    private var connectionPanel: some View {
        VStack(spacing: 14) {
            Text("Aircraft Not Connected")
                .font(.headline)
                .foregroundStyle(.white.opacity(0.85))

            Text(connectionStatusSummary)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.5))
                .multilineTextAlignment(.center)

            if !orc.djiManager.pairingStatus.isEmpty {
                Text(orc.djiManager.pairingStatus)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            }

            if orc.djiManager.isConnecting {
                HStack(spacing: 8) {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .scaleEffect(0.75)
                        .tint(.white)
                    Text("Connecting…")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.6))
                }
            } else {
                HStack(spacing: 10) {
                    // Connect
                    Button { orc.djiManager.startConnectionToProduct() } label: {
                        Label("Connect", systemImage: "link")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 18).padding(.vertical, 9)
                            .background(Color.blue.opacity(0.85))
                            .clipShape(Capsule())
                    }
                    .disabled(!orc.djiManager.isRegistered)

                    // Pair RC  (available once RC is plugged into phone)
                    if orc.djiManager.isPairing {
                        Button { orc.djiManager.stopPairing() } label: {
                            Label("Stop Pair", systemImage: "antenna.radiowaves.left.and.right.slash")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 18).padding(.vertical, 9)
                                .background(Color.orange.opacity(0.85))
                                .clipShape(Capsule())
                        }
                    } else {
                        Button { orc.djiManager.startPairing() } label: {
                            Label("Pair RC", systemImage: "antenna.radiowaves.left.and.right")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 18).padding(.vertical, 9)
                                .background(Color.orange.opacity(0.75))
                                .clipShape(Capsule())
                        }
                        .disabled(!orc.djiManager.isRCConnected)
                    }
                }

                // Disconnect  (useful to force-reset a stuck connection)
                Button { orc.djiManager.disconnectFromProduct() } label: {
                    Text("Disconnect")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.white.opacity(0.55))
                        .padding(.horizontal, 14).padding(.vertical, 6)
                        .background(Color.white.opacity(0.08))
                        .clipShape(Capsule())
                }
            }
        }
        .padding(.horizontal, 28).padding(.vertical, 22)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .padding(.horizontal, 36)
    }

    private var connectionStatusSummary: String {
        if !orc.djiManager.isRegistered { return "Registering SDK…" }
        if orc.djiManager.isRCConnected  { return "RC detected — power on the drone to link." }
        return "Power on the drone and RC. Connecting automatically."
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

            // RC signal — shown when RC is present (connected or not to aircraft)
            if orc.djiManager.isRCConnected {
                rcSignalBadge
            }

            if orc.bridge.isAircraftConnected {
                let t = orc.bridge.telemetry
                statBadge(icon: "battery.75",   text: "\(t.batteryPercent)%",
                          warn: (1..<20).contains(t.batteryPercent))
                statBadge(icon: "arrow.up",      text: "\(Int(t.altitudeM))m")
                statBadge(icon: "location.fill", text: t.isGPSValid ? "\(t.satelliteCount)sat" : "No GPS",
                          warn: !t.isGPSValid)
            }

            // AirPods: green = tracking, yellow = connected but idle, dim = not connected
            Image(systemName: "airpodspro")
                .font(.caption2)
                .foregroundStyle(
                    orc.headTracking.isTracking  ? Color.green :
                    orc.headTracking.isAvailable ? Color.yellow :
                    Color.white.opacity(0.3)
                )
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
            // Disconnect button when connected
            if orc.bridge.isAircraftConnected {
                Button { orc.djiManager.disconnectFromProduct() } label: {
                    Image(systemName: "eject.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.5))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Color.white.opacity(0.10))
        .clipShape(Capsule())
    }

    // MARK: - RC Signal Badge

    private var rcSignalBadge: some View {
        HStack(spacing: 3) {
            Image(systemName: rcSignalIcon)
                .font(.caption2)
            if orc.djiManager.rcSignalPercent >= 0 {
                Text("\(orc.djiManager.rcSignalPercent)%")
                    .font(.caption2.monospacedDigit())
            }
        }
        .foregroundStyle(rcSignalColor)
    }

    private var rcSignalIcon: String {
        switch orc.djiManager.rcSignalPercent {
        case 75...: return "wifi"
        case 50..<75: return "wifi"
        case 25..<50: return "wifi.exclamationmark"
        default:     return "wifi.slash"
        }
    }

    private var rcSignalColor: Color {
        switch orc.djiManager.rcSignalPercent {
        case 50...: return .white.opacity(0.85)
        case 25..<50: return .orange
        default:     return .red
        }
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
