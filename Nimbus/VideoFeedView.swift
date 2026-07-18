import SwiftUI

/// Renders the DJI primary video feed (main camera).
/// The Mavic Mini 2 has a single gimbal camera; there is no secondary FPV feed.
struct VideoFeedView: UIViewRepresentable {

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .black
        view.clipsToBounds   = true

        if let previewer = DJIVideoPreviewer.instance() {
            previewer.enableHardwareDecode = true
            previewer.setView(view)
            // start() registers with DJISDKManager.videoFeeder().primaryVideoFeed.
            // Called again in DJIManager.productConnected for correct timing.
            previewer.start()
        }

        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        // Keep the target view current whenever SwiftUI re-renders this node.
        if let previewer = DJIVideoPreviewer.instance() {
            previewer.setView(uiView)
        }
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        if let previewer = DJIVideoPreviewer.instance() {
            previewer.setView(nil)
            previewer.close()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    class Coordinator {}
}
