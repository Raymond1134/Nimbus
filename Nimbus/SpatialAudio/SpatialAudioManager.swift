// SpatialAudioManager.swift — Nimbus
// Converts drone telemetry into spatial audio cues through AirPods.
// Spec §3 component 10.
//
// The AVAudioEnvironmentNode positions 3-D audio sources so the user can
// hear the drone's relative bearing and distance. Cue playback stubs
// are ready for audio files once they are added to the project.

import AVFoundation

final class SpatialAudioManager {

    private let engine      = AVAudioEngine()
    private let environment = AVAudioEnvironmentNode()
    private var running     = false

    // TODO: Add AVAudioPlayerNode instances for:
    //   - drone hum (looping, positioned at drone bearing / elevation)
    //   - command-confirm beep
    //   - error / not-found tone
    //   - low-battery warning tone

    // MARK: - Lifecycle

    func start() {
        do {
            engine.attach(environment)
            engine.connect(environment,
                           to: engine.mainMixerNode,
                           format: environment.outputFormat(forBus: 0))
            environment.renderingAlgorithm = .HRTFHQ   // best spatial quality with AirPods
            environment.listenerPosition   = AVAudio3DPoint(x: 0, y: 0, z: 0)
            try engine.start()
            running = true
            print("SpatialAudioManager: engine started.")
        } catch {
            print("SpatialAudioManager: engine start failed — \(error.localizedDescription)")
        }
    }

    func stop() {
        engine.stop()
        running = false
    }

    // MARK: - Drone Position

    /// Reposition the drone audio source based on bearing + distance from telemetry.
    /// Call from the Orchestrator whenever telemetry refreshes.
    func updateDronePosition(bearingDeg: Double,
                             distanceM: Double,
                             elevationDeg: Double) {
        guard running else { return }
        let br = bearingDeg   * .pi / 180
        let el = elevationDeg * .pi / 180
        let x  = Float(distanceM * sin(br) * cos(el))
        let y  = Float(distanceM * sin(el))
        let z  = Float(-distanceM * cos(br) * cos(el))
        // TODO: move drone player node source to AVAudio3DPoint(x: x, y: y, z: z)
        _ = (x, y, z)   // suppress unused-variable warning until nodes are wired
    }

    // Retained players — AVAudioPlayer is deallocated (and silent) if not kept alive.
    private var wakewordPlayer: AVAudioPlayer?
    private var confirmPlayer:  AVAudioPlayer?
    private var errorPlayer:    AVAudioPlayer?

    // MARK: - Cue Playback

    /// Two ascending tones (880 Hz → 1047 Hz, 90 ms each).
    /// Distinct "activated" chirp — fires immediately when the wakeword is heard.
    func playWakewordCue() {
        print("SpatialAudio: [wakeword]")
        let sR = 44100
        var samples = makeSamples(frequency: 880,  duration: 0.09, sampleRate: sR)
        samples.append(makeSamples(frequency: 1047, duration: 0.09, sampleRate: sR))
        wakewordPlayer = makePlayer(from: samples, sampleRate: sR)
        wakewordPlayer?.play()
    }

    /// Single short beep (660 Hz, 80 ms): generic action confirmation.
    func playCommandConfirmation() {
        print("SpatialAudio: [confirm]")
        let sR = 44100
        confirmPlayer = makePlayer(from: makeSamples(frequency: 660, duration: 0.08, sampleRate: sR),
                                   sampleRate: sR)
        confirmPlayer?.play()
    }

    /// Low tone (330 Hz, 220 ms): error.
    func playErrorCue() {
        print("SpatialAudio: [error]")
        let sR = 44100
        errorPlayer = makePlayer(from: makeSamples(frequency: 330, duration: 0.22, sampleRate: sR),
                                 sampleRate: sR)
        errorPlayer?.play()
    }

    func playNotFound() {
        print("SpatialAudio: [not found]")
        playErrorCue()
    }

    func playBatteryWarning() {
        print("SpatialAudio: [battery warning]")
    }

    // MARK: - Tone generation

    /// Generate Int16 PCM samples for a sine tone with 10 ms fade-in and 15 ms fade-out.
    private func makeSamples(frequency: Double, duration: Double, sampleRate: Int) -> Data {
        let n       = Int(Double(sampleRate) * duration)
        let fadeIn  = Int(Double(sampleRate) * 0.010)
        let fadeOut = Int(Double(sampleRate) * 0.015)
        var data = Data(capacity: n * 2)
        for i in 0..<n {
            let env: Double
            if i < fadeIn {
                env = Double(i) / Double(fadeIn)
            } else if i > n - fadeOut {
                env = Double(n - i) / Double(fadeOut)
            } else {
                env = 1.0
            }
            let t      = Double(i) / Double(sampleRate)
            let raw    = Int(env * sin(2 * .pi * frequency * t) * 20_000)
            let sample = Int16(max(Int(Int16.min), min(Int(Int16.max), raw)))
            withUnsafeBytes(of: sample.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    /// Wrap raw Int16 mono PCM samples in a WAV container and return an AVAudioPlayer.
    private func makePlayer(from samples: Data, sampleRate: Int) -> AVAudioPlayer? {
        var wav = Data(capacity: 44 + samples.count)
        let dataSize = samples.count
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { wav.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { wav.append(contentsOf: $0) } }
        func str(_ s: String) { wav.append(contentsOf: s.utf8) }
        str("RIFF"); u32(UInt32(dataSize + 36)); str("WAVE")
        str("fmt "); u32(16); u16(1); u16(1)            // PCM, mono
        u32(UInt32(sampleRate))                         // sample rate
        u32(UInt32(sampleRate * 2))                     // byte rate (16-bit mono)
        u16(2); u16(16)                                 // block align, bits per sample
        str("data"); u32(UInt32(dataSize))
        wav.append(samples)
        return try? AVAudioPlayer(data: wav, fileTypeHint: AVFileType.wav.rawValue)
    }
}
