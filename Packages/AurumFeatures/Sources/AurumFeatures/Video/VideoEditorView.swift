import AVFoundation
import SwiftUI
import UIKit
import AurumCore
import AurumDesign
import AurumRender
import AurumServices

/// The video editor: the player on top, a timeline of clips sized by their
/// length with trim handles and the playhead, then a tool sheet and the
/// tool rail.
///
/// On regular width (iPad) the player and a wider, more detailed timeline
/// fill the main column and the tool's controls sit in a trailing inspector.
struct VideoEditorView: View {
    @ObservedObject var model: VideoEditorViewModel
    @ObservedObject var app: AppModel
    let onClose: () -> Void
    @State private var isConfirmingClose = false
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        Group {
            if horizontalSizeClass == .regular {
                regularLayout
            } else {
                compactLayout
            }
        }
        .animation(Motion.respectingReduceMotion(Motion.atelier), value: model.activeTool)
        .background(AurumColor.background.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .sheet(isPresented: $model.isExportPresented) {
            VideoExportSheet(model: model.makeExportModel(), app: app)
        }
        .confirmationDialog("Discard this video?", isPresented: $isConfirmingClose, titleVisibility: .visible) {
            Button("Discard", role: .destructive) { onClose() }
            Button("Keep editing", role: .cancel) {}
        } message: {
            Text("Videos aren't kept as drafts yet. Export it first to keep it.")
        }
    }

    private var compactLayout: some View {
        VStack(spacing: 0) {
            topBar
            VideoPlayerArea(model: model)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            transport
            VideoTimeline(model: model, photos: app.deps.photos)
                .frame(height: 112)
            if let tool = model.activeTool {
                ToolSheet { VideoToolSheet(tool: tool, model: model) }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            toolRail
        }
    }

    private var regularLayout: some View {
        VStack(spacing: 0) {
            topBar
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    VideoPlayerArea(model: model)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    transport
                    VideoTimeline(model: model, photos: app.deps.photos, pointsPerSecond: VideoTimeline.regularPointsPerSecond, showsFilmstrip: true)
                        .frame(height: 112)
                    toolRail
                }
                if let tool = model.activeTool, !tool.isAction {
                    InspectorColumn(title: tool.title) {
                        VideoToolSheet(tool: tool, model: model)
                            .padding(.top, Spacing.xs)
                    }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
        }
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: Spacing.xs) {
            IconButton(.close, label: String(localized: "Close")) { isConfirmingClose = true }
                .accessibilityIdentifier("video.close")
            Spacer()
            IconButton(.undo, label: String(localized: "Undo"), isEnabled: model.canUndo) { model.undo() }
                .keyboardShortcut("z", modifiers: .command)
            IconButton(.redo, label: String(localized: "Redo"), isEnabled: model.canRedo) { model.redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
            Spacer()
            Button("Export") { model.presentExport() }
                .buttonStyle(GoldButtonStyle(compact: true))
                .disabled(model.project.clips.isEmpty)
                .keyboardShortcut("e", modifiers: .command)
                .accessibilityIdentifier("video.export")
        }
        .padding(.horizontal, Spacing.s)
        .frame(height: 52)
    }

    // MARK: Transport

    private var transport: some View {
        HStack(spacing: Spacing.s) {
            Button { model.togglePlay() } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundColor(AurumColor.textPrimary)
                    .frame(width: Size.touch, height: Size.touch)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.pressable)
            .hoverEffect(.highlight)
            .accessibilityLabel(model.isPlaying ? String(localized: "Pause") : String(localized: "Play"))
            .accessibilityIdentifier("video.play")
            Text(verbatim: "\(Self.timecode(model.playhead)) / \(Self.timecode(model.duration))")
                .aurumText(.caption, color: AurumColor.textSecondary)
                .monospacedDigit()
            Spacer()
            if model.isBuilding {
                GoldProgressRing(progress: nil, size: 20)
                    .transition(.opacity)
                    .accessibilityLabel("Updating preview")
            }
        }
        .padding(.horizontal, Spacing.s)
        .frame(height: 44)
        .animation(Motion.respectingReduceMotion(Motion.velvet), value: model.isBuilding)
    }

    /// "m:ss" for a time in seconds.
    nonisolated static func timecode(_ seconds: Seconds) -> String {
        let total = Int(max(0, seconds).rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    // MARK: Tool rail

    private var toolRail: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(VideoTool.allCases) { tool in
                    let available = model.isToolAvailable(tool)
                    ToolRailItem(icon: Self.icon(for: tool), title: tool.title, isActive: model.activeTool == tool) {
                        model.toolTapped(tool)
                        if !tool.isAction { Haptics.detent() }
                    }
                    .disabled(!available)
                    .opacity(available ? 1 : 0.4)
                    .accessibilityIdentifier("videoTool.\(tool.rawValue)")
                }
            }
            .padding(.horizontal, Spacing.xs)
        }
        .frame(height: 68)
        .background(AurumColor.background)
    }

    static func icon(for tool: VideoTool) -> AurumIcon {
        switch tool {
        case .trim: return .crop
        case .split: return .layers
        case .speed: return .rotate
        case .reverse: return .flip
        case .volume: return .adjust
        case .transition: return .compare
        case .music: return .music
        case .text: return .text
        case .effects: return .effects
        case .look: return .looks
        case .bookends: return .sparkle
        case .aspect: return .crop
        }
    }
}

// MARK: - Player

/// The preview: an `AVPlayerLayer` letterboxed in the project's aspect.
struct VideoPlayerArea: View {
    @ObservedObject var model: VideoEditorViewModel

    var body: some View {
        GeometryReader { geo in
            let container = geo.frame(in: .local).insetBy(dx: Spacing.m, dy: Spacing.s)
            let ratio = model.project.aspect.ratio ?? 9.0 / 16.0
            let frame = StudioCanvas.fittedRect(imageSize: CGSize(width: ratio * 1000, height: 1000), in: container)
            ZStack {
                PlayerSurface(player: model.player)
                    .frame(width: frame.width, height: frame.height)
                    .background(Color.black)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.chip))
                    .position(x: frame.midX, y: frame.midY)
                    .accessibilityElement()
                    .accessibilityLabel("Video preview")
                    .accessibilityAddTraits(.startsMediaSession)
                    .accessibilityAction { model.togglePlay() }
                if model.previewFailed {
                    Text("This video couldn't be previewed.")
                        .aurumText(.body, color: AurumColor.textTertiary)
                        .position(x: frame.midX, y: frame.midY)
                } else if model.isBuilding && model.player.currentItem == nil {
                    GoldProgressRing(progress: nil, size: 36)
                        .position(x: frame.midX, y: frame.midY)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { model.togglePlay() }
        }
        .animation(Motion.respectingReduceMotion(Motion.velvet), value: model.project.aspect)
    }
}

/// Hosts an `AVPlayerLayer` without the system playback controls.
struct PlayerSurface: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        view.backgroundColor = .black
        return view
    }

    func updateUIView(_ view: PlayerLayerView, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
    }

    final class PlayerLayerView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        // The layer class is fixed above, so the cast always succeeds.
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}

// MARK: - Timeline

/// Clips laid out at their start times, each as wide as it lasts. The
/// ruler scrubs; the selected clip shows trim handles; text layers sit
/// in a thin lane below.
struct VideoTimeline: View {
    @ObservedObject var model: VideoEditorViewModel
    let photos: PhotoLibraryService
    /// Timeline scale. iPad uses `regularPointsPerSecond` for a wider, finer timeline.
    var pointsPerSecond: CGFloat = 48
    /// Repeats each clip's frame along its length, like a filmstrip (iPad).
    var showsFilmstrip = false
    @State private var trimBase: (start: Seconds, end: Seconds)?

    static let regularPointsPerSecond: CGFloat = 72
    static let clipHeight: CGFloat = 56
    static let space = "videoTimeline"

    var body: some View {
        let project = model.project
        let pps = pointsPerSecond
        let total = CGFloat(max(project.duration, 0.5)) * pps
        let seconds = max(1, Int(project.duration.rounded(.up)))
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 6) {
                    ruler(seconds: seconds, width: total)
                    ZStack(alignment: .topLeading) {
                        bookends(project)
                        clips(project)
                    }
                    .frame(width: total, height: Self.clipHeight, alignment: .topLeading)
                    layerLane(project)
                        .frame(width: total, height: 12, alignment: .topLeading)
                }
                .overlay(alignment: .topLeading) {
                    Rectangle()
                        .fill(AurumColor.accent)
                        .frame(width: 2)
                        .shadow(color: AurumColor.accent.opacity(0.5), radius: 3)
                        .offset(x: CGFloat(model.playhead) * pps - 1)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                .coordinateSpace(name: Self.space)
                .padding(.horizontal, Spacing.m)
                .padding(.vertical, Spacing.xs)
            }
            .onChange(of: Int(model.playhead)) { second in
                guard model.isPlaying else { return }
                withAnimation(Motion.respectingReduceMotion(Motion.velvet)) { proxy.scrollTo(second, anchor: .center) }
            }
        }
    }

    // MARK: Ruler

    private func ruler(seconds: Int, width: CGFloat) -> some View {
        HStack(spacing: 0) {
            ForEach(0..<seconds, id: \.self) { second in
                VStack(alignment: .leading, spacing: 2) {
                    Rectangle()
                        .fill(second % 5 == 0 ? AurumColor.textTertiary : AurumColor.hairline)
                        .frame(width: 1, height: second % 5 == 0 ? 8 : 5)
                    if second % 5 == 0 {
                        Text(verbatim: VideoEditorView.timecode(Double(second)))
                            .font(AurumTextStyle.label.font)
                            .foregroundColor(AurumColor.textTertiary)
                            .fixedSize()
                    }
                }
                .frame(width: pointsPerSecond, height: 22, alignment: .topLeading)
                .id(second)
            }
        }
        .frame(width: width, height: 22, alignment: .leading)
        .clipped()
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
                .onChanged { g in model.seek(to: Double(g.location.x / pointsPerSecond)) }
                .onEnded { _ in model.selectClipAtPlayhead() }
        )
        .accessibilityElement()
        .accessibilityLabel("Playhead")
        .accessibilityValue(VideoEditorView.timecode(model.playhead))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: model.seek(to: model.playhead + 1)
            case .decrement: model.seek(to: model.playhead - 1)
            @unknown default: break
            }
        }
    }

    // MARK: Clips

    @ViewBuilder
    private func bookends(_ project: VideoProject) -> some View {
        let pps = pointsPerSecond
        if let intro = project.intro {
            bookendBlock(String(localized: "Intro"))
                .frame(width: max(CGFloat(intro.duration) * pps - 2, 8), height: Self.clipHeight)
        }
        if let outro = project.outro {
            bookendBlock(String(localized: "Outro"))
                .frame(width: max(CGFloat(outro.duration) * pps - 2, 8), height: Self.clipHeight)
                .offset(x: CGFloat(project.duration - outro.duration) * pps + 2)
        }
    }

    private func bookendBlock(_ title: String) -> some View {
        RoundedRectangle(cornerRadius: Radius.chip)
            .fill(AurumColor.surfaceRaised)
            .overlay(RoundedRectangle(cornerRadius: Radius.chip).stroke(AurumColor.goldHairline, lineWidth: 1))
            .overlay(Text(title).aurumText(.label, color: AurumColor.accent).lineLimit(1).padding(.horizontal, 4))
            .onTapGesture { model.toolTapped(.bookends) }
            .accessibilityAddTraits(.isButton)
    }

    private func clips(_ project: VideoProject) -> some View {
        let pps = pointsPerSecond
        let starts = project.clipStartTimes
        return ForEach(Array(project.clips.enumerated()), id: \.element.id) { index, clip in
            let isSelected = model.selectedClipID == clip.id
            TimelineClipCell(clip: clip, photos: photos, isSelected: isSelected, showsFilmstrip: showsFilmstrip)
                .frame(width: max(CGFloat(clip.duration) * pps - 2, 8), height: Self.clipHeight)
                .aurumEntrance(index, distance: 8)
                .overlay(alignment: .leading) { if isSelected { trimHandle(clip, leading: true) } }
                .overlay(alignment: .trailing) { if isSelected { trimHandle(clip, leading: false) } }
                .offset(x: CGFloat(starts.indices.contains(index) ? starts[index] : 0) * pps + 1)
                .zIndex(isSelected ? 1 : 0)
                .onTapGesture {
                    model.selectClip(clip.id)
                    Haptics.detent()
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(clipLabel(clip, index: index))
                .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
                .accessibilityAction(named: String(localized: "Move earlier")) { model.selectClip(clip.id); model.moveSelectedClip(by: -1) }
                .accessibilityAction(named: String(localized: "Move later")) { model.selectClip(clip.id); model.moveSelectedClip(by: 1) }
        }
    }

    private func clipLabel(_ clip: Clip, index: Int) -> String {
        let length = clip.duration.formatted(.number.precision(.fractionLength(1)))
        return clip.kind == .video
            ? String(localized: "Clip \(index + 1), \(length) seconds")
            : String(localized: "Photo \(index + 1), \(length) seconds")
    }

    /// A gold handle that drags the clip's in or out point.
    private func trimHandle(_ clip: Clip, leading: Bool) -> some View {
        Capsule()
            .fill(AurumColor.accent)
            .frame(width: 6, height: Self.clipHeight * 0.55)
            .frame(width: 22, height: Self.clipHeight)
            .contentShape(Rectangle())
            .offset(x: leading ? -11 : 11)
            .highPriorityGesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
                    .onChanged { g in
                        if trimBase == nil {
                            trimBase = (clip.trimStart, clip.trimEnd)
                            model.beginInteraction()
                        }
                        guard let base = trimBase else { return }
                        let delta = Double(g.translation.width / pointsPerSecond) * clip.speed
                        var start = base.start
                        var end = base.end
                        switch (leading, clip.isReversed) {
                        case (true, false): start = base.start + delta
                        case (true, true): end = base.end - delta
                        case (false, false): end = base.end + delta
                        case (false, true): start = base.start - delta
                        }
                        model.trimSelected(start: start, end: end)
                    }
                    .onEnded { _ in
                        trimBase = nil
                        model.endInteraction()
                        Haptics.detent()
                    }
            )
            .accessibilityHidden(true)
    }

    // MARK: Layers

    private func layerLane(_ project: VideoProject) -> some View {
        let pps = pointsPerSecond
        return ZStack(alignment: .topLeading) {
            ForEach(project.layers) { layer in
                let isSelected = model.selectedLayerID == layer.id
                Capsule()
                    .fill(isSelected ? AurumColor.accent : AurumColor.textTertiary.opacity(0.6))
                    .frame(width: max(CGFloat(layer.end - layer.start) * pps, 6), height: 6)
                    .frame(height: 12)
                    .contentShape(Rectangle())
                    .offset(x: CGFloat(layer.start) * pps)
                    .onTapGesture {
                        model.selectedLayerID = layer.id
                        if model.activeTool != .text { model.toolTapped(.text) }
                    }
                    .accessibilityElement()
                    .accessibilityLabel(layerLabel(layer))
                    .accessibilityAddTraits(.isButton)
            }
        }
    }

    private func layerLabel(_ layer: TimedLayer) -> String {
        if case .text(let text) = layer.overlay.content { return String(localized: "Text: \(text.text)") }
        return String(localized: "Layer")
    }
}

/// One clip on the timeline: its first frame (or the photo), a speed badge
/// and a mark for the transition into it.
struct TimelineClipCell: View {
    let clip: Clip
    let photos: PhotoLibraryService
    let isSelected: Bool
    var showsFilmstrip = false
    @State private var image: UIImage?

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            AurumColor.surfaceRaised
                .overlay {
                    if let image {
                        if showsFilmstrip {
                            Filmstrip(image: image)
                        } else {
                            Image(uiImage: image).resizable().scaledToFill()
                        }
                    }
                }
                .clipped()
            HStack(spacing: 4) {
                if clip.speed != 1 {
                    Text(verbatim: "\(clip.speed.formatted(.number.precision(.fractionLength(0...2))))×")
                }
                if clip.isReversed {
                    IconView(.flip, size: 10, lineWidth: 1.6)
                }
                if clip.volume == 0 && clip.kind == .video {
                    Image(systemName: "speaker.slash.fill").font(.system(size: 9))
                }
            }
            .font(AurumTextStyle.label.font)
            .foregroundColor(AurumColor.textPrimary)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(Capsule().fill(.black.opacity(0.55)))
            .padding(4)
            .opacity(clip.speed != 1 || clip.isReversed || (clip.volume == 0 && clip.kind == .video) ? 1 : 0)
        }
        .clipShape(RoundedRectangle(cornerRadius: Radius.chip))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.chip)
                .stroke(isSelected ? AurumColor.accent : AurumColor.hairline, lineWidth: isSelected ? 2 : 1)
        )
        .shadow(color: AurumColor.accent.opacity(isSelected ? 0.28 : 0), radius: 6)
        .animation(Motion.respectingReduceMotion(Motion.atelier), value: isSelected)
        .overlay(alignment: .leading) {
            if clip.transitionIn != .cut {
                Rectangle()
                    .fill(AurumColor.accent)
                    .frame(width: 8, height: 8)
                    .rotationEffect(.degrees(45))
                    .offset(x: -4)
                    .accessibilityHidden(true)
            }
        }
        .task(id: clip.source.localIdentifier) {
            guard LibraryMediaSource.fileURL(from: clip.source.localIdentifier) == nil else { return }
            image = await photos.thumbnail(for: clip.source.localIdentifier, side: 80)
        }
    }
}

/// A clip's frame repeated in square tiles along its length.
struct Filmstrip: View {
    let image: UIImage

    var body: some View {
        GeometryReader { geo in
            let side = max(geo.size.height, 1)
            let count = max(1, Int((geo.size.width / side).rounded(.up)))
            HStack(spacing: 0) {
                ForEach(0..<count, id: \.self) { _ in
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: side, height: side)
                        .clipped()
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .leading)
            .clipped()
        }
        .accessibilityHidden(true)
    }
}
