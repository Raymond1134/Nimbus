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

    // MARK: - Cue Playback

    func playCommandConfirmation() {
        // TODO: trigger short confirmation beep via AVAudioPlayerNode
        print("SpatialAudio: [confirm]")
    }

    func playErrorCue() {
        // TODO: trigger error tone
        print("SpatialAudio: [error]")
    }

    func playNotFound() {
        // TODO: "not found" rising-then-falling tone
        print("SpatialAudio: [not found]")
    }

    func playBatteryWarning() {
        // TODO: pulsed warning tone
        print("SpatialAudio: [battery warning]")
    }
}
