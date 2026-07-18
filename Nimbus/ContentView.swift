import SwiftUI

struct ContentView: View {
    @Environment(Orchestrator.self) private var orc

    var body: some View {
        TabView {
            OperationalView()
                .tabItem { Label("Fly", systemImage: "airplane") }

            DebugView()
                .tabItem { Label("Debug", systemImage: "wrench.and.screwdriver") }
        }
        .onAppear {
            DJIManager.shared.registerApp()
        }
    }
}

#Preview {
    ContentView()
        .environment(Orchestrator())
}
