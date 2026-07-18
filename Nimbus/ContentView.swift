///
//  ContentView.swift
//  Nimbus
//
//  Created by Andrew Dai on 2026-07-17.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var djiManager = DJIManager.shared
    
    // 💡 Pipeline and UI states for your ElevenLabs mic test
    @State private var pipeline = VoiceCommandPipeline()
    @State private var isPressing = false
    @State private var transcriptionResult = "Press and hold the button below to speak..."

    var body: some View {
        VStack(spacing: 24) {
            // --- 1. Your Existing DJI Connection Header ---
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

            // --- 2. Voice Test Interface ---
            Text("Voice Pipeline Test")
                .font(.title2)
                .bold()
                .frame(maxWidth: .infinity, alignment: .leading)
            
            // Audio Status Visualizer
            VStack(spacing: 8) {
                Image(systemName: isPressing ? "mic.fill" : "mic.circle")
                    .font(.system(size: 56))
                    .foregroundColor(isPressing ? .red : .blue)
                    .scaleEffect(isPressing ? 1.15 : 1.0)
                    .animation(.easeInOut(duration: 0.2), value: isPressing)
                
                Text(isPressing ? "Recording from AirPods / Phone Mic..." : "Microphone Idle")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .frame(height: 100)
            
            // Transcription Console Display Box
            ScrollView {
                Text(transcriptionResult)
                    .font(.system(.body, design: .monospaced))
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.systemBackground))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color(.systemGray4), lineWidth: 1)
                    )
            }
            
            // Push-To-Talk Interactivity Layer
            Text("HOLD TO TALK")
                .font(.headline)
                .foregroundColor(.white)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity)
                .background(isPressing ? Color.red : Color.blue)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .shadow(radius: isPressing ? 1 : 4)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in
                            if !isPressing {
                                isPressing = true
                                transcriptionResult = "Listening to audio feed..."
                                pipeline.onPressStartTalking()
                            }
                        }
                        .onEnded { _ in
                            isPressing = false
                            transcriptionResult = "Sending payload to ElevenLabs..."
                            executeLocalTranscription()
                        }
                )
        }
        .padding()
        .onAppear {
            DJIManager.shared.registerApp()
        }
        .alert("Register App", isPresented: $djiManager.showRegistrationAlert) {
            Button("OK") { }
        } message: {
            Text(djiManager.registrationMessage)
        }
    }
    
    /// Pulls raw recorded data, converts it via ElevenLabs, and dumps it directly to our screen console.
    private func executeLocalTranscription() {
        guard let fileURL = pipeline.recorder.stopRecording() else {
            transcriptionResult = "Local Storage Error: Audio file could not be generated."
            return
        }
        
        Task {
            do {
                let transcript = try await ElevenLabsSTT.transcribe(fileURL: fileURL)
                
                // Print the result directly to your app screen!
                transcriptionResult = "Transcribed Text:\n\n\"\(transcript)\""
                print("Captured Transcript: \(transcript)")
                
                // Forward text string along to your background parsing engine
                try await FreeSoloClient.send(transcript: transcript)
            } catch {
                transcriptionResult = "Pipeline Execution Error:\n\(error.localizedDescription)"
                print("Transcription thread error: \(error)")
            }
        }
    }
}

#Preview {
    ContentView()
}
