import CryptoKit
import Foundation
import AurumCore

/// Keeps downloadable content packs in step with the remote catalogue.
///
/// Nothing touches the network unless a manifest URL is configured. Each pack
/// is downloaded to a temporary file, checked against the manifest's SHA-256,
/// and only then moved to Application Support/Packs/<id>/<version>.pack and
/// recorded as installed. A pack that fails its checksum is discarded.
public actor CatalogUpdater {
    public enum UpdateError: Error, Equatable {
        case notConfigured
        case badResponse(status: Int)
        case checksumMismatch(packID: String)
        case insecureURL(packID: String)
    }

    public struct Report: Equatable, Sendable {
        public var installed: [String] = []
        public var removed: [String] = []
        public var failed: [String] = []
    }

    public let manifestURL: URL?
    public let appVersion: SemanticVersion
    private let directory: URL
    private let session: URLSession

    public init(manifestURL: URL?, appVersion: SemanticVersion, directory: URL = CatalogUpdater.defaultDirectory(), session: URLSession = .shared) {
        self.manifestURL = manifestURL?.scheme?.lowercased() == "https" ? manifestURL : nil
        self.appVersion = appVersion
        self.directory = directory
        self.session = session
    }

    public static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Packs", isDirectory: true)
    }

    public var isConfigured: Bool { manifestURL != nil }

    var installedURL: URL { directory.appendingPathComponent("installed.json") }

    /// Packs recorded as installed.
    public func installed() -> [InstalledPack] {
        guard let data = try? Data(contentsOf: installedURL) else { return [] }
        return (try? JSONDecoder().decode([InstalledPack].self, from: data)) ?? []
    }

    /// The archive of an installed pack, if present.
    public func archiveURL(for pack: InstalledPack) -> URL {
        directory.appendingPathComponent(pack.id, isDirectory: true).appendingPathComponent("\(pack.version).pack")
    }

    /// Fetches the manifest and applies the diff. Packs that fail are
    /// reported and left at their previous version.
    public func update() async throws -> Report {
        guard let manifestURL else { throw UpdateError.notConfigured }
        let (data, response) = try await session.data(from: manifestURL)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw UpdateError.badResponse(status: code) }
        let manifest = try CatalogManifest.decode(from: data)
        return await apply(manifest)
    }

    /// Applies a manifest that has already been fetched and validated.
    public func apply(_ manifest: CatalogManifest) async -> Report {
        var current = installed()
        let diff = manifest.diff(installed: current, appVersion: appVersion)
        var report = Report()
        for pack in diff.download {
            do {
                try await download(pack)
                current.removeAll { $0.id == pack.id }
                current.append(InstalledPack(id: pack.id, version: pack.version))
                report.installed.append(pack.id)
                save(current)
            } catch {
                report.failed.append(pack.id)
            }
        }
        for id in diff.remove {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(id, isDirectory: true))
            current.removeAll { $0.id == id }
            report.removed.append(id)
        }
        save(current)
        return report
    }

    func download(_ pack: CatalogPack) async throws {
        guard let url = URL(string: pack.url), url.scheme?.lowercased() == "https" else { throw UpdateError.insecureURL(packID: pack.id) }
        let (temp, response) = try await session.download(from: url)
        defer { try? FileManager.default.removeItem(at: temp) }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw UpdateError.badResponse(status: code) }
        let data = try Data(contentsOf: temp, options: .mappedIfSafe)
        guard Self.sha256Hex(data) == pack.sha256.lowercased() else { throw UpdateError.checksumMismatch(packID: pack.id) }

        let packDir = directory.appendingPathComponent(pack.id, isDirectory: true)
        // Replace older versions of this pack.
        try? FileManager.default.removeItem(at: packDir)
        try FileManager.default.createDirectory(at: packDir, withIntermediateDirectories: true)
        try data.write(to: archiveURL(for: InstalledPack(id: pack.id, version: pack.version)), options: .atomic)
    }

    /// Lowercase hex SHA-256.
    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func save(_ packs: [InstalledPack]) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(packs) else { return }
        try? data.write(to: installedURL, options: .atomic)
    }
}
