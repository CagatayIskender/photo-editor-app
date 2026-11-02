import Foundation
import Photos
import AurumCore

extension LivePhotoLibrary {
    /// The photo's original file data (with any embedded depth), current
    /// version, downloading from iCloud if needed. Used by 3D Motion to read
    /// Portrait-mode disparity.
    public func originalData(for id: String) async throws -> Data {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else {
            throw PhotoLibraryError.notFound
        }
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.version = .current
        options.deliveryMode = .highQualityFormat
        return try await withCheckedThrowingContinuation { continuation in
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, _ in
                if let data { continuation.resume(returning: data) } else { continuation.resume(throwing: PhotoLibraryError.loadFailed) }
            }
        }
    }
}
