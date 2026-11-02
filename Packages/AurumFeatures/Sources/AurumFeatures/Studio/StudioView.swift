import SwiftUI
import AurumCore
import AurumDesign
import AurumRender

/// The editor. The photo fills the space above a tool sheet and the tool rail.
///
/// Gestures on the photo:
/// - press and hold shows the original;
/// - swipe left or right moves to the next or previous look;
/// - tap an overlay to select it, then drag, pinch and rotate it.
///
/// On regular width (iPad) the tool rail runs down the leading edge, the
/// photo takes the centre and the active tool's controls sit in a trailing
/// inspector. A hardware keyboard adds ⌘Z, ⇧⌘Z, ⌘E and the arrow keys.
struct StudioView: View {
    @ObservedObject var model: StudioViewModel
    let onClose: () -> Void
    @ObservedObject var app: AppModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var chromeShown = false

    var body: some View {
        Group {
            if horizontalSizeClass == .regular {
                regularLayout
            } else {
                compactLayout
            }
        }
        .animation(Motion.respectingReduceMotion(Motion.atelier), value: model.activeTool)
        .onAppear {
            guard !chromeShown else { return }
            withAnimation(Motion.respectingReduceMotion(Motion.atelier)) { chromeShown = true }
        }
        .background(AurumColor.background.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .sheet(isPresented: $model.isExportPresented) {
            ExportSheet(model: model.makeExportModel(), app: app)
        }
    }

    private var compactLayout: some View {
        VStack(spacing: 0) {
            topBar
            StudioCanvas(model: model, scheduler: model.scheduler)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let tool = model.activeTool {
                toolSheet(tool)
                    .transition(.aurumSheet)
            }
            toolRail
        }
    }

    private var regularLayout: some View {
        VStack(spacing: 0) {
            topBar
            HStack(spacing: 0) {
                verticalToolRail
                ColumnHairline()
                StudioCanvas(model: model, scheduler: model.scheduler)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if let tool = model.activeTool {
                    InspectorColumn(title: tool.title) {
                        toolContent(tool)
                    }
                    .transition(reduceMotion ? .opacity : .move(edge: .trailing).combined(with: .opacity))
                }
            }
        }
        .background { lookKeyCommands }
    }

    /// Arrow keys move through the looks, as a swipe on the photo does. Left
    /// out while editing text, so the arrows still move the text cursor.
    @ViewBuilder
    private var lookKeyCommands: some View {
        if model.activeTool != .text {
            ZStack {
                Button("Previous look") { model.cycleLook(by: -1) }
                    .keyboardShortcut(.leftArrow, modifiers: [])
                Button("Next look") { model.cycleLook(by: 1) }
                    .keyboardShortcut(.rightArrow, modifiers: [])
            }
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
        }
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: Spacing.xs) {
            IconButton(.close, label: String(localized: "Close")) {
                Task {
                    await model.saveDraft()
                    onClose()
                }
            }
            .accessibilityIdentifier("studio.close")
            Spacer()
            IconButton(.undo, label: String(localized: "Undo"), isEnabled: model.canUndo) { model.undo() }
                .keyboardShortcut("z", modifiers: .command)
            IconButton(.redo, label: String(localized: "Redo"), isEnabled: model.canRedo) { model.redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
            Spacer()
            Button("Export") {
                model.isExportPresented = true
            }
            .buttonStyle(GoldButtonStyle(compact: true))
            .disabled(model.isLoading)
            .keyboardShortcut("e", modifiers: .command)
            .accessibilityIdentifier("studio.export")
        }
        .padding(.horizontal, Spacing.s)
        .frame(height: 52)
        .opacity(chromeShown ? 1 : 0)
        .offset(y: chromeShown || reduceMotion ? 0 : -10)
    }

    // MARK: Tools

    private func toolSheet(_ tool: StudioTool) -> some View {
        ToolSheet {
            toolContent(tool)
        }
    }

    @ViewBuilder
    private func toolContent(_ tool: StudioTool) -> some View {
        switch tool {
        case .looks: LooksSheet(model: model)
        case .adjust: AdjustSheet(model: model)
        case .retouch: RetouchSheet(model: model)
        case .crop: CropSheet(model: model)
        case .text: TextSheet(model: model)
        case .stickers: StickersSheet(model: model, entitlement: app.entitlement)
        }
    }

    /// The tool rail down the leading edge, on iPad.
    private var verticalToolRail: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: Spacing.xs) {
                ForEach(StudioTool.allCases) { tool in
                    railItem(tool)
                }
            }
            .padding(.vertical, Spacing.s)
            .padding(.horizontal, Spacing.xxs)
        }
        .frame(width: 76)
        .background(AurumColor.background)
        .opacity(chromeShown ? 1 : 0)
    }

    private var toolRail: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 0) {
                ForEach(StudioTool.allCases) { tool in
                    railItem(tool).frame(maxWidth: .infinity)
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(StudioTool.allCases) { tool in
                        railItem(tool)
                    }
                }
                .padding(.horizontal, Spacing.xs)
            }
        }
        .frame(height: 68)
        .background(AurumColor.background)
        .opacity(chromeShown ? 1 : 0)
        .offset(y: chromeShown || reduceMotion ? 0 : 14)
    }

    private func railItem(_ tool: StudioTool) -> some View {
        ToolRailItem(icon: Self.icon(for: tool), title: tool.title, isActive: model.activeTool == tool) {
            model.toolOpened(tool)
            Haptics.detent()
        }
        .overlay(alignment: .topTrailing) {
            if tool.isPremium {
                CrownBadge(size: 14).offset(x: -10, y: 2).allowsHitTesting(false)
            }
        }
        .accessibilityIdentifier("tool.\(tool.rawValue)")
    }

    static func icon(for tool: StudioTool) -> AurumIcon {
        switch tool {
        case .looks: return .looks
        case .adjust: return .adjust
        case .retouch: return .retouch
        case .crop: return .crop
        case .text: return .text
        case .stickers: return .stickers
        }
    }
}

// MARK: - Canvas

struct StudioCanvas: View {
    @ObservedObject var model: StudioViewModel
    @ObservedObject var scheduler: PreviewScheduler
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            let container = geo.frame(in: .local).insetBy(dx: Spacing.m, dy: Spacing.s)
            ZStack {
                if let image = scheduler.image {
                    let frame = Self.fittedRect(imageSize: CGSize(width: image.width, height: image.height), in: container)
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .frame(width: frame.width, height: frame.height)
                        .position(x: frame.midX, y: frame.midY)
                        .transition(.opacity)
                        .accessibilityLabel(imageLabel)
                        .accessibilityHint("Swipe left or right with three fingers to change the look")
                        .accessibilityAddTraits(.isImage)
                        .accessibilityScrollAction { edge in
                            model.cycleLook(by: edge == .trailing ? -1 : 1)
                        }
                    OverlayLayer(model: model, frame: frame)
                        .opacity(model.isComparing ? 0 : 1)
                } else if model.loadFailed {
                    Text("This photo couldn't be opened.").aurumText(.body, color: AurumColor.textTertiary)
                } else {
                    loadingPlaceholder(in: container)
                }
                if model.isComparing {
                    Text("ORIGINAL").aurumText(.label, color: AurumColor.textPrimary)
                        .padding(.horizontal, Spacing.xs).padding(.vertical, 4)
                        .background(Capsule().fill(.black.opacity(0.5)))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .padding(.top, Spacing.s)
                        .transition(.aurumPop)
                }
            }
            .animation(Motion.respectingReduceMotion(Motion.velvet), value: scheduler.image != nil)
            .animation(Motion.respectingReduceMotion(Motion.atelier), value: model.isComparing)
            .contentShape(Rectangle())
            .onTapGesture { model.selectedOverlayID = nil }
            .onLongPressGesture(minimumDuration: 0.2, maximumDistance: 12, pressing: { pressing in
                model.isComparing = pressing
                if pressing { Haptics.detent() }
            }, perform: {})
            .simultaneousGesture(swipe)
        }
        .clipped()
    }

    private func loadingPlaceholder(in container: CGRect) -> some View {
        ZStack {
            SkeletonBlock(cornerRadius: Radius.chip)
                .frame(width: container.width * 0.8, height: container.height * 0.8)
            GoldProgressRing(progress: nil, size: 36)
        }
        .transition(.opacity)
    }

    private var swipe: some Gesture {
        DragGesture(minimumDistance: 40)
            .onEnded { value in
                guard model.selectedOverlayID == nil,
                      abs(value.translation.width) > abs(value.translation.height) * 2 else { return }
                model.cycleLook(by: value.translation.width < 0 ? 1 : -1)
                Haptics.apply()
            }
    }

    private var imageLabel: String {
        if let look = model.activeLookRecipe {
            return String(localized: "Your photo, with the \(look.name) look")
        }
        return String(localized: "Your photo")
    }

    /// The largest rect with the image's aspect ratio that fits in `container`.
    static func fittedRect(imageSize: CGSize, in container: CGRect) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0, container.width > 0, container.height > 0 else { return .zero }
        let scale = min(container.width / imageSize.width, container.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(x: container.midX - size.width / 2, y: container.midY - size.height / 2, width: size.width, height: size.height)
    }
}
