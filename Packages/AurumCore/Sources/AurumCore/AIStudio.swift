import Foundation

// The client-side contract for AURUM's server AI features (Phase 3).
// Everything here is plain data and rules, so it can be validated, tested and
// shown in the UI before a request ever leaves the device.

/// A server-side AI feature in the AI Studio.
public enum AIFeature: String, Codable, CaseIterable, Sendable {
    /// Stylised portrait of the person in the photo.
    case portrait
    /// Profile picture in a chosen style.
    case avatar
    /// Re-lights the scene from a prompt such as "golden hour".
    case relight
    /// Removes what the user brushed over.
    case removeObject
    /// Keeps the subject and generates a new background from a prompt.
    case replaceBackground
    /// Sharpens, denoises and restores detail.
    case enhance
    /// A generated transition between two clips.
    case aiTransition

    /// Credits charged when a job is accepted. Refunded if it fails or is
    /// rejected by moderation.
    public var creditCost: Int {
        switch self {
        case .enhance: return 1
        case .removeObject, .relight: return 2
        case .replaceBackground: return 3
        case .portrait, .avatar: return 4
        case .aiTransition: return 5
        }
    }

    /// The user must brush or outline what to change.
    public var requiresMask: Bool { self == .removeObject }

    /// The user must pick one of the feature's `AIStyle`s.
    public var requiresStyle: Bool { self == .portrait || self == .avatar }

    /// A text prompt is accepted (optional unless `requiresPrompt`).
    public var acceptsPrompt: Bool {
        switch self {
        case .portrait, .avatar, .relight, .replaceBackground: return true
        case .removeObject, .enhance, .aiTransition: return false
        }
    }

    /// The feature cannot run without a prompt.
    public var requiresPrompt: Bool { self == .replaceBackground }

    /// Number of photos or frames the job needs.
    public var inputCount: Int { self == .aiTransition ? 2 : 1 }

    /// Largest input, in total pixels, the server accepts. The app downsizes
    /// before upload.
    public var maxInputPixels: Int {
        switch self {
        case .enhance: return 4_000_000
        case .aiTransition: return 1920 * 1080
        case .portrait, .avatar: return 8_000_000
        case .relight, .removeObject, .replaceBackground: return 12_000_000
        }
    }

    /// Key for the localised feature name.
    public var displayNameKey: String { "ai.feature.\(rawValue)" }
}

/// A style offered for portraits and avatars.
public struct AIStyle: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var feature: AIFeature
    public var tier: Tier

    public init(id: String, name: String, feature: AIFeature, tier: Tier) {
        self.id = id
        self.name = name
        self.feature = feature
        self.tier = tier
    }

    /// Styles built into the app. The server may offer more through the catalogue.
    public static let library: [AIStyle] = [
        AIStyle(id: "portrait.studio", name: "Studio", feature: .portrait, tier: .free),
        AIStyle(id: "portrait.editorial", name: "Editorial", feature: .portrait, tier: .member),
        AIStyle(id: "portrait.oil", name: "Oil Portrait", feature: .portrait, tier: .member),
        AIStyle(id: "portrait.noir", name: "Silver Screen", feature: .portrait, tier: .member),
        AIStyle(id: "avatar.clean", name: "Clean", feature: .avatar, tier: .free),
        AIStyle(id: "avatar.gilded", name: "Gilded", feature: .avatar, tier: .member),
        AIStyle(id: "avatar.illustrated", name: "Illustrated", feature: .avatar, tier: .member),
        AIStyle(id: "avatar.clay", name: "Soft Clay", feature: .avatar, tier: .member)
    ]

    public static func styles(for feature: AIFeature, in styles: [AIStyle] = library) -> [AIStyle] {
        styles.filter { $0.feature == feature }
    }
}

/// What the user marked on the photo, in normalised coordinates of the input.
public struct AIMask: Codable, Equatable, Sendable {
    /// A brush stroke. `radius` is a fraction of the input's shorter side.
    public struct Stroke: Codable, Equatable, Sendable {
        public var points: [NormalizedPoint]
        public var radius: Double
        /// Erases earlier strokes instead of painting.
        public var isEraser: Bool

        public init(points: [NormalizedPoint], radius: Double = 0.03, isEraser: Bool = false) {
            self.points = points
            self.radius = (0.001...0.5).clamp(radius)
            self.isEraser = isEraser
        }
    }

    /// Closed outlines (lasso). Each needs at least three points.
    public var polygons: [[NormalizedPoint]]
    public var strokes: [Stroke]

    public init(polygons: [[NormalizedPoint]] = [], strokes: [Stroke] = []) {
        self.polygons = polygons
        self.strokes = strokes
    }

    /// True when nothing would be painted: no usable outline and no painting stroke.
    public var isEmpty: Bool {
        !polygons.contains { $0.count >= 3 } && !strokes.contains { !$0.isEraser && !$0.points.isEmpty }
    }

    /// Every point lies inside the unit square.
    public var isInBounds: Bool {
        func inside(_ p: NormalizedPoint) -> Bool { (0.0...1.0).contains(p.x) && (0.0...1.0).contains(p.y) }
        return polygons.allSatisfy { $0.allSatisfy(inside) } && strokes.allSatisfy { $0.points.allSatisfy(inside) }
    }
}

public enum AIValidationError: Error, Equatable, Sendable {
    case promptTooLong(length: Int, limit: Int)
    case promptRequired
    case promptNotSupported
    case maskRequired
    case maskOutOfBounds
    case styleRequired
    case unknownStyle(String)
    case styleForOtherFeature(String)
    case wrongInputCount(expected: Int, actual: Int)
    case inputTooLarge(pixels: Int, limit: Int)
    case emptyInput
}

/// A request for one AI job. `id` doubles as the idempotency key for the
/// server and for the credit ledger.
public struct AIJobRequest: Codable, Equatable, Identifiable, Sendable {
    public static let maxPromptLength = 300

    public var id: UUID
    public var feature: AIFeature
    public var styleID: String?
    public var prompt: String?
    public var mask: AIMask?
    /// The photos (or frames) the job runs on, already within `maxInputPixels`.
    public var inputs: [SourceAsset]
    /// Whole seconds, so the request round-trips exactly through JSON.
    public var createdAt: Date

    public init(id: UUID = UUID(), feature: AIFeature, styleID: String? = nil, prompt: String? = nil, mask: AIMask? = nil, inputs: [SourceAsset], createdAt: Date = Date()) {
        self.id = id
        self.feature = feature
        self.styleID = styleID
        self.prompt = prompt
        self.mask = mask
        self.inputs = inputs
        self.createdAt = createdAt.wholeSeconds
    }

    /// The prompt without surrounding whitespace, or nil if there is none.
    public var trimmedPrompt: String? {
        guard let p = prompt?.trimmingCharacters(in: .whitespacesAndNewlines), !p.isEmpty else { return nil }
        return p
    }

    /// Everything wrong with the request, in a stable order. Empty means valid.
    public func validate(styles: [AIStyle] = AIStyle.library) -> [AIValidationError] {
        var errors: [AIValidationError] = []

        if let p = trimmedPrompt {
            if !feature.acceptsPrompt {
                errors.append(.promptNotSupported)
            } else if p.count > Self.maxPromptLength {
                errors.append(.promptTooLong(length: p.count, limit: Self.maxPromptLength))
            }
        } else if feature.requiresPrompt {
            errors.append(.promptRequired)
        }

        if feature.requiresMask {
            if let mask, !mask.isEmpty {
                if !mask.isInBounds { errors.append(.maskOutOfBounds) }
            } else {
                errors.append(.maskRequired)
            }
        }

        if let styleID {
            if let style = styles.first(where: { $0.id == styleID }) {
                if style.feature != feature { errors.append(.styleForOtherFeature(styleID)) }
            } else {
                errors.append(.unknownStyle(styleID))
            }
        } else if feature.requiresStyle {
            errors.append(.styleRequired)
        }

        if inputs.count != feature.inputCount {
            errors.append(.wrongInputCount(expected: feature.inputCount, actual: inputs.count))
        }
        for input in inputs {
            let pixels = input.pixelSize.width * input.pixelSize.height
            if input.pixelSize.width <= 0 || input.pixelSize.height <= 0 {
                errors.append(.emptyInput)
            } else if pixels > feature.maxInputPixels {
                errors.append(.inputTooLarge(pixels: pixels, limit: feature.maxInputPixels))
            }
        }
        return errors
    }

    public var isValid: Bool { validate().isEmpty }
}

/// Where a job is. Encoded as a tagged union: `{"type": "running", "progress": 0.4}`.
public enum AIJobStatus: Equatable, Sendable {
    case queued
    /// progress is 0...1.
    case running(progress: Double)
    /// References to the results on the server (usually one image or clip).
    case succeeded(resultRefs: [String])
    case failed(reason: String)
    case rejectedByModeration(reason: String)

    /// The job will not change any more.
    public var isTerminal: Bool {
        switch self {
        case .queued, .running: return false
        case .succeeded, .failed, .rejectedByModeration: return true
        }
    }

    /// Credits spent on a job ending in this state go back to the user.
    public var refundsCredits: Bool {
        switch self {
        case .failed, .rejectedByModeration: return true
        case .queued, .running, .succeeded: return false
        }
    }
}

extension AIJobStatus: Codable {
    enum CodingKeys: String, CodingKey { case type, progress, resultRefs, reason }
    enum Tag: String, Codable { case queued, running, succeeded, failed, rejectedByModeration }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Tag.self, forKey: .type) {
        case .queued: self = .queued
        case .running: self = .running(progress: try c.decodeIfPresent(Double.self, forKey: .progress) ?? 0)
        case .succeeded: self = .succeeded(resultRefs: try c.decodeIfPresent([String].self, forKey: .resultRefs) ?? [])
        case .failed: self = .failed(reason: try c.decodeIfPresent(String.self, forKey: .reason) ?? "")
        case .rejectedByModeration: self = .rejectedByModeration(reason: try c.decodeIfPresent(String.self, forKey: .reason) ?? "")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .queued:
            try c.encode(Tag.queued, forKey: .type)
        case .running(let p):
            try c.encode(Tag.running, forKey: .type)
            try c.encode(p, forKey: .progress)
        case .succeeded(let refs):
            try c.encode(Tag.succeeded, forKey: .type)
            try c.encode(refs, forKey: .resultRefs)
        case .failed(let reason):
            try c.encode(Tag.failed, forKey: .type)
            try c.encode(reason, forKey: .reason)
        case .rejectedByModeration(let reason):
            try c.encode(Tag.rejectedByModeration, forKey: .type)
            try c.encode(reason, forKey: .reason)
        }
    }
}

// MARK: - Credits

/// The user's AI credits. A pure value type: the app persists it and the
/// server stays the authority; this mirrors the rules so the UI never
/// double-charges or forgets a refund.
public struct CreditLedger: Codable, Equatable, Sendable {
    public static let monthlyMemberGrant = 100
    public static let historyLimit = 200

    public struct Entry: Codable, Equatable, Sendable {
        public enum Kind: String, Codable, Sendable { case grant, purchase, spend, refund }
        public var kind: Kind
        /// Signed: positive adds credits, negative spends them.
        public var amount: Int
        public var jobID: UUID?
        /// Grant period ("2026-11") or store transaction id.
        public var reference: String?
        public var date: Date

        public init(kind: Kind, amount: Int, jobID: UUID? = nil, reference: String? = nil, date: Date) {
            self.kind = kind
            self.amount = amount
            self.jobID = jobID
            self.reference = reference
            self.date = date.wholeSeconds
        }
    }

    public enum SpendResult: Equatable, Sendable {
        case spent
        /// The job was already charged; nothing changed.
        case alreadySpent
        case insufficientCredits(balance: Int, cost: Int)
    }

    public private(set) var balance: Int
    /// Newest last, bounded to `historyLimit`.
    public private(set) var history: [Entry]
    /// Credits charged per job, kept apart from the bounded history so
    /// idempotency never expires.
    private var charges: [UUID: Int]
    private var refunded: Set<UUID>
    private var grantedPeriods: Set<String>
    private var purchases: Set<String>

    public init(balance: Int = 0) {
        self.balance = max(0, balance)
        self.history = []
        self.charges = [:]
        self.refunded = []
        self.grantedPeriods = []
        self.purchases = []
    }

    public func canAfford(_ cost: Int) -> Bool { balance >= max(0, cost) }
    public func canAfford(_ feature: AIFeature) -> Bool { canAfford(feature.creditCost) }

    public func hasCharged(jobID: UUID) -> Bool { charges[jobID] != nil }

    /// The period key for a monthly grant, such as "2026-11", in the calendar's time zone.
    public static func period(for date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month], from: date)
        let year = c.year ?? 0
        let month = c.month ?? 0
        return month < 10 ? "\(year)-0\(month)" : "\(year)-\(month)"
    }

    /// Adds the members' monthly credits once per period. Returns false if
    /// that period was already granted.
    @discardableResult
    public mutating func grantMonthly(period: String, amount: Int = CreditLedger.monthlyMemberGrant, date: Date) -> Bool {
        guard amount > 0, grantedPeriods.insert(period).inserted else { return false }
        balance += amount
        append(Entry(kind: .grant, amount: amount, reference: period, date: date))
        return true
    }

    /// Adds purchased credits once per store transaction.
    @discardableResult
    public mutating func purchase(credits: Int, transactionID: String, date: Date) -> Bool {
        guard credits > 0, purchases.insert(transactionID).inserted else { return false }
        balance += credits
        append(Entry(kind: .purchase, amount: credits, reference: transactionID, date: date))
        return true
    }

    /// Charges a job once. Calling again with the same job id changes nothing.
    @discardableResult
    public mutating func spend(_ cost: Int, jobID: UUID, date: Date) -> SpendResult {
        if charges[jobID] != nil { return .alreadySpent }
        let cost = max(0, cost)
        guard balance >= cost else { return .insufficientCredits(balance: balance, cost: cost) }
        balance -= cost
        charges[jobID] = cost
        append(Entry(kind: .spend, amount: -cost, jobID: jobID, date: date))
        return .spent
    }

    @discardableResult
    public mutating func spend(for request: AIJobRequest, date: Date) -> SpendResult {
        spend(request.feature.creditCost, jobID: request.id, date: date)
    }

    /// Gives back what a job was charged, once. Returns false if the job was
    /// never charged or already refunded.
    @discardableResult
    public mutating func refund(jobID: UUID, date: Date) -> Bool {
        guard let cost = charges[jobID], !refunded.contains(jobID) else { return false }
        refunded.insert(jobID)
        balance += cost
        append(Entry(kind: .refund, amount: cost, jobID: jobID, date: date))
        return true
    }

    /// Applies a job's new status: refunds when it failed or was rejected.
    @discardableResult
    public mutating func settle(jobID: UUID, status: AIJobStatus, date: Date) -> Bool {
        status.refundsCredits ? refund(jobID: jobID, date: date) : false
    }

    private mutating func append(_ entry: Entry) {
        history.append(entry)
        if history.count > Self.historyLimit { history.removeFirst(history.count - Self.historyLimit) }
    }
}

// MARK: - Moderation

/// A quick on-device check of prompts before they are sent. The server runs
/// the real moderation; this only saves a round trip and a refund for the
/// obvious cases.
public struct ModerationPolicy: Equatable, Sendable {
    public enum Category: String, Codable, CaseIterable, Sendable {
        case weapons, explicit, violence
    }

    public enum Verdict: Equatable, Sendable {
        case allow
        case deny(category: Category, term: String)

        public var isAllowed: Bool { self == .allow }
    }

    /// Terms per category, already normalised. Multi-word terms match whole word sequences.
    public var blockedTerms: [Category: [String]]

    public init(blockedTerms: [Category: [String]]) {
        self.blockedTerms = blockedTerms.mapValues { $0.map(Self.normalize) }
    }

    /// A deliberately short, generic list. The server keeps the full one.
    public static let standard = ModerationPolicy(blockedTerms: [
        .weapons: ["gun", "rifle", "firearm", "explosive", "bomb"],
        .explicit: ["nude", "naked", "nsfw", "explicit", "porn"],
        .violence: ["gore", "bloody", "corpse", "beheaded"]
    ])

    /// Lowercased, diacritics and width folded, so "NÚDE" and "nude" match.
    public static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
    }

    static func words(_ text: String) -> [String] {
        normalize(text)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    /// Checks a prompt. Matches whole words (and simple plurals), so
    /// "bombastic" is fine but "bombs" is not.
    public func check(_ prompt: String) -> Verdict {
        let tokens = Self.words(prompt)
        guard !tokens.isEmpty else { return .allow }
        for category in Category.allCases {
            for term in blockedTerms[category] ?? [] {
                let termWords = Self.words(term)
                guard !termWords.isEmpty, termWords.count <= tokens.count else { continue }
                for start in 0...(tokens.count - termWords.count) {
                    var matched = true
                    for (k, word) in termWords.enumerated() {
                        let token = tokens[start + k]
                        if token != word && token != word + "s" && token != word + "es" { matched = false; break }
                    }
                    if matched { return .deny(category: category, term: term) }
                }
            }
        }
        return .allow
    }

    /// Validation and moderation together, for the Generate button.
    public func check(_ request: AIJobRequest) -> Verdict {
        guard let prompt = request.trimmedPrompt else { return .allow }
        return check(prompt)
    }
}

// MARK: - Provider and history

/// The backend that runs AI jobs. The app's implementation talks to AURUM's
/// server; tests use a fake.
public protocol AIProvider: Sendable {
    /// Starts a job. Submitting the same request id twice must not start a second job.
    func submit(_ request: AIJobRequest) async throws -> AIJobStatus
    func status(of jobID: UUID) async throws -> AIJobStatus
    func cancel(jobID: UUID) async throws
}

/// Recent AI jobs, newest first, bounded.
public struct AIJobHistory: Codable, Equatable, Sendable {
    public static let defaultLimit = 50

    public struct Record: Codable, Equatable, Identifiable, Sendable {
        public var request: AIJobRequest
        public var status: AIJobStatus
        public var updatedAt: Date

        public var id: UUID { request.id }

        public init(request: AIJobRequest, status: AIJobStatus, updatedAt: Date) {
            self.request = request
            self.status = status
            self.updatedAt = updatedAt.wholeSeconds
        }
    }

    public private(set) var records: [Record]
    public let limit: Int

    public init(limit: Int = AIJobHistory.defaultLimit) {
        self.records = []
        self.limit = max(1, limit)
    }

    /// Adds a job at the front. Re-adding an existing id moves it to the front.
    public mutating func add(_ request: AIJobRequest, status: AIJobStatus = .queued, date: Date) {
        records.removeAll { $0.id == request.id }
        records.insert(Record(request: request, status: status, updatedAt: date), at: 0)
        if records.count > limit { records.removeLast(records.count - limit) }
    }

    /// Updates a job's status in place. Returns false for an unknown job.
    @discardableResult
    public mutating func update(jobID: UUID, status: AIJobStatus, date: Date) -> Bool {
        guard let i = records.firstIndex(where: { $0.id == jobID }) else { return false }
        records[i].status = status
        records[i].updatedAt = date.wholeSeconds
        return true
    }

    public func record(id: UUID) -> Record? { records.first { $0.id == id } }

    /// Jobs still queued or running, to poll.
    public var pending: [Record] { records.filter { !$0.status.isTerminal } }

    public mutating func remove(id: UUID) { records.removeAll { $0.id == id } }
}

extension Date {
    /// The date truncated to whole seconds, so it survives JSON exactly.
    var wholeSeconds: Date {
        Date(timeIntervalSince1970: timeIntervalSince1970.rounded(.down))
    }
}
