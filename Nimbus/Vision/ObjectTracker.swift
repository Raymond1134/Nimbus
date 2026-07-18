// ObjectTracker.swift — Nimbus
// Maintains identity of a grounded object across frames using VNTrackObjectRequest.
// Spec §3 component 4.
//
// The Orchestrator starts tracking after a successful grounding, then
// re-anchors every ~1 s via the Detector (once YOLO is enabled).

import Vision
import UIKit

final class ObjectTracker {

    private var trackingRequest: VNTrackObjectRequest?
    private(set) var trackedBBox: CGRect?

    /// Fires on the main actor with the current tracked bbox, or nil if lost.
    var onTrackingUpdated: ((CGRect?) -> Void)?

    // MARK: - Lifecycle

    /// Begin tracking the object at the given normalised Vision rect.
    /// Call this after a successful grounding result.
    func startTracking(bbox: CGRect) {
        let obs = VNDetectedObjectObservation(boundingBox: bbox)
        let req = VNTrackObjectRequest(detectedObjectObservation: obs) { [weak self] request, error in
            guard let self else { return }
            if error != nil {
                Task { @MainActor [weak self] in
                    self?.trackedBBox = nil
                    self?.onTrackingUpdated?(nil)
                }
                return
            }
            let updated = (request.results as? [VNDetectedObjectObservation])?.first
            Task { @MainActor [weak self] in
                self?.trackedBBox = updated?.boundingBox
                self?.onTrackingUpdated?(updated?.boundingBox)
            }
        }
        req.trackingLevel = .accurate
        trackingRequest = req
    }

    func stopTracking() {
        trackingRequest = nil
        trackedBBox = nil
        onTrackingUpdated?(nil)
    }

    // MARK: - Per-Frame Update

    /// Call with each new pixel buffer from the drone camera.
    func process(pixelBuffer: CVPixelBuffer) {
        guard let req = trackingRequest else { return }
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        try? handler.perform([req])
    }

    /// Re-anchor the tracker to a fresh detection result (called ~1 s by Orchestrator).
    func reanchor(to bbox: CGRect) {
        startTracking(bbox: bbox)
    }
}
