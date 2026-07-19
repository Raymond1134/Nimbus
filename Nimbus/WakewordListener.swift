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

@Observable
final class WakewordListener {
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()
    private var lastWakewordAt = Date.distantPast
    private let wakewordDebounceSec: TimeInterval = 1.2
    
    // Callback closure to trigger the ElevenLabs recording pipeline
    var onWakewordDetected: (() -> Void)?
    var isListeningForWakeword = false

    func startListening() {
        guard !audioEngine.isRunning else { return }
        let status = SFSpeechRecognizer.authorizationStatus()
        if status == .authorized {
            setupAudioEngineAndStart()
            return
        }
        guard status == .notDetermined else {
            print("❌ Speech recognition authorization denied")
            return
        }
        // Request authorization once, then re-use authorization status for later starts.
        SFSpeechRecognizer.requestAuthorization { [weak self] authStatus in
            DispatchQueue.main.async {
                guard authStatus == .authorized else {
                    print("❌ Speech recognition authorization denied")
                    return
                }
                self?.setupAudioEngineAndStart()
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
        
        // Smaller buffer lowers wakeword latency.
        inputNode.installTap(onBus: 0, bufferSize: 512, format: recordingFormat) { buffer, _ in
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
            
            if self.matchesWakeword(latestTranscription) {
                let now = Date()
                guard now.timeIntervalSince(self.lastWakewordAt) > self.wakewordDebounceSec else { return }
                self.lastWakewordAt = now
                print("🎯 Wakeword 'Nimbus' Detected locally!")
                DispatchQueue.main.async {
                    self.stopListening()
                    // Fire off the callback to start recording for ElevenLabs!
                    self.onWakewordDetected?()
                }
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

    private func matchesWakeword(_ transcript: String) -> Bool {
        let words = transcript
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map { String($0).lowercased() }
        guard !words.isEmpty else { return false }
        let tail = Array(words.suffix(4))
        let wakewordTokens = ["nimbus", "nimbus", "nimbis"]
        if tail.contains(where: { wakewordTokens.contains($0) }) {
            return true
        }
        // Handle small transcription mistakes ("nimis", "nimbuz"), but avoid loose
        // matching to unrelated words like "numbers".
        if let last = tail.last, levenshtein(last, "nimbus") <= 2 {
            return true
        }
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
