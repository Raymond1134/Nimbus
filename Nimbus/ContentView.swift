//
//  ContentView.swift
//  Nimbus
//
//  Created by Andrew Dai on 2026-07-17.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var djiManager = DJIManager.shared
    @State private var openController = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 32) {
                Spacer()

                Image(systemName: djiManager.isRegistered ? "checkmark.circle.fill" : "airplane")
                    .font(.system(size: 72))
                    .foregroundStyle(djiManager.isRegistered ? Color.green : Color.accentColor)
                    .symbolEffect(.pulse, isActive: !djiManager.isRegistered)

                VStack(spacing: 8) {
                    Text("Nimbus")
                        .font(.largeTitle)
                        .bold()
                    Text(djiManager.isRegistered ? "SDK Registered" : "Registering DJI SDK…")
                        .foregroundStyle(.secondary)
                }

                if djiManager.isRegistered {
                    NavigationLink("Open Controller →", destination: DroneControlView())
                        .buttonStyle(.borderedProminent)
                        .font(.headline)
                        .padding(.top, 8)
                }

                Spacer()
            }
            .padding()
            .navigationTitle("")
        }
        .onAppear {
            DJIManager.shared.registerApp()
            WaypointManager.shared.setupListeners()
        }
        .alert("Register App", isPresented: $djiManager.showRegistrationAlert) {
            Button("OK") { }
        } message: {
            Text(djiManager.registrationMessage)
        }
    }
}

#Preview {
    ContentView()
}
