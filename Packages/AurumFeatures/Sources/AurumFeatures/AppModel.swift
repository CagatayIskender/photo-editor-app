import CoreImage
import SwiftUI
import AurumCore
import AurumDesign
import AurumRender
import AurumServices

/// Everything a screen needs from outside itself. The app builds the live
/// set; previews and tests build one from mocks with `AppDependencies.sample()`.
public struct AppDependencies {
    public var catalog: LookCatalog
    public var brand: Brand
    public var engine: RenderEngine
    public var photos: PhotoLibraryService
    public var drafts: DraftStore
    public var presets: PresetStore
    public var purchases: PurchaseService
    public var analytics: Analytics
    public var remoteConfig: RemoteConfig
    public var preferences: Preferences
    /// Templates, intro and outro styles and the music catalogue.
    public var content: ContentLibrary

    public init(catalog: LookCatalog, brand: Brand, engine: RenderEngine, photos: PhotoLibraryService, drafts: DraftStore, presets: PresetStore, purchases: PurchaseService, analytics: Analytics, remoteConfig: RemoteConfig, preferences: Preferences, content: ContentLibrary = ContentLibrary.load(from: .main)) {
        self.catalog = catalog
        self.brand = brand
        self.engine = engine
        self.photos = photos
        self.drafts = drafts
        self.presets = presets
        self.purchases = purchases
        self.analytics = analytics
        self.remoteConfig = remoteConfig
        self.preferences = preferences
        self.content = content
    }

    /// Mock services with generated sample photos, for previews and tests.
    @MainActor
    public static func sample(catalog: LookCatalog, entitlement: Entitlement = .free, directory: URL = FileManager.default.temporaryDirectory.appendingPathComponent("aurum-sample-\(UUID().uuidString)")) -> AppDependencies {
        AppDependencies(
            catalog: catalog,
            brand: .default,
            engine: RenderEngine(catalog: catalog),
            photos: SamplePhotoLibrary(),
            drafts: FileDraftStore(directory: directory.appendingPathComponent("Drafts"), catalog: catalog),
            presets: PresetStore(fileURL: directory.appendingPathComponent("presets.json")),
            purchases: MockPurchaseService(entitlement: entitlement),
            analytics: RecordingAnalytics(),
            remoteConfig: BundledRemoteConfig(),
            preferences: Preferences(defaults: UserDefaults(suiteName: "aurum.sample.\(UUID().uuidString)") ?? .standard),
            content: ContentLibrary.load(from: .main)
        )
    }
}

/// The top-level tabs. The centre "+" is an action, not a tab.
public enum AppTab: Hashable {
    case salon, vault
}

/// Full-screen flows other than the Studio: the video editor, templates,
/// the camera and the media picker that starts a video.
public enum CreateFlow: Identifiable {
    case video(VideoEditorViewModel)
    case templates
    case camera
    case mediaPicker

    public var id: String {
        switch self {
        case .video(let model): return "video-\(model.id.uuidString)"
        case .templates: return "templates"
        case .camera: return "camera"
        case .mediaPicker: return "mediaPicker"
        }
    }
}

/// What covers the tabs. One full-screen cover shows whichever is set, so
/// moving from the camera to the Studio (or from Templates to the video
/// editor) replaces one cover with the next instead of stacking them.
public enum AppCover: Identifiable {
    case studio(StudioViewModel)
    case flow(CreateFlow)

    public var id: String {
        switch self {
        case .studio(let model): return "studio-\(model.id.uuidString)"
        case .flow(let flow): return flow.id
        }
    }
}

/// App-wide state: membership, onboarding, navigation into the Studio and
/// the Vault's drafts. Screens read it from the environment.
@MainActor
public final class AppModel: ObservableObject {
    public let deps: AppDependencies

    @Published public private(set) var entitlement: Entitlement = .free
    @Published public private(set) var hasCompletedOnboarding: Bool
    @Published public private(set) var config: RemoteConfigValues = .defaults
    @Published public var selectedTab: AppTab = .salon
    @Published public var isPickerPresented = false
    @Published public var studio: StudioViewModel?
    /// The video editor, templates, camera or media picker, when open.
    @Published public var flow: CreateFlow?
    @Published public private(set) var drafts: [DraftSummary] = []
    @Published public private(set) var presets: [Preset] = []
    /// A look chosen in the Salon before a photo was picked.
    @Published public var queuedLookID: String?
    /// A preset opened from a shared link, applied to the next photo picked.
    @Published public var queuedPreset: Preset?
    @Published public var notice: String?

    public init(deps: AppDependencies) {
        self.deps = deps
        self.hasCompletedOnboarding = deps.preferences.hasCompletedOnboarding
        self.entitlement = deps.purchases.entitlement
    }

    public var catalog: LookCatalog { deps.catalog }

    /// Called once at launch.
    public func start() async {
        deps.purchases.onEntitlementChange = { [weak self] entitlement in
            Task { @MainActor in self?.entitlement = entitlement }
        }
        await deps.purchases.start()
        config = await deps.remoteConfig.values()
        await refreshVault()
    }

    // MARK: Onboarding

    public func completeOnboarding(vibes: [String]) {
        deps.preferences.vibes = vibes
        deps.preferences.hasCompletedOnboarding = true
        hasCompletedOnboarding = true
        deps.analytics.track(.onboardingCompleted(vibes: vibes))
    }

    // MARK: Opening the Studio

    /// Starts editing a photo from the library. The Studio opens at once and
    /// shows the photo as soon as the proxy loads, with a suggested look applied.
    public func openPhoto(_ item: LibraryPhoto) {
        isPickerPresented = false
        let document = EditDocument(source: SourceAsset(localIdentifier: item.id, pixelSize: item.pixelSize))
        let model = makeStudio(document: document, isNew: true)
        studio = model
        deps.analytics.track(.photoImported(source: "library"))
        let lookID = queuedLookID
        let preset = queuedPreset
        queuedLookID = nil
        queuedPreset = nil
        Task { await model.load(startingLook: lookID, preset: preset) }
    }

    /// Reopens a saved draft exactly as it was left.
    public func openDraft(id: UUID) async {
        do {
            let document = try await deps.drafts.load(id: id)
            let model = makeStudio(document: document, isNew: false)
            studio = model
            await model.load(startingLook: nil, preset: nil)
        } catch {
            notice = String(localized: "This draft could not be opened.")
        }
    }

    public func closeStudio() {
        studio = nil
        Task { await refreshVault() }
    }

    /// Opens a photo just taken with the camera, wearing the look it was shot with.
    public func openCapturedPhoto(_ item: LibraryPhoto, lookID: String?) {
        flow = nil
        let document = EditDocument(source: SourceAsset(localIdentifier: item.id, pixelSize: item.pixelSize))
        let model = makeStudio(document: document, isNew: true)
        studio = model
        deps.analytics.track(.photoImported(source: "camera"))
        Task { await model.load(startingLook: lookID, preset: nil) }
    }

    func makeStudio(document: EditDocument, isNew: Bool) -> StudioViewModel {
        StudioViewModel(document: document, isNew: isNew, deps: deps, entitlement: { [weak self] in self?.entitlement ?? .free })
    }

    /// The "+" button and the Salon's call to action.
    public func startCreating(withLook lookID: String? = nil) {
        if let lookID { queuedLookID = lookID }
        isPickerPresented = true
    }

    // MARK: Video, templates and camera

    /// The Studio or a create flow, for the root view's single full-screen cover.
    public var cover: AppCover? {
        if let studio { return .studio(studio) }
        return flow.map { .flow($0) }
    }

    /// Called when the system dismisses the cover on its own.
    public func coverDismissed() {
        if case .video(let model)? = flow { model.close() }
        studio = nil
        flow = nil
    }

    /// Picks photos and clips, then opens them in the video editor.
    public func startVideo() {
        flow = .mediaPicker
        deps.analytics.track(.toolOpened(tool: "video.new"))
    }

    public func openTemplates() {
        flow = .templates
        deps.analytics.track(.toolOpened(tool: "templates"))
    }

    public func openCamera() {
        flow = .camera
        deps.analytics.track(.toolOpened(tool: "camera"))
    }

    /// Opens the video editor on a project built from picked media, a template or the camera.
    public func openVideo(_ project: VideoProject, source: String) {
        let model = VideoEditorViewModel(project: project, deps: deps, entitlement: { [weak self] in self?.entitlement ?? .free })
        flow = .video(model)
        deps.analytics.track(.photoImported(source: "video.\(source)"))
    }

    public func closeVideoEditor() {
        if case .video(let model)? = flow { model.close() }
        flow = nil
    }

    public func closeFlow() {
        flow = nil
    }

    // MARK: Vault

    public func refreshVault() async {
        drafts = await deps.drafts.list()
        presets = await deps.presets.all()
    }

    public func deleteDraft(id: UUID) async {
        try? await deps.drafts.delete(id: id)
        await refreshVault()
    }

    public func deletePreset(id: UUID) async {
        try? await deps.presets.remove(id: id)
        await refreshVault()
    }

    /// Applies a saved preset to the next photo the user picks.
    public func usePreset(_ preset: Preset) {
        queuedPreset = preset
        isPickerPresented = true
    }

    // MARK: Links

    /// Handles `aurum://preset/...` links. Returns false for links it does not understand.
    @discardableResult
    public func handle(url: URL) -> Bool {
        let codec = PresetLinkCodec(scheme: deps.brand.urlScheme)
        guard let preset = try? codec.preset(from: url) else {
            if url.scheme == deps.brand.urlScheme { notice = String(localized: "That link isn't a preset AURUM can open.") }
            return false
        }
        queuedPreset = preset
        notice = String(localized: "“\(preset.name)” is ready. Pick a photo to use it.")
        isPickerPresented = true
        return true
    }

    // MARK: Membership

    /// Membership state changed by the paywall.
    public func membershipDidChange() {
        entitlement = deps.purchases.entitlement
    }
}
