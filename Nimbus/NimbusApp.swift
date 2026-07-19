// NimbusApp.swift — Nimbus
// App entry point. Creates the single Orchestrator instance and injects it
// into the SwiftUI environment for all views to access.

import SwiftUI

@main
struct NimbusApp: App {

    private let orchestrator: Orchestrator

    init() {
        // Install the stderr filter before DJI SDK starts so any residual
        // FFmpeg H264 decoder noise is silenced from the very first frame.
        // Hardware decode (enableHardwareDecode = true in DJILiveVideoFeedManager)
        // is the primary fix; this is a belt-and-suspenders safety net.
        VideoLogFilter.install()
        orchestrator = Orchestrator()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(orchestrator)
        }
    }
}
