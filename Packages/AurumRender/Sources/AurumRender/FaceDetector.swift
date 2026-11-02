import CoreImage
import Vision
import AurumCore

/// Finds faces and their landmarks with Vision and converts them to
/// `FaceGeometry`, in normalised image coordinates with the origin at the
/// top-left (the convention used everywhere else in Aurum).
///
/// Detection runs entirely on device. It is comparatively slow (tens of
/// milliseconds), so callers go through `FaceCache` to run it once per photo.
public enum FaceDetector {
    /// Detects every face in the image, sorted in `FaceGeometry.readingOrder`
    /// so per-face retouch settings keep pointing at the same person.
    public static func detect(in image: CIImage) throws -> [FaceGeometry] {
        let extent = image.extent
        guard !extent.isEmpty, !extent.isInfinite, extent.width >= 1, extent.height >= 1 else { return [] }

        let request = VNDetectFaceLandmarksRequest()
        let handler = VNImageRequestHandler(ciImage: image, options: [:])
        try handler.perform([request])

        let observations = request.results ?? []
        let faces = observations.map { geometry(from: $0, imageSize: extent.size) }
        return FaceGeometry.readingOrder(faces)
    }

    /// Converts one observation. Vision's bounding box is normalised with a
    /// bottom-left origin; landmark points are relative to the bounding box,
    /// so they go through `pointsInImage(imageSize:)` (pixels, bottom-left)
    /// and are then normalised and flipped.
    static func geometry(from observation: VNFaceObservation, imageSize: CGSize) -> FaceGeometry {
        let box = observation.boundingBox
        let bounds = NormalizedRect(
            x: Double(box.minX),
            y: Double(1 - box.maxY),
            width: Double(box.width),
            height: Double(box.height)
        )

        var regions: [FaceGeometry.Region: [AurumCore.NormalizedPoint]] = [:]
        if let landmarks = observation.landmarks {
            let mapping: [(FaceGeometry.Region, VNFaceLandmarkRegion2D?)] = [
                (.faceContour, landmarks.faceContour),
                (.leftEye, landmarks.leftEye),
                (.rightEye, landmarks.rightEye),
                (.leftEyebrow, landmarks.leftEyebrow),
                (.rightEyebrow, landmarks.rightEyebrow),
                (.nose, landmarks.nose),
                (.outerLips, landmarks.outerLips),
                (.innerLips, landmarks.innerLips)
            ]
            for (region, landmark) in mapping {
                guard let landmark, landmark.pointCount > 0 else { continue }
                let points = landmark.pointsInImage(imageSize: imageSize).map { p in
                    AurumCore.NormalizedPoint(
                        x: Double(p.x / imageSize.width),
                        y: Double(1 - p.y / imageSize.height)
                    )
                }
                regions[region] = points
            }
        }
        return FaceGeometry(bounds: bounds, regions: regions)
    }
}

/// Caches detected faces by asset identifier, so detection runs once per
/// photo however many times the preview and export render it.
///
/// Geometry is normalised, so faces found on a screen-size proxy apply
/// unchanged to the full-resolution export.
public actor FaceCache {
    private var storage: [String: [FaceGeometry]] = [:]

    public init() {}

    /// The faces in the asset, detecting them in `image` on the first call.
    /// A failed detection returns no faces and is retried on the next call.
    public func faces(for assetID: String, image: CIImage) -> [FaceGeometry] {
        if let cached = storage[assetID] { return cached }
        guard let found = try? FaceDetector.detect(in: image) else { return [] }
        storage[assetID] = found
        return found
    }

    /// Stores faces found elsewhere, or corrected by the user.
    public func store(_ found: [FaceGeometry], for assetID: String) {
        storage[assetID] = found
    }

    public func removeAll() {
        storage.removeAll()
    }
}
