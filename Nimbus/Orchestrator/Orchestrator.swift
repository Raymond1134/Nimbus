// Orchestrator.swift — Nimbus
// Central command lifecycle state machine. Spec §3 component 11, §5.
//
// Data flow (spec §5):
//   PTT press       → onPushToTalkPressed()  → starts recording, freezes head-tracking
//   PTT release     → handleVoiceRelease()   → ElevenLabsSTT → BackendClient → executeIntent()
//   executeIntent() → FlightBehaviors        → DJISDKBridge.sendVelocity()
//   behavior done   → onBehaviorComplete     → idle
//
// Inject into the SwiftUI view tree via .environment(orchestrator) on the
// root view; access with @Environment(Orchestrator.self) in child views.

import SwiftUI
import Observation
import AVFoundation

@Observable
final class Orchestrator {

    // MARK: - Observed State

    var appState: AppState              = .idle
    var lastTranscript                  = ""
    var lastResponse: NimbusResponse?
    var logMessages: [LogEntry]         = []
    var isBackendReachable              = false
    var rememberedSpots: [RememberedSpot] = []
    var isOverheadFollowModeEnabled     = true
    var followTargetBox: CGRect?
    /// True once the user launched a session: drone is airborne and defaults
    /// to hovering above the operator's head between commands.
    var isSessionActive                 = false
    /// Hands-free mode: "Nimbus …" wakeword triggers listening automatically.
    var isHandsFreeEnabled              = false

    // MARK: - Subsystems

    let djiManager   = DJIManager.shared
    let bridge       = DJISDKBridge.shared
    let headTracking = HeadTrackingManager()
    let detector     = ObjectDetector()
    let tracker      = ObjectTracker()
    let spatialAudio = SpatialAudioManager()
    let safety       = SafetySupervisor()

    /// Voice capture pipeline (AudioRecorderManager lives inside).
    let voicePipeline = VoiceCommandPipeline()

    /// Wakeword listener for hands-free "Nimbus …" commands.
    let wakeword = WakewordListener()

    /// Flight behaviors — initialized in init() to break init-order dependency
    /// on bridge + safety (@Observable is incompatible with lazy stored properties).
    /// @ObservationIgnored because behaviors is never read in a SwiftUI body.
    @ObservationIgnored private(set) var behaviors: FlightBehaviors!
    /// Executes multi-step MissionPlans from the backend.
    @ObservationIgnored private(set) var missionExecutor: MissionExecutor!
    @ObservationIgnored private let rememberedSpotsKey = "Nimbus.RememberedSpots"
    /// How long the auto-recording window stays open after the wakeword fires.
    @ObservationIgnored private let handsFreeRecordSeconds: Double = 5.0
    @ObservationIgnored private let speechSynth = AVSpeechSynthesizer()

    // MARK: - Init

    init() {
        let b = FlightBehaviors(bridge: bridge, safety: safety, headTracking: headTracking)
        b.onBehaviorComplete = { [weak self] in
            guard let self else { return }
            // During a mission the executor owns behavior sequencing.
            if self.missionExecutor?.isRunning == true { return }
            // Overhead follow is the session default — keep it alive.
            if self.isSessionActive, case .executing(let verb, _) = self.appState, verb == "OVERHEAD" {
                self.log("Overhead follow window elapsed — renewing.")
                self.resumeOverheadHold()
                return
            }
            self.log("Behavior complete → idle.")
            self.returnToIdle()
        }
        b.onFollowTargetBoxUpdated = { [weak self] box in
            self?.followTargetBox = box
        }
        behaviors = b
        missionExecutor = MissionExecutor(
            bridge: bridge,
            behaviors: b,
            safety: safety,
            log: { [weak self] msg in self?.log("[Mission] \(msg)") },
            say: { [weak self] text in self?.speak(text) }
        )
        missionExecutor.onAbortRequested = { [weak self] in
            self?.resumeOverheadHold_public()
        }
        wakeword.onWakewordDetected = { [weak self] in
            self?.handleWakewordTriggered()
        }
        loadRememberedSpots()
        headTracking.start(compassHeadingDeg: bridge.telemetry.headingDeg)
        headTracking.calibrate()
        log("Orchestrator initialised.")
        Task { await checkBackendHealth() }
    }

    // MARK: - Session Lifecycle (launch → overhead hover → commands → land)

    /// Launch Nimbus: take off, climb, find the operator, and settle into the
    /// default overhead-follow hold. The drone then follows the user around
    /// until a voice command interrupts, and returns overhead afterwards.
    func startSession() {
        guard bridge.isAircraftConnected else {
            log("Cannot launch — aircraft not connected.", level: .warning)
            return
        }
        guard !isSessionActive else { return }
        isSessionActive = true
        appState = .executing(verb: "LAUNCH", target: nil)
        log("Session start: taking off…")

        Task { [weak self] in
            guard let self else { return }
            if !self.bridge.telemetry.isFlying {
                let ok = await self.bridge.takeOff()
                guard ok else {
                    self.log("Takeoff failed.", level: .error)
                    self.isSessionActive = false
                    self.returnToIdle()
                    return
                }
                // Wait for the auto-takeoff to reach its ~1.2 m hover.
                let deadline = Date().addingTimeInterval(12)
                while !self.bridge.telemetry.isFlying && Date() < deadline {
                    try? await Task.sleep(for: .seconds(0.25))
                }
                try? await Task.sleep(for: .seconds(1.5))
            }
            await self.waitForCameraWarmup(maxSeconds: 8.0)
            self.speak("Nimbus airborne.")
            self.resumeOverheadHold()
            if self.isHandsFreeEnabled { self.wakeword.startListening() }
        }
    }

    /// End the session: stop everything and land.
    func endSession() {
        missionExecutor.cancel()
        behaviors.stop()
        isSessionActive = false
        wakeword.stopListening()
        appState = .executing(verb: "LAND", target: nil)
        log("Session end: landing.")
        Task { [weak self] in
            guard let self else { return }
            _ = await self.bridge.startLanding()
            self.returnToIdle()
        }
    }

    /// (Re)start the default hover-above-head hold. Uses person detection to
    /// find the operator, keeps the gimbal straight down, and yaw-follows the
    /// AirPods heading.
    private func resumeOverheadHold() {
        guard isSessionActive, bridge.isAircraftConnected else { return }
        if !headTracking.isTracking {
            headTracking.start(compassHeadingDeg: bridge.telemetry.headingDeg)
        }
        if bridge.cameraFrame == nil {
            Task { [weak self] in
                guard let self else { return }
                await self.waitForCameraWarmup(maxSeconds: 4.0)
                guard self.isSessionActive, self.bridge.isAircraftConnected else { return }
                self.resumeOverheadHold()
            }
            return
        }
        bridge.pointGimbalDownImmediately(airpodsPitchDeg: CGFloat(headTracking.effectiveAttitude.pitchDeg),
                                          strictDown: true)
        behaviors.followPerson(maxSeconds: 600, overheadMode: true)
        appState = .executing(verb: "OVERHEAD", target: "operator")
        log("Holding overhead of operator (default state).")
    }

    // MARK: - Hands-Free Wakeword

    func setHandsFree(_ enabled: Bool) {
        isHandsFreeEnabled = enabled
        if enabled {
            wakeword.startListening()
            log("Hands-free enabled — say \"Nimbus …\".")
        } else {
            wakeword.stopListening()
            log("Hands-free disabled.")
        }
    }

    /// Wakeword fired: auto-record a fixed window, then process like PTT release.
    private func handleWakewordTriggered() {
        guard case .idle = appState else {
            // Busy — executing states also accept commands: interrupt current mission.
            if case .executing = appState {
                interruptForNewCommand()
            } else {
                restartWakewordIfNeeded()
                return
            }
            return
        }
        beginHandsFreeCapture()
    }

    private func beginHandsFreeCapture() {
        spatialAudio.playCommandConfirmation()
        headTracking.freeze()
        voicePipeline.onPressStartTalking()
        appState = .listening
        log("Wakeword → listening for \(Int(handsFreeRecordSeconds))s…")
        Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(self.handsFreeRecordSeconds))
            self.handleVoiceRelease()
        }
    }

    /// A new voice command arrived while flying: pause the current activity
    /// (mission or overhead hold) and listen.
    private func interruptForNewCommand() {
        missionExecutor.cancel()
        behaviors.stop()          // hover while listening
        appState = .idle
        beginHandsFreeCapture()
    }

    private func restartWakewordIfNeeded() {
        if isHandsFreeEnabled {
            wakeword.startListening()
        }
    }

    // MARK: - Spoken Feedback

    func speak(_ text: String) {
        log("Say: \"\(text)\"")
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = 0.52
        speechSynth.speak(utterance)
    }

    // MARK: - Push-To-Talk Entry Points

    /// Call when the PTT button is pressed.
    /// Allowed from idle AND while executing — a new command interrupts the
    /// current mission / overhead hold (drone hovers while listening).
    func onPushToTalkPressed() {
        switch appState {
        case .idle:
            break
        case .executing:
            log("PTT during \(appState.displayTitle) — interrupting.")
            missionExecutor.cancel()
            behaviors.stop()
            tracker.stopTracking()
        default:
            log("PTT ignored — state is \(appState.displayTitle).", level: .warning)
            return
        }
        headTracking.freeze()        // lock frame for grounding (spec §5 step 2)
        voicePipeline.onPressStartTalking()
        appState = .listening
        spatialAudio.playCommandConfirmation()
        log("Listening — head-tracking frozen.")
    }

    /// Call when the PTT button is released.
    func handleVoiceRelease() {
        guard case .listening = appState else { return }
        appState = .processing

        Task {
            guard let fileURL = voicePipeline.recorder.stopRecording() else {
                log("Recording failed — no output file.", level: .error)
                appState = .error(message: "Recording failed")
                scheduleReturnToIdle(after: 2)
                return
            }

            do {
                let text = try await ElevenLabsSTT.transcribe(fileURL: fileURL)
                lastTranscript = text
                log("STT: \"\(text)\"")
                await processTranscript(text)
            } catch {
                log("STT error: \(error.localizedDescription)", level: .error)
                spatialAudio.playErrorCue()
                appState = .error(message: "Speech recognition failed")
                headTracking.unfreeze()
                scheduleReturnToIdle(after: 3)
            }
        }
    }

    /// Post-command handoff: while a session is live the drone always returns
    /// to the overhead hold; otherwise go idle. Re-arms the wakeword listener.
    private func finishCommandCycle() {
        // A newer command may already be capturing/processing (voice interrupt)
        // — never stomp it.
        if case .listening = appState { return }
        if case .processing = appState { return }
        headTracking.unfreeze()
        if isSessionActive && bridge.telemetry.isFlying {
            resumeOverheadHold()
        } else {
            returnToIdle()
        }
        restartWakewordIfNeeded()
    }

    // MARK: - Transcript → Backend → Intent

    private func processTranscript(_ transcript: String) async {
        do {
            let frameData = bridge.captureFrameJPEG()
            log("→ backend: \(frameData.count) B frame + transcript")

            let response = try await BackendClient.processVoiceCommand(
                transcript: transcript,
                imageData: frameData
            )
            lastResponse = response

            log("← \(response.steps.count) step(s) | transcript: \(response.transcript) | confidence: \(String(format: "%.2f", response.confidence))")

            await runMission(steps: response.steps)

        } catch {
            log("Backend error: \(error.localizedDescription)", level: .error)
            spatialAudio.playErrorCue()
            appState = .error(message: error.localizedDescription)
            headTracking.unfreeze()
            scheduleReturnToIdle(after: 3)
        }
    }

    // MARK: - Mission Execution

    private func runMission(steps: [NimbusStep]) async {
        // Suspend the overhead hold / any running behavior while the mission owns the aircraft.
        behaviors.stop()
        tracker.stopTracking()
        headTracking.unfreeze()

        let firstOp = steps.first?.op.uppercased() ?? "MISSION"
        appState = .executing(verb: firstOp, target: steps.first?.target)
        log("Mission start: \(steps.map(\.op).joined(separator: " → "))")
        // Keep the wakeword hot during the mission so "Nimbus, stop" interrupts.
        restartWakewordIfNeeded()

        let result = await missionExecutor.run(steps: steps)
        switch result {
        case .completed:
            spatialAudio.playCommandConfirmation()
            log("Mission completed.")
        case .cancelled:
            log("Mission cancelled.", level: .warning)
        case .failed(let reason):
            spatialAudio.playErrorCue()
            log("Mission failed: \(reason)", level: .warning)
        }
        finishCommandCycle()
    }

    // MARK: - Abort (from UI)

    func abort() {
        missionExecutor.cancel()
        behaviors.stop()
        tracker.stopTracking()
        headTracking.unfreeze()
        log("User aborted.")
        if isSessionActive && bridge.telemetry.isFlying {
            // Stay airborne — hold overhead and wait for the next command.
            resumeOverheadHold()
            restartWakewordIfNeeded()
        } else {
            returnToIdle()
        }
    }

    func saveRememberedSpot(name: String? = nil) {
        guard let location = bridge.telemetry.currentLocation else {
            log("Remember spot failed — GPS location unavailable.", level: .warning)
            return
        }

        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let finalName = trimmedName.isEmpty ? "Spot \(rememberedSpots.count + 1)" : trimmedName
        let spot = RememberedSpot(name: finalName, coordinate: location, capturedAt: Date())
        rememberedSpots.append(spot)
        persistRememberedSpots()
        let lat = String(format: "%.6f", location.latitude)
        let lon = String(format: "%.6f", location.longitude)
        log("Remembered spot saved: \(finalName) @ \(lat), \(lon)")
    }

    func returnToRememberedSpot(_ spot: RememberedSpot? = nil) {
        let destination = spot ?? rememberedSpots.last
        guard let destination else {
            log("No remembered spot saved yet.", level: .warning)
            return
        }
        guard bridge.telemetry.currentLocation != nil else {
            log("Remembered spot unavailable — no GPS fix.", level: .warning)
            return
        }
        log("Returning to remembered spot: \(destination.name)")
        behaviors.goToCoordinate(destination.coordinate, toleranceM: 1.5, maxSeconds: 120)
        appState = .executing(verb: "RETURN SPOT", target: destination.name)
    }

    func deleteRememberedSpots(at offsets: IndexSet) {
        guard !offsets.isEmpty else { return }
        rememberedSpots.remove(atOffsets: offsets)
        persistRememberedSpots()
    }

    func clearRememberedSpots() {
        rememberedSpots.removeAll()
        persistRememberedSpots()
    }

    func startPersonFollow() {
        guard bridge.isAircraftConnected else {
            log("Cannot start follow — aircraft not connected.", level: .warning)
            return
        }
        if !headTracking.isTracking {
            headTracking.start(compassHeadingDeg: bridge.telemetry.headingDeg)
        }
        // Recalibrate at follow start so drone heading alignment matches the user's current forward direction.
        headTracking.calibrate()
        bridge.pointGimbalDownImmediately(airpodsPitchDeg: CGFloat(headTracking.effectiveAttitude.pitchDeg),
                                          strictDown: true)
        behaviors.followPerson(maxSeconds: 90,
                               overheadMode: isOverheadFollowModeEnabled)
        appState = .executing(verb: "FOLLOW", target: "head")
        log("Person follow started (mode: \(isOverheadFollowModeEnabled ? "overhead-topdown" : "heading-follow"), airpodsTracking=\(headTracking.isTracking), calibrated=\(headTracking.isCalibrated)).")
    }

    func stopSpecialMission() {
        behaviors.stop()
        headTracking.unfreeze()
        returnToIdle()
    }

    // MARK: - Backend Health

    func checkBackendHealth() async {
        isBackendReachable = await BackendClient.checkHealth()
        let status = isBackendReachable ? "✓" : "✗"
        log("Backend \(status) at \(BackendClient.baseURL.absoluteString)")
    }

    // MARK: - Helpers

    private func returnToIdle() {
        headTracking.unfreeze()
        appState = .idle
    }

    private func scheduleReturnToIdle(after seconds: Double) {
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            // If a session is live, recover into the overhead hold instead of idling.
            finishCommandCycle()
        }
    }

    private func waitForCameraWarmup(maxSeconds: Double) async {
        let deadline = Date().addingTimeInterval(maxSeconds)
        while Date() < deadline {
            if bridge.hasLiveVideoData, bridge.cameraFrame != nil { return }
            try? await Task.sleep(for: .seconds(0.2))
        }
    }

    private func resumeOverheadHold_public() {
        resumeOverheadHold()
    }

    // MARK: - Logging

    func log(_ message: String, level: LogEntry.Level = .info) {
        print("[Orchestrator] \(message)")
        let entry = LogEntry(timestamp: Date(), message: message, level: level)
        logMessages.append(entry)
        if logMessages.count > 200 { logMessages.removeFirst(50) }
    }

    // MARK: - Remembered Spots Persistence

    private func loadRememberedSpots() {
        guard let data = UserDefaults.standard.data(forKey: rememberedSpotsKey) else { return }
        do {
            rememberedSpots = try JSONDecoder().decode([RememberedSpot].self, from: data)
        } catch {
            log("Failed to load remembered spots: \(error.localizedDescription)", level: .warning)
        }
    }

    private func persistRememberedSpots() {
        do {
            let data = try JSONEncoder().encode(rememberedSpots)
            UserDefaults.standard.set(data, forKey: rememberedSpotsKey)
        } catch {
            log("Failed to persist remembered spots: \(error.localizedDescription)", level: .error)
        }
    }
}
