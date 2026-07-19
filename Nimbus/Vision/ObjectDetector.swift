// ObjectDetector.swift — Nimbus
// Real-time object detection via Vision framework built-in models.
// Spec §3 component 3.
//
// Primary path: built-in Vision neural networks (no bundle required).
//   • VNDetectHumanRectanglesRequest  → "person" bounding boxes
// Optional upgrade: drop a YOLOv8n.mlmodelc into the Xcode target for
//   80-class COCO detection (chairs, cars, etc.).

import CoreML
import Vision
import UIKit

final class ObjectDetector {

    private var model: VNCoreMLModel?
    private var hasAttemptedModelLoad = false
    private let hairAnalyzer = HairAttributeAnalyzer()
    private(set) var detections: [DetectedObject] = []
    /// Always true — built-in Vision requests need no model file.
    private(set) var isModelAvailable = true

    /// Called on the main actor after each frame is processed.
    var onDetectionsUpdated: (([DetectedObject]) -> Void)?

    init() {
        preloadModelIfNeeded()
    }

    // MARK: - Model Loading

    private func preloadModelIfNeeded() {
        guard !hasAttemptedModelLoad else { return }
        hasAttemptedModelLoad = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.loadModel()
        }
    }

    private func loadModel() {
        // Optionally load a bundled YOLO model for 80-class COCO coverage.
        // Falls back gracefully to built-in Vision person + animal detection.
        guard
            let modelURL = Bundle.main.url(forResource: "YOLOv8n", withExtension: "mlmodelc"),
            let mlModel  = try? MLModel(contentsOf: modelURL),
            let vnModel  = try? VNCoreMLModel(for: mlModel)
        else {
            print("ObjectDetector: using built-in Vision (person + animal detection).")
            return
        }
        DispatchQueue.main.async { [weak self] in
            self?.model = vnModel
        }
        print("ObjectDetector: YOLO model loaded — 80-class mode.")
    }

    // MARK: - Per-Frame Inference

    /// Feed the latest drone camera pixel buffer.
    func process(pixelBuffer: CVPixelBuffer) {
        run(handler: VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:]), sourceImage: nil)
    }

    /// Feed a CGImage directly (useful when the app only has JPEG/UIImage snapshots).
    func process(cgImage: CGImage) {
        run(handler: VNImageRequestHandler(cgImage: cgImage, options: [:]), sourceImage: cgImage)
    }

    // MARK: - Private

    private func run(handler: VNImageRequestHandler, sourceImage: CGImage?) {
        if let model {
            runCoreML(model: model, handler: handler, sourceImage: sourceImage)
        } else {
            runBuiltIn(handler: handler, sourceImage: sourceImage)
        }
    }

    private func runCoreML(model: VNCoreMLModel, handler: VNImageRequestHandler, sourceImage: CGImage?) {
        let request = VNCoreMLRequest(model: model) { [weak self] req, _ in
            let objects = (req.results as? [VNRecognizedObjectObservation] ?? [])
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
            var finalObjects = objects
            if let sourceImage {
                let people = objects.filter { $0.label.lowercased() == "person" }
                finalObjects.append(contentsOf: self?.hairAnalyzer.findDarkHair(in: sourceImage, people: people) ?? [])
            }
            self?.publish(finalObjects)
        }
        request.imageCropAndScaleOption = .scaleFill
        try? handler.perform([request])
    }

    /// Uses Apple's on-device person detector — no bundle needed.
    private func runBuiltIn(handler: VNImageRequestHandler, sourceImage: CGImage?) {
        var objects: [DetectedObject] = []

        // Full-body person bounding boxes.
        let personReq = VNDetectHumanRectanglesRequest { req, _ in
            let people = (req.results as? [VNHumanObservation] ?? []).map { obs in
                DetectedObject(
                    id:         UUID().uuidString,
                    label:      "person",
                    confidence: obs.confidence,
                    bbox:       obs.boundingBox
                )
            }
            objects.append(contentsOf: people)
        }
        personReq.upperBodyOnly = false

        try? handler.perform([personReq])
        if let sourceImage {
            objects.append(contentsOf: hairAnalyzer.findDarkHair(in: sourceImage, people: objects))
        }
        publish(objects)
    }

    private func publish(_ objects: [DetectedObject]) {
        Task { @MainActor [weak self] in
            self?.detections = objects
            self?.onDetectionsUpdated?(objects)
        }
    }
}

private struct HairAttributeAnalyzer {
    private let outputLabel = "black_hair"
    /// High threshold to reduce false positives / hallucinations.
    private let minConfidence: Float = 0.78
    /// Ignore tiny detections where hair signal is too noisy.
    private let minHeadAreaNorm: CGFloat = 0.003

    func findDarkHair(in image: CGImage, people: [DetectedObject]) -> [DetectedObject] {
        people.compactMap { person in
            let headBox = headROI(from: person.bbox)
            guard headBox.width * headBox.height >= minHeadAreaNorm else { return nil }
            guard let crop = crop(normalizedBox: headBox, from: image),
                  let metrics = darknessMetrics(from: crop) else { return nil }

            let confidence = darkHairConfidence(from: metrics)
            guard confidence >= minConfidence else { return nil }

            return DetectedObject(
                id: UUID().uuidString,
                label: outputLabel,
                confidence: confidence,
                bbox: headBox
            )
        }
    }

    private func headROI(from person: CGRect) -> CGRect {
        // Narrow center + top band to isolate hair region from clothes/background.
        let width = person.width * 0.58
        let height = person.height * 0.30
        let x = person.midX - width / 2
        let y = person.maxY - height * 1.02
        let box = CGRect(x: x, y: y, width: width, height: height)
        return box.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    private func crop(normalizedBox: CGRect, from image: CGImage) -> CGImage? {
        guard !normalizedBox.isEmpty else { return nil }
        let imgW = CGFloat(image.width)
        let imgH = CGFloat(image.height)

        // Vision bbox origin is bottom-left; CGImage crop origin is top-left.
        let x = normalizedBox.minX * imgW
        let y = (1.0 - normalizedBox.maxY) * imgH
        let w = normalizedBox.width * imgW
        let h = normalizedBox.height * imgH
        let rect = CGRect(x: x, y: y, width: w, height: h).integral
        guard rect.width > 3, rect.height > 3 else { return nil }
        return image.cropping(to: rect)
    }

    private func darknessMetrics(from image: CGImage) -> (darkRatio: Float, veryDarkRatio: Float, luminanceStd: Float)? {
        let targetW = 32
        let targetH = 32
        let bytesPerPixel = 4
        let bytesPerRow = bytesPerPixel * targetW
        var pixels = [UInt8](repeating: 0, count: targetH * bytesPerRow)

        guard let ctx = CGContext(
            data: &pixels,
            width: targetW,
            height: targetH,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        ctx.interpolationQuality = .low
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: targetW, height: targetH))

        let total = targetW * targetH
        guard total > 0 else { return nil }

        var dark = 0
        var veryDark = 0
        var luminances = [Float]()
        luminances.reserveCapacity(total)

        for i in stride(from: 0, to: pixels.count, by: bytesPerPixel) {
            let r = Float(pixels[i]) / 255.0
            let g = Float(pixels[i + 1]) / 255.0
            let b = Float(pixels[i + 2]) / 255.0
            let luma = (0.2126 * r) + (0.7152 * g) + (0.0722 * b)
            luminances.append(luma)
            if luma < 0.30 { dark += 1 }
            if luma < 0.20 { veryDark += 1 }
        }

        let mean = luminances.reduce(0, +) / Float(total)
        let variance = luminances.reduce(0) { partial, value in
            let d = value - mean
            return partial + (d * d)
        } / Float(total)

        return (
            darkRatio: Float(dark) / Float(total),
            veryDarkRatio: Float(veryDark) / Float(total),
            luminanceStd: sqrtf(variance)
        )
    }

    private func darkHairConfidence(from metrics: (darkRatio: Float, veryDarkRatio: Float, luminanceStd: Float)) -> Float {
        // Weighted for conservative detection: require both dark coverage and texture variation.
        let textureSignal = min(1.0, metrics.luminanceStd / 0.22)
        return (0.45 * metrics.darkRatio) + (0.35 * metrics.veryDarkRatio) + (0.20 * textureSignal)
    }
}
