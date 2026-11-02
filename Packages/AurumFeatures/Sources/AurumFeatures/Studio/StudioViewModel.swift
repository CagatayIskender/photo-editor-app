import CoreImage
import SwiftUI
import AurumCore
import AurumRender
import AurumServices

/// The tools on the Studio's rail, in rail order. Phase 1 ships the first
/// five; the rest appear with a "Soon" state so the rail layout is final.
public enum StudioTool: String, CaseIterable, Identifiable {
    case looks, adjust, crop, text, stickers

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .looks: return String(localized: "Looks")
        case .adjust: return String(localized: "Adjust")
        case .crop: return String(localized: "Crop")
        case .text: return String(localized: "Text")
        case .stickers: return String(localized: "Stickers")
        }
    }
}

/// All editing state for one photo. Every change goes through `EditHistory`,
/// so undo and redo cover looks, adjustments, crop and overlays alike.
///
/// Continuous gestures (sliders, dragging an overlay) call `beginInteraction`,
/// any number of `preview` calls, then `endInteraction`, which records a
/// single undo step.
@MainActor
public final class StudioViewModel: ObservableObject, Identifiable {
    public let id = UUID()

    @Published public private(set) var history: EditHistory
    @Published public var activeTool: StudioTool? = .looks
    @Published public var selectedCollectionID: String
    @Published public var lookQuery = ""
    @Published public var selectedOverlayID: UUID?
    @Published public private(set) var thumbnails: [String: CGImage] = [:]
    @Published public private(set) var isLoading = true
    @Published public private(set) var loadFailed = false
    @Published public private(set) var favouriteLookIDs: Set<String>
    @Published public var isExportPresented = false
    @Published public var isComparing = false {
        didSet { if isComparing != oldValue { render() } }
    }

    public let scheduler: PreviewScheduler
    public let isNew: Bool
    let deps: AppDependencies
    let currentEntitlement: () -> Entitlement
    private var thumbnailProxy: CIImage?
    private var thumbnailsInFlight: Set<String> = []
    private var isInteracting = false

    /// Longest side of the on-screen proxy and of look thumbnails, in pixels.
    static let previewPixelSize: CGFloat = 1600
    static let thumbnailPixelSize: CGFloat = 220

    public init(document: EditDocument, isNew: Bool, deps: AppDependencies, entitlement: @escaping () -> Entitlement) {
        self.history = EditHistory(initial: document)
        self.isNew = isNew
        self.deps = deps
        self.currentEntitlement = entitlement
        self.scheduler = PreviewScheduler(engine: deps.engine)
        self.favouriteLookIDs = deps.preferences.favouriteLookIDs
        let vibes = deps.preferences.vibes
        self.selectedCollectionID = vibes.first(where: { id in deps.catalog.collections.contains { $0.id == id } })
            ?? deps.catalog.collections.first?.id ?? ""
    }

    public var document: EditDocument { history.current }
    public var catalog: LookCatalog { deps.catalog }
    public var entitlement: Entitlement { currentEntitlement() }

    // MARK: Loading

    /// Loads the photo, then applies (in order of preference) a shared preset,
    /// the look chosen in the Salon, or a suggested free look.
    public func load(startingLook: String?, preset: Preset?) async {
        do {
            let proxy = try await deps.photos.image(for: document.source.localIdentifier, maxPixelSize: Self.previewPixelSize)
            await loaded(proxy: proxy, startingLook: startingLook, preset: preset)
        } catch {
            isLoading = false
            loadFailed = true
        }
    }

    /// Separated from `load` so tests can supply an image directly.
    func loaded(proxy: CIImage, startingLook: String?, preset: Preset?) async {
        scheduler.setProxy(proxy)
        thumbnailProxy = RenderEngine.proxy(of: proxy, maxPixelSize: Self.thumbnailPixelSize)
        if isNew {
            var doc = document
            if let preset {
                doc = preset.apply(to: doc)
            } else if let startingLook, catalog.look(id: startingLook) != nil {
                doc.applyLook(startingLook)
            } else {
                let stats = await deps.engine.stats(of: thumbnailProxy ?? proxy)
                if let look = LookSuggestion.suggest(for: stats, vibes: deps.preferences.vibes, catalog: catalog) {
                    doc.applyLook(look.id)
                }
            }
            // The starting look is where the user begins, not an edit to undo.
            history = EditHistory(initial: doc)
            if let id = doc.lookApplications.last?.lookID, let look = catalog.look(id: id) {
                selectedCollectionID = look.collection
            }
        }
        isLoading = false
        render()
    }

    // MARK: Editing

    /// Applies a discrete change as one undo step.
    public func edit(_ change: (inout EditDocument) -> Void) {
        var doc = document
        change(&doc)
        if isInteracting {
            history.update(doc)
        } else {
            history.commit(doc)
        }
        render()
    }

    public func beginInteraction() {
        guard !isInteracting else { return }
        isInteracting = true
        history.beginTransaction()
    }

    public func endInteraction() {
        guard isInteracting else { return }
        isInteracting = false
        history.commit(document)
        render()
    }

    public var canUndo: Bool { history.canUndo }
    public var canRedo: Bool { history.canRedo }

    public func undo() {
        history.undo()
        render()
    }

    public func redo() {
        history.redo()
        render()
    }

    func render() {
        scheduler.request(document, compareOriginal: isComparing)
    }

    // MARK: Looks

    public var activeLook: LookApplication? {
        document.activeLookIndex.flatMap { i -> LookApplication? in
            if case .look(let l) = document.operations[i].kind { return l }
            return nil
        }
    }

    public var activeLookRecipe: LookRecipe? {
        activeLook.flatMap { catalog.look(id: $0.lookID) }
    }

    /// Looks shown in the strip: search results, favourites, or the selected collection.
    public var visibleLooks: [LookRecipe] {
        let query = lookQuery.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty { return catalog.search(query) }
        if selectedCollectionID == Self.favouritesID {
            return catalog.looks.filter { favouriteLookIDs.contains($0.id) }
        }
        return catalog.looks(in: selectedCollectionID)
    }

    public static let favouritesID = "favourites"

    /// Tapping a thumbnail. Tapping the active look again removes it.
    /// Premium looks can be tried freely; membership is asked for only at export.
    public func selectLook(_ lookID: String) {
        if activeLook?.lookID == lookID {
            edit { doc in
                if let i = doc.activeLookIndex { doc.removeOperation(id: doc.operations[i].id) }
            }
            return
        }
        let intensity = activeLook?.intensity ?? 0.8
        edit { $0.applyLook(lookID, intensity: intensity) }
        let premium = catalog.look(id: lookID)?.tier == .member
        deps.analytics.track(.lookApplied(lookID: lookID, premium: premium))
    }

    /// Swiping across the photo moves to the next or previous look.
    public func cycleLook(by offset: Int) {
        let next: LookRecipe?
        if let current = activeLook?.lookID {
            next = catalog.neighbour(of: current, offset: offset)
        } else {
            let looks = catalog.looks(in: selectedCollectionID)
            next = offset >= 0 ? looks.first : looks.last
        }
        guard let next else { return }
        selectLook(next.id)
        selectedCollectionID = next.collection
    }

    public func setLookIntensity(_ value: Double) {
        edit { $0.setActiveLookIntensity(value) }
    }

    public func setRefine(_ refine: RefineOverrides) {
        edit { $0.setActiveLookRefine(refine) }
    }

    public func toggleFavourite(_ lookID: String) {
        deps.preferences.toggleFavourite(lookID)
        favouriteLookIDs = deps.preferences.favouriteLookIDs
    }

    /// Requests a thumbnail of the user's photo with a look applied. Cached by the engine.
    public func requestThumbnail(for lookID: String) {
        guard thumbnails[lookID] == nil, !thumbnailsInFlight.contains(lookID), let proxy = thumbnailProxy else { return }
        thumbnailsInFlight.insert(lookID)
        let engine = deps.engine
        let assetID = document.source.localIdentifier
        Task {
            let image = await engine.thumbnail(lookID: lookID, assetID: assetID, proxy: proxy)
            thumbnailsInFlight.remove(lookID)
            if let image { thumbnails[lookID] = image }
        }
    }

    // MARK: Adjust

    public func adjustment(_ control: AdjustmentControl) -> Double {
        document.adjustments[control]
    }

    public func setAdjustment(_ control: AdjustmentControl, _ value: Double) {
        edit { $0.adjustments[control] = value }
    }

    public func resetAdjustments() {
        edit { $0.adjustments = AdjustmentSet() }
    }

    // MARK: Crop

    public func setAspect(_ aspect: AspectPreset) {
        edit { doc in
            var crop = CropSpec.centred(aspect: aspect, source: doc.source.pixelSize)
            crop.quarterTurns = doc.crop.quarterTurns
            crop.straightenDegrees = doc.crop.straightenDegrees
            crop.flipHorizontal = doc.crop.flipHorizontal
            crop.flipVertical = doc.crop.flipVertical
            doc.crop = crop
        }
    }

    public func rotateQuarterTurn() {
        edit { doc in
            doc.crop.quarterTurns = (doc.crop.quarterTurns + 1) % 4
        }
    }

    public func flipHorizontal() {
        edit { $0.crop.flipHorizontal.toggle() }
    }

    public func setStraighten(_ degrees: Double) {
        edit { $0.crop.straightenDegrees = (-45.0...45.0).clamp(degrees) }
    }

    public func resetCrop() {
        edit { $0.crop = .identity }
    }

    // MARK: Overlays

    public var selectedOverlay: Overlay? {
        selectedOverlayID.flatMap { id in document.overlays.first { $0.id == id } }
    }

    @discardableResult
    public func addText(_ text: String = String(localized: "Your words")) -> UUID {
        let overlay = Overlay(content: .text(TextOverlay(text: text)))
        edit { $0.addOverlay(overlay) }
        selectedOverlayID = overlay.id
        return overlay.id
    }

    @discardableResult
    public func addSticker(_ sticker: StickerDefinition) -> UUID {
        let overlay = Overlay(content: .sticker(StickerOverlay(stickerID: sticker.id, tier: sticker.tier)), scale: 0.6)
        edit { $0.addOverlay(overlay) }
        selectedOverlayID = overlay.id
        return overlay.id
    }

    public func updateOverlay(_ overlay: Overlay) {
        edit { $0.updateOverlay(overlay) }
    }

    /// Changes the selected overlay's text settings.
    public func updateSelectedText(_ change: (inout TextOverlay) -> Void) {
        guard var overlay = selectedOverlay, case .text(var text) = overlay.content else { return }
        change(&text)
        overlay.content = .text(text)
        updateOverlay(overlay)
    }

    public func removeSelectedOverlay() {
        guard let id = selectedOverlayID else { return }
        edit { $0.removeOverlay(id: id) }
        selectedOverlayID = nil
    }

    // MARK: Presets and drafts

    /// Saves the current looks and adjustments as a reusable preset.
    public func saveAsPreset(named name: String) async -> Preset? {
        let preset = Preset(name: name, from: document)
        do {
            try await deps.presets.add(preset)
            return preset
        } catch {
            return nil
        }
    }

    public func shareLink(for preset: Preset) -> URL? {
        try? PresetLinkCodec(scheme: deps.brand.urlScheme).link(for: preset)
    }

    /// Saves the edit to the Vault.
    public func saveDraft() async {
        // A new photo the user never touched (only the suggested look) is not saved.
        guard !isNew || history.canUndo else { return }
        let thumb = scheduler.image.flatMap { Self.jpegThumbnail(of: $0) }
        try? await deps.drafts.save(document, thumbnailJPEG: thumb)
    }

    static func jpegThumbnail(of image: CGImage, maxSide: CGFloat = 480) -> Data? {
        let ui = UIImage(cgImage: image)
        let scale = min(1, maxSide / max(ui.size.width, ui.size.height))
        let size = CGSize(width: ui.size.width * scale, height: ui.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let small = UIGraphicsImageRenderer(size: size, format: format).image { _ in ui.draw(in: CGRect(origin: .zero, size: size)) }
        return small.jpegData(compressionQuality: 0.8)
    }

    // MARK: Export

    public func makeExportModel() -> ExportViewModel {
        ExportViewModel(document: document, deps: deps, entitlement: entitlement)
    }

    public func toolOpened(_ tool: StudioTool) {
        activeTool = (activeTool == tool) ? nil : tool
        if activeTool != nil { deps.analytics.track(.toolOpened(tool: tool.rawValue)) }
        if tool != .text && tool != .stickers { selectedOverlayID = nil }
    }
}
