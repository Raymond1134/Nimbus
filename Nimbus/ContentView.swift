//
//  ContentView.swift
//  Nimbus
//
//  Created by Andrew Dai on 2026-07-17.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var djiManager = DJIManager.shared

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: djiManager.isRegistered ? "checkmark.circle.fill" : "airplane")
                .font(.system(size: 64))
                .foregroundStyle(djiManager.isRegistered ? Color.green : Color.accentColor)

            Text("Nimbus")
                .font(.largeTitle)
                .bold()

            Text(djiManager.isRegistered ? "DJI SDK Registered" : "Registering DJI SDK...")
                .foregroundStyle(.secondary)
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
}

#Preview {
    ContentView()
}
