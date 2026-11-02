import AVFoundation
import SwiftUI
import AurumCore
import AurumDesign
import AurumRender
import AurumServices

/// The tools on the video editor's rail, in rail order. Split and Reverse act
/// at once; the others open a sheet.
public enum VideoTool: String, CaseIterable, Identifiable {
    case trim, split, speed, reverse, volume, transition, music, text, effects, look, bookends, aspect

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .trim: return String(localized: "Trim")
        case .split: return String(localized: "Split")
        case .speed: return String(localized: "Speed")
        case .reverse: return String(localized: "Reverse")
        case .volume: return String(localized: "Volume")
        case .transition: return String(localized: "Transition")
        case .music: return String(localized: "Music")
        case .text: return String(localized: "Text")
        case .effects: return String(localized: "Effects")
        case .look: return String(localized: "Look")
        case .bookends: return String(localized: "Intro/Outro")
        case .aspect: return String(localized: "Aspect")
        }
    }

    /// Tools that change the project immediately instead of opening a sheet.
    public var isAction: Bool { self == .split || self == .reverse }

    /// Tools that need a clip selected.
    public var needsClip: Bool {
        switch self {
        case .trim, .split, .speed, .reverse, .volume, .transition: return true
        default: return false
        }
    }
}

/// The transitions offered in the editor. AI transitions arrive in Phase 3.
public enum TransitionChoice: String, CaseIterable, Identifiable {
    case cut, dissolve, dipToBlack, slide, zoom

    public var id: String { rawValue }

    public static let defaultDuration: Seconds = 0.5

    public init(_ transition: AurumCore.Transition) {
        switch transition {
        case .cut: self = .cut
        case .dissolve, .ai: self = .dissolve
        case .dipToBlack: self = .dipToBlack
        case .slide: self = .slide
        case .zoom: self = .zoom
        }
    }

    public func transition(duration: Seconds = TransitionChoice.defaultDuration) -> AurumCore.Transition {
        switch self {
        case .cut: return .cut
        case .dissolve: return .dissolve(duration: duration)
        case .dipToBlack: return .dipToBlack(duration: duration)
        case .slide: return .slide(duration: duration)
        case .zoom: return .zoom(duration: duration)
        }
    }

    public var title: String {
        switch self {
        case .cut: return String(localized: "Cut")
        case .dissolve: return String(localized: "Dissolve")
        case .dipToBlack: return String(localized: "Dip to black")
        case .slide: return String(localized: "Slide")
        case .zoom: return String(localized: "Zoom")
        }
    }
}

/// All editing state for one video. Every change goes through
/// `Undoable<VideoProject>`, so undo covers clips, music, layers and grade.
///
/// The preview is an `AVPlayer` whose item is rebuilt from the project a
/// moment after the last edit, so a run of quick changes costs one rebuild.
/// Continuous gestures (sliders, trim handles) call `beginInteraction`, any
/// number of edits, then `endInteraction`, which records one undo step.
@MainActor
public final class VideoEditorViewModel: ObservableObject, Identifiable {
    public let id = UUID()

    @Published public private(set) var history: Undoable<VideoProject>
    @Published public var activeTool: VideoTool?
    @Published public var selectedClipID: UUID?
    @Published public var selectedLayerID: UUID?
    @Published public var selectedEffectID: UUID?
    @Published public private(set) var playhead: Seconds = 0
    @Published public private(set) var isPlaying = false
    @Published public private(set) var isBuilding = false
    @Published public private(set) var previewFailed = false
    @Published public var isExportPresented = false

    public let player = AVPlayer()
    let deps: AppDependencies
    let media: VideoMediaSource
    let currentEntitlement: () -> Entitlement
    /// False in tests, so editing never touches AVFoundation playback.
    let buildsPreview: Bool

    private var isInteracting = false
    private var rebuildTask: Task<Void, Never>?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var isClosed = false

    /// Longest side of the preview render, in pixels.
    static let previewPixelSize = 1280
    /// Wait after the last edit before rebuilding the preview.
    static let rebuildDelay: UInt64 = 350_000_000

    public init(project: VideoProject, deps: AppDependencies, media: VideoMediaSource? = nil, entitlement: @escaping () -> Entitlement, buildsPreview: Bool = true) {
        self.history = Undoable(project)
        self.deps = deps
        self.media = media ?? LibraryMediaSource(photos: deps.photos, content: deps.content)
        self.currentEntitlement = entitlement
        self.buildsPreview = buildsPreview
        self.selectedClipID = project.clips.first?.id
        if buildsPreview {
            observePlayer()
            scheduleRebuild(immediately: true)
        }
    }

    public var project: VideoProject { history.current }
    public var catalog: LookCatalog { deps.catalog }
    public var content: ContentLibrary { deps.content }
    public var entitlement: Entitlement { currentEntitlement() }
    public var duration: Seconds { project.duration }

    // MARK: Editing

    /// Applies a change as one undo step (or as part of the open interaction).
    public func edit(_ change: (inout VideoProject) -> Void) {
        var p = project
        change(&p)
        guard p != project else { return }
        p.modifiedAt = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        if isInteracting {
            history.update(p)
        } else {
            history.commit(p)
        }
        projectDidChange()
    }

    public func beginInteraction() {
        guard !isInteracting else { return }
        isInteracting = true
    }

    public func endInteraction() {
        guard isInteracting else { return }
        isInteracting = false
        history.commit(project)
        projectDidChange()
    }

    /// A slider binding helper, matching the Studio's.
    func binding(_ get: @escaping () -> Double, _ set: @escaping (Double) -> Void) -> Binding<Double> {
        Binding(get: get, set: set)
    }

    func sliderEditing(_ isEditing: Bool) {
        if isEditing { beginInteraction() } else { endInteraction() }
    }

    public var canUndo: Bool { history.canUndo }
    public var canRedo: Bool { history.canRedo }

    public func undo() {
        history.undo()
        projectDidChange()
    }

    public func redo() {
        history.redo()
        projectDidChange()
    }

    private func projectDidChange() {
        if let id = selectedClipID, !project.clips.contains(where: { $0.id == id }) {
            selectedClipID = project.clips.first?.id
        }
        if let id = selectedLayerID, !project.layers.contains(where: { $0.id == id }) {
            selectedLayerID = nil
        }
        if let id = selectedEffectID, !project.effects.contains(where: { $0.id == id }) {
            selectedEffectID = nil
        }
        playhead = min(playhead, max(0, project.duration - 0.01))
        scheduleRebuild()
    }

    // MARK: Clips

    public var selectedClip: Clip? {
        selectedClipID.flatMap { id in project.clips.first { $0.id == id } }
    }

    public var selectedClipIndex: Int? {
        selectedClipID.flatMap { id in project.clips.firstIndex { $0.id == id } }
    }

    public func selectClip(_ id: UUID?) {
        selectedClipID = id
    }

    /// Sets the selected clip's in and out points, in source seconds.
    public func trimSelected(start: Seconds, end: Seconds) {
        guard let id = selectedClipID else { return }
        edit { $0.updateClip(id: id) { $0.trim(start: start, end: end) } }
    }

    /// Cuts the clip under the playhead in two. Returns false when the
    /// playhead is too close to either end of the clip.
    @discardableResult
    public func splitAtPlayhead() -> Bool {
        var p = project
        guard p.split(at: playhead) else { return false }
        if let (index, _) = p.clip(at: playhead) { selectedClipID = p.clips[index].id }
        edit { $0 = p }
        return true
    }

    public func moveSelectedClip(by offset: Int) {
        guard let index = selectedClipIndex else { return }
        let destination = index + offset
        guard project.clips.indices.contains(destination) else { return }
        edit { $0.moveClip(from: index, to: destination) }
    }

    public func moveClip(from source: Int, to destination: Int) {
        edit { $0.moveClip(from: source, to: destination) }
    }

    /// Deletes the selected clip. The last clip can't be deleted; a video needs one.
    public func deleteSelectedClip() {
        guard let id = selectedClipID, project.clips.count > 1 else { return }
        let index = selectedClipIndex ?? 0
        edit { p in
            p.removeClip(id: id)
            // The new first clip never starts with a transition.
            if !p.clips.isEmpty { p.clips[0].transitionIn = .cut }
        }
        selectedClipID = project.clips[min(index, project.clips.count - 1)].id
    }

    public var canDeleteClip: Bool { selectedClipID != nil && project.clips.count > 1 }

    public func setSpeed(_ speed: Double) {
        guard let id = selectedClipID else { return }
        edit { $0.updateClip(id: id) { $0.setSpeed(speed) } }
    }

    /// Reverses the selected video clip. Photos have nothing to reverse.
    public func toggleReverse() {
        guard let clip = selectedClip, clip.kind == .video else { return }
        edit { $0.updateClip(id: clip.id) { $0.isReversed.toggle() } }
    }

    public func setVolume(_ volume: Double) {
        guard let id = selectedClipID else { return }
        edit { $0.updateClip(id: id) { $0.volume = (0.0...1.0).clamp(volume) } }
    }

    /// Sets the transition into the selected clip. The first clip has none.
    public func setTransition(_ choice: TransitionChoice) {
        guard let index = selectedClipIndex, index > 0 else { return }
        let id = project.clips[index].id
        edit { $0.updateClip(id: id) { $0.transitionIn = choice.transition() } }
    }

    public func setAspect(_ aspect: AspectPreset) {
        edit { $0.aspect = aspect }
    }

    /// Aspects offered for video; free and original don't apply to a timeline.
    public static let aspects: [AspectPreset] = [.story, .portrait, .square, .landscape]

    // MARK: Music

    public func setMusic(_ music: MusicSelection?) {
        edit { $0.music = music }
    }

    public func useLibraryTrack(_ track: AurumCore.MusicTrack) {
        setMusic(MusicSelection(source: .library(trackID: track.id), title: track.title, volume: project.music?.volume ?? 0.8, beats: track.beats))
    }

    public func useImportedSong(fileName: String) {
        let title = (fileName as NSString).deletingPathExtension
        setMusic(MusicSelection(source: .imported(fileName: fileName), title: title, volume: project.music?.volume ?? 0.8))
    }

    public func setMusicVolume(_ volume: Double) {
        edit { p in p.music?.volume = (0.0...1.0).clamp(volume) }
    }

    // MARK: Intro and outro

    public var introPresets: [BookendPreset] { content.bookends.filter { $0.kind == .intro } }
    public var outroPresets: [BookendPreset] { content.bookends.filter { $0.kind == .outro } }

    public func setIntro(_ preset: BookendPreset?) {
        edit { p in p.intro = preset.map { BookendEffect(presetID: $0.id, duration: $0.duration, title: p.intro?.title) } }
    }

    public func setOutro(_ preset: BookendPreset?) {
        edit { p in p.outro = preset.map { BookendEffect(presetID: $0.id, duration: $0.duration, title: p.outro?.title) } }
    }

    public func setBookendTitle(_ title: String, intro: Bool) {
        let value: String? = title.isEmpty ? nil : title
        edit { p in
            if intro { p.intro?.title = value } else { p.outro?.title = value }
        }
    }

    // MARK: Text layers

    public var selectedLayer: TimedLayer? {
        selectedLayerID.flatMap { id in project.layers.first { $0.id == id } }
    }

    /// Adds a text layer at the playhead, shown for three seconds.
    @discardableResult
    public func addText(_ text: String = String(localized: "Your words")) -> UUID {
        let start = min(playhead, max(0, duration - Clip.minimumDuration))
        let end = min(start + 3, max(duration, start + Clip.minimumDuration))
        let layer = TimedLayer(overlay: Overlay(content: .text(TextOverlay(text: text))), start: start, end: end, animationIn: .rise, animationOut: .fade)
        edit { $0.layers.append(layer) }
        selectedLayerID = layer.id
        return layer.id
    }

    public func updateSelectedLayer(_ change: (inout TimedLayer) -> Void) {
        guard let id = selectedLayerID else { return }
        edit { p in
            guard let i = p.layers.firstIndex(where: { $0.id == id }) else { return }
            change(&p.layers[i])
        }
    }

    public func updateSelectedText(_ change: (inout TextOverlay) -> Void) {
        updateSelectedLayer { layer in
            guard case .text(var text) = layer.overlay.content else { return }
            change(&text)
            layer.overlay.content = .text(text)
        }
    }

    /// Starts or ends the selected layer at the playhead.
    public func setSelectedLayerBound(atPlayhead isStart: Bool) {
        let t = playhead
        updateSelectedLayer { layer in
            if isStart {
                layer.start = min(t, layer.end - Clip.minimumDuration)
            } else {
                layer.end = max(t, layer.start + Clip.minimumDuration)
            }
        }
    }

    public func removeSelectedLayer() {
        guard let id = selectedLayerID else { return }
        edit { $0.layers.removeAll { $0.id == id } }
        selectedLayerID = nil
    }

    // MARK: Animated effects

    /// Which effects are for members. The subtle ones are free.
    public nonisolated static func tier(for kind: AnimatedEffect.Kind) -> Tier {
        switch kind {
        case .flicker, .lightLeak, .shake: return .free
        case .glitter, .vhsTracking, .zoomPulse: return .member
        }
    }

    public func effect(of kind: AnimatedEffect.Kind) -> AnimatedEffect? {
        project.effects.first { $0.kind == kind }
    }

    /// Adds an effect over the whole video, or removes it if it is already on.
    public func toggleEffect(_ kind: AnimatedEffect.Kind) {
        if let existing = effect(of: kind) {
            removeEffect(id: existing.id)
            return
        }
        let effect = AnimatedEffect(kind: kind, seed: UInt64.random(in: 1...UInt64(UInt32.max)), tier: Self.tier(for: kind))
        edit { $0.effects.append(effect) }
        selectedEffectID = effect.id
        deps.analytics.track(.toolOpened(tool: "video.effect.\(kind.rawValue)"))
    }

    public func removeEffect(id: UUID) {
        edit { $0.effects.removeAll { $0.id == id } }
        if selectedEffectID == id { selectedEffectID = nil }
    }

    public func setEffectIntensity(_ value: Double) {
        guard let id = selectedEffectID else { return }
        edit { p in
            guard let i = p.effects.firstIndex(where: { $0.id == id }) else { return }
            p.effects[i].intensity = (0.0...1.0).clamp(value)
        }
    }

    // MARK: Look

    public var activeLook: LookApplication? {
        for op in project.operations.reversed() {
            if case .look(let l) = op.kind { return l }
        }
        return nil
    }

    /// Grades the whole video with a look. Tapping the active look removes it.
    public func selectLook(_ lookID: String) {
        if activeLook?.lookID == lookID {
            edit { p in p.operations.removeAll { if case .look = $0.kind { return true } else { return false } } }
            return
        }
        let intensity = activeLook?.intensity ?? 0.8
        edit { p in
            p.operations.removeAll { if case .look = $0.kind { return true } else { return false } }
            p.operations.insert(EditOperation(kind: .look(LookApplication(lookID: lookID, intensity: intensity))), at: 0)
        }
        let premium = catalog.look(id: lookID)?.tier == .member
        deps.analytics.track(.lookApplied(lookID: lookID, premium: premium))
    }

    public func setLookIntensity(_ value: Double) {
        edit { p in
            guard let i = p.operations.lastIndex(where: { if case .look = $0.kind { return true } else { return false } }),
                  case .look(var l) = p.operations[i].kind else { return }
            l.intensity = (0.0...1.0).clamp(value)
            p.operations[i].kind = .look(l)
        }
    }

    // MARK: Tools

    public func toolTapped(_ tool: VideoTool) {
        deps.analytics.track(.toolOpened(tool: "video.\(tool.rawValue)"))
        switch tool {
        case .split:
            activeTool = nil
            if splitAtPlayhead() { Haptics.apply() } else { Haptics.warning() }
        case .reverse:
            activeTool = nil
            toggleReverse()
            Haptics.apply()
        default:
            activeTool = activeTool == tool ? nil : tool
            if tool != .text { selectedLayerID = nil }
        }
    }

    public func isToolAvailable(_ tool: VideoTool) -> Bool {
        switch tool {
        case .reverse: return selectedClip?.kind == .video
        case .split: return project.clip(at: playhead) != nil
        default: return !tool.needsClip || selectedClip != nil
        }
    }

    // MARK: Playback

    public func togglePlay() {
        guard buildsPreview else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            if playhead >= duration - 0.05 { seek(to: 0) }
            player.play()
            isPlaying = true
        }
    }

    /// Moves the playhead, pausing playback while scrubbing.
    public func seek(to t: Seconds) {
        let clamped = min(max(0, t), max(0, duration - 0.01))
        playhead = clamped
        guard buildsPreview else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        }
        player.seek(to: VideoCompositionBuilder.time(clamped), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// Selects whichever clip is under the playhead.
    public func selectClipAtPlayhead() {
        if let (index, _) = project.clip(at: playhead) {
            selectedClipID = project.clips[index].id
        }
    }

    private func observePlayer() {
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
            let seconds = time.seconds
            Task { @MainActor in
                guard let self, self.isPlaying, seconds.isFinite else { return }
                self.playhead = seconds
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] note in
            let item = note.object as? AVPlayerItem
            Task { @MainActor in
                guard let self, item === self.player.currentItem else { return }
                self.isPlaying = false
            }
        }
    }

    // MARK: Preview

    func scheduleRebuild(immediately: Bool = false) {
        guard buildsPreview, !isClosed else { return }
        rebuildTask?.cancel()
        let project = self.project
        rebuildTask = Task { [weak self] in
            if !immediately {
                try? await Task.sleep(nanoseconds: Self.rebuildDelay)
            }
            guard !Task.isCancelled else { return }
            await self?.rebuild(project)
        }
    }

    private func rebuild(_ project: VideoProject) async {
        guard !project.clips.isEmpty else { return }
        isBuilding = true
        do {
            let built = try await VideoCompositionBuilder.build(project, media: media, catalog: catalog, maxPixelSize: Self.previewPixelSize)
            guard !Task.isCancelled, !isClosed else { return }
            let wasPlaying = isPlaying
            player.replaceCurrentItem(with: built.playerItem())
            _ = await player.seek(to: VideoCompositionBuilder.time(playhead), toleranceBefore: .zero, toleranceAfter: .zero)
            if wasPlaying { player.play() }
            previewFailed = false
        } catch {
            if !Task.isCancelled { previewFailed = true }
        }
        isBuilding = false
    }

    /// Stops playback and releases the player. Call when the editor closes.
    public func close() {
        guard !isClosed else { return }
        isClosed = true
        rebuildTask?.cancel()
        player.pause()
        isPlaying = false
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        player.replaceCurrentItem(with: nil)
    }

    // MARK: Export

    /// Pauses and opens the Export sheet.
    public func presentExport() {
        if isPlaying { togglePlay() }
        isExportPresented = true
    }

    public func makeExportModel() -> VideoExportViewModel {
        VideoExportViewModel(project: project, deps: deps, media: media, entitlement: entitlement)
    }
}
