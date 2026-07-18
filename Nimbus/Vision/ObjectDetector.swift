// ObjectDetector.swift — Nimbus
// Wraps a YOLO CoreML model for continuous real-time object detection.
// Spec §3 component 3.
//
// Setup: Add YOLOv8n.mlmodelc (compiled) to the Xcode target,
// then uncomment the model-loading block in loadModel().

import CoreML
import Vision
import UIKit

final class ObjectDetector {

    private var model: VNCoreMLModel?
    private(set) var detections: [DetectedObject] = []
    private(set) var isModelAvailable = false

    /// Called on the main actor after each frame is processed.
    var onDetectionsUpdated: (([DetectedObject]) -> Void)?

    init() {
        loadModel()
    }

    // MARK: - Model Loading

    private func loadModel() {
        // TODO: replace "YOLOv8n" with the actual compiled model resource name.
        guard
            let modelURL = Bundle.main.url(forResource: "YOLOv8n", withExtension: "mlmodelc"),
            let mlModel  = try? MLModel(contentsOf: modelURL),
            let vnModel  = try? VNCoreMLModel(for: mlModel)
        else {
            isModelAvailable = false
            print("ObjectDetector: YOLOv8n.mlmodelc not found — object grounding detection disabled (person follow still uses Vision human rectangles).")
            return
        }
        self.model = vnModel
        isModelAvailable = true
        print("ObjectDetector: YOLO model loaded.")
    }

    // MARK: - Per-Frame Inference

    /// Feed the latest drone camera pixel buffer.
    /// Results arrive asynchronously via `onDetectionsUpdated` on the main actor.
    func process(pixelBuffer: CVPixelBuffer) {
        guard let model else { return }

        let request = VNCoreMLRequest(model: model) { [weak self] req, _ in
            guard let self else { return }

            let objects: [DetectedObject] = (req.results as? [VNRecognizedObjectObservation] ?? [])
                .prefix(20)
                .map { obs in
                    DetectedObject(
                        id:         UUID().uuidString,
                        label:      obs.labels.first?.identifier ?? "object",
                        confidence: obs.labels.first?.confidence ?? obs.confidence,
                        // Vision uses bottom-left origin; callers flip Y for display as needed.
                        bbox:       obs.boundingBox
                    )
                }

            Task { @MainActor [weak self] in
                self?.detections = objects
                self?.onDetectionsUpdated?(objects)
            }
        }
        request.imageCropAndScaleOption = .scaleFill

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        try? handler.perform([request])
    }

    /// Feed a CGImage directly (useful when the app only has JPEG/UIImage snapshots).
    func process(cgImage: CGImage) {
        guard let model else { return }

        let request = VNCoreMLRequest(model: model) { [weak self] req, _ in
            guard let self else { return }

            let objects: [DetectedObject] = (req.results as? [VNRecognizedObjectObservation] ?? [])
                .prefix(20)
                .map { obs in
                    DetectedObject(
                        id:         UUID().uuidString,
                        label:      obs.labels.first?.identifier ?? "object",
                        confidence: obs.labels.first?.confidence ?? obs.confidence,
                        bbox:       obs.boundingBox
                    )
                }

            Task { @MainActor [weak self] in
                self?.detections = objects
                self?.onDetectionsUpdated?(objects)
            }
        }
        request.imageCropAndScaleOption = .scaleFill

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try? handler.perform([request])
    }
}
