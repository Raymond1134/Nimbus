// NimbusApp.swift — Nimbus
// App entry point. Creates the single Orchestrator instance and injects it
// into the SwiftUI environment for all views to access.

import SwiftUI

@main
struct NimbusApp: App {

    private let orchestrator = Orchestrator()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(orchestrator)
        }
    }
}
