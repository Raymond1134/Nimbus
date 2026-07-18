// ElevenLabsSTT.swift — Nimbus
// Audio recording (AVAudioRecorder) + ElevenLabs speech-to-text API client.
// FreeSoloClient stub has been replaced by BackendClient (Backend/BackendClient.swift).

import Foundation
import AVFoundation
import Observation

// MARK: - 1. Audio Recording

@Observable
final class AudioRecorderManager: NSObject, AVAudioRecorderDelegate {

    private var recorder: AVAudioRecorder?
    private var recordingURL: URL?

    func configureSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord,
                                    options: [.allowBluetoothHFP, .defaultToSpeaker])
            try session.setActive(true)
            Task {
                let granted = await AVAudioApplication.requestRecordPermission()
                print(granted ? "Mic: granted" : "Mic: denied")
            }
        } catch {
            print("Audio session error: \(error)")
        }
    }

    func startRecording() {
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
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            do {
                self.recorder = try AVAudioRecorder(url: url, settings: settings)
                self.recorder?.delegate = self
                self.recorder?.record()
                print("Recording started.")
            } catch {
                print("Recording start error: \(error)")
            }
        }
    }

    func stopRecording() -> URL? {
        recorder?.stop()
        recorder = nil
        return recordingURL
    }
}

// MARK: - 2. ElevenLabs Speech-to-Text

enum ElevenLabsSTT {

    static let apiKey: String = {
        Bundle.main.object(forInfoDictionaryKey: "ELEVENLABS_API_KEY") as? String ?? ""
    }()

    static let endpoint = URL(string: "https://api.elevenlabs.io/v1/speech-to-text")!

    static func transcribe(fileURL: URL) async throws -> String {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")

        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue(
            "multipart/form-data; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type"
        )

        var body = Data()
        // model_id
        body.appendStr("--\(boundary)\r\n")
        body.appendStr("Content-Disposition: form-data; name=\"model_id\"\r\n\r\n")
        body.appendStr("scribe_v2\r\n")
        // audio file
        let audioData = try Data(contentsOf: fileURL)
        body.appendStr("--\(boundary)\r\n")
        body.appendStr("Content-Disposition: form-data; name=\"file\"; filename=\"audio.m4a\"\r\n")
        body.appendStr("Content-Type: audio/x-m4a\r\n\r\n")
        body.append(audioData)
        body.appendStr("\r\n")
        body.appendStr("--\(boundary)--\r\n")
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let errBody = String(data: data, encoding: .utf8) ?? "unknown"
            throw NSError(domain: "ElevenLabsSTT",
                          code: (response as? HTTPURLResponse)?.statusCode ?? 500,
                          userInfo: [NSLocalizedDescriptionKey: errBody])
        }
        struct ElevenLabsResponse: Decodable { let text: String }
        return try JSONDecoder().decode(ElevenLabsResponse.self, from: data).text
    }
}
// MARK: - 3. Forward to freesolo

<<<<<<< HEAD
// MARK: - 3. Forward to freesolo

// MARK: - 3. Forward to freesolo

enum FreeSoloClient {

    // ✅ Make sure this points to your active ngrok link ending in /parse
    static let endpoint = URL(string: "https://ngrok-free.dev")!

    static func send(transcript: String) async throws {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["text": transcript])

        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            throw NSError(domain: "FreeSoloClient", code: 1, userInfo: [NSLocalizedDescriptionKey: "freesolo request failed"])
        }
        
        if let jsonString = String(data: data, encoding: .utf8) {
            print("\n🛸 ==================================================")
            print("🤖 FREESOLO BACKEND RESPONSE:")
            print(jsonString)
            print("==================================================\n")
        }
    }
}


// MARK: - 4. Voice Pipeline Setup
=======
>>>>>>> 1e429ef368f1e7032c5f1250205be4bedc6cd225
private extension Data {
    mutating func appendStr(_ s: String) {
        if let d = s.data(using: .utf8) { append(d) }
    }
}

// MARK: - 3. Voice Pipeline
// Owned by the Orchestrator. Connects PTT gestures to the recorder.

final class VoiceCommandPipeline {
    let recorder = AudioRecorderManager()

    func onPressStartTalking() {
        recorder.configureSession()
        recorder.startRecording()
    }
}
