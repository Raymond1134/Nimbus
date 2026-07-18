///
//  ContentView.swift
//  Nimbus
//
//  Created by Andrew Dai on 2026-07-17.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var djiManager = DJIManager.shared
    
    // 🚀 MEMORY PROTECTION FIX: Encase your custom classes in @State memory wrappers
    // This tells the iOS kernel never to garbage-collect or kill these background audio loops!
    @State private var pipeline = VoiceCommandPipeline()
    @State private var wakewordListener = WakewordListener()
    
    @State private var appStatus = "Waiting to hear 'Hey Nimbus'..."
    @State private var isRecordingCommand = false

    var body: some View {
        VStack(spacing: 24) {
            // Your existing DJI Registration Header block stays completely intact here...
            
            Divider()
            
            Text("Hands-Free Voice Controller")
                .font(.title2)
                .bold()
            
            // Visual state feedback container box
            VStack(spacing: 16) {
                Image(systemName: isRecordingCommand ? "mic.fill" : "ear")
                    .font(.system(size: 64))
                    .foregroundColor(isRecordingCommand ? .red : .blue)
                    .scaleEffect(isRecordingCommand ? 1.2 : 1.0)
                
                Text(appStatus)
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .padding()
            }
            .frame(height: 200)
            .background(Color(.systemGray6))
            .cornerRadius(16)
        }
        .padding()
        .onAppear {
            DJIManager.shared.registerApp()
            setupHandsFreeLoop()
        }
    }
    
    /// Binds the low-power listener directly into your premium ElevenLabs pipeline
    private func setupHandsFreeLoop() {
        print("🎧 Initializing Hands-Free Wakeword Listen Loop...")
        
        // Explicitly tie the callback straight to our state instance
        wakewordListener.onWakewordDetected = {
            print("🔔 CALLBACK TRIGGERED: Wakeword heard inside ContentView!")
            
            Task { @MainActor in
                self.wakewordListener.stopListening()
                self.isRecordingCommand = true
                self.appStatus = "Listening to your flight instruction..."
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    print("🎙️ Handover complete. Opening ElevenLabs audio file recorder.")
                    self.pipeline.onPressStartTalking()
                }
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 4.4) {
                    Task { @MainActor in
                        self.isRecordingCommand = false
                        self.appStatus = "Processing command with ElevenLabs..."
                        self.executeTranscriptionPipeline()
                    }
                }
            }
        }
        
        // Wake up the hardware microchips
        wakewordListener.startListening()
    }

    
    private func executeTranscriptionPipeline() {
        guard let fileURL = pipeline.recorder.stopRecording() else {
            appStatus = "Error retrieving audio capture file."
            return
        }
        
        Task {
            do {
                // 1. Send the recording up to the server
                let transcript = try await ElevenLabsSTT.transcribe(fileURL: fileURL)
                
                // 🚀 CONSOLE PRINT FIX: This will dump the text directly into your Xcode console!
                print("\n==================================================")
                print("🎯 ELEVENLABS TRANSCRIPTION RESULT:")
                print("\"\(transcript)\"")
                print("==================================================\n")
                
                // 2. Render the text directly onto your iPhone interface layout screen
                await MainActor.run {
                    self.appStatus = "ElevenLabs Result:\n\n\"\(transcript)\""
                }
                
                // 3. Forward the text string along to your teammate's background parsing node
                try await FreeSoloClient.send(transcript: transcript)
                
                // 4. Smooth reset transition: wait 3 seconds so you can read the screen before listening again
                try await Task.sleep(nanoseconds: 3_000_000_000)
                
                await MainActor.run {
                    self.appStatus = "Waiting to hear 'Hey Nimbus'..."
                    self.wakewordListener.startListening()
                }
                
            } catch {
                print("❌ Pipeline Transcription Thread Error: \(error.localizedDescription)")
                await MainActor.run {
                    self.appStatus = "Pipeline Error: \(error.localizedDescription)"
                    self.wakewordListener.startListening() // Automatically reset on failure
                }
            }
        }
    }
}
