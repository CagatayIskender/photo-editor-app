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
struct StudioView: View {
    @ObservedObject var model: StudioViewModel
    let onClose: () -> Void
    @ObservedObject var app: AppModel

    var body: some View {
        VStack(spacing: 0) {
            topBar
            StudioCanvas(model: model, scheduler: model.scheduler)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let tool = model.activeTool {
                toolSheet(tool)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            toolRail
        }
        .animation(Motion.respectingReduceMotion(Motion.atelier), value: model.activeTool)
        .background(AurumColor.background.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .sheet(isPresented: $model.isExportPresented) {
            ExportSheet(model: model.makeExportModel(), app: app)
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
            IconButton(.redo, label: String(localized: "Redo"), isEnabled: model.canRedo) { model.redo() }
            Spacer()
            Button("Export") {
                model.isExportPresented = true
            }
            .buttonStyle(GoldButtonStyle(compact: true))
            .disabled(model.isLoading)
            .accessibilityIdentifier("studio.export")
        }
        .padding(.horizontal, Spacing.s)
        .frame(height: 52)
    }

    // MARK: Tools

    @ViewBuilder
    private func toolSheet(_ tool: StudioTool) -> some View {
        ToolSheet {
            switch tool {
            case .looks: LooksSheet(model: model)
            case .adjust: AdjustSheet(model: model)
            case .crop: CropSheet(model: model)
            case .text: TextSheet(model: model)
            case .stickers: StickersSheet(model: model, entitlement: app.entitlement)
            }
        }
    }

    private var toolRail: some View {
        HStack(spacing: 0) {
            ForEach(StudioTool.allCases) { tool in
                ToolRailItem(icon: Self.icon(for: tool), title: tool.title, isActive: model.activeTool == tool) {
                    model.toolOpened(tool)
                    Haptics.detent()
                }
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("tool.\(tool.rawValue)")
            }
        }
        .frame(height: 68)
        .background(AurumColor.background)
    }

    static func icon(for tool: StudioTool) -> AurumIcon {
        switch tool {
        case .looks: return .looks
        case .adjust: return .adjust
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
                    ProgressView().tint(AurumColor.accent)
                }
                if model.isComparing {
                    Text("ORIGINAL").aurumText(.label, color: AurumColor.textPrimary)
                        .padding(.horizontal, Spacing.xs).padding(.vertical, 4)
                        .background(Capsule().fill(.black.opacity(0.5)))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .padding(.top, Spacing.s)
                }
            }
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
