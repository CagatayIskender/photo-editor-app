import CoreImage
import Photos
import UIKit
import AurumCore

/// A photo the user can pick, independent of PhotoKit so previews and tests
/// can supply their own.
public struct LibraryItem: Identifiable, Hashable, Sendable {
    public let id: String
    public let pixelSize: PixelSize
    public let creationDate: Date?

    public init(id: String, pixelSize: PixelSize, creationDate: Date?) {
        self.id = id
        self.pixelSize = pixelSize
        self.creationDate = creationDate
    }
}

public enum LibraryAccess: Sendable {
    case notDetermined, full, limited, denied
}

public protocol PhotoLibraryService: Sendable {
    func access() -> LibraryAccess
    func requestAccess() async -> LibraryAccess
    /// Most recent photos first.
    func recentPhotos(limit: Int) async -> [LibraryItem]
    func thumbnail(for id: String, side: CGFloat) async -> UIImage?
    /// Loads the photo as a CIImage, downscaled so its longest side is at most
    /// `maxPixelSize` (nil loads full resolution).
    func image(for id: String, maxPixelSize: CGFloat?) async throws -> CIImage
    /// Saves encoded image data as a new photo.
    func save(_ data: Data, fileExtension: String) async throws
}

public enum PhotoLibraryError: Error {
    case notFound
    case loadFailed
    case notAuthorized
}

/// PhotoKit implementation.
public final class LivePhotoLibrary: PhotoLibraryService, @unchecked Sendable {
    private let imageManager = PHCachingImageManager()

    public init() {}

    public func access() -> LibraryAccess {
        Self.map(PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }

    public func requestAccess() async -> LibraryAccess {
        Self.map(await PHPhotoLibrary.requestAuthorization(for: .readWrite))
    }

    static func map(_ status: PHAuthorizationStatus) -> LibraryAccess {
        switch status {
        case .authorized: return .full
        case .limited: return .limited
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }

    public func recentPhotos(limit: Int) async -> [LibraryItem] {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = limit
        let result = PHAsset.fetchAssets(with: .image, options: options)
        var items: [LibraryItem] = []
        items.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in
            items.append(LibraryItem(id: asset.localIdentifier, pixelSize: PixelSize(width: asset.pixelWidth, height: asset.pixelHeight), creationDate: asset.creationDate))
        }
        return items
    }

    private func asset(_ id: String) -> PHAsset? {
        PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject
    }

    public func thumbnail(for id: String, side: CGFloat) async -> UIImage? {
        guard let asset = asset(id) else { return nil }
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.isNetworkAccessAllowed = true
        options.resizeMode = .fast
        let scale = await MainActor.run { UIScreen.main.scale }
        let target = CGSize(width: side * scale, height: side * scale)
        return await withCheckedContinuation { continuation in
            var resumed = false
            imageManager.requestImage(for: asset, targetSize: target, contentMode: .aspectFill, options: options) { image, info in
                // Opportunistic delivery may call back twice; resume on the final image.
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                guard !resumed, !degraded || image == nil else { return }
                resumed = true
                continuation.resume(returning: image)
            }
        }
    }

    public func image(for id: String, maxPixelSize: CGFloat?) async throws -> CIImage {
        guard let asset = asset(id) else { throw PhotoLibraryError.notFound }
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.version = .current
        options.deliveryMode = .highQualityFormat
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, _ in
                if let data { continuation.resume(returning: data) } else { continuation.resume(throwing: PhotoLibraryError.loadFailed) }
            }
        }
        guard let image = CIImage(data: data, options: [.applyOrientationProperty: true]) else {
            throw PhotoLibraryError.loadFailed
        }
        let upright = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        guard let maxPixelSize else { return upright }
        let longest = max(upright.extent.width, upright.extent.height)
        guard longest > maxPixelSize else { return upright }
        let scale = maxPixelSize / longest
        return upright.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    }

    public func save(_ data: Data, fileExtension: String) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw PhotoLibraryError.notAuthorized }
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            let options = PHAssetResourceCreationOptions()
            options.uniformTypeIdentifier = fileExtension == "png" ? "public.png" : (fileExtension == "heic" ? "public.heic" : "public.jpeg")
            request.addResource(with: .photo, data: data, options: options)
        }
    }
}

/// In-memory photos built from gradients, for previews, UI tests and the
/// onboarding sample.
public final class SamplePhotoLibrary: PhotoLibraryService, @unchecked Sendable {
    public static let palette: [(UIColor, UIColor)] = [
        (UIColor(red: 0.91, green: 0.73, blue: 0.48, alpha: 1), UIColor(red: 0.54, green: 0.31, blue: 0.17, alpha: 1)),
        (UIColor(red: 0.56, green: 0.76, blue: 0.84, alpha: 1), UIColor(red: 0.18, green: 0.29, blue: 0.35, alpha: 1)),
        (UIColor(red: 0.95, green: 0.86, blue: 0.88, alpha: 1), UIColor(red: 0.66, green: 0.54, blue: 0.60, alpha: 1)),
        (UIColor(red: 0.35, green: 0.35, blue: 0.38, alpha: 1), UIColor(red: 0.05, green: 0.05, blue: 0.06, alpha: 1)),
        (UIColor(red: 0.95, green: 0.84, blue: 0.60, alpha: 1), UIColor(red: 0.42, green: 0.29, blue: 0.10, alpha: 1)),
        (UIColor(red: 0.31, green: 0.48, blue: 0.84, alpha: 1), UIColor(red: 0.16, green: 0.05, blue: 0.23, alpha: 1))
    ]

    public private(set) var saved: [Data] = []

    public init() {}

    public func access() -> LibraryAccess { .full }
    public func requestAccess() async -> LibraryAccess { .full }

    public func recentPhotos(limit: Int) async -> [LibraryItem] {
        (0..<min(limit, 24)).map { LibraryItem(id: "sample-\($0)", pixelSize: PixelSize(width: 1600, height: 2000), creationDate: nil) }
    }

    static func index(of id: String) -> Int {
        Int(id.split(separator: "-").last ?? "0") ?? 0
    }

    func render(id: String, size: CGSize) -> UIImage {
        let colours = Self.palette[Self.index(of: id) % Self.palette.count]
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [colours.0.cgColor, colours.1.cgColor] as CFArray, locations: [0, 1])!
            ctx.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width * 0.4, y: size.height), options: [])
            // A soft "subject" so looks have skin-like tones to act on.
            UIColor(red: 0.93, green: 0.82, blue: 0.72, alpha: 0.9).setFill()
            ctx.cgContext.fillEllipse(in: CGRect(x: size.width * 0.36, y: size.height * 0.24, width: size.width * 0.28, height: size.height * 0.24))
        }
    }

    public func thumbnail(for id: String, side: CGFloat) async -> UIImage? {
        render(id: id, size: CGSize(width: side * 2, height: side * 2))
    }

    public func image(for id: String, maxPixelSize: CGFloat?) async throws -> CIImage {
        let longest = min(maxPixelSize ?? 2000, 2000)
        let size = CGSize(width: longest * 0.8, height: longest)
        guard let cg = render(id: id, size: size).cgImage else { throw PhotoLibraryError.loadFailed }
        return CIImage(cgImage: cg)
    }

    public func save(_ data: Data, fileExtension: String) async throws {
        saved.append(data)
    }
}
