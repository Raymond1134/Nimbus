import SwiftUI

struct ContentView: View {
    @Environment(Orchestrator.self) private var orc
    @State private var didRequestRegistration = false

    var body: some View {
        TabView {
            OperationalView()
                .tabItem { Label("Fly", systemImage: "airplane") }

            DebugView()
                .tabItem { Label("Debug", systemImage: "wrench.and.screwdriver") }
        }
        .onAppear {
            guard !didRequestRegistration else { return }
            didRequestRegistration = true
            DJIManager.shared.registerApp()
        }
    }
}

#Preview {
    ContentView()
        .environment(Orchestrator())
}
