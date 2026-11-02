import Foundation

/// A "major.minor.patch" version. Missing parts read as 0, a leading "v" and
/// any "-prerelease" or "+build" suffix are ignored. Encoded as a string.
public struct SemanticVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    public var major: Int
    public var minor: Int
    public var patch: Int

    public init(_ major: Int, _ minor: Int = 0, _ patch: Int = 0) {
        self.major = max(0, major)
        self.minor = max(0, minor)
        self.patch = max(0, patch)
    }

    public init?(_ text: String) {
        var s = Substring(text.trimmingCharacters(in: .whitespaces))
        if s.hasPrefix("v") || s.hasPrefix("V") { s = s.dropFirst() }
        if let cut = s.firstIndex(where: { $0 == "-" || $0 == "+" }) { s = s[..<cut] }
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(part) else { return nil }
            numbers.append(n)
        }
        while numbers.count < 3 { numbers.append(0) }
        self.init(numbers[0], numbers[1], numbers[2])
    }

    public var description: String { "\(major).\(minor).\(patch)" }

    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    /// Compares two version strings; unparsable versions sort first.
    public static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let va = SemanticVersion(a), vb = SemanticVersion(b)
        switch (va, vb) {
        case (nil, nil): return .orderedSame
        case (nil, _): return .orderedAscending
        case (_, nil): return .orderedDescending
        case let (x?, y?): return x == y ? .orderedSame : (x < y ? .orderedAscending : .orderedDescending)
        }
    }
}

extension SemanticVersion: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let text = try c.decode(String.self)
        guard let v = SemanticVersion(text) else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Not a version: \(text)")
        }
        self = v
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(description)
    }
}

/// A downloadable content pack (looks, stickers, templates...).
public struct CatalogPack: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var version: SemanticVersion
    public var itemCount: Int
    /// Hex SHA-256 of the pack archive (either case is accepted).
    public var sha256: String
    public var url: String
    public var minAppVersion: SemanticVersion

    public init(id: String, version: SemanticVersion, itemCount: Int, sha256: String, url: String, minAppVersion: SemanticVersion = SemanticVersion(1)) {
        self.id = id
        self.version = version
        self.itemCount = itemCount
        self.sha256 = sha256.lowercased()
        self.url = url
        self.minAppVersion = minAppVersion
    }

    public var hasValidChecksum: Bool {
        sha256.count == 64 && sha256.lowercased().allSatisfy { "0123456789abcdef".contains($0) }
    }

    public func isCompatible(with appVersion: SemanticVersion) -> Bool { minAppVersion <= appVersion }
}

/// A pack already on the device.
public struct InstalledPack: Codable, Equatable, Sendable {
    public var id: String
    public var version: SemanticVersion

    public init(id: String, version: SemanticVersion) {
        self.id = id
        self.version = version
    }
}

/// What to change to match a manifest.
public struct CatalogDiff: Equatable, Sendable {
    /// New packs and packs whose version changed, in manifest order.
    public var download: [CatalogPack]
    /// Installed pack ids the manifest no longer lists, sorted.
    public var remove: [String]

    public init(download: [CatalogPack] = [], remove: [String] = []) {
        self.download = download
        self.remove = remove
    }

    public var isEmpty: Bool { download.isEmpty && remove.isEmpty }
}

/// The remote list of content packs.
public struct CatalogManifest: Codable, Equatable, Sendable {
    public var version: Int
    public var packs: [CatalogPack]

    public init(version: Int = 1, packs: [CatalogPack]) {
        self.version = version
        self.packs = packs
    }

    public enum ValidationError: Error, Equatable {
        case duplicatePackID(String)
        case badChecksum(String)
        case insecureURL(String)
        case negativeItemCount(String)
    }

    public func validate() throws {
        var seen = Set<String>()
        for pack in packs {
            guard seen.insert(pack.id).inserted else { throw ValidationError.duplicatePackID(pack.id) }
            guard pack.hasValidChecksum else { throw ValidationError.badChecksum(pack.id) }
            guard pack.url.lowercased().hasPrefix("https://") else { throw ValidationError.insecureURL(pack.id) }
            guard pack.itemCount >= 0 else { throw ValidationError.negativeItemCount(pack.id) }
        }
    }

    public static func decode(from data: Data) throws -> CatalogManifest {
        let manifest = try JSONDecoder().decode(CatalogManifest.self, from: data)
        try manifest.validate()
        return manifest
    }

    /// Packs to download and remove so the device matches the manifest.
    ///
    /// Any version change downloads, so the server can roll back a bad pack.
    /// Packs that need a newer app are skipped, and an installed copy of such
    /// a pack is kept rather than removed.
    public func diff(installed: [InstalledPack], appVersion: SemanticVersion? = nil) -> CatalogDiff {
        let installedVersions = Dictionary(installed.map { ($0.id, $0.version) }, uniquingKeysWith: { first, _ in first })
        let listed = Set(packs.map(\.id))
        var download: [CatalogPack] = []
        for pack in packs {
            if let app = appVersion, !pack.isCompatible(with: app) { continue }
            if installedVersions[pack.id] != pack.version { download.append(pack) }
        }
        let remove = installedVersions.keys.filter { !listed.contains($0) }.sorted()
        return CatalogDiff(download: download, remove: remove)
    }
}
