//
//  WakewordListener.swift
//  Nimbus
//
//  Created by Julia Chen on 2026-07-18.
//

import Foundation
import Speech
import AVFoundation
import Observation

/// Listens for the wakeword using Apple's on-device SFSpeechRecognizer and keeps
/// AVAudioEngine alive the entire time — including during command capture.
///
/// When the wakeword fires, the tap is flipped from "feed speech recognizer" to
/// "write to an AVAudioFile". There is zero hardware handoff, so there is no gap
/// at the start of the recording. The file is written in the engine's native PCM
/// format (WAV) and is returned to the caller via stopCapture().
@Observable
final class WakewordListener {

    // MARK: - Public state

    var onWakewordDetected: (() -> Void)?
    var isListeningForWakeword = false
    var latestTranscription = ""
    var wakewordDetectionCount = 0

    /// True while the tap is writing audio to the capture file.
    private(set) var isCapturing = false

    /// RMS and peak dBFS of the most recent buffer written during capture.
    /// Updated from the audio thread on every buffer (~10 ms intervals).
    /// @ObservationIgnored so these never trigger a SwiftUI body re-render.
    @ObservationIgnored var captureRMSDB:  Float = -160
    @ObservationIgnored var capturePeakDB: Float = -160

    // MARK: - Private

    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()
    private var lastWakewordAt = Date.distantPast
    private let wakewordDebounceSec: TimeInterval = 1.2

    // Capture file — set before isCapturing = true, cleared after isCapturing = false
    // so the audio thread always sees a valid file when isCapturing is true.
    private var captureFile: AVAudioFile?
    private var captureURL: URL?

    // MARK: - Listening lifecycle

    /// Start (or resume) wakeword listening.
    /// If the engine is already running (returning from a capture cycle), this
    /// only restarts the recognition task — no hardware round-trip.
    func startListening() {
        if audioEngine.isRunning {
            startRecognitionTask()
            return
        }
        latestTranscription = ""
        let status = SFSpeechRecognizer.authorizationStatus()
        if status == .authorized {
            setupEngineAndStart()
            return
        }
        guard status == .notDetermined else {
            print("❌ Speech recognition authorization denied")
            return
        }
        SFSpeechRecognizer.requestAuthorization { [weak self] authStatus in
            DispatchQueue.main.async {
                guard authStatus == .authorized else {
                    print("❌ Speech recognition authorization denied")
                    return
                }
                self?.setupEngineAndStart()
            }
        }
    }

    /// Hard stop: kills both the engine and any in-progress capture.
    func stopListening() {
        guard isListeningForWakeword || isCapturing || audioEngine.isRunning else { return }
        isListeningForWakeword = false

        // Stop capture without returning the URL — discard whatever was buffered.
        if isCapturing {
            isCapturing = false
            captureFile = nil
            captureURL = nil
            captureRMSDB  = -160
            capturePeakDB = -160
        }

        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)

        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil

        print("🛑 Audio engine stopped.")
    }

    // MARK: - Capture

    /// Stop capturing and return the audio file URL for STT.
    /// Returns nil if not currently capturing.
    func stopCapture() -> URL? {
        guard isCapturing else { return nil }
        // Clear flag first so the tap stops writing before we nil the file.
        isCapturing = false
        captureFile = nil   // ARC closes and flushes the file
        let url = captureURL
        captureURL = nil
        captureRMSDB  = -160
        capturePeakDB = -160
        return url
    }

    // MARK: - Private setup

    private func setupEngineAndStart() {
        let inputNode = audioEngine.inputNode
        let format    = inputNode.outputFormat(forBus: 0)

        inputNode.removeTap(onBus: 0)   // clear any stale tap
        // Smaller buffer keeps wakeword latency low.
        inputNode.installTap(onBus: 0, bufferSize: 512, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            if self.isCapturing {
                // Capture mode: write to file for ElevenLabs and update VAD meters.
                try? self.captureFile?.write(from: buffer)
                self.updateCaptureMeters(from: buffer)
            } else {
                // Wakeword mode: feed on-device speech recognizer.
                self.recognitionRequest?.append(buffer)
            }
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
            print("Audio engine started — waiting for 'Nimbus'…")
        } catch {
            print("Audio engine failed to start: \(error.localizedDescription)")
            return
        }
        startRecognitionTask()
    }

    private func startRecognitionTask() {
        recognitionTask?.cancel()
        recognitionTask = nil

        let request = SFSpeechAudioBufferRecognitionRequest()
        // On-device recognition: instant, no network round-trip.
        request.requiresOnDeviceRecognition = true
        if #available(iOS 16.0, *) { request.addsPunctuation = false }
        request.shouldReportPartialResults = true
        recognitionRequest = request
        isListeningForWakeword = true
        latestTranscription = ""

        recognitionTask = speechRecognizer?.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            guard let result else {
                if let error { print("Local recognition error: \(error)") }
                return
            }
            let text = result.bestTranscription.formattedString.lowercased()
            print("Local buffer raw text: \(text)")
            DispatchQueue.main.async { self.latestTranscription = text }

            guard self.matchesWakeword(text) else { return }
            let now = Date()
            guard now.timeIntervalSince(self.lastWakewordAt) > self.wakewordDebounceSec else { return }
            self.lastWakewordAt = now
            print("🎯 Wakeword detected — switching tap to capture mode.")
            DispatchQueue.main.async {
                self.wakewordDetectionCount += 1
                self.switchToCapture()
                self.onWakewordDetected?()
            }
        }
    }

    /// Flip the tap from wakeword-recognition to audio-capture without stopping
    /// the engine. There is no gap between detection and the first captured buffer.
    private func switchToCapture() {
        // End the recognizer — engine and tap keep running.
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        isListeningForWakeword = false

        // Open the capture file before setting isCapturing = true so the audio
        // thread always sees a valid file when it checks the flag.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
        captureURL = url
        let nativeFormat = audioEngine.inputNode.outputFormat(forBus: 0)
        captureFile = try? AVAudioFile(forWriting: url, settings: nativeFormat.settings)
        captureRMSDB  = -160
        capturePeakDB = -160
        isCapturing = true
        print("Capture started (no gap): \(url.lastPathComponent)")
    }

    // MARK: - VAD metering from raw PCM

    /// Compute RMS and peak dBFS from a PCM buffer's channel-0 float samples.
    /// Called from the audio thread on every buffer during capture (~10 ms cadence).
    private func updateCaptureMeters(from buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData?[0] else { return }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return }
        var sumSq: Float = 0
        var peak:  Float = 0
        for i in 0..<n {
            let s = abs(data[i])
            sumSq += s * s
            if s > peak { peak = s }
        }
        let rms = sqrt(sumSq / Float(n))
        captureRMSDB  = rms  > 0 ? 20 * log10(rms)  : -160
        capturePeakDB = peak > 0 ? 20 * log10(peak) : -160
    }

    // MARK: - Wakeword matching

    private func matchesWakeword(_ transcript: String) -> Bool {
        let words = transcript
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map { String($0).lowercased() }
        guard !words.isEmpty else { return false }
        let tail = Array(words.suffix(4))

        // "Nimbus" — primary wakeword.
        let nimbusTokens = ["nimbus", "nimbis"]
        if tail.contains(where: { nimbusTokens.contains($0) }) { return true }
        // Fuzzy fallback: tolerate up to 2 edits (catches "nimis", "nimbuz") but
        // not broad false-positives like "numbers".
        if let last = tail.last, levenshtein(last, "nimbus") <= 2 { return true }


        return false
    }

    private func levenshtein(_ a: String, _ b: String) -> Int {
        let aChars = Array(a)
        let bChars = Array(b)
        var dist = Array(repeating: Array(repeating: 0, count: bChars.count + 1), count: aChars.count + 1)
        for i in 0...aChars.count { dist[i][0] = i }
        for j in 0...bChars.count { dist[0][j] = j }
        if aChars.isEmpty { return bChars.count }
        if bChars.isEmpty { return aChars.count }
        for i in 1...aChars.count {
            for j in 1...bChars.count {
                let cost = aChars[i - 1] == bChars[j - 1] ? 0 : 1
                dist[i][j] = min(
                    dist[i - 1][j] + 1,
                    dist[i][j - 1] + 1,
                    dist[i - 1][j - 1] + cost
                )
            }
        }
        return dist[aChars.count][bChars.count]
    }
}
