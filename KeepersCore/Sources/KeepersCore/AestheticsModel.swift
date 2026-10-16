import CoreGraphics
import CoreML
import Foundation
import Vision

/// Aesthetics for macOS 13–14, where Vision's built-in aesthetics score is
/// not available: CLIP ViT-B/32 image features into the LAION aesthetic
/// linear head, converted to Core ML by `scripts/convert_aesthetics_model.py`.
///
/// The model is optional. Without it, scoring simply drops the aesthetics
/// signal and re-weights the others.
public final class AestheticsModel {
    /// Where the compiled model lives once downloaded and installed.
    public static var installURL: URL {
        AppPaths.supportDirectory.appendingPathComponent("Models/KeepersAesthetics.mlmodelc", isDirectory: true)
    }

    public static var isNeeded: Bool {
        if #available(macOS 15.0, *) { return false }
        return true
    }

    /// The installed model, or nil when it isn't needed or not downloaded.
    public static func installed() -> AestheticsModel? {
        guard isNeeded, FileManager.default.fileExists(atPath: installURL.path) else { return nil }
        return try? AestheticsModel(compiledModelAt: installURL)
    }

    private let model: VNCoreMLModel

    public init(compiledModelAt url: URL) throws {
        let config = MLModelConfiguration()
        config.computeUnits = .all
        model = try VNCoreMLModel(for: MLModel(contentsOf: url, configuration: config))
    }

    /// 0...1. The LAION head predicts a 1–10 rating; real photos land in
    /// roughly 3.5–7.5, so that band is stretched to the full range.
    public func score(_ image: CGImage) throws -> Double? {
        let request = VNCoreMLRequest(model: model)
        request.imageCropAndScaleOption = .centerCrop
        try VNImageRequestHandler(cgImage: image, orientation: .up).perform([request])
        guard let value = (request.results?.first as? VNCoreMLFeatureValueObservation)?
            .featureValue.multiArrayValue?[0].doubleValue
        else { return nil }
        return min(max((value - 3.5) / 4, 0), 1)
    }
}

public enum AppPaths {
    public static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Keepers", isDirectory: true)
    }
}
