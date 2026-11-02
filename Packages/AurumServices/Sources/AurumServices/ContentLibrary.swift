import Foundation
import AurumCore

/// Templates, intro/outro presets and the music catalogue shipped in the app
/// bundle. Phase 3 adds CDN delivery with the same file formats.
public struct ContentLibrary: Sendable {
    public var templates: [TemplateDefinition]
    public var bookends: [BookendPreset]
    public var music: [MusicTrack]

    public init(templates: [TemplateDefinition] = [], bookends: [BookendPreset] = [], music: [MusicTrack] = []) {
        self.templates = templates
        self.bookends = bookends
        self.music = music
    }

    /// Loads `templates.json`, `bookends.json` and `music.json` from a bundle.
    /// Missing files give empty lists rather than a crash.
    public static func load(from bundle: Bundle) -> ContentLibrary {
        func decode<T: Decodable>(_ name: String, as type: T.Type) -> T? {
            guard let url = bundle.url(forResource: name, withExtension: "json"),
                  let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(T.self, from: data)
        }
        return ContentLibrary(
            templates: decode("templates", as: [TemplateDefinition].self) ?? [],
            bookends: decode("bookends", as: [BookendPreset].self) ?? [],
            music: decode("music", as: [MusicTrack].self) ?? []
        )
    }
}
