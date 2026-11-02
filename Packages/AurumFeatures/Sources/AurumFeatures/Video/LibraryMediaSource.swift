import AVFoundation
import CoreImage
import Foundation
import AurumCore
import AurumRender
import AurumServices

/// Supplies the video renderer with media from the user's library, files the
/// camera wrote, bundled music and songs the user imported.
///
/// A clip's `localIdentifier` is normally a Photos identifier. Clips recorded
/// when the library can't be read use a `file://` URL instead, so they still
/// open in the editor.
public struct LibraryMediaSource: VideoMediaSource {
    public enum MediaError: Error {
        case musicNotFound
        case imageNotReadable
    }

    let photos: PhotoLibraryService
    let content: ContentLibrary

    public init(photos: PhotoLibraryService, content: ContentLibrary) {
        self.photos = photos
        self.content = content
    }

    // MARK: VideoMediaSource

    public func videoAsset(for localIdentifier: String) async throws -> AVAsset {
        if let url = Self.fileURL(from: localIdentifier) {
            return AVURLAsset(url: url)
        }
        return try await photos.videoAsset(for: localIdentifier)
    }

    public func image(for localIdentifier: String, maxPixelSize: CGFloat?) async throws -> CIImage {
        guard let url = Self.fileURL(from: localIdentifier) else {
            return try await photos.image(for: localIdentifier, maxPixelSize: maxPixelSize)
        }
        guard let image = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else {
            throw MediaError.imageNotReadable
        }
        let upright = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        guard let maxPixelSize else { return upright }
        let longest = max(upright.extent.width, upright.extent.height)
        guard longest > maxPixelSize, longest > 0 else { return upright }
        let scale = maxPixelSize / longest
        return upright.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    }

    public func musicURL(for source: MusicSelection.Source) async throws -> URL {
        switch source {
        case .library(let trackID):
            guard let track = content.music.first(where: { $0.id == trackID }),
                  let url = Self.bundledURL(for: track) else { throw MediaError.musicNotFound }
            return url
        case .imported(let fileName):
            let url = Self.importedMusicDirectory().appendingPathComponent(fileName)
            guard FileManager.default.fileExists(atPath: url.path) else { throw MediaError.musicNotFound }
            return url
        }
    }

    // MARK: Files

    /// The file a `file://` identifier points to, or nil for a Photos identifier.
    public static func fileURL(from identifier: String) -> URL? {
        guard identifier.hasPrefix("file://"), let url = URL(string: identifier), url.isFileURL else { return nil }
        return url
    }

    /// An identifier for a local file, for clips that are not in the library.
    public static func identifier(for fileURL: URL) -> String {
        fileURL.absoluteString
    }

    /// Documents/Music, where imported songs are copied. Created on first use.
    public static func importedMusicDirectory() -> URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("Music", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Songs the user has imported, newest first.
    public static func importedSongs() -> [URL] {
        let dir = importedMusicDirectory()
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        func date(_ url: URL) -> Date {
            (try? url.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast
        }
        return files.sorted { date($0) > date($1) }
    }

    /// Copies a picked audio file into Documents/Music and returns its file name.
    public static func importSong(from url: URL) throws -> String {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let dir = importedMusicDirectory()
        var destination = dir.appendingPathComponent(url.lastPathComponent)
        if FileManager.default.fileExists(atPath: destination.path) {
            let stem = url.deletingPathExtension().lastPathComponent
            destination = dir.appendingPathComponent("\(stem)-\(UUID().uuidString.prefix(4))").appendingPathExtension(url.pathExtension)
        }
        try FileManager.default.copyItem(at: url, to: destination)
        return destination.lastPathComponent
    }

    /// A library track shipped in the app bundle, or downloaded earlier to Caches/Music.
    static func bundledURL(for track: AurumCore.MusicTrack) -> URL? {
        let fm = FileManager.default
        var candidates: [URL] = []
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appendingPathComponent(track.path))
            candidates.append(resources.appendingPathComponent("Music").appendingPathComponent((track.path as NSString).lastPathComponent))
        }
        let name = ((track.path as NSString).lastPathComponent as NSString).deletingPathExtension
        let ext = (track.path as NSString).pathExtension
        if let url = Bundle.main.url(forResource: name, withExtension: ext.isEmpty ? nil : ext) {
            candidates.append(url)
        }
        if let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first {
            candidates.append(caches.appendingPathComponent("Music").appendingPathComponent((track.path as NSString).lastPathComponent))
        }
        return candidates.first { fm.fileExists(atPath: $0.path) }
    }
}
