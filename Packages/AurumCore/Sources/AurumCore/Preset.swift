import Foundation

/// A reusable stack of looks and adjustments, saved from an edit.
/// It carries no photo, crop or overlays, so it can be applied to any image.
public struct Preset: Codable, Equatable, Identifiable, Sendable {
    public var schemaVersion: Int
    public var id: UUID
    public var name: String
    public var operations: [EditOperation]
    public var createdAt: Date

    public init(id: UUID = UUID(), name: String, operations: [EditOperation], createdAt: Date = Date()) {
        self.schemaVersion = 1
        self.id = id
        self.name = name
        self.operations = operations
        self.createdAt = createdAt
    }

    /// Captures the enabled operations of a document.
    public init(name: String, from document: EditDocument) {
        self.init(name: name, operations: document.operations.filter(\.isEnabled))
    }

    /// Applies the preset to a document, replacing its looks and adjustments.
    /// Operation IDs are regenerated so the same preset can be applied twice.
    public func apply(to document: EditDocument) -> EditDocument {
        var doc = document
        doc.operations = operations.map { EditOperation(isEnabled: $0.isEnabled, kind: $0.kind) }
        return doc
    }
}

/// Encodes presets as shareable links: `aurum://preset/<base64url JSON>`.
///
/// The scheme comes from the brand configuration, so a rename does not
/// require code changes.
public struct PresetLinkCodec: Sendable {
    public enum LinkError: Error, Equatable {
        case wrongScheme
        case notAPresetLink
        case invalidPayload
        case tooLarge
    }

    /// Links longer than this are refused; messaging apps truncate long URLs.
    public static let maxPayloadBytes = 8_000

    public let scheme: String

    public init(scheme: String = "aurum") {
        self.scheme = scheme
    }

    public func link(for preset: Preset) throws -> URL {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let json = try encoder.encode(preset)
        let payload = Self.base64URLEncode(json)
        guard payload.utf8.count <= Self.maxPayloadBytes else { throw LinkError.tooLarge }
        guard let url = URL(string: "\(scheme)://preset/\(payload)") else { throw LinkError.invalidPayload }
        return url
    }

    public func preset(from url: URL) throws -> Preset {
        guard url.scheme?.lowercased() == scheme.lowercased() else { throw LinkError.wrongScheme }
        guard url.host == "preset" else { throw LinkError.notAPresetLink }
        let payload = url.path.hasPrefix("/") ? String(url.path.dropFirst()) : url.path
        guard payload.utf8.count <= Self.maxPayloadBytes,
              let data = Self.base64URLDecode(payload) else { throw LinkError.invalidPayload }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(Preset.self, from: data)
        } catch {
            throw LinkError.invalidPayload
        }
    }

    static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func base64URLDecode(_ string: String) -> Data? {
        var s = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = s.count % 4
        if remainder > 0 { s += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: s)
    }
}
