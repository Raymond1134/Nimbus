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

@Observable
final class Orchestrator {

    // MARK: - Observed State

    var appState: AppState              = .idle
    var lastTranscript                  = ""
    var lastIntent: ParsedIntent?
    var lastResponse: BackendVoiceCommandResponse?
    var logMessages: [LogEntry]         = []
    var isBackendReachable              = false

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

    /// Flight behaviors — initialized in init() to break init-order dependency
    /// on bridge + safety (@Observable is incompatible with lazy stored properties).
    /// @ObservationIgnored because behaviors is never read in a SwiftUI body.
    @ObservationIgnored private(set) var behaviors: FlightBehaviors!

    // MARK: - Init

    init() {
        let b = FlightBehaviors(bridge: bridge, safety: safety)
        b.onBehaviorComplete = { [weak self] in
            self?.log("Behavior complete → idle.")
            self?.returnToIdle()
        }
        behaviors = b
        log("Orchestrator initialised.")
        Task { await checkBackendHealth() }
    }

    // MARK: - Push-To-Talk Entry Points

    /// Call when the PTT button is pressed.
    func onPushToTalkPressed() {
        guard case .idle = appState else {
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

            let gStr = response.found
                ? "found \(String(format: "%.2f", response.groundingConfidence))"
                : "not found"
            log("← intent=\(response.intent ?? "nil")  target=\(response.target ?? "-")  grounding=\(gStr)")

            lastIntent = ParsedIntent(
                intent:       response.intent ?? "unknown",
                target:       response.target,
                sayText:      response.sayText,
                constraints:  response.constraints ?? .empty,
                confidence:   response.confidence ?? 0
            )

            await executeIntent(response)

        } catch {
            log("Backend error: \(error.localizedDescription)", level: .error)
            spatialAudio.playErrorCue()
            appState = .error(message: error.localizedDescription)
            headTracking.unfreeze()
            scheduleReturnToIdle(after: 3)
        }
    }

    // MARK: - Intent Dispatcher (spec §5 steps 4–6)

    private func executeIntent(_ r: BackendVoiceCommandResponse) async {
        headTracking.unfreeze()
        let intent = r.intent ?? "unknown"

        switch intent {

        case "abort":
            behaviors.stop()
            tracker.stopTracking()
            log("Aborted.")
            returnToIdle()

        case "hover_station":
            behaviors.hover()
            appState = .executing(verb: "HOVER", target: nil)
            log("Hovering at station.")
            scheduleReturnToIdle(after: 1.5)

        case "return_to_station":
            behaviors.returnToHome()
            appState = .executing(verb: "RETURN", target: nil)
            log("Returning to home point.")
            // Stays in executing; DJI SDK auto-transitions when home is reached.

        case "land":
            behaviors.land()
            appState = .executing(verb: "LAND", target: nil)
            log("Landing.")

        case "say":
            log("Say: \"\(r.sayText ?? "")\"")
            returnToIdle()

        case "seek_and_photo":
            guard r.found, !r.box2d.isEmpty else {
                log("Grounding: target '\(r.target ?? "")' not found in frame.", level: .warning)
                spatialAudio.playNotFound()
                returnToIdle()
                return
            }
            guard r.groundingConfidence >= 0.30 else {
                log("Grounding confidence \(String(format: "%.2f", r.groundingConfidence)) too low — aborting.", level: .warning)
                spatialAudio.playNotFound()
                returnToIdle()
                return
            }

            let targetName = r.target ?? "object"
            let standoff   = resolveStandoff(from: r.constraints?.maxRadiusM)
            let maxSec     = r.constraints?.maxSeconds ?? 45.0

            let flightTarget = FlightTarget(
                intent:       intent,
                target:       targetName,
                groundingBox: r.box2d,
                standoffM:    standoff,
                maxSeconds:   maxSec,
                maxRadiusM:   r.constraints?.maxRadiusM ?? 30.0
            )

            switch safety.validate(flightTarget, telemetry: bridge.telemetry) {
            case .rejected(let reason):
                log("Safety rejected: \(reason)", level: .warning)
                spatialAudio.playErrorCue()
                returnToIdle()
                return
            case .approved:
                break
            }

            // Lock object tracker onto the grounded box (spec §5 step 5)
            tracker.startTracking(bbox: normalizedVisionBox(from: r.box2d))

            appState = .executing(verb: "APPROACH", target: targetName)
            log("Executing approach → '\(targetName)'  standoff=\(standoff)m  maxSec=\(maxSec)s")
            behaviors.approach(box: r.box2d, standoffM: standoff, maxSeconds: maxSec)

        default:
            log("Unknown intent '\(intent)' — idle.", level: .warning)
            returnToIdle()
        }
    }

    // MARK: - Abort (from UI)

    func abort() {
        behaviors.stop()
        tracker.stopTracking()
        headTracking.unfreeze()
        log("User aborted.")
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
            returnToIdle()
        }
    }

    /// max_radius_m from constraints is a search bound, not a standoff.
    /// Map it to a reasonable standoff (default 3 m).
    private func resolveStandoff(from radiusHint: Double?) -> Double {
        let raw = radiusHint ?? 30.0
        return raw > 10 ? 3.0 : max(safety.minStandoffM, raw)
    }

    /// Convert backend [ymin, xmin, ymax, xmax] (0–1000) to a Vision CGRect
    /// (origin bottom-left, 0–1, Y flipped).
    private func normalizedVisionBox(from box: [Int]) -> CGRect {
        guard box.count == 4 else { return .zero }
        let xMin   = CGFloat(box[1]) / 1000
        let yMin   = 1.0 - CGFloat(box[2]) / 1000   // flip Y
        let width  = CGFloat(box[3] - box[1]) / 1000
        let height = CGFloat(box[2] - box[0]) / 1000
        return CGRect(x: xMin, y: yMin, width: width, height: height)
    }

    // MARK: - Logging

    func log(_ message: String, level: LogEntry.Level = .info) {
        print("[Orchestrator] \(message)")
        let entry = LogEntry(timestamp: Date(), message: message, level: level)
        logMessages.append(entry)
        if logMessages.count > 200 { logMessages.removeFirst(50) }
    }
}
