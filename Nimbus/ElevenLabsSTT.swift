import Foundation
import AVFoundation
import Observation

// MARK: - 1. Audio Recording

@MainActor
@Observable
final class AudioRecorderManager: NSObject, AVAudioRecorderDelegate {

    private var recorder: AVAudioRecorder?
    private var recordingURL: URL?

    /// Call once (e.g. in onAppear) to request mic permission and configure the session.
    func configureSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, options: [.allowBluetoothHFP, .defaultToSpeaker])
            try session.setActive(true)
            
            if #available(iOS 17.0, *) {
                Task {
                    let granted = await AVAudioApplication.requestRecordPermission()
                    if granted {
                        print("Microphone permission granted")
                    } else {
                        print("Microphone permission denied")
                    }
                }
            } else {
                session.requestRecordPermission { granted in
                    DispatchQueue.main.async {
                        if granted {
                            print("Microphone permission granted")
                        } else {
                            print("Microphone permission denied")
                        }
                    }
                }
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
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        // 💡 Fix: Run asynchronously to let the system fully register file-writing paths before recording begins
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            do {
                self.recorder = try AVAudioRecorder(url: url, settings: settings)
                self.recorder?.delegate = self
                self.recorder?.record()
                print("🎙️ Local audio stream recording active.")
            } catch {
                print("Failed to start recording: \(error)")
            }
        }
    }

    /// Stops recording and returns the local file URL of the clip.
    func stopRecording() -> URL? {
        recorder?.stop()
        recorder = nil
        return recordingURL
    }
}

// MARK: - 2. ElevenLabs Speech-to-Text

enum ElevenLabsSTT {

    // ✅ Securely resolved from your Info.plist hardcoded string profile
    static let apiKey: String = {
        guard let key = Bundle.main.object(forInfoDictionaryKey: "ELEVENLABS_API_KEY") as? String else {
            print("❌ Error: ELEVENLABS_API_KEY missing from Info.plist settings")
            return ""
        }
        return key
    }()
    
    // ✅ Direct endpoint destination path for file parsing
    static let endpoint = URL(string: "https://api.elevenlabs.io/v1/speech-to-text")!

    /// Uploads the audio file and returns the transcribed text.
    static func transcribe(fileURL: URL) async throws -> String {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")

        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()

        // 1. model_id field configuration
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"model_id\"\r\n\r\n".data(using: .utf8)!)
        body.append("scribe_v2\r\n".data(using: .utf8)!) // Premium ElevenLabs transcription selection

        // 2. Fix: Structure explicit binary file multi-part blocks
        let audioData = try Data(contentsOf: fileURL)
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.m4a\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/x-m4a\r\n\r\n".data(using: .utf8)!) // Standardized container description
        body.append(audioData)
        body.append("\r\n".data(using: .utf8)!)

        
        // 3. Close data payload structure
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        let httpResponse = response as? HTTPURLResponse

        guard let httpResponse = httpResponse, httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown response failure"
            throw NSError(domain: "ElevenLabsSTT", code: httpResponse?.statusCode ?? 500, userInfo: [NSLocalizedDescriptionKey: errorBody])
        }

        // ✅ Renamed definition completely avoids structural collision issues
        struct ElevenLabsResponse: Decodable { let text: String }
        let decoded = try JSONDecoder().decode(ElevenLabsResponse.self, from: data)
        return decoded.text
    }
}

// MARK: - 3. Forward to freesolo

enum FreeSoloClient {

    static let endpoint = URL(string: "https://example.com")!

    static func send(transcript: String) async throws {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["text": transcript])

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            throw NSError(domain: "FreeSoloClient", code: 1, userInfo: [NSLocalizedDescriptionKey: "freesolo request failed"])
        }
    }
}

// MARK: - 4. Voice Pipeline Setup

@MainActor
final class VoiceCommandPipeline {

    let recorder = AudioRecorderManager()

    func onPressStartTalking() {
        recorder.configureSession()
        recorder.startRecording()
    }

    func onReleaseStopTalking() {
        // Will handle standard stopping triggers via local UI hooks
    }
}
