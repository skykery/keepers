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
        // A RAW+JPEG pair: shooting details come from the RAW.
        let metadata = photo.decodeURL == photo.primary ? decoded.metadata : ImageDecoder.metadata(photo.primary)
        return try analyze(decoded.image, captureDate: date, metadata: metadata)
    }

    public func analyze(_ image: CGImage, captureDate: Date, metadata: CaptureMetadata = CaptureMetadata()) throws -> PhotoAnalysis {
        guard let px = PixelBuffer(image) else { throw ImageDecoder.Failure.unreadable(URL(fileURLWithPath: "/")) }

        let quality = VNDetectFaceCaptureQualityRequest()
        let saliency = VNGenerateAttentionBasedSaliencyImageRequest()
        let featurePrint = VNGenerateImageFeaturePrintRequest()
        featurePrint.imageCropAndScaleOption = .scaleFill
        let animalsRequest = VNRecognizeAnimalsRequest()
        var requests: [VNRequest] = [quality, saliency, featurePrint, animalsRequest]
        var aestheticsRequest: VNRequest?
        if #available(macOS 15.0, *) {
            let r = VNCalculateImageAestheticsScoresRequest()
            requests.append(r)
            aestheticsRequest = r
        }
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up)
        try handler.perform(requests)
        let mouths = Self.mouthShapes(handler: handler, faces: quality.results ?? [], imageSize: image)

        // Faces.
        let expressions = Self.expressions(in: image)
        let faceHeightFloor = Self.minSubjectFaceHeight
        let observed = (quality.results ?? []).map { NormRect(bottomLeft: $0.boundingBox).clamped() }
        let largest = observed.map(\.height).max() ?? 0
        var faces: [PhotoAnalysis.Face] = []
        for (i, (obs, rect)) in zip(quality.results ?? [], observed).enumerated() {
            let expression = expressions.max { $0.rect.intersectionOverUnion(rect) < $1.rect.intersectionOverUnion(rect) }
            let matched = expression.flatMap { $0.rect.intersectionOverUnion(rect) > 0.3 ? $0 : nil }
            faces.append(PhotoAnalysis.Face(
                rect: rect,
                quality: obs.faceCaptureQuality.map(Double.init),
                focus: PixelMetrics.focusEnergy(px, in: rect.eyeBand, maxSide: Self.eyeBandSide),
                smiling: matched?.smiling,
                eyesClosed: matched?.eyesClosed,
                mouth: mouths[safe: i] ?? nil,
                isSubject: rect.height >= faceHeightFloor && rect.height >= largest * 0.4
            ))
        }
        let subjectFaces = faces.filter(\.isSubject)
        let animals = (animalsRequest.results ?? []).map { NormRect(bottomLeft: $0.boundingBox).clamped() }

        // Subject region and its focus: faces, else where the camera focused,
        // else a cat or dog, else what draws attention, else the center.
        let subject: NormRect
        let subjectFocus: Double
        if !subjectFaces.isEmpty {
            subject = subjectFaces.map(\.rect).reduce(subjectFaces[0].rect) { $0.union($1) }
            subjectFocus = Self.weightedFaceFocus(subjectFaces)
        } else if let point = metadata.focusPoint {
            // Where the camera focused: the photographer's own choice of subject.
            subject = NormRect(x: point.midX - max(point.width, 0.04) * 1.5, y: point.midY - max(point.height, 0.05) * 1.5,
                               width: max(point.width, 0.04) * 3, height: max(point.height, 0.05) * 3).clamped()
            subjectFocus = PixelMetrics.focusEnergy(px, in: subject)
        } else if let pet = Self.petSubject(handler: handler, animals: animals) {
            subject = pet
            subjectFocus = PixelMetrics.focusEnergy(px, in: pet, maxSide: Self.eyeBandSide * 2)
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
            featurePrint: fp,
            metadata: metadata,
            animals: animals,
            revision: PhotoAnalysis.currentRevision
        )
    }

    /// How far the view moved from `a` to `b`, as fractions of the frame
    /// (+x right, +y down), from Vision's image registration on small copies.
    public static func translation(from a: Photo, to b: Photo) throws -> CGVector {
        let ia = try ImageDecoder.decode(a.decodeURL, maxPixelSize: 512).image
        let ib = try ImageDecoder.decode(b.decodeURL, maxPixelSize: 512).image
        let request = VNTranslationalImageRegistrationRequest(targetedCGImage: ib)
        try VNImageRequestHandler(cgImage: ia, orientation: .up).perform([request])
        guard let t = request.results?.first?.alignmentTransform else { return .zero }
        // Vision's y axis points up; flip it so +y means the view moved down.
        return CGVector(dx: t.tx / CGFloat(ia.width), dy: -t.ty / CGFloat(ia.height))
    }

    /// The region to judge a cat's or dog's sharpness on: its eyes when
    /// Vision's animal pose finds them (macOS 14+), else the largest animal.
    static func petSubject(handler: VNImageRequestHandler, animals: [NormRect]) -> NormRect? {
        guard let largest = animals.max(by: { $0.area < $1.area }) else { return nil }
        if #available(macOS 14.0, *) {
            let pose = VNDetectAnimalBodyPoseRequest()
            if (try? handler.perform([pose])) != nil, let body = pose.results?.first,
               let left = try? body.recognizedPoint(.leftEye), let right = try? body.recognizedPoint(.rightEye),
               left.confidence > 0.3, right.confidence > 0.3 {
                let a = left.location, b = right.location  // normalized, bottom-left origin
                let span = max(hypot(a.x - b.x, a.y - b.y), 0.02)
                let box = CGRect(x: min(a.x, b.x) - span * 0.6, y: min(a.y, b.y) - span * 0.6,
                                 width: abs(a.x - b.x) + span * 1.2, height: abs(a.y - b.y) + span * 1.2)
                return NormRect(bottomLeft: box).clamped()
            }
        }
        return largest
    }

    /// Mouth geometry for each face, in order, from Vision's landmarks.
    static func mouthShapes(handler: VNImageRequestHandler, faces: [VNFaceObservation], imageSize image: CGImage) -> [MouthShape?] {
        guard !faces.isEmpty else { return [] }
        let request = VNDetectFaceLandmarksRequest()
        request.inputFaceObservations = faces
        guard (try? handler.perform([request])) != nil, let results = request.results else {
            return faces.map { _ in nil }
        }
        let size = CGSize(width: image.width, height: image.height)
        // Match results back to the input faces by box overlap.
        return faces.map { face in
            let box = NormRect(bottomLeft: face.boundingBox)
            guard let match = results.max(by: {
                NormRect(bottomLeft: $0.boundingBox).intersectionOverUnion(box) < NormRect(bottomLeft: $1.boundingBox).intersectionOverUnion(box)
            }), NormRect(bottomLeft: match.boundingBox).intersectionOverUnion(box) > 0.5,
                  let lm = match.landmarks, let le = lm.leftEye, let re = lm.rightEye,
                  let outer = lm.outerLips, let inner = lm.innerLips
            else { return nil }
            return MouthShape(leftEye: le.pointsInImage(imageSize: size), rightEye: re.pointsInImage(imageSize: size),
                              outerLips: outer.pointsInImage(imageSize: size), innerLips: inner.pointsInImage(imageSize: size))
        }
    }

    /// Focus energy at full detail for burst ranking: the primary face's eye
    /// band (or the subject) cropped from the largest available image and
    /// measured without downscaling.
    public func detailFocus(_ photo: Photo, analysis: PhotoAnalysis) throws -> Double {
        let large = try ImageDecoder.decodeLarge(photo.decodeURL, full: false)
        let region = (analysis.primaryFace?.rect.eyeBand ?? analysis.subject).clamped()
        let w = Double(large.image.width), h = Double(large.image.height)
        let crop = CGRect(x: region.x * w, y: region.y * h, width: region.width * w, height: region.height * h).integral
        guard let cropped = large.image.cropping(to: crop), let px = PixelBuffer(cropped) else { return 0 }
        return PixelMetrics.focusEnergy(px)
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
