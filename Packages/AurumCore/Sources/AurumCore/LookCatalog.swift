import Foundation

/// The full set of looks and collections, loaded from `catalog.json`.
public struct LookCatalog: Codable, Equatable, Sendable {
    public var version: Int
    public var collections: [LookCollection]
    public var looks: [LookRecipe]

    public init(version: Int = 1, collections: [LookCollection], looks: [LookRecipe]) {
        self.version = version
        self.collections = collections
        self.looks = looks
    }

    public enum LoadError: Error, Equatable {
        case duplicateLookID(String)
        case unknownCollection(lookID: String, collection: String)
    }

    /// Decodes and validates a catalogue.
    public static func decode(from data: Data) throws -> LookCatalog {
        let catalog = try JSONDecoder().decode(LookCatalog.self, from: data)
        try catalog.validate()
        return catalog
    }

    /// Checks ids are unique and every look belongs to a known collection.
    public func validate() throws {
        var seen = Set<String>()
        let collectionIDs = Set(collections.map(\.id))
        for look in looks {
            guard seen.insert(look.id).inserted else { throw LoadError.duplicateLookID(look.id) }
            guard collectionIDs.contains(look.collection) else {
                throw LoadError.unknownCollection(lookID: look.id, collection: look.collection)
            }
        }
    }

    public func look(id: String) -> LookRecipe? {
        looks.first { $0.id == id }
    }

    public func looks(in collectionID: String) -> [LookRecipe] {
        looks.filter { $0.collection == collectionID }
    }

    /// The look `offset` places away from `lookID` within its collection,
    /// wrapping around. Powers swipe-to-cycle on the Studio canvas.
    public func neighbour(of lookID: String, offset: Int) -> LookRecipe? {
        guard let current = look(id: lookID) else { return nil }
        let siblings = looks(in: current.collection)
        guard let index = siblings.firstIndex(where: { $0.id == lookID }), !siblings.isEmpty else { return nil }
        let count = siblings.count
        let next = ((index + offset) % count + count) % count
        return siblings[next]
    }

    // MARK: Search

    /// Words that should find each other, for example "90s" finds "retro".
    static let synonyms: [String: [String]] = [
        "90s": ["retro", "vhs", "camcorder"],
        "y2k": ["2000s", "chrome", "glossy"],
        "warm": ["golden", "sunlit", "amber"],
        "cool": ["blue", "cold", "frost"],
        "bw": ["monochrome", "black and white", "noir"],
        "sparkle": ["glitter", "bling", "diamond", "shimmer"],
        "dreamy": ["haze", "soft", "glow"],
        "moody": ["dark", "noir", "shadow"],
        "film": ["analog", "35mm", "grain"]
    ]

    /// Ranks looks against a free-text query. Name matches rank above
    /// collection and tag matches. Returns all looks for an empty query.
    public func search(_ query: String) -> [LookRecipe] {
        let terms = Self.expand(query)
        guard !terms.isEmpty else { return looks }
        let names = Dictionary(collections.map { ($0.id, $0.name.lowercased()) }, uniquingKeysWith: { first, _ in first })
        let scored: [(LookRecipe, Int)] = looks.compactMap { look -> (LookRecipe, Int)? in
            let name = look.name.lowercased()
            let collection = names[look.collection] ?? look.collection
            let tags = look.tags.map { $0.lowercased() }
            var score = 0
            for term in terms {
                if name.contains(term) { score += 3 }
                if collection.contains(term) { score += 2 }
                if tags.contains(where: { $0.contains(term) }) { score += 1 }
            }
            return score > 0 ? (look, score) : nil
        }
        return scored
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.name < $1.0.name }
            .map(\.0)
    }

    static func expand(_ query: String) -> [String] {
        let base = query
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        var out = base
        for word in base {
            if let more = synonyms[word] { out.append(contentsOf: more) }
            for (key, values) in synonyms where values.contains(word) { out.append(key) }
        }
        var seen = Set<String>()
        return out.filter { seen.insert($0).inserted }
    }
}
