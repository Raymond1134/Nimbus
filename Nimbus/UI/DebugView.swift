// DebugView.swift — Nimbus
// Developer / debug panel.  Tab 2 of ContentView.
// Exposes raw subsystem state for testing and tuning without connecting a real drone.

import SwiftUI
import AVFoundation
import Combine

struct DebugView: View {

    @Environment(Orchestrator.self) private var orc

    // Standalone STT test (doesn't go through the Orchestrator state machine)
    @State private var sttResult   = "Hold the button below to test STT in isolation…"
    @State private var isSttTest   = false
    @State private var testPipeline = VoiceCommandPipeline()
    @State private var sttPlaybackPlayer: AVAudioPlayer?
    @State private var debugWakeword = WakewordListener()
    @State private var liveInputLevelDB: Float = -160

    // Audio input/output device switching (debug)
    @State private var audioRoutes = AudioRouteManager()

    // Mission Ops (execute any action directly)
    private static let missionOps = [
        "takeoff", "land", "fly_to", "change_altitude", "rotate", "orbit",
        "hover", "look_at", "photo", "selfie", "panorama", "follow",
        "return", "abort",
    ]
    @State private var selectedOp       = "takeoff"
    @State private var opFlyToMode      = "visual"      // "visual" | "direction"
    @State private var opTarget         = ""
    @State private var opDirection      = "forward"     // fly_to cardinal
    @State private var opRotateDirection = "right"      // rotate
    @State private var opDegrees        = ""
    @State private var opDeltaM         = ""
    @State private var opSeconds        = ""
    @State private var opRevolutions    = ""
    @State private var opDistanceM      = ""
    @State private var opUsePersonSeed  = true

    var body: some View {
        NavigationStack {
            List {
                djiSection
                rcSection
                controlMappingSection
                manualFlightControlSection
                missionOpsSection
                backendSection
                lastCommandSection
                logSection
                wakewordDebugSection
                audioDevicesSection
                sttTestSection
            }
            .navigationTitle("Debug")
            .navigationBarTitleDisplayMode(.inline)
            .listStyle(.insetGrouped)
            .onAppear { audioRoutes.refresh() }
            .onReceive(Timer.publish(every: 0.12, on: .main, in: .common).autoconnect()) { _ in
                liveInputLevelDB = currentLiveInputLevelDB() ?? -160
            }
            .onDisappear {
                debugWakeword.stopListening()
            }
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
                row("GPS",
                    t.isGPSValid ? "\(t.satelliteCount) sat" : "No fix",
                    color: t.isGPSValid ? .primary : .orange)
                // VPS (Vision-Assisted Positioning) is the indoor GPS replacement.
                // Green = optical-flow is actively stabilising position.
                row("VPS / Optical Flow",
                    t.isVisionPositioningActive ? "✓ Active" : "✕ Inactive",
                    color: t.isVisionPositioningActive ? .green
                         : t.isFlying              ? .orange
                         :                            .secondary)
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

    private func playLastSttRecording() {
        let url = testPipeline.recorder.lastRecordingURL ?? orc.voicePipeline.recorder.lastRecordingURL
        guard let url else { return }
        playRecording(at: url)
    }

    /// Play back a recorded clip so you can hear what you sound like.
    private func playRecording(at url: URL) {
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.prepareToPlay()
            player.play()
            sttPlaybackPlayer = player
        } catch {
            sttResult = "Playback error: \(error.localizedDescription)"
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

    // MARK: - Control Mapping

    private var controlMappingSection: some View {
        Section("Control Mapping") {
            Toggle("Swap pitch/roll axes", isOn: Binding(
                get: { ActionTuning.shared.swapPitchAndRollAxes },
                set: { ActionTuning.shared.swapPitchAndRollAxes = $0 }
            ))
            .font(.subheadline)
            Text("Enable if forward/back feels like left/right on this aircraft.")
                .font(.caption)
                .foregroundStyle(.secondary)
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

    // MARK: - Mission Ops (execute any action with parameters)

    private var missionOpsSection: some View {
        Section("Mission Ops (execute any action)") {
            Picker("Action", selection: $selectedOp) {
                ForEach(Self.missionOps, id: \.self) { Text($0).tag($0) }
            }

            opParameterFields

            if opNeedsVisualTarget {
                Toggle("Seed target from person detection", isOn: $opUsePersonSeed)
                    .font(.subheadline)
            }

            Button {
                let step = buildDebugStep()
                Task { await orc.executeDebugMission(steps: [step]) }
            } label: {
                Label("Execute \(selectedOp)", systemImage: "play.circle.fill")
                    .font(.subheadline.weight(.semibold))
            }
            .disabled(!orc.bridge.isAircraftConnected)

            Button(role: .destructive) {
                orc.abort()
            } label: {
                Label("Abort / Stop", systemImage: "xmark.octagon.fill")
                    .font(.subheadline.weight(.semibold))
            }
            .disabled(!orc.bridge.isAircraftConnected)

            if !orc.bridge.isAircraftConnected {
                Text("Connect aircraft to execute mission ops")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let photo = orc.bridge.lastCapturedPhoto {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Last captured photo")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Image(uiImage: photo)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 180)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    /// Ops that servo on a visual bounding-box target.
    private var opNeedsVisualTarget: Bool {
        switch selectedOp {
        case "look_at", "orbit", "follow": return true
        case "fly_to":                     return opFlyToMode == "visual"
        default:                           return false
        }
    }

    @ViewBuilder
    private var opParameterFields: some View {
        switch selectedOp {
        case "fly_to":
            Picker("Mode", selection: $opFlyToMode) {
                Text("visual target").tag("visual")
                Text("cardinal direction").tag("direction")
            }
            .pickerStyle(.segmented)
            if opFlyToMode == "direction" {
                Picker("Direction (user-relative)", selection: $opDirection) {
                    ForEach(["forward", "back", "left", "right"], id: \.self) { Text($0).tag($0) }
                }
                paramField("Distance (m)", text: $opDistanceM,
                           placeholder: "\(ActionTuning.shared.flyToCardinalDefaultDistanceM)")
            } else {
                paramField("Target label", text: $opTarget, placeholder: "person", numeric: false)
            }

        case "change_altitude":
            paramField("Δ altitude (m, +up/−down)", text: $opDeltaM, placeholder: "1.0")

        case "rotate":
            Picker("Direction", selection: $opRotateDirection) {
                Text("left").tag("left")
                Text("right").tag("right")
            }
            .pickerStyle(.segmented)
            paramField("Degrees", text: $opDegrees,
                       placeholder: "\(Int(ActionTuning.shared.rotateDefaultDegrees))")

        case "orbit":
            paramField("Revolutions", text: $opRevolutions,
                       placeholder: "\(ActionTuning.shared.orbitDefaultRevolutions)")

        case "hover":
            paramField("Seconds", text: $opSeconds,
                       placeholder: "\(Int(ActionTuning.shared.hoverDefaultSeconds))")

        case "look_at":
            paramField("Target label", text: $opTarget, placeholder: "person", numeric: false)

        case "follow":
            paramField("Seconds", text: $opSeconds,
                       placeholder: "\(Int(ActionTuning.shared.followDefaultSeconds))")

        default:
            EmptyView()
        }
    }

    private func paramField(_ label: String,
                            text: Binding<String>,
                            placeholder: String,
                            numeric: Bool = true) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            TextField(placeholder, text: text)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 120)
                .keyboardType(numeric ? .numbersAndPunctuation : .default)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
        }
    }

    /// Build a NimbusStep from the panel state — same shape the backend sends.
    private func buildDebugStep() -> NimbusStep {
        var box: [Int] = []
        var found = false
        var direction: String?

        switch selectedOp {
        case "fly_to" where opFlyToMode == "direction":
            direction = opDirection
        case "rotate":
            direction = opRotateDirection
        default:
            break
        }

        // Debug panel has no Gemini grounding — optionally seed visual-target
        // ops from onboard person detection on the live frame.
        if opNeedsVisualTarget, opUsePersonSeed,
           let frame = orc.bridge.cameraFrame?.cgImage,
           let person = FlightBehaviors.detectPersonBox(in: frame) {
            // Vision (origin bottom-left) → Gemini box [ymin,xmin,ymax,xmax] 0–1000.
            box = [
                Int((1.0 - person.maxY) * 1000.0),
                Int(person.minX * 1000.0),
                Int((1.0 - person.minY) * 1000.0),
                Int(person.maxX * 1000.0),
            ]
            found = true
        }

        return NimbusStep(
            op: selectedOp,
            target: opTarget.isEmpty ? nil : opTarget,
            box2d: box,
            found: found,
            distanceM: Double(opDistanceM),
            confidence: 1.0,
            deltaM: Double(opDeltaM),
            direction: direction,
            degrees: Double(opDegrees),
            revolutions: Double(opRevolutions),
            seconds: Double(opSeconds),
            text: nil
        )
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

                if let r = orc.lastResponse {
                    Divider()
                    row("Steps",      "\(r.steps.count)")
                    row("Confidence", String(format: "%.0f%%", r.confidence * 100))
                    ForEach(Array(r.steps.enumerated()), id: \.offset) { idx, step in
                        let found  = step.found ? " ✓" : ""
                        let target = step.target.map { " → \($0)" } ?? ""
                        row("#\(idx) \(step.op)\(target)",
                            found.isEmpty ? "—" : "found\(found)",
                            color: step.found ? .green : .secondary)
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

    // MARK: - Audio Devices

    private var audioDevicesSection: some View {
        Section("Audio Devices") {
            Picker("Input", selection: Binding(
                get: { audioRoutes.selectedInputUID ?? "" },
                set: { audioRoutes.selectInput(uid: $0.isEmpty ? nil : $0) }
            )) {
                Text("System Default").tag("")
                ForEach(audioRoutes.availableInputs, id: \.uid) { port in
                    Text(port.portName).tag(port.uid)
                }
            }
            .font(.subheadline)

            row("Active Input",  audioRoutes.currentInputName)
            row("Active Output", audioRoutes.currentOutputName)

            Toggle("Force speaker output", isOn: Binding(
                get: { audioRoutes.speakerOverride },
                set: { audioRoutes.setSpeakerOverride($0) }
            ))
            .font(.subheadline)

            HStack {
                Text("Output device")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                AudioRoutePickerButton()
                    .frame(width: 44, height: 44)
            }

            Button("Refresh devices") {
                audioRoutes.prepareSession()
                audioRoutes.refresh()
            }
            .font(.subheadline)
        }
    }

    // MARK: - Standalone STT Test

    private var wakewordDebugSection: some View {
        Section("Wakeword debug") {
            row("Listening", debugWakeword.isListeningForWakeword ? "✓ Active" : "✗ Inactive",
                color: debugWakeword.isListeningForWakeword ? .green : .secondary)
            row("Detections", "\(debugWakeword.wakewordDetectionCount)")

            if debugWakeword.latestTranscription.isEmpty {
                Text("Say “hey nimbus” to test activation. Live recognized speech will appear here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text(debugWakeword.latestTranscription)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.primary)
                    .lineLimit(4)
            }

            if debugWakeword.isListeningForWakeword {
                Button("Stop wakeword listening") {
                    debugWakeword.stopListening()
                }
                .font(.subheadline)
                .foregroundStyle(.red)
            } else {
                Button("Start wakeword listening") {
                    debugWakeword.startListening()
                }
                .font(.subheadline)
            }
        }
    }

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
            Text(
                String(
                    format: "Live input: %.1f dBFS  |  VAD start > %.0f  continue > %.0f  silence %.1fs",
                    liveInputLevelDB,
                    orc.handsFreeVadStartThresholdDB,
                    orc.handsFreeVadContinueThresholdDB,
                    orc.handsFreeVadSilenceStopSeconds
                )
            )
            .font(.system(.caption2, design: .monospaced))
            .foregroundStyle(liveInputLevelColor())
            .lineLimit(2)

            HStack(spacing: 10) {
                Button {
                    playLastSttRecording()
                } label: {
                    Label("Play last recorded clip", systemImage: "play.circle")
                        .font(.subheadline.weight(.semibold))
                }
                .disabled(testPipeline.recorder.lastRecordingURL == nil &&
                          orc.voicePipeline.recorder.lastRecordingURL == nil)

                if sttPlaybackPlayer?.isPlaying == true {
                    Button {
                        sttPlaybackPlayer?.stop()
                    } label: {
                        Label("Stop", systemImage: "stop.circle")
                            .font(.subheadline.weight(.semibold))
                    }
                    .foregroundStyle(.red)
                }
            }

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
        guard let url = testPipeline.stopCommandCapture() else {
            sttResult = "Error: no recording file."
            return
        }
        // Play the clip back immediately so you hear what you sounded like
        // while the transcription request is in flight.
        playRecording(at: url)
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

    private func currentLiveInputLevelDB() -> Float? {
        if testPipeline.recorder.isRecording {
            return testPipeline.recorder.currentAveragePowerDB()
        }
        if orc.voicePipeline.recorder.isRecording {
            return orc.voicePipeline.recorder.currentAveragePowerDB()
        }
        return nil
    }

    private func liveInputLevelColor() -> Color {
        if liveInputLevelDB > orc.handsFreeVadStartThresholdDB {
            return .green
        }
        if liveInputLevelDB > orc.handsFreeVadContinueThresholdDB {
            return .orange
        }
        return .secondary
    }
}


#Preview {
    DebugView()
        .environment(Orchestrator())
}
