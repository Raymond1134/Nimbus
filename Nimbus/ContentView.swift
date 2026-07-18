import SwiftUI

struct ContentView: View {
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
        }
        .padding()
        .onAppear {
            DJIManager.shared.registerApp()
            setupHandsFreeLoop()
        }
    }
    
    private func setupHandsFreeLoop() {
        print("🎧 Initializing Hands-Free Wakeword Listen Loop...")
        
        wakewordListener.onWakewordDetected = {
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
                
                try await FreeSoloClient.send(transcript: transcript)
                
                try await Task.sleep(nanoseconds: 3_000_000_000)
                
                await MainActor.run {
                    self.appStatus = "Waiting to hear 'Hey Nimbus'..."
                    self.wakewordListener.startListening()
                }
                
            } catch {
                print("❌ Pipeline Transcription Thread Error: \(error.localizedDescription)")
                await MainActor.run {
                    self.appStatus = "Pipeline Error: \(error.localizedDescription)"
                    self.wakewordListener.startListening()
                }
            }
        }
    }
}

#Preview {
    ContentView()
}
