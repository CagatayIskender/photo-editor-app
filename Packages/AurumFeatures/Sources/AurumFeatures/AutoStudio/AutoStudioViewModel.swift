import CoreImage
import SwiftUI
import AurumCore
import AurumRender
import AurumServices

/// A background offered by the Background tool.
public enum AutoBackgroundChoice: String, CaseIterable, Identifiable {
    case ivory, onyx, champagne, blush, softFocus, photo

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .ivory: return String(localized: "Ivory")
        case .onyx: return String(localized: "Onyx")
        case .champagne: return String(localized: "Champagne")
        case .blush: return String(localized: "Blush")
        case .softFocus: return String(localized: "Soft focus")
        case .photo: return String(localized: "Your photo")
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
        case .photo: return ["#3A3A3C", "#1C1C1E"]
        }
    }

    /// What goes behind the person; nil for `.photo` until a photo is chosen.
    func background(photo: CIImage?) -> OnDeviceImaging.Background? {
        switch self {
        case .softFocus: return .blur(radius: 30)
        case .photo: return photo.map { OnDeviceImaging.Background.image($0) }
        default: return .gradient(top: CollageRenderer.color(hex: swatch[0]), bottom: CollageRenderer.color(hex: swatch[1]))
        }
    }
}

/// Drives the Auto Studio: one photo, analysed once on open for suggested
/// fixes, and a set of tools that all run on the iPhone with Vision
/// detection and classic Core Image processing. Nothing is generated and
/// nothing is uploaded.
///
/// Every tool previews for free. Keeping a result that uses a members' tool
/// or look (Retouch, members' Portrait Looks) asks for membership, the same
/// moment as an export anywhere else in AURUM.
@MainActor
public final class AutoStudioViewModel: ObservableObject {
    public enum Phase: Equatable {
        case idle
        case loading
        case working
        case result
        case saving
        case failed(String)
    }

    @Published public private(set) var feature: AutoFeature = .enhance
    @Published public private(set) var photo: PickedMedia?
    @Published public private(set) var sourcePreview: CGImage?
    @Published public private(set) var resultPreview: CGImage?
    @Published public private(set) var phase: Phase = .idle
    @Published public private(set) var analysis: SceneAnalysis?
    @Published public private(set) var suggestions: [AutoSuggestion] = []
    @Published public private(set) var isAnalysing = false
    @Published public var enhanceOptions = OnDeviceImaging.EnhanceOptions.all
    @Published public var blurAmount = 0.6
    @Published public var maskEditor = BrushMaskEditor()
    @Published public var background: AutoBackgroundChoice = .ivory
    @Published public private(set) var hasBackgroundPhoto = false
    @Published public var lightDirection: OnDeviceImaging.LightDirection = .left
    @Published public var lightIntensity = 0.6
    @Published public var retouchStrength = 0.8
    @Published public var portraitLookID: String = PortraitLook.library[0].id
    @Published public var isPaywallPresented = false

    let deps: AppDependencies
    let currentEntitlement: () -> Entitlement
    /// Used off the main thread for measuring, analysis and Object Remove.
    let ciContext = CIContext(options: [.cacheIntermediates: false])
    private var sourceImage: CIImage?
    private var personMask: CIImage?
    private var backgroundImage: CIImage?
    private var resultData: Data?
    /// Membership needed to keep the result on screen.
    public private(set) var resultTier: Tier = .free

    /// Longest side used for processing and previews.
    static let workingPixelSize: CGFloat = 2048

    public init(deps: AppDependencies, entitlement: @escaping () -> Entitlement) {
        self.deps = deps
        self.currentEntitlement = entitlement
    }

    public var entitlement: Entitlement { currentEntitlement() }

    // MARK: Text

    public nonisolated static func title(for feature: AutoFeature) -> String {
        switch feature {
        case .enhance: return String(localized: "Auto Enhance")
        case .portraitBlur: return String(localized: "Portrait Blur")
        case .replaceBackground: return String(localized: "Background")
        case .relight: return String(localized: "Relight")
        case .retouch: return String(localized: "Skin Retouch")
        case .removeObject: return String(localized: "Remove Object")
        case .portraitLooks: return String(localized: "Portrait Looks")
        }
    }

    public nonisolated static func subtitle(for feature: AutoFeature) -> String {
        switch feature {
        case .enhance: return String(localized: "Tone, colour, horizon and red eye in one tap")
        case .portraitBlur: return String(localized: "A soft, blurred background behind people")
        case .replaceBackground: return String(localized: "Keep the subject, change what's behind")
        case .relight: return String(localized: "Soft, warm light on faces")
        case .retouch: return String(localized: "Natural smoothing, placed on each face")
        case .removeObject: return String(localized: "Brush over what shouldn't be there")
        case .portraitLooks: return String(localized: "Curated looks made for faces")
        }
    }

    /// A suggestion's button title, such as "Straighten 2.3°".
    public nonisolated static func title(for suggestion: AutoSuggestion) -> String {
        switch suggestion.kind {
        case .fixRedEye: return String(localized: "Fix red eye")
        case .straighten:
            let tilt = abs(suggestion.degrees ?? 0)
            let degrees = tilt.formatted(.number.precision(.fractionLength(1)))
            return String(localized: "Straighten \(degrees)°")
        case .brightenFaces: return String(localized: "Brighten faces")
        case .blurBackground: return String(localized: "Blur background")
        case .balanceColour: return String(localized: "Balance colour")
        case .smoothSkin: return String(localized: "Smooth skin")
        case .enhance: return String(localized: "Enhance")
        }
    }

    // MARK: Membership

    /// The tier of a result made with `feature` (and, for Portrait Looks, `lookID`).
    public nonisolated static func tier(of feature: AutoFeature, lookID: String?) -> Tier {
        if feature == .portraitLooks, let lookID, let look = PortraitLook.look(id: lookID) {
            return look.tier
        }
        return feature.tier
    }

    public nonisolated static func requiresMembership(feature: AutoFeature, lookID: String?, entitlement: Entitlement) -> Bool {
        entitlement == .free && tier(of: feature, lookID: lookID) == .member
    }

    /// True when keeping the current result needs membership.
    public var resultRequiresMembership: Bool {
        resultTier == .member && entitlement == .free
    }

    // MARK: Photo

    /// Opens a tool with fresh results; the photo and its analysis stay.
    public func select(_ feature: AutoFeature) {
        self.feature = feature
        maskEditor = BrushMaskEditor()
        resultPreview = nil
        resultData = nil
        phase = .idle
    }

    /// Uses the first picked photo (videos are ignored) and analyses it.
    public func setPhoto(_ picked: [PickedMedia]) async {
        guard let first = AtelierSupport.photosOnly(picked).first else { return }
        photo = first
        resultPreview = nil
        resultData = nil
        maskEditor = BrushMaskEditor()
        analysis = nil
        suggestions = []
        personMask = nil
        isAnalysing = false
        phase = .loading
        do {
            let image = try await deps.photos.image(for: first.id, maxPixelSize: Self.workingPixelSize)
            sourceImage = image
            sourcePreview = await deps.engine.cgImage(image)
            phase = .idle
        } catch {
            sourceImage = nil
            sourcePreview = nil
            phase = .failed(String(localized: "This photo couldn't be opened."))
            return
        }
        await analyse()
    }

    /// Supplies an image directly, for tests and previews.
    func setSourceImage(_ image: CIImage) {
        sourceImage = image
    }

    /// Runs Vision once on the photo and ranks the one-tap fixes.
    func analyse() async {
        guard let source = sourceImage else { return }
        isAnalysing = true
        let context = ciContext
        let result = await Task.detached(priority: .userInitiated) { () -> SceneAnalyzer.Result in
            SceneAnalyzer.analyze(source, context: context)
        }.value
        // The photo may have changed while Vision was busy.
        guard sourceImage === source else { return }
        analysis = result.analysis
        personMask = result.personMask
        suggestions = AutoSuggestions.rank(result.analysis)
        isAnalysing = false
    }

    /// Chooses the photo shown behind the person in Background.
    public func setBackgroundPhoto(_ picked: [PickedMedia]) async {
        guard let first = AtelierSupport.photosOnly(picked).first else { return }
        do {
            backgroundImage = try await deps.photos.image(for: first.id, maxPixelSize: Self.workingPixelSize)
            hasBackgroundPhoto = true
            background = .photo
        } catch {
            phase = .failed(String(localized: "This photo couldn't be opened."))
        }
    }

    // MARK: Suggestions

    /// The Enhance parts a suggestion switches on, or nil if it uses another tool.
    public nonisolated static func enhanceOptions(for kind: AutoSuggestion.Kind) -> OnDeviceImaging.EnhanceOptions? {
        var options = OnDeviceImaging.EnhanceOptions.none
        switch kind {
        case .fixRedEye: options.redEye = true
        case .straighten: options.straighten = true
        case .balanceColour: options.whiteBalance = true
        case .enhance: options = .all
        case .brightenFaces, .blurBackground, .smoothSkin: return nil
        }
        return options
    }

    /// Opens the suggestion's tool with matching settings and runs it.
    public func apply(_ suggestion: AutoSuggestion) async {
        select(suggestion.feature)
        if let options = Self.enhanceOptions(for: suggestion.kind) {
            enhanceOptions = options
        }
        switch suggestion.kind {
        case .brightenFaces:
            lightDirection = .front
            lightIntensity = 0.5
        case .blurBackground:
            blurAmount = 0.6
        case .smoothSkin:
            retouchStrength = 0.8
        default:
            break
        }
        deps.analytics.track(.toolOpened(tool: "auto.suggestion.\(suggestion.kind.rawValue)"))
        await run()
    }

    // MARK: Running

    public var isBusy: Bool {
        switch phase {
        case .loading, .working, .saving: return true
        default: return false
        }
    }

    /// Why Preview is unavailable, or nil when it can run.
    public var runIssue: String? {
        if photo == nil && sourceImage == nil { return String(localized: "Choose a photo.") }
        if feature.requiresMask && maskEditor.mask.isEmpty { return String(localized: "Brush over what you'd like removed.") }
        if feature == .replaceBackground && background == .photo && backgroundImage == nil {
            return String(localized: "Choose the photo to put behind.")
        }
        return nil
    }

    /// A request for the work done off the main thread.
    struct Job: @unchecked Sendable {
        var feature: AutoFeature
        var source: CIImage
        var context: CIContext
        var analysis: SceneAnalysis?
        var personMask: CIImage?
        var enhanceOptions: OnDeviceImaging.EnhanceOptions
        var blurAmount: Double
        var background: OnDeviceImaging.Background?
        var lightDirection: OnDeviceImaging.LightDirection
        var lightIntensity: Double
        var retouchStrength: Double
        var look: PortraitLook?
        var mask: BrushMask
    }

    enum JobFailure: Error {
        case noPerson, noFace, emptyMask, failed
    }

    /// Runs the current tool on the photo. Free; nothing leaves the iPhone.
    public func run() async {
        guard let source = sourceImage, runIssue == nil else { return }
        phase = .working
        let job = Job(
            feature: feature,
            source: source,
            context: ciContext,
            analysis: analysis,
            personMask: personMask,
            enhanceOptions: enhanceOptions,
            blurAmount: blurAmount,
            background: background.background(photo: backgroundImage),
            lightDirection: lightDirection,
            lightIntensity: lightIntensity,
            retouchStrength: retouchStrength,
            look: PortraitLook.look(id: portraitLookID),
            mask: maskEditor.mask
        )
        let outcome: Result<CIImage, JobFailure> = await Task.detached(priority: .userInitiated) { () -> Result<CIImage, JobFailure> in
            Self.process(job)
        }.value
        switch outcome {
        case .failure(let failure):
            phase = .failed(Self.message(for: failure, feature: job.feature))
        case .success(let output):
            do {
                resultData = try await deps.engine.encode(output)
                resultPreview = await deps.engine.cgImage(output)
                resultTier = Self.tier(of: job.feature, lookID: job.look?.id)
                phase = .result
                deps.analytics.track(.toolOpened(tool: "auto.\(job.feature.rawValue)"))
            } catch {
                phase = .failed(Self.message(for: .failed, feature: job.feature))
            }
        }
    }

    nonisolated static func message(for failure: JobFailure, feature: AutoFeature) -> String {
        switch failure {
        case .noPerson: return String(localized: "No person was found in this photo. This tool works best on portraits.")
        case .noFace: return String(localized: "No face was found in this photo.")
        case .emptyMask: return String(localized: "Brush over what you'd like removed.")
        case .failed: return String(localized: "That didn't work on this photo. Please try another.")
        }
    }

    /// The work itself, off the main thread.
    nonisolated static func process(_ job: Job) -> Result<CIImage, JobFailure> {
        let source = job.source
        func faces() -> [FaceGeometry] {
            if let found = job.analysis?.faces { return found }
            return (try? FaceDetector.detect(in: source)) ?? []
        }
        func person() -> CIImage? {
            job.personMask ?? (try? OnDeviceImaging.personMask(for: source))
        }
        switch job.feature {
        case .enhance:
            let horizon = job.analysis?.horizonDegrees
            return .success(OnDeviceImaging.enhance(source, options: job.enhanceOptions, horizonDegrees: horizon, context: job.context))
        case .portraitBlur:
            guard let matte = person() else { return .failure(.noPerson) }
            guard let out = try? OnDeviceImaging.portraitBlur(source, amount: job.blurAmount, mask: matte) else { return .failure(.failed) }
            return .success(out)
        case .replaceBackground:
            guard let matte = person() else { return .failure(.noPerson) }
            guard let background = job.background else { return .failure(.failed) }
            guard let out = try? OnDeviceImaging.replaceBackground(source, background: background, mask: matte) else { return .failure(.failed) }
            return .success(out)
        case .relight:
            return .success(OnDeviceImaging.relight(source, faces: faces(), direction: job.lightDirection, intensity: job.lightIntensity, mask: job.personMask))
        case .retouch:
            let found = faces()
            guard !found.isEmpty else { return .failure(.noFace) }
            return .success(OnDeviceImaging.naturalRetouch(source, faces: found, strength: job.retouchStrength))
        case .removeObject:
            guard !job.mask.isEmpty else { return .failure(.emptyMask) }
            guard let out = try? ObjectRemover.remove(job.mask, from: source, context: job.context) else { return .failure(.failed) }
            return .success(out)
        case .portraitLooks:
            guard let look = job.look else { return .failure(.failed) }
            return .success(OnDeviceImaging.portraitLook(source, look: look, faces: faces(), personMask: person()))
        }
    }

    // MARK: Results

    public func discardResult() {
        resultPreview = nil
        resultData = nil
        phase = .idle
    }

    /// Saves the result to Photos and opens it in the Studio. A result made
    /// with a members' tool or look asks for membership first.
    public func openResultInStudio(app: AppModel) async {
        guard let data = resultData else { return }
        if resultRequiresMembership {
            isPaywallPresented = true
            deps.analytics.track(.paywallViewed(trigger: "autoStudio"))
            return
        }
        phase = .saving
        do {
            guard let item = try await AtelierSupport.saveAndFetch(data, photos: deps.photos) else {
                app.notice = String(localized: "Saved to Photos")
                phase = .result
                return
            }
            app.openGeneratedPhoto(item, source: "auto.\(feature.rawValue)")
        } catch {
            phase = .failed(AtelierSupport.saveFailureMessage(error))
        }
    }
}

/// Brush strokes painted over the photo for Remove Object, in normalised
/// coordinates of the photo.
public struct BrushMaskEditor: Equatable {
    public private(set) var mask = BrushMask()
    /// The stroke being painted, not yet in `mask`.
    public private(set) var current: [AurumCore.NormalizedPoint] = []
    /// Brush radius as a fraction of the photo's shorter side.
    public var radius = 0.04
    public var isEraser = false

    public init() {}

    public var canUndo: Bool { !mask.strokes.isEmpty }
    public var hasPaint: Bool { !mask.isEmpty }

    /// Adds a point to the stroke being painted, clamped to the photo.
    public mutating func extend(to point: AurumCore.NormalizedPoint) {
        let p = AurumCore.NormalizedPoint(x: min(max(point.x, 0), 1), y: min(max(point.y, 0), 1))
        if let last = current.last, abs(last.x - p.x) < 0.002, abs(last.y - p.y) < 0.002 { return }
        current.append(p)
    }

    /// Finishes the stroke being painted.
    public mutating func endStroke() {
        guard !current.isEmpty else { return }
        mask.strokes.append(BrushMask.Stroke(points: current, radius: radius, isEraser: isEraser))
        current = []
    }

    public mutating func undo() {
        current = []
        if !mask.strokes.isEmpty { mask.strokes.removeLast() }
    }

    public mutating func clear() {
        current = []
        mask = BrushMask()
    }
}
