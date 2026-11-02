import Foundation
import AurumCore

/// A saved draft as listed in the Vault.
public struct DraftSummary: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let title: String
    public let modifiedAt: Date
    public let thumbnailURL: URL?

    public init(id: UUID, title: String, modifiedAt: Date, thumbnailURL: URL?) {
        self.id = id
        self.title = title
        self.modifiedAt = modifiedAt
        self.thumbnailURL = thumbnailURL
    }
}

public protocol DraftStore: Sendable {
    func save(_ document: EditDocument, thumbnailJPEG: Data?) async throws
    func load(id: UUID) async throws -> EditDocument
    func list() async -> [DraftSummary]
    func delete(id: UUID) async throws
}

/// Stores each draft as `<id>.json` plus `<id>.jpg` in a directory
/// (Application Support/Drafts in the app). The original photo is never copied.
public actor FileDraftStore: DraftStore {
    private let directory: URL
    private let catalog: LookCatalog?

    public init(directory: URL, catalog: LookCatalog? = nil) {
        self.directory = directory
        self.catalog = catalog
    }

    /// The default location inside Application Support.
    public static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Drafts", isDirectory: true)
    }

    private func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func jsonURL(_ id: UUID) -> URL { directory.appendingPathComponent("\(id.uuidString).json") }
    private func thumbURL(_ id: UUID) -> URL { directory.appendingPathComponent("\(id.uuidString).jpg") }

    public func save(_ document: EditDocument, thumbnailJPEG: Data?) async throws {
        try ensureDirectory()
        var doc = document
        doc.modifiedAt = Date()
        try doc.encoded().write(to: jsonURL(doc.id), options: .atomic)
        if let thumbnailJPEG {
            try thumbnailJPEG.write(to: thumbURL(doc.id), options: .atomic)
        }
    }

    public func load(id: UUID) async throws -> EditDocument {
        try EditDocument.decode(from: Data(contentsOf: jsonURL(id)))
    }

    public func list() async -> [DraftSummary] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return [] }
        let summaries: [DraftSummary] = files
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> DraftSummary? in
                guard let data = try? Data(contentsOf: url), let doc = try? EditDocument.decode(from: data) else { return nil }
                let thumb = thumbURL(doc.id)
                return DraftSummary(
                    id: doc.id,
                    title: title(for: doc),
                    modifiedAt: doc.modifiedAt,
                    thumbnailURL: FileManager.default.fileExists(atPath: thumb.path) ? thumb : nil
                )
            }
        return summaries.sorted { $0.modifiedAt > $1.modifiedAt }
    }

    /// Names a draft after its looks, for example "Linen + Graphite".
    func title(for doc: EditDocument) -> String {
        let names = doc.lookApplications.compactMap { catalog?.look(id: $0.lookID)?.name }
        return names.isEmpty ? "Untitled edit" : names.joined(separator: " + ")
    }

    public func delete(id: UUID) async throws {
        try? FileManager.default.removeItem(at: thumbURL(id))
        try FileManager.default.removeItem(at: jsonURL(id))
    }
}
