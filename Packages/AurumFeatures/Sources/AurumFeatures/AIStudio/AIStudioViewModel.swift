import CoreImage
import SwiftUI
import AurumCore
import AurumRender
import AurumServices

/// How a feature runs right now.
public enum AIFeatureMode: Equatable {
    /// Runs on the iPhone, free, as a preview.
    case onDevice
    /// Runs on AURUM's servers for credits.
    case server
    /// Needs the server, which isn't available yet.
    case comingSoon
}

/// A background offered by the on-device background tool.
public enum AIBackgroundChoice: String, CaseIterable, Identifiable {
    case ivory, onyx, champagne, blush, softFocus

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .ivory: return String(localized: "Ivory")
        case .onyx: return String(localized: "Onyx")
        case .champagne: return String(localized: "Champagne")
        case .blush: return String(localized: "Blush")
        case .softFocus: return String(localized: "Soft focus")
        }
    }

    /// Swatch colours, top to bottom.
    public var swatch: [String] {
        switch self {
        case .ivory: return ["#F4EFE6", "#E6DDCF"]
        case .onyx: return ["#1A1A1C", "#0B0B0C"]
        case .champagne: return ["#E9D9BC", "#B89A6A"]
        case .blush: return ["#F2DEDB", "#C9A6A4"]
        case .softFocus: return ["#8A8A8A", "#4A4A4A"]
        }
    }

    var background: OnDeviceAI.Background {
        switch self {
        case .softFocus: return .blur(radius: 30)
        default: return .gradient(top: CollageRenderer.color(hex: swatch[0]), bottom: CollageRenderer.color(hex: swatch[1]))
        }
    }
}

/// Drives the AI Studio: the feature cards, the credit balance, one job at a
/// time and the job history.
///
/// Rules it keeps:
/// - The credit cost is shown before anything runs.
/// - Prompts go through `ModerationPolicy` before submission; a refused
///   prompt is never sent or charged.
/// - Credits are charged once per job id and refunded when a job fails or is
///   rejected (`CreditLedger`).
/// - Enhance, background and relight also run on device, free, as a preview.
/// - Server features show "coming soon" while no server is configured.
@MainActor
public final class AIStudioViewModel: ObservableObject {
    public enum Phase: Equatable {
        case idle
        case loading
        /// progress is nil when unknown.
        case working(progress: Double?)
        case result
        case saving
        case failed(String)
    }

    @Published public private(set) var ledger: CreditLedger
    @Published public private(set) var history: AIJobHistory
    @Published public private(set) var feature: AIFeature = .enhance
    @Published public private(set) var inputs: [PickedMedia] = []
    @Published public private(set) var sourcePreview: CGImage?
    @Published public private(set) var resultPreview: CGImage?
    @Published public private(set) var phase: Phase = .idle
    @Published public var prompt = ""
    @Published public var styleID: String?
    @Published public var maskEditor = AIMaskEditor()
    @Published public var background: AIBackgroundChoice = .ivory
    @Published public var lightDirection: OnDeviceAI.LightDirection = .left
    @Published public var lightIntensity = 0.6

    let deps: AppDependencies
    let currentEntitlement: () -> Entitlement
    let serverEnabled: Bool
    let moderation: ModerationPolicy
    private var sourceImage: CIImage?
    private var resultData: Data?
    private var activeJobID: UUID?
    private var pollTask: Task<Void, Never>?

    /// Longest side used for on-device work and previews.
    static let workingPixelSize: CGFloat = 2048
    /// Seconds between status checks, and the most checks before giving up.
    static let pollInterval: UInt64 = 2_000_000_000
    static let maxPolls = 150

    public init(deps: AppDependencies, entitlement: @escaping () -> Entitlement, serverEnabled: Bool, moderation: ModerationPolicy = .standard) {
        self.deps = deps
        self.currentEntitlement = entitlement
        self.serverEnabled = serverEnabled
        self.moderation = moderation
        self.ledger = deps.credits.ledger
        self.history = deps.credits.history
    }

    public var entitlement: Entitlement { currentEntitlement() }

    // MARK: Cards

    /// Features that also run on the iPhone.
    public nonisolated static func runsOnDevice(_ feature: AIFeature) -> Bool {
        feature == .enhance || feature == .replaceBackground || feature == .relight
    }

    /// Server features need a configured provider and the remote switch.
    public var isServerAvailable: Bool {
        serverEnabled && deps.ai.availability == .available
    }

    public nonisolated static func mode(for feature: AIFeature, serverAvailable: Bool) -> AIFeatureMode {
        if runsOnDevice(feature) { return .onDevice }
        return serverAvailable ? .server : .comingSoon
    }

    public func mode(for feature: AIFeature) -> AIFeatureMode {
        Self.mode(for: feature, serverAvailable: isServerAvailable)
    }

    public nonisolated static func title(for feature: AIFeature) -> String {
        switch feature {
        case .portrait: return String(localized: "Portrait")
        case .avatar: return String(localized: "Avatar")
        case .relight: return String(localized: "Relight")
        case .removeObject: return String(localized: "Remove object")
        case .replaceBackground: return String(localized: "Background")
        case .enhance: return String(localized: "Enhance")
        case .aiTransition: return String(localized: "AI transition")
        }
    }

    public nonisolated static func subtitle(for feature: AIFeature) -> String {
        switch feature {
        case .portrait: return String(localized: "A styled portrait of the person in your photo")
        case .avatar: return String(localized: "A profile picture in a chosen style")
        case .relight: return String(localized: "Soft, warm light on faces")
        case .removeObject: return String(localized: "Brush over what shouldn't be there")
        case .replaceBackground: return String(localized: "Keep the subject, change the scene")
        case .enhance: return String(localized: "Clearer detail, cleaner colour")
        case .aiTransition: return String(localized: "A generated move between two photos")
        }
    }

    public nonisolated static func costText(_ feature: AIFeature) -> String {
        feature.creditCost == 1 ? String(localized: "1 credit") : String(localized: "\(feature.creditCost) credits")
    }

    public var balanceText: String {
        ledger.balance == 1 ? String(localized: "1 credit") : String(localized: "\(ledger.balance) credits")
    }

    /// Members receive their monthly credits once per month, on first visit.
    public func grantMonthlyCreditsIfMember(date: Date = Date(), calendar: Calendar = .current) {
        guard entitlement == .member else { return }
        let period = CreditLedger.period(for: date, calendar: calendar)
        ledger = deps.credits.updateLedger { (ledger: inout CreditLedger) -> CreditLedger in
            ledger.grantMonthly(period: period, date: date)
            return ledger
        }
    }

    // MARK: Selection

    /// Opens a feature with fresh options.
    public func select(_ feature: AIFeature) {
        cancelPolling()
        self.feature = feature
        prompt = ""
        styleID = AIStyle.styles(for: feature).first { $0.tier == .free }?.id
        maskEditor = AIMaskEditor()
        resultPreview = nil
        resultData = nil
        phase = .idle
        if inputs.count > feature.inputCount { inputs = Array(inputs.prefix(feature.inputCount)) }
        if !inputs.isEmpty, sourcePreview == nil { Task { await loadPreview() } }
    }

    public var styles: [AIStyle] { AIStyle.styles(for: feature) }

    /// Uses picked photos as the inputs (videos are ignored).
    public func setInputs(_ picked: [PickedMedia]) async {
        inputs = Array(AtelierSupport.photosOnly(picked).prefix(feature.inputCount))
        resultPreview = nil
        resultData = nil
        maskEditor = AIMaskEditor()
        await loadPreview()
    }

    func loadPreview() async {
        guard let first = inputs.first else {
            sourcePreview = nil
            sourceImage = nil
            return
        }
        phase = .loading
        do {
            let image = try await deps.photos.image(for: first.id, maxPixelSize: Self.workingPixelSize)
            sourceImage = image
            sourcePreview = await deps.engine.cgImage(image)
            phase = .idle
        } catch {
            phase = .failed(String(localized: "This photo couldn't be opened."))
        }
    }

    /// Supplies an image directly, for tests and previews.
    func setSourceImage(_ image: CIImage) {
        sourceImage = image
    }

    // MARK: Checks

    /// A gentle explanation when the prompt can't be used, or nil.
    public var promptIssue: String? {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.count > AIJobRequest.maxPromptLength {
            return String(localized: "Keep the description under \(AIJobRequest.maxPromptLength) characters.")
        }
        if case .deny = moderation.check(trimmed) {
            return String(localized: "That description can't be used. Try describing the scene another way.")
        }
        return nil
    }

    /// The request the Generate button would send. Inputs are recorded at the
    /// size they are uploaded, within the feature's limit.
    public func makeRequest(id: UUID = UUID(), date: Date = Date()) -> AIJobRequest {
        let sources = inputs.map { item -> SourceAsset in
            SourceAsset(localIdentifier: item.id, pixelSize: Self.uploadSize(item.pixelSize, maxPixels: feature.maxInputPixels))
        }
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return AIJobRequest(
            id: id,
            feature: feature,
            styleID: feature.requiresStyle ? styleID : nil,
            prompt: feature.acceptsPrompt && !trimmed.isEmpty ? trimmed : nil,
            mask: feature.requiresMask ? maskEditor.mask : nil,
            inputs: sources,
            createdAt: date
        )
    }

    /// The size a photo is downscaled to before upload.
    nonisolated static func uploadSize(_ size: PixelSize, maxPixels: Int) -> PixelSize {
        let pixels = size.width * size.height
        guard pixels > maxPixels, pixels > 0 else { return size }
        let scale = (Double(maxPixels) / Double(pixels)).squareRoot()
        return PixelSize(width: max(1, Int((Double(size.width) * scale).rounded(.down))),
                         height: max(1, Int((Double(size.height) * scale).rounded(.down))))
    }

    /// The first thing stopping the request, in plain words, or nil.
    nonisolated static func message(for errors: [AIValidationError]) -> String? {
        guard let first = errors.first else { return nil }
        switch first {
        case .promptTooLong(_, let limit): return String(localized: "Keep the description under \(limit) characters.")
        case .promptRequired: return String(localized: "Describe the scene you'd like.")
        case .promptNotSupported: return nil
        case .maskRequired, .maskOutOfBounds: return String(localized: "Brush over what you'd like removed.")
        case .styleRequired, .unknownStyle, .styleForOtherFeature: return String(localized: "Choose a style.")
        case .wrongInputCount(let expected, _):
            return expected == 1 ? String(localized: "Choose a photo.") : String(localized: "Choose \(expected) photos.")
        case .inputTooLarge, .emptyInput: return String(localized: "This photo can't be used.")
        }
    }

    /// Why Generate is unavailable, or nil when it can run.
    public var generateIssue: String? {
        if let issue = promptIssue { return issue }
        if let message = Self.message(for: makeRequest().validate()) { return message }
        if !ledger.canAfford(feature) {
            return String(localized: "This needs \(feature.creditCost) credits. You have \(ledger.balance).")
        }
        return nil
    }

    public var isBusy: Bool {
        switch phase {
        case .loading, .working, .saving: return true
        default: return false
        }
    }

    // MARK: On device

    /// Runs the on-device version of the feature. Free; nothing leaves the iPhone.
    public func runOnDevice() async {
        guard Self.runsOnDevice(feature), let source = sourceImage else { return }
        phase = .working(progress: nil)
        let feature = self.feature
        let background = self.background.background
        let direction = lightDirection
        let intensity = lightIntensity
        let output: CIImage? = await Task.detached(priority: .userInitiated) { () -> CIImage? in
            switch feature {
            case .enhance:
                return OnDeviceAI.enhance(source)
            case .replaceBackground:
                return try? OnDeviceAI.replaceBackground(source, background: background)
            case .relight:
                let faces = (try? FaceDetector.detect(in: source)) ?? []
                return OnDeviceAI.relight(source, faces: faces, direction: direction, intensity: intensity)
            default:
                return nil
            }
        }.value
        guard let output else {
            phase = .failed(feature == .replaceBackground
                ? String(localized: "No person was found in this photo. Background works best on portraits.")
                : String(localized: "That didn't work on this photo. Please try another."))
            return
        }
        do {
            resultData = try await deps.engine.encode(output)
            resultPreview = await deps.engine.cgImage(output)
            phase = .result
            deps.analytics.track(.toolOpened(tool: "ai.\(feature.rawValue).device"))
        } catch {
            phase = .failed(String(localized: "That didn't work on this photo. Please try another."))
        }
    }

    // MARK: Server

    /// Checks, charges and submits a job, then follows it to the end.
    public func generate() async {
        guard isServerAvailable else { return }
        let request = makeRequest()
        if promptIssue != nil { return }
        guard request.validate().isEmpty else { return }
        guard moderation.check(request).isAllowed else { return }

        let now = Date()
        var spend: CreditLedger.SpendResult = .alreadySpent
        ledger = deps.credits.updateLedger { (ledger: inout CreditLedger) -> CreditLedger in
            spend = ledger.spend(for: request, date: now)
            return ledger
        }
        guard spend == .spent else {
            phase = .failed(String(localized: "This needs \(feature.creditCost) credits. You have \(ledger.balance)."))
            return
        }
        record(request, status: .queued)
        activeJobID = request.id
        phase = .working(progress: 0)
        deps.analytics.track(.toolOpened(tool: "ai.\(request.feature.rawValue).server"))
        do {
            let status = try await deps.ai.submit(request)
            await follow(jobID: request.id, initial: status)
        } catch {
            finish(jobID: request.id, status: .failed(reason: "submit"))
        }
    }

    func follow(jobID: UUID, initial: AIJobStatus) async {
        var status = initial
        var polls = 0
        while !status.isTerminal, polls < Self.maxPolls, !Task.isCancelled, activeJobID == jobID {
            update(jobID: jobID, status: status)
            try? await Task.sleep(nanoseconds: Self.pollInterval)
            polls += 1
            if let next = try? await deps.ai.status(of: jobID) { status = next }
        }
        guard activeJobID == jobID else { return }
        if !status.isTerminal { status = .failed(reason: "timeout") }
        finish(jobID: jobID, status: status)
        if case .succeeded(let refs) = status, let ref = refs.first {
            await loadResult(ref)
        }
    }

    func loadResult(_ reference: String) async {
        do {
            let data = try await deps.ai.result(reference)
            guard let image = CIImage(data: data, options: [.applyOrientationProperty: true]) else { throw AIServiceError.invalidResultReference }
            resultData = data
            resultPreview = await deps.engine.cgImage(image)
            phase = .result
        } catch {
            phase = .failed(String(localized: "The result couldn't be downloaded. Your credits are safe; please try again later."))
        }
    }

    func record(_ request: AIJobRequest, status: AIJobStatus) {
        history = deps.credits.updateHistory { (history: inout AIJobHistory) -> AIJobHistory in
            history.add(request, status: status, date: Date())
            return history
        }
    }

    func update(jobID: UUID, status: AIJobStatus) {
        history = deps.credits.updateHistory { (history: inout AIJobHistory) -> AIJobHistory in
            history.update(jobID: jobID, status: status, date: Date())
            return history
        }
        if case .running(let p) = status { phase = .working(progress: p) }
    }

    /// Records the final status and refunds a failed or rejected job.
    func finish(jobID: UUID, status: AIJobStatus) {
        update(jobID: jobID, status: status)
        ledger = deps.credits.updateLedger { (ledger: inout CreditLedger) -> CreditLedger in
            ledger.settle(jobID: jobID, status: status, date: Date())
            return ledger
        }
        activeJobID = nil
        switch status {
        case .succeeded: phase = .working(progress: 1)
        case .rejectedByModeration:
            phase = .failed(String(localized: "This request wasn't accepted. Your credits have been returned."))
        case .failed:
            phase = .failed(String(localized: "The job didn't finish. Your credits have been returned."))
        case .queued, .running: break
        }
    }

    /// Stops following and cancels the job on the server; its credits come back.
    public func cancelJob() {
        guard let id = activeJobID else { return }
        activeJobID = nil
        cancelPolling()
        Task { try? await deps.ai.cancel(jobID: id) }
        finish(jobID: id, status: .failed(reason: "cancelled"))
        phase = .idle
    }

    func cancelPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: Results

    /// Shows a finished job from the history again.
    public func reopen(_ record: AIJobHistory.Record) async {
        guard isServerAvailable, case .succeeded(let refs) = record.status, let ref = refs.first else { return }
        feature = record.request.feature
        phase = .working(progress: nil)
        await loadResult(ref)
    }

    public func discardResult() {
        resultPreview = nil
        resultData = nil
        phase = .idle
    }

    /// Saves the result to Photos and opens it in the Studio.
    public func openResultInStudio(app: AppModel) async {
        guard let data = resultData else { return }
        phase = .saving
        do {
            guard let item = try await AtelierSupport.saveAndFetch(data, photos: deps.photos) else {
                app.notice = String(localized: "Saved to Photos")
                phase = .result
                return
            }
            app.openGeneratedPhoto(item, source: "ai.\(feature.rawValue)")
        } catch {
            phase = .failed(AtelierSupport.saveFailureMessage(error))
        }
    }

    // MARK: History text

    public nonisolated static func statusText(_ status: AIJobStatus) -> String {
        switch status {
        case .queued: return String(localized: "Waiting")
        case .running: return String(localized: "Working")
        case .succeeded: return String(localized: "Ready")
        case .failed: return String(localized: "Didn't finish · refunded")
        case .rejectedByModeration: return String(localized: "Not accepted · refunded")
        }
    }
}

/// Brush strokes painted over the photo for Remove object, in normalised
/// coordinates of the photo.
public struct AIMaskEditor: Equatable {
    public private(set) var mask = AIMask()
    /// The stroke being painted, not yet in `mask`.
    public private(set) var current: [NormalizedPoint] = []
    /// Brush radius as a fraction of the photo's shorter side.
    public var radius = 0.04
    public var isEraser = false

    public init() {}

    public var canUndo: Bool { !mask.strokes.isEmpty }
    public var hasPaint: Bool { !mask.isEmpty }

    /// Adds a point to the stroke being painted, clamped to the photo.
    public mutating func extend(to point: NormalizedPoint) {
        let p = NormalizedPoint(x: min(max(point.x, 0), 1), y: min(max(point.y, 0), 1))
        if let last = current.last, abs(last.x - p.x) < 0.002, abs(last.y - p.y) < 0.002 { return }
        current.append(p)
    }

    /// Finishes the stroke being painted.
    public mutating func endStroke() {
        guard !current.isEmpty else { return }
        mask.strokes.append(AIMask.Stroke(points: current, radius: radius, isEraser: isEraser))
        current = []
    }

    public mutating func undo() {
        current = []
        if !mask.strokes.isEmpty { mask.strokes.removeLast() }
    }

    public mutating func clear() {
        current = []
        mask = AIMask()
    }
}
