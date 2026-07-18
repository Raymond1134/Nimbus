// ContentView.swift — Nimbus
// Root view: Tab 1 = OperationalView (product UI), Tab 2 = DebugView.
// The Orchestrator is injected from NimbusApp and read via @Environment.

import SwiftUI

struct ContentView: View {

    @Environment(Orchestrator.self) private var orc

    var body: some View {
        TabView {
            Tab("Fly", systemImage: "airplane") {
                OperationalView()
            }
            Tab("Debug", systemImage: "wrench.and.screwdriver") {
                DebugView()
            }
        }
        .onAppear {
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
        }
    }
}

#Preview {
    ContentView()
        .environment(Orchestrator())
}
