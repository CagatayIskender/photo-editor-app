import Foundation
import AurumCore

/// The user's saved presets, stored as one JSON file.
public actor PresetStore {
    private let fileURL: URL
    private var cache: [Preset]?

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("presets.json")
    }

    public func all() -> [Preset] {
        if let cache { return cache }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let loaded = (try? Data(contentsOf: fileURL)).flatMap { try? decoder.decode([Preset].self, from: $0) } ?? []
        cache = loaded
        return loaded
    }

    public func add(_ preset: Preset) throws {
        var list = all()
        list.insert(preset, at: 0)
        try write(list)
    }

    public func remove(id: UUID) throws {
        try write(all().filter { $0.id != id })
    }

    private func write(_ list: [Preset]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(list).write(to: fileURL, options: .atomic)
        cache = list
    }
}
