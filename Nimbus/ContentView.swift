// ContentView.swift — Nimbus
// Root view: Tab 1 = OperationalView (product UI), Tab 2 = DebugView.
// The Orchestrator is injected from NimbusApp and read via @Environment.

import SwiftUI

struct ContentView: View {
<<<<<<< HEAD
    // 🚀 FIXED: Changed from @StateObject to a standard variable since DJIManager now uses @Observable!
    private var djiManager = DJIManager.shared
    
    // Core Hands-Free Engines
    @State private var pipeline = VoiceCommandPipeline()
    @State private var wakewordListener = WakewordListener()
    
    @State private var appStatus = "Waiting to hear 'Hey Nimbus'..."
    @State private var isRecordingCommand = false

    var body: some View {
        VStack(spacing: 24) {
            // Existing DJI Header System Setup
            HStack(spacing: 16) {
                Image(systemName: djiManager.isRegistered ? "checkmark.circle.fill" : "airplane")
                    .font(.title)
                    .foregroundStyle(djiManager.isRegistered ? Color.green : Color.accentColor)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Nimbus Drone Core")
                        .font(.headline)
                    Text(djiManager.isRegistered ? "DJI SDK Registered" : "Registering DJI SDK...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding()
            .background(Color(.systemGray6))
            .cornerRadius(12)
            
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
                    .animation(.spring(response: 0.4, dampingFraction: 0.5), value: isRecordingCommand)
                
                Text(appStatus)
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .padding()
            }
            .frame(height: 200)
            .background(Color(.systemGray6))
            .cornerRadius(16)
=======

    @Environment(Orchestrator.self) private var orc

    var body: some View {
        TabView {
            Tab("Fly", systemImage: "airplane") {
                OperationalView()
            }
            Tab("Debug", systemImage: "wrench.and.screwdriver") {
                DebugView()
            }
>>>>>>> 1e429ef368f1e7032c5f1250205be4bedc6cd225
        }
        .padding()
        .onAppear {
<<<<<<< HEAD
            DJIManager.shared.registerApp()
            setupHandsFreeLoop()
        }
    }
    
    /// Binds the low-power listener directly into your premium ElevenLabs pipeline
    private func setupHandsFreeLoop() {
        print("🎧 Initializing Hands-Free Wakeword Listen Loop...")
        
        wakewordListener.onWakewordDetected = {
            Task { @MainActor in
                self.wakewordListener.stopListening()
                self.isRecordingCommand = true
                self.appStatus = "Listening to your flight instruction..."
                
                // Give CoreAudio 400ms to cleanly release the microphone tap
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    print("🎙️ Handover complete. Opening ElevenLabs audio file recorder.")
                    self.pipeline.onPressStartTalking()
                }
                
                // Capture a clean 4-second command window (0.4s buffer + 4.0s recording)
                DispatchQueue.main.asyncAfter(deadline: .now() + 4.4) {
                    Task { @MainActor in
                        self.isRecordingCommand = false
                        self.appStatus = "Processing command with ElevenLabs..."
                        self.executeTranscriptionPipeline()
                    }
                }
            }
        }
        
        // Start monitoring audio streams right on launch
        wakewordListener.startListening()
    }
    
    private func executeTranscriptionPipeline() {
        guard let fileURL = pipeline.recorder.stopRecording() else {
            appStatus = "Error retrieving audio capture file."
            return
        }
        
        Task {
            do {
                let transcript = try await ElevenLabsSTT.transcribe(fileURL: fileURL)
                
                print("\n==================================================")
                print("🎯 ELEVENLABS TRANSCRIPTION RESULT:")
                print("\"\(transcript)\"")
                print("==================================================\n")
                
                await MainActor.run {
                    self.appStatus = "ElevenLabs Result:\n\n\"\(transcript)\""
                }
                
                // Send text to your backend system
                try await FreeSoloClient.send(transcript: transcript)
                
                // Wait 3 seconds before resetting
                try await Task.sleep(nanoseconds: 3_000_000_000)
                
                await MainActor.run {
                    self.appStatus = "Waiting to hear 'Hey Nimbus'..."
                    self.wakewordListener.startListening()
                }
                
            } catch {
                print("❌ Pipeline Transcription Thread Error: \(error.localizedDescription)")
                await MainActor.run {
                    self.appStatus = "Pipeline Error: \(error.localizedDescription)"
                    self.wakewordListener.startListening() // Restart listener on fail
                }
            }
=======
            orc.djiManager.registerApp()
        }
        .alert("DJI SDK",
               isPresented: Binding(
                get: { orc.djiManager.showRegistrationAlert },
                set: { orc.djiManager.showRegistrationAlert = $0 }
               )
        ) {
            Button("OK") { }
        } message: {
            Text(orc.djiManager.registrationMessage)
>>>>>>> 1e429ef368f1e7032c5f1250205be4bedc6cd225
        }
    }
}

#Preview {
    ContentView()
<<<<<<< HEAD
=======
        .environment(Orchestrator())
>>>>>>> 1e429ef368f1e7032c5f1250205be4bedc6cd225
}
