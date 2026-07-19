// AudioRouteManager.swift — Nimbus
// Debug helper for inspecting and switching audio input / output routes.
// Backs the "Audio Devices" section of DebugView.

import Foundation
import AVFoundation
import AVKit
import SwiftUI
import Observation

@Observable
final class AudioRouteManager {

    private let session = AVAudioSession.sharedInstance()

    /// Selectable capture devices (built-in mic, Bluetooth HFP, wired, …).
    var availableInputs: [AVAudioSessionPortDescription] = []
    /// Human-readable name of the active input port.
    var currentInputName = "—"
    /// Human-readable name of the active output port.
    var currentOutputName = "—"
    /// UID of the preferred input, used as the Picker selection.
    var selectedInputUID: String?
    /// Whether output is force-routed to the loudspeaker.
    var speakerOverride = false

    private var routeObserver: NSObjectProtocol?

    init() {
        prepareSession()
        refresh()
        routeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refresh()
        }
    }

    deinit {
        if let routeObserver {
            NotificationCenter.default.removeObserver(routeObserver)
        }
    }

    /// Put the session into a record+playback state so route/input changes stick.
    func prepareSession() {
        do {
            try session.setCategory(.playAndRecord,
                                    options: [.allowBluetoothHFP, .defaultToSpeaker])
            try session.setActive(true)
        } catch {
            print("AudioRouteManager: session config error — \(error)")
        }
    }

    /// Re-read the current route from the audio session.
    func refresh() {
        availableInputs = session.availableInputs ?? []
        let route = session.currentRoute
        currentInputName  = route.inputs.first?.portName  ?? "—"
        currentOutputName = route.outputs.first?.portName ?? "—"
        selectedInputUID  = session.preferredInput?.uid ?? route.inputs.first?.uid
        speakerOverride   = route.outputs.contains { $0.portType == .builtInSpeaker }
    }

    /// Route capture to the port with the given UID (nil = system default).
    func selectInput(uid: String?) {
        do {
            if let uid, let port = availableInputs.first(where: { $0.uid == uid }) {
                try session.setPreferredInput(port)
            } else {
                try session.setPreferredInput(nil)
            }
        } catch {
            print("AudioRouteManager: setPreferredInput error — \(error)")
        }
        refresh()
    }

    /// Force output to the loudspeaker, or restore the default route.
    func setSpeakerOverride(_ on: Bool) {
        do {
            try session.overrideOutputAudioPort(on ? .speaker : .none)
        } catch {
            print("AudioRouteManager: overrideOutputAudioPort error — \(error)")
        }
        refresh()
    }
}

/// System route picker (AirPlay / Bluetooth) for choosing the audio *output*
/// device. iOS does not expose arbitrary output selection outside this control.
struct AudioRoutePickerButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.prioritizesVideoDevices = false
        return picker
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
