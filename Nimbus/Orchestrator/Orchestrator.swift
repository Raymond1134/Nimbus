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
    /// True while the heading-align hold button is being pressed.
    var isHeadingCalibrationHoldActive  = false
    /// Hands-free mode: "Nimbus …" wakeword triggers listening automatically.
    var isHandsFreeEnabled              = false
    var handsFreeVadStartThresholdDB: Float { handsFreeSpeechStartThresholdDB }
    var handsFreeVadContinueThresholdDB: Float { handsFreeSpeechContinueThresholdDB }
    var handsFreeVadSilenceStopSeconds: Double { handsFreeSilenceStopSeconds }

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
    /// Hard ceiling for wakeword-initiated capture.
    @ObservationIgnored private let handsFreeMaxRecordSeconds: Double = 2.0
    /// End recording after this much trailing silence once speech started.
    @ObservationIgnored private let handsFreeSilenceStopSeconds: Double = 1.0
    /// dBFS threshold to declare speech start (less sensitive).
    @ObservationIgnored private let handsFreeSpeechStartThresholdDB: Float = -38
    /// dBFS threshold to continue speech (more sensitive hysteresis).
    @ObservationIgnored private let handsFreeSpeechContinueThresholdDB: Float = -45
    /// Minimum crest factor (peak − average, dB) required to qualify as speech.
    /// Speech is bursty: crest factor is typically 6–18 dB.
    /// Steady drone / wind noise is continuous: crest factor is usually < 4 dB.
    @ObservationIgnored private let handsFreeMinCrestFactorDB: Float = 5.0
    /// Consecutive meter frames that must pass the speech test before committing.
    /// At 80 ms/frame this is 160 ms — filters out transient clicks / taps.
    @ObservationIgnored private let handsFreeMinSpeechFrames: Int = 2
    /// If no qualifying speech is heard within this window, abandon silently
    /// and rearm the wakeword instead of sending an empty recording to STT.
    @ObservationIgnored private let handsFreeNoSpeechTimeoutSeconds: Double = 1.0
    @ObservationIgnored private let handsFreeMeterPollSeconds: Double = 0.08
    @ObservationIgnored private let wakewordYawCalibrationSeconds: Double = 1.0
    @ObservationIgnored private var handsFreeCaptureTask: Task<Void, Never>?
    @ObservationIgnored private var wakewordYawCalibrationTask: Task<Void, Never>?
    @ObservationIgnored private let speechSynth = AVSpeechSynthesizer()

    // MARK: - Init

    init() {
        let b = FlightBehaviors(bridge: bridge, safety: safety, headTracking: headTracking)
        b.onBehaviorComplete = { [weak self] in
            guard let self else { return }
            // During a mission the executor owns behavior sequencing.
            if self.missionExecutor?.isRunning == true { return }
            self.log("Behavior complete → idle hover.")
            if self.isSessionActive && self.bridge.isAircraftConnected
                                    && self.bridge.telemetry.isFlying {
                self.resumeIdleHover()
            } else {
                self.headTracking.unfreeze()
                self.appState = .idle
            }
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
            guard let self else { return }
            if ActionTuning.shared.abortResumesOverheadHold {
                self.resumeIdleHover()
            } else {
                // Spec: stop everything and hold in place.
                self.behaviors.hover()
                self.appState = .executing(verb: "HOLD", target: nil)
                self.log("Abort → holding in place.")
            }
        }
        wakeword.onWakewordDetected = { [weak self] in
            self?.handleWakewordTriggered()
        }
        loadRememberedSpots()
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
            self.speak("Nimbus airborne.")
            self.resumeIdleHover()
            if self.isHandsFreeEnabled { self.wakeword.startListening() }
        }
    }

    /// End the session: stop everything and land.
    func endSession() {
        missionExecutor.cancel()
        behaviors.stop()
        isSessionActive = false
        wakeword.stopListening()
        voicePipeline.stopWakewordPreRollCapture()
        appState = .executing(verb: "LAND", target: nil)
        log("Session end: landing.")
        Task { [weak self] in
            guard let self else { return }
            _ = await self.bridge.startLanding()
            self.returnToIdle()
        }
    }

    /// Immediate forced landing flow from UI controls.
    func forceLandNow() {
        missionExecutor.cancel()
        behaviors.stop()
        tracker.stopTracking()
        headTracking.unfreeze()
        isSessionActive = false
        wakeword.stopListening()
        voicePipeline.stopWakewordPreRollCapture()
        appState = .executing(verb: "FORCE LAND", target: nil)
        log("Force landing requested.")
        Task { [weak self] in
            guard let self else { return }
            _ = await self.bridge.startLanding()
            self.returnToIdle()
        }
    }

    /// Stop any active behavior and settle into a vanilla position hold with
    /// neutral yaw (no idle head-direction following).
    private func resumeIdleHover() {
        guard isSessionActive, bridge.isAircraftConnected else { return }
        if !headTracking.isTracking {
            headTracking.start(compassHeadingDeg: bridge.telemetry.headingDeg)
        }
        behaviors.hover()
        appState = .idle
        log("Idle hover active — yaw follow disabled.")
    }

    // MARK: - Hands-Free Wakeword

    func setHandsFree(_ enabled: Bool) {
        isHandsFreeEnabled = enabled
        if enabled {
            voicePipeline.startWakewordPreRollCapture()
            wakeword.startListening()
            log("Hands-free enabled — say \"Nimbus …\".")
        } else {
            handsFreeCaptureTask?.cancel()
            handsFreeCaptureTask = nil
            wakewordYawCalibrationTask?.cancel()
            wakewordYawCalibrationTask = nil
            behaviors.setHeadingControlSuppressed(false)
            wakeword.stopListening()
            voicePipeline.stopWakewordPreRollCapture()
            log("Hands-free disabled.")
        }
    }

    /// Wakeword fired: auto-record, then stop on end-of-speech (with max cap).
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
        spatialAudio.playWakewordCue()
        // Stop TTS so it doesn't bleed into the capture. The AVAudioEngine stays
        // live — switchToCapture() already flipped the tap to write mode before
        // onWakewordDetected fired, so the very first buffer after the wakeword
        // phrase is already in the file. No hardware handoff, no gap.
        speechSynth.stopSpeaking(at: .immediate)
        appState = .listening
        beginWakewordYawCalibrationWindow()
        log("Wakeword → cue + 1s yaw calibration while speaking, then listening continues (auto-stop on silence, max \(Int(handsFreeMaxRecordSeconds))s)…")
        handsFreeCaptureTask?.cancel()
        handsFreeCaptureTask = Task { [weak self] in
            await self?.monitorHandsFreeCaptureUntilSpeechEnds()
        }
    }

    private func beginWakewordYawCalibrationWindow() {
        wakewordYawCalibrationTask?.cancel()
        if !headTracking.isTracking {
            headTracking.start(compassHeadingDeg: bridge.telemetry.headingDeg)
        }
        headTracking.unfreeze()
        behaviors.setHeadingControlSuppressed(true)
        wakewordYawCalibrationTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(self.wakewordYawCalibrationSeconds))
            guard !Task.isCancelled else { return }
            self.completeWakewordYawCalibration(lockHeadTracking: true)
        }
    }

    private func completeWakewordYawCalibration(lockHeadTracking: Bool) {
        guard wakewordYawCalibrationTask != nil else { return }
        if case .listening = appState {
            headTracking.calibrate(toCompassHeadingDeg: bridge.telemetry.headingDeg)
            if lockHeadTracking {
                headTracking.freeze()
            } else {
                headTracking.unfreeze()
            }
            log("Wakeword yaw calibration saved at \(Int(bridge.telemetry.headingDeg))°.")
        }
        behaviors.setHeadingControlSuppressed(false)
        wakewordYawCalibrationTask?.cancel()
        wakewordYawCalibrationTask = nil
    }

    /// A new voice command arrived while flying: pause the current activity
    /// (mission or overhead hold) and listen.
    private func interruptForNewCommand() {
        missionExecutor.cancel()
        behaviors.hover()   // hold position while listening
        appState = .idle
        beginHandsFreeCapture()
    }

    private func restartWakewordIfNeeded() {
        if isHandsFreeEnabled {
            voicePipeline.startWakewordPreRollCapture()
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
        handsFreeCaptureTask?.cancel()
        handsFreeCaptureTask = nil
        wakewordYawCalibrationTask?.cancel()
        wakewordYawCalibrationTask = nil
        behaviors.setHeadingControlSuppressed(false)
        switch appState {
        case .idle:
            break
        case .executing:
            log("PTT during \(appState.displayTitle) — interrupting.")
            missionExecutor.cancel()
            behaviors.hover()   // hold position while listening
            tracker.stopTracking()
        case .error:
            log("PTT recovering from error state.")
        default:
            log("PTT ignored — state is \(appState.displayTitle).", level: .warning)
            return
        }
        // Release the wakeword engine and TTS before starting the recorder.
        // AVAudioEngine (wakeword), AVSpeechSynthesizer, and AVAudioRecorder all
        // share the same input hardware — running them together kills the recording.
        wakeword.stopListening()
        speechSynth.stopSpeaking(at: .immediate)
        headTracking.freeze()
        voicePipeline.onPressStartTalking()
        appState = .listening
        spatialAudio.playCommandConfirmation()
        log("Listening — head-tracking frozen.")
    }

    /// Call when the PTT button is released.
    func handleVoiceRelease() {
        guard case .listening = appState else { return }
        handsFreeCaptureTask?.cancel()
        handsFreeCaptureTask = nil
        completeWakewordYawCalibration(lockHeadTracking: true)
        appState = .processing

        Task {
            // Hands-free uses the always-on engine tap (wakeword.stopCapture).
            // PTT uses AVAudioRecorder (voicePipeline.stopCommandCapture).
            // Try both — exactly one will be active.
            let fileURL = wakeword.stopCapture() ?? voicePipeline.stopCommandCapture()
            guard let fileURL else {
                log("Recording failed — no output file.", level: .error)
                appState = .error(message: "Recording failed")
                scheduleReturnToIdle(after: 2)
                return
            }
            do {
                let rawText = try await ElevenLabsSTT.transcribe(fileURL: fileURL)
                let text = trimmedTranscriptForCommandPrinting(rawText)
                lastTranscript = text
                log("STT: \"\(text)\"")
                speak("Got it. Planning your command now.")
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
        // An abort step put the drone into a hold-in-place — keep it there.
        if case .executing(let verb, _) = appState, verb == "HOLD" {
            restartWakewordIfNeeded()
            return
        }
        headTracking.unfreeze()
        if isSessionActive && bridge.telemetry.isFlying {
            resumeIdleHover()
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
        speak("Executing now.")
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
            // Stay airborne — neutral hover and wait for next command.
            resumeIdleHover()
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
        behaviors.hover()
        headTracking.unfreeze()
        appState = .idle
    }

    // MARK: - Heading Alignment Calibration (hold-to-align)

    /// Press-and-hold: freeze yaw alignment output so the drone does not rotate
    /// while the operator lines up their facing direction with the aircraft.
    func beginHeadingAlignmentCalibrationHold() {
        guard bridge.isAircraftConnected else { return }
        guard bridge.telemetry.isFlying else { return }
        guard !isHeadingCalibrationHoldActive else { return }
        if !headTracking.isTracking {
            headTracking.start(compassHeadingDeg: bridge.telemetry.headingDeg)
        }
        isHeadingCalibrationHoldActive = true
        headTracking.freeze()
        behaviors.setHeadingControlSuppressed(true)
        behaviors.hover()
        log("Heading calibration hold started — yaw frozen.")
    }

    /// Release: save the AirPods offset against the drone's current heading,
    /// then resume normal heading-hold behavior.
    func endHeadingAlignmentCalibrationHold() {
        guard isHeadingCalibrationHoldActive else { return }
        isHeadingCalibrationHoldActive = false
        headTracking.calibrate(toCompassHeadingDeg: bridge.telemetry.headingDeg)
        headTracking.unfreeze()
        behaviors.setHeadingControlSuppressed(false)
        if isSessionActive && bridge.isAircraftConnected && bridge.telemetry.isFlying {
            resumeIdleHover()
        } else {
            appState = .idle
        }
        log("Heading calibration saved at drone heading \(Int(bridge.telemetry.headingDeg))°.")
    }

    // MARK: - Debug Mission (Debug panel op dropdown)

    /// Execute a single hand-built step from the Debug panel, going through
    /// the exact same MissionExecutor path as voice commands.
    func executeDebugMission(steps: [NimbusStep]) async {
        guard bridge.isAircraftConnected else {
            log("Debug mission ignored — aircraft not connected.", level: .warning)
            return
        }
        guard !missionExecutor.isRunning else {
            log("Debug mission ignored — a mission is already running.", level: .warning)
            return
        }
        log("Debug mission: \(steps.map(\.op).joined(separator: " → "))")
        await runMission(steps: steps)
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

    /// When wakeword pre-roll is enabled, the transcript can contain speech
    /// from before activation. For command printing/logging, trim to start at
    /// "hey nimbus" if present.
    private func trimmedTranscriptForCommandPrinting(_ transcript: String) -> String {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        let lowered = trimmed.lowercased()
        if let range = lowered.range(of: "hey nimbus") {
            return String(trimmed[range.lowerBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed
    }

    private func monitorHandsFreeCaptureUntilSpeechEnds() async {
        let startedAt = Date()
        var speechStartedAt: Date?          // nil until enough qualifying frames seen
        var lastSpeechAt:   Date = startedAt
        var consecutiveSpeechFrames = 0

        while !Task.isCancelled {
            guard case .listening = appState else { return }
            guard wakeword.isCapturing || voicePipeline.recorder.isRecording else { return }

            let now     = Date()
            let elapsed = now.timeIntervalSince(startedAt)

        // --- Speech detection (volume + crest-factor filter) ---
            // Crest factor = peak − average. Speech: 6–18 dB. Drone/wind: < 4 dB.
            // Requiring both conditions filters out steady broadband noise that
            // happens to be loud enough to cross the volume threshold alone.
            // Meter values are updated from raw PCM by the engine tap (~10 ms
            // cadence) — far more responsive than polling AVAudioRecorder metering.
            do {
                let (avgDB, peakDB) = (wakeword.captureRMSDB, wakeword.capturePeakDB)
                let crestFactor = peakDB - avgDB
                let volumeThreshold = speechStartedAt != nil
                    ? handsFreeSpeechContinueThresholdDB   // hysteresis: easier to stay in speech
                    : handsFreeSpeechStartThresholdDB
                let frameIsSpeech = avgDB > volumeThreshold && crestFactor > handsFreeMinCrestFactorDB

                if frameIsSpeech {
                    consecutiveSpeechFrames += 1
                    // Require a run of qualifying frames so single taps/clicks don't trigger.
                    if consecutiveSpeechFrames >= handsFreeMinSpeechFrames {
                        if speechStartedAt == nil {
                            speechStartedAt = now
                            log(String(format: "Wakeword capture: speech detected (avg %.0f dB, crest %.0f dB).", avgDB, crestFactor))
                        }
                        lastSpeechAt = now
                    }
                } else {
                    consecutiveSpeechFrames = 0
                }
            }

            // --- Stop conditions ---

            // Trailing silence after confirmed speech → send to STT.
            if let _ = speechStartedAt,
               now.timeIntervalSince(lastSpeechAt) >= handsFreeSilenceStopSeconds {
                log("Wakeword capture: trailing silence → processing.")
                handleVoiceRelease()
                return
            }

            // No qualifying speech within the startup window → abandon and rearm
            // rather than sending an empty (or noise-only) clip to STT.
            if speechStartedAt == nil, elapsed >= handsFreeNoSpeechTimeoutSeconds {
                log("Wakeword capture: no speech in \(Int(handsFreeNoSpeechTimeoutSeconds))s — rearming wakeword.")
                abandonListening()
                return
            }

            // Absolute ceiling — force a cut even mid-sentence.
            if elapsed >= handsFreeMaxRecordSeconds {
                log("Wakeword capture: max window reached → processing.")
                handleVoiceRelease()
                return
            }

            try? await Task.sleep(for: .seconds(handsFreeMeterPollSeconds))
        }
    }

    /// Silently abandon a listening session that captured no qualifying speech.
    /// Discards the recording without hitting the STT API and rearms the wakeword.
    private func abandonListening() {
        guard case .listening = appState else { return }
        handsFreeCaptureTask = nil   // we're already inside the task; just clear the ref
        wakewordYawCalibrationTask?.cancel()
        wakewordYawCalibrationTask = nil
        behaviors.setHeadingControlSuppressed(false)
        headTracking.unfreeze()
        _ = wakeword.stopCapture()              // discard hands-free capture
        _ = voicePipeline.stopCommandCapture()  // discard PTT capture (no-op if not active)
        appState = .idle
        if isSessionActive && bridge.telemetry.isFlying {
            resumeIdleHover()
        }
        restartWakewordIfNeeded()
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
