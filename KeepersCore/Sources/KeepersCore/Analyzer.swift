import CoreGraphics
import CoreImage
import Foundation
import Vision

/// Turns a photo file into a `PhotoAnalysis`. Stateless and safe to call
/// from several tasks at once: every call builds its own Vision requests.
public struct Analyzer {
    /// Long edge, in pixels, of the image all measurements run on.
    public static let workingSize = 2048
    /// Faces smaller than this fraction of the image height are bystanders.
    static let minSubjectFaceHeight = 0.06
    /// Eye bands are measured at most this wide, so close-ups and distant
    /// faces are judged at the same scale.
    static let eyeBandSide = 256

    public var aestheticsModel: AestheticsModel?

    public init(aestheticsModel: AestheticsModel? = AestheticsModel.installed()) {
        self.aestheticsModel = aestheticsModel
    }

    public func analyze(_ photo: Photo) throws -> PhotoAnalysis {
        let decoded = try ImageDecoder.decode(photo.decodeURL, maxPixelSize: Self.workingSize)
        let date = decoded.captureDate ?? Self.fileDate(photo.primary)
        return try analyze(decoded.image, captureDate: date)
    }

    public func analyze(_ image: CGImage, captureDate: Date) throws -> PhotoAnalysis {
        guard let px = PixelBuffer(image) else { throw ImageDecoder.Failure.unreadable(URL(fileURLWithPath: "/")) }

        let quality = VNDetectFaceCaptureQualityRequest()
        let saliency = VNGenerateAttentionBasedSaliencyImageRequest()
        let featurePrint = VNGenerateImageFeaturePrintRequest()
        featurePrint.imageCropAndScaleOption = .scaleFill
        var requests: [VNRequest] = [quality, saliency, featurePrint]
        var aestheticsRequest: VNRequest?
        if #available(macOS 15.0, *) {
            let r = VNCalculateImageAestheticsScoresRequest()
            requests.append(r)
            aestheticsRequest = r
        }
        try VNImageRequestHandler(cgImage: image, orientation: .up).perform(requests)

        // Faces.
        let expressions = Self.expressions(in: image)
        let faceHeightFloor = Self.minSubjectFaceHeight
        let observed = (quality.results ?? []).map { NormRect(bottomLeft: $0.boundingBox).clamped() }
        let largest = observed.map(\.height).max() ?? 0
        var faces: [PhotoAnalysis.Face] = []
        for (obs, rect) in zip(quality.results ?? [], observed) {
            let expression = expressions.max { $0.rect.intersectionOverUnion(rect) < $1.rect.intersectionOverUnion(rect) }
            let matched = expression.flatMap { $0.rect.intersectionOverUnion(rect) > 0.3 ? $0 : nil }
            faces.append(PhotoAnalysis.Face(
                rect: rect,
                quality: obs.faceCaptureQuality.map(Double.init),
                focus: PixelMetrics.focusEnergy(px, in: rect.eyeBand, maxSide: Self.eyeBandSide),
                smiling: matched?.smiling,
                eyesClosed: matched?.eyesClosed,
                isSubject: rect.height >= faceHeightFloor && rect.height >= largest * 0.4
            ))
        }
        let subjectFaces = faces.filter(\.isSubject)

        // Subject region and its focus.
        let subject: NormRect
        let subjectFocus: Double
        if !subjectFaces.isEmpty {
            subject = subjectFaces.map(\.rect).reduce(subjectFaces[0].rect) { $0.union($1) }
            subjectFocus = Self.weightedFaceFocus(subjectFaces)
        } else {
            let salient = (saliency.results?.first?.salientObjects ?? []).map { NormRect(bottomLeft: $0.boundingBox) }
            if let first = salient.first {
                subject = salient.reduce(first) { $0.union($1) }.clamped()
            } else {
                subject = NormRect(x: 0.15, y: 0.15, width: 0.7, height: 0.7)
            }
            subjectFocus = PixelMetrics.focusEnergy(px, in: subject)
        }

        // Aesthetics.
        var aesthetics: Double?
        var isUtility = false
        if #available(macOS 15.0, *),
           let obs = (aestheticsRequest as? VNCalculateImageAestheticsScoresRequest)?.results?.first {
            aesthetics = (Double(obs.overallScore) + 1) / 2
            isUtility = obs.isUtility
        } else if let model = aestheticsModel {
            aesthetics = try? model.score(image)
        }

        let fp = featurePrint.results?.first.flatMap { obs -> FeaturePrint? in
            guard obs.elementType == .float else { return nil }
            let floats = obs.data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            return FeaturePrint(revision: featurePrint.revision, vector: floats)
        }

        return PhotoAnalysis(
            captureDate: captureDate,
            pixelWidth: image.width,
            pixelHeight: image.height,
            subject: subject,
            subjectFocus: subjectFocus,
            globalFocus: PixelMetrics.focusEnergy(px),
            exposure: PixelMetrics.exposure(px, subject: subject),
            aesthetics: aesthetics,
            isUtility: isUtility,
            faces: faces,
            featurePrint: fp
        )
    }

    /// The most prominent face counts double: in a group shot the person in
    /// front matters most, but someone soft at the side still costs points.
    static func weightedFaceFocus(_ faces: [PhotoAnalysis.Face]) -> Double {
        guard let primary = faces.max(by: { $0.rect.area < $1.rect.area }) else { return 0 }
        let total = faces.reduce(0) { $0 + $1.focus } + primary.focus
        return total / Double(faces.count + 1)
    }

    struct Expression {
        var rect: NormRect
        var smiling: Bool
        var eyesClosed: Bool
    }

    private static let faceDetector = CIDetector(
        ofType: CIDetectorTypeFace, context: CIContext(options: [.useSoftwareRenderer: false]),
        options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]
    )
    private static let faceDetectorLock = NSLock()

    /// Smile and closed-eye flags. Vision has no expression classifier;
    /// Core Image's face detector does.
    static func expressions(in image: CGImage) -> [Expression] {
        let ci = CIImage(cgImage: image)
        faceDetectorLock.lock()
        let features = faceDetector?.features(in: ci, options: [CIDetectorSmile: true, CIDetectorEyeBlink: true]) ?? []
        faceDetectorLock.unlock()
        let w = Double(image.width), h = Double(image.height)
        return features.compactMap { $0 as? CIFaceFeature }.map { f in
            let b = f.bounds
            let rect = NormRect(bottomLeft: CGRect(x: b.minX / w, y: b.minY / h, width: b.width / w, height: b.height / h))
            return Expression(rect: rect, smiling: f.hasSmile, eyesClosed: f.leftEyeClosed && f.rightEyeClosed)
        }
    }

    static func fileDate(_ url: URL) -> Date {
        let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        return values?.creationDate ?? values?.contentModificationDate ?? Date(timeIntervalSince1970: 0)
    }
}
