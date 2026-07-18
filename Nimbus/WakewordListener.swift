//
//  WakewordListener.swift
//  Nimbus
//
//  Created by Julia Chen on 2026-07-18.
//

import Foundation
import Speech
import Observation

@MainActor
@Observable
final class WakewordListener {
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()
    
    // Callback closure to trigger the ElevenLabs recording pipeline
    var onWakewordDetected: (() -> Void)?
    var isListeningForWakeword = false

    func startListening() {
        guard !audioEngine.isRunning else { return }
        
        // Request authorization from the user
        SFSpeechRecognizer.requestAuthorization { authStatus in
            Task { @MainActor in
                guard authStatus == .authorized else {
                    print("❌ Speech recognition authorization denied")
                    return
                }
                self.setupAudioEngineAndStart()
            }
        }
    }

    private func setupAudioEngineAndStart() {
            recognitionTask?.cancel()
            recognitionTask = nil
            
            recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
            guard let recognitionRequest = recognitionRequest else { return }
            
            // (for speed) Force processing to stay local on-device (instant neural chip lookup)
            recognitionRequest.requiresOnDeviceRecognition = true
            
            // (for speed) Tell the speech matrix to prioritize processing speed over punctuation accuracy
            if #available(iOS 16.0, *) {
                recognitionRequest.addsPunctuation = false
            }
            recognitionRequest.shouldReportPartialResults = true
        
        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
            self.recognitionRequest?.append(buffer)
        }
        
        audioEngine.prepare()
        do {
            try audioEngine.start()
            isListeningForWakeword = true
            print("Waiting for 'Hey Nimbus'...")
        } catch {
            print("Audio Engine failed to start: \(error.localizedDescription)")
            return
        }
        
        recognitionTask = speechRecognizer?.recognitionTask(with: recognitionRequest) { result, error in
            guard let result = result else {
                if let error = error { print("Local extraction error: \(error)") }
                return
            }
            
            // Scan transcription string for your custom keywords
            let latestTranscription = result.bestTranscription.formattedString.lowercased()
            print("Local buffer raw text: \(latestTranscription)")
            
            if latestTranscription.contains("nimbus") {
                print("🎯 Wakeword 'Nimbus' Detected locally!")
                self.stopListening()
                
                // Fire off the callback to start recording for ElevenLabs!
                self.onWakewordDetected?()
            }
        }
    }

    func stopListening() {
        // 🚀 HARDWARE FIX 1: Completely halt the engine loop and remove hardware pipes
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        
        // Reset request boundaries
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        
        recognitionTask?.cancel()
        recognitionTask = nil
        
        isListeningForWakeword = false
        print("🛑 Local audio hardware node completely released and vacant.")
        }
}
