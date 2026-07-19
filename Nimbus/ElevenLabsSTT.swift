// ElevenLabsSTT.swift — Nimbus
// Audio recording (AVAudioRecorder) + ElevenLabs speech-to-text API client.

import Foundation
import AVFoundation
import Observation

// MARK: - 1. Audio Recording

@Observable
final class AudioRecorderManager: NSObject, AVAudioRecorderDelegate {

    private var recorder: AVAudioRecorder?
    private var recordingURL: URL?
    private(set) var lastRecordingURL: URL?
    var isRecording: Bool { recorder?.isRecording == true }
    private var hasRequestedPermission = false

    func configureSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .playAndRecord,
                options: [.allowBluetoothHFP, .defaultToSpeaker]
            )
            try session.setActive(true)
            if !hasRequestedPermission {
                hasRequestedPermission = true
                Task {
                    let granted = await AVAudioApplication.requestRecordPermission()
                    print(granted ? "Mic: granted" : "Mic: denied")
                }
            }
        } catch {
            print("Audio session error: \(error)")
        }
    }

    func startRecording(resetFile: Bool = true) {
        if recorder?.isRecording == true, !resetFile { return }
        if recorder?.isRecording == true, resetFile {
            recorder?.stop()
            recorder = nil
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("m4a")
        recordingURL = url

        let settings: [String: Any] = [
            AVFormatIDKey:            Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey:          44100,
            AVNumberOfChannelsKey:    1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        do {
            recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder?.delegate = self
            recorder?.isMeteringEnabled = true
            recorder?.record()
            print("Recording started: \(url.lastPathComponent)")
        } catch {
            print("Recording start error: \(error)")
        }
    }

    func stopRecording() -> URL? {
        recorder?.stop()
        recorder = nil
        if let recordingURL {
            lastRecordingURL = recordingURL
        }
        return recordingURL
    }

    /// Returns channel-0 average power in dBFS (-160...0). Higher is louder.
    func currentAveragePowerDB() -> Float? {
        guard let recorder else { return nil }
        recorder.updateMeters()
        return recorder.averagePower(forChannel: 0)
    }
}

// MARK: - 2. ElevenLabs Speech-to-Text

enum ElevenLabsSTTError: LocalizedError {
    case missingAPIKey
    case audioFileMissing
    case audioFileTooSmall
    case invalidResponse(String)
    case emptyTranscript

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Missing ELEVENLABS_API_KEY."
        case .audioFileMissing:
            return "Recorded audio file not found."
        case .audioFileTooSmall:
            return "Recorded audio was too short or empty."
        case .invalidResponse(let body):
            return "ElevenLabs returned an unexpected response: \(body.prefix(200))"
        case .emptyTranscript:
            return "Speech recognition returned empty text."
        }
    }
}

enum ElevenLabsSTT {

    static let apiKey: String = {
        Bundle.main.object(forInfoDictionaryKey: "ELEVENLABS_API_KEY") as? String ?? ""
    }()

    static let endpoint = URL(string: "https://api.elevenlabs.io/v1/speech-to-text")!

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 75
        return URLSession(configuration: config)
    }()

    private static let maxAttempts = 3

    static func transcribe(fileURL: URL) async throws -> String {
        guard !apiKey.isEmpty else { throw ElevenLabsSTTError.missingAPIKey }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw ElevenLabsSTTError.audioFileMissing
        }
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let size = (fileAttributes[.size] as? NSNumber)?.intValue ?? 0
        guard size > 2048 else { throw ElevenLabsSTTError.audioFileTooSmall }

        var lastError: Error?
        for attempt in 1...maxAttempts {
            do {
                let text = try await sendTranscribeRequest(fileURL: fileURL)
                let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !normalized.isEmpty else { throw ElevenLabsSTTError.emptyTranscript }
                return normalized
            } catch {
                lastError = error
                if attempt == maxAttempts || !shouldRetry(error: error) {
                    throw error
                }
                let delay = min(pow(2.0, Double(attempt - 1)) * 0.6, 2.0)
                try? await Task.sleep(for: .seconds(delay))
            }
        }
        throw lastError ?? ElevenLabsSTTError.invalidResponse("Unknown STT failure")
    }

    private static func sendTranscribeRequest(fileURL: URL) async throws -> String {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")

        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let audioData = try Data(contentsOf: fileURL)
        var body = Data()
        body.appendStr("--\(boundary)\r\n")
        body.appendStr("Content-Disposition: form-data; name=\"model_id\"\r\n\r\n")
        body.appendStr("scribe_v1\r\n")
        body.appendStr("--\(boundary)\r\n")
        body.appendStr("Content-Disposition: form-data; name=\"language_code\"\r\n\r\n")
        body.appendStr("en\r\n")
        body.appendStr("--\(boundary)\r\n")
        body.appendStr("Content-Disposition: form-data; name=\"file\"; filename=\"audio.m4a\"\r\n")
        body.appendStr("Content-Type: audio/x-m4a\r\n\r\n")
        body.append(audioData)
        body.appendStr("\r\n")
        body.appendStr("--\(boundary)--\r\n")
        request.httpBody = body

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ElevenLabsSTTError.invalidResponse("Non-HTTP response")
        }
        guard http.statusCode == 200 else {
            let errBody = String(data: data, encoding: .utf8) ?? "unknown"
            throw NSError(
                domain: "ElevenLabsSTT",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: errBody]
            )
        }

        if let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let text = dict["text"] as? String { return text }
            if let text = dict["transcript"] as? String { return text }
        }
        throw ElevenLabsSTTError.invalidResponse(String(data: data, encoding: .utf8) ?? "Invalid JSON body")
    }

    private static func shouldRetry(error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorTimedOut,
                 NSURLErrorCannotConnectToHost,
                 NSURLErrorNetworkConnectionLost,
                 NSURLErrorNotConnectedToInternet,
                 NSURLErrorCannotFindHost:
                return true
            default:
                return false
            }
        }
        if nsError.domain == "ElevenLabsSTT" {
            return nsError.code == 429 || (500...599).contains(nsError.code)
        }
        return false
    }
}

// MARK: - 3. Forward to freesolo

enum FreeSoloClient {
    // ✅ Permanently locked to your custom static ngrok domain loop route!
    static let endpoint = URL(string: "https://ngrok-free.dev")!

    static func send(transcript: String) async throws {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["text": transcript])

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            throw NSError(domain: "FreeSoloClient", code: 1, userInfo: [NSLocalizedDescriptionKey: "freesolo request failed"])
        }
        print("🚀 Successfully forwarded transcript to backend pipeline over ngrok.")
    }
}

// MARK: - 4. Voice Pipeline Setup

final class VoiceCommandPipeline {
    let recorder = AudioRecorderManager()

    private enum CaptureMode { case idle, wakewordPreRoll, command }
    private var captureMode: CaptureMode = .idle
    private var preRollRollTask: Task<Void, Never>?
    private let preRollRotationSeconds: Double = 10.0

    /// Legacy entry point used by PTT and debug hold-to-talk.
    func onPressStartTalking() {
        startCommandCapture(includeWakewordPreRoll: false)
    }

    /// Used by wakeword flow: if a pre-roll recording is already live, promote
    /// it to command capture so words spoken just before activation are kept.
    func onWakewordActivatedStartTalking() {
        startCommandCapture(includeWakewordPreRoll: true)
    }

    /// Begin rolling pre-roll capture while waiting for wakeword activation.
    /// File is rotated periodically to bound disk growth.
    func startWakewordPreRollCapture() {
        guard captureMode == .idle else { return }
        recorder.configureSession()
        recorder.startRecording()
        captureMode = .wakewordPreRoll
        startPreRollRotation()
    }

    func stopWakewordPreRollCapture() {
        guard captureMode == .wakewordPreRoll else { return }
        stopPreRollRotation()
        _ = recorder.stopRecording()
        captureMode = .idle
    }

    /// Stop active command capture and return the recorded file.
    func stopCommandCapture() -> URL? {
        guard captureMode == .command else { return nil }
        let url = recorder.stopRecording()
        captureMode = .idle
        stopPreRollRotation()
        return url
    }

    private func startCommandCapture(includeWakewordPreRoll: Bool) {
        recorder.configureSession()

        if includeWakewordPreRoll, captureMode == .wakewordPreRoll {
            stopPreRollRotation()
            captureMode = .command
            return
        }

        recorder.startRecording()
        captureMode = .command
        stopPreRollRotation()
    }

    private func startPreRollRotation() {
        stopPreRollRotation()
        preRollRollTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(self.preRollRotationSeconds))
                if Task.isCancelled { return }
                guard self.captureMode == .wakewordPreRoll else { return }
                _ = self.recorder.stopRecording()
                self.recorder.startRecording()
            }
        }
    }

    private func stopPreRollRotation() {
        preRollRollTask?.cancel()
        preRollRollTask = nil
    }
}

private extension Data {
    mutating func appendStr(_ s: String) {
        if let d = s.data(using: .utf8) { append(d) }
    }
}