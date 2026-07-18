import Foundation
import Combine

/// Wraps DJI SDK registration and exposes state to SwiftUI via ObservableObject.
final class DJIManager: NSObject, ObservableObject {

    static let shared = DJIManager()

    @Published var isRegistered = false
    @Published var registrationMessage = ""
    @Published var showRegistrationAlert = false

    private override init() {
        super.init()
    }

    func registerApp() {
        DJISDKManager.registerApp(with: self)
    }
}

// MARK: - DJISDKManagerDelegate

extension DJIManager: DJISDKManagerDelegate {

    func appRegisteredWithError(_ error: Error?) {
        DispatchQueue.main.async {
            if let error = error {
                print("DJI Register App Failed: \(error.localizedDescription)")
                self.registrationMessage = "Register App Failed! Please check your App Key and network connection."
                self.isRegistered = false
            } else {
                print("DJI Register App Succeeded!")
                self.registrationMessage = "Register App Succeeded!"
                self.isRegistered = true
                // Automatically start connecting to the RC/product after registration
                DJISDKManager.startConnectionToProduct()
            }
            self.showRegistrationAlert = true
        }
    }

    func didUpdateDatabaseDownloadProgress(_ progress: Progress) {
        let percent = Int(progress.fractionCompleted * 100)
        print("DJI fly-safe database download: \(percent)%")
    }

    func productConnected(_ product: DJIBaseProduct?) {
        DispatchQueue.main.async {
            DroneState.shared.isConnected = true
            DroneState.shared.productName = product?.model ?? "Unknown"
            DroneState.shared.setupListeners()
            // Register the previewer with the live video feed now that the
            // product is connected. start() hooks DJIVideoPreviewer into
            // DJISDKManager.videoFeeder().primaryVideoFeed automatically.
            DJIVideoPreviewer.instance()?.start()
        }
    }

    func productDisconnected() {
        DispatchQueue.main.async {
            DroneState.shared.isConnected = false
            DroneState.shared.productName = ""
            DroneState.shared.teardownListeners()
        }
    }
}
