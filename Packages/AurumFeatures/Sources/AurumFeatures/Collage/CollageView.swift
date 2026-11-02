import SwiftUI
import AurumCore
import AurumDesign
import AurumRender

/// The collage editor: a layout picker, the canvas (tap to select or swap,
/// drag and pinch to frame), and spacing, corners and background below.
struct CollageView: View {
    @ObservedObject var app: AppModel
    @StateObject private var model: CollageViewModel
    @State private var picker: PickerRequest?

    /// What the media picker is filling.
    enum PickerRequest: Identifiable {
        case fill
        case replace(Int)
        var id: String {
            switch self {
            case .fill: return "fill"
            case .replace(let i): return "replace-\(i)"
            }
        }
    }

    init(app: AppModel) {
        self.app = app
        _model = StateObject(wrappedValue: CollageViewModel(deps: app.deps, entitlement: { [weak app] in app?.entitlement ?? .free }))
    }

    var body: some View {
        VStack(spacing: 0) {
            AtelierHeader(title: String(localized: "Collage"), onClose: { app.closeFlow() }) {
                Button("Save") {
                    Task {
                        await model.export()
                        if model.phase == .saved { Haptics.success() }
                    }
                }
                .buttonStyle(GoldButtonStyle(compact: true))
                .disabled(!model.canExport)
                .accessibilityIdentifier("collage.export")
            }
            CollageCanvas(model: model, onEmptyCell: { picker = .fill })
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(Spacing.m)
            statusLine
            controls
        }
        .background(AurumColor.background.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .sheet(item: $picker) { request in
            switch request {
            case .fill:
                MediaPickerView(app: app, required: max(1, model.emptyCellCount), title: String(localized: "Choose photos")) { picked in
                    picker = nil
                    model.add(picked)
                } onCancel: { picker = nil }
            case .replace(let index):
                MediaPickerView(app: app, required: 1, title: String(localized: "Choose a photo")) { picked in
                    picker = nil
                    model.replace(cell: index, with: picked)
                } onCancel: { picker = nil }
            }
        }
        .sheet(isPresented: $model.isPaywallPresented) {
            PaywallView(app: app, trigger: "collage") {
                model.isPaywallPresented = false
            }
        }
        .onAppear { if model.project.filledCount == 0 { picker = .fill } }
    }

    @ViewBuilder
    private var statusLine: some View {
        Group {
            switch model.phase {
            case .exporting:
                HStack(spacing: Spacing.s) {
                    ProgressView().tint(AurumColor.accent)
                    Text("Finishing your collage…").aurumText(.caption, color: AurumColor.textSecondary)
                }
            case .saved:
                Text("Saved to Photos").aurumText(.caption, color: AurumColor.accent)
            case .failed(let message):
                Text(message).aurumText(.caption, color: AurumColor.textSecondary)
            case .editing:
                if let selected = model.selectedCell {
                    HStack(spacing: Spacing.s) {
                        Text("Tap another photo to swap, or drag and pinch to frame.")
                            .aurumText(.caption, color: AurumColor.textTertiary)
                        Spacer()
                        Button("Replace") { picker = .replace(selected) }.buttonStyle(TextActionButtonStyle())
                        Button("Remove") { model.clear(cell: selected) }.buttonStyle(TextActionButtonStyle())
                    }
                } else if case .requiresMembership = model.decision {
                    HStack(spacing: Spacing.xs) {
                        CrownBadge(size: 14)
                        Text("A member layout. Membership is asked for when you save.")
                            .aurumText(.caption, color: AurumColor.textTertiary)
                    }
                } else {
                    Text("Tap a photo to select it.").aurumText(.caption, color: AurumColor.textTertiary)
                }
            }
        }
        .padding(.horizontal, Spacing.m)
        .frame(minHeight: Size.touch)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Spacing.s) {
                    ForEach(model.layouts) { layout in
                        Button { model.setLayout(layout); Haptics.detent() } label: {
                            CollageLayoutThumbnail(layout: layout, isSelected: model.project.layout.id == layout.id)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(String(localized: "\(Localized.dynamic(layout.name)) layout, \(layout.photoCount) photos"))
                        .accessibilityAddTraits(model.project.layout.id == layout.id ? .isSelected : [])
                    }
                }
                .padding(.vertical, 2)
            }
            HStack(spacing: Spacing.m) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Spacing").aurumText(.label, color: AurumColor.textTertiary)
                    AurumSlider(value: Binding(get: { model.spacing }, set: { model.spacing = $0 }), in: CollageProject.spacingRange, detentStep: 0.01, label: String(localized: "Spacing"))
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text("Corners").aurumText(.label, color: AurumColor.textTertiary)
                    AurumSlider(value: Binding(get: { model.cornerRadius }, set: { model.cornerRadius = $0 }), in: CollageProject.cornerRadiusRange, detentStep: 0.01, label: String(localized: "Corners"))
                }
            }
            HStack(spacing: Spacing.s) {
                ForEach(CollageViewModel.backgrounds, id: \.self) { hex in
                    let isSelected = model.project.backgroundHex == hex
                    Button { model.setBackground(hex); Haptics.detent() } label: {
                        Circle().fill(Color(hex: hex))
                            .frame(width: 28, height: 28)
                            .overlay(Circle().stroke(isSelected ? AurumColor.accent : AurumColor.hairline, lineWidth: isSelected ? 2 : 1))
                            .frame(width: Size.touch, height: Size.touch)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(String(localized: "Background colour"))
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
                Spacer()
                if model.emptyCellCount > 0 {
                    Button("Add photos") { picker = .fill }.buttonStyle(TextActionButtonStyle())
                }
            }
        }
        .padding(Spacing.m)
        .background(
            AurumColor.surface
                .overlay(alignment: .top) { Rectangle().fill(AurumColor.goldHairline).frame(height: 0.5) }
                .ignoresSafeArea(edges: .bottom)
        )
    }
}

/// The collage as the user frames it. Matches `CollageRenderer` exactly.
struct CollageCanvas: View {
    @ObservedObject var model: CollageViewModel
    let onEmptyCell: () -> Void

    var body: some View {
        GeometryReader { geo in
            let ratio = CGFloat(model.project.layout.canvasRatio)
            let fit = StudioCanvas.fittedRect(imageSize: CGSize(width: ratio, height: 1), in: geo.frame(in: .local))
            let radius = CGFloat(model.project.cornerRadius) * min(fit.width, fit.height)
            ZStack(alignment: .topLeading) {
                Color(hex: model.project.backgroundHex)
                ForEach(Array(model.project.frames.enumerated()), id: \.offset) { index, frame in
                    let rect = CGRect(x: CGFloat(frame.x) * fit.width, y: CGFloat(frame.y) * fit.height, width: CGFloat(frame.width) * fit.width, height: CGFloat(frame.height) * fit.height)
                    CollageCellView(model: model, index: index, size: rect.size, radius: min(radius, min(rect.width, rect.height) / 2), onEmpty: onEmptyCell)
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: rect.minX, y: rect.minY)
                }
            }
            .frame(width: fit.width, height: fit.height)
            .clipped()
            .position(x: fit.midX, y: fit.midY)
            .animation(Motion.respectingReduceMotion(Motion.atelier), value: model.project.layout.id)
        }
    }
}

struct CollageCellView: View {
    @ObservedObject var model: CollageViewModel
    let index: Int
    let size: CGSize
    let radius: CGFloat
    let onEmpty: () -> Void

    @State private var translation: CGSize = .zero
    @State private var magnification: CGFloat = 1

    var body: some View {
        let cell = model.project.cells.indices.contains(index) ? model.project.cells[index] : nil
        let isSelected = model.selectedCell == index
        ZStack {
            if let cell {
                let imageSize = CGSize(width: cell.source.pixelSize.width, height: cell.source.pixelSize.height)
                let frame = CollageCellGeometry.imageFrame(cell: size, image: imageSize, zoom: cell.zoom, center: cell.center)
                Group {
                    if let thumb = model.thumbnails[cell.source.localIdentifier] {
                        Image(uiImage: thumb).resizable()
                    } else {
                        AurumColor.surfaceRaised
                    }
                }
                .frame(width: frame.width, height: frame.height)
                .position(x: frame.midX, y: frame.midY)
            } else {
                AurumColor.surface
                IconView(.plus, size: 22).foregroundColor(AurumColor.textTertiary)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: radius))
        .overlay(RoundedRectangle(cornerRadius: radius).stroke(AurumColor.accent, lineWidth: isSelected ? 2 : 0))
        .contentShape(Rectangle())
        .onTapGesture {
            if cell == nil {
                onEmpty()
            } else if model.tap(cell: index) {
                Haptics.apply()
            } else {
                Haptics.detent()
            }
        }
        .gesture(framingGesture, including: isSelected && cell != nil ? .all : .subviews)
        .accessibilityElement()
        .accessibilityLabel(cell == nil ? String(localized: "Empty cell \(index + 1)") : String(localized: "Photo \(index + 1)"))
        .accessibilityHint(cell == nil ? String(localized: "Add a photo") : String(localized: "Select, then select another photo to swap"))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var framingGesture: some Gesture {
        SimultaneousGesture(
            DragGesture(minimumDistance: 4)
                .onChanged { value in
                    model.beginAdjusting(cell: index)
                    translation = value.translation
                    model.adjust(cell: index, translation: translation, magnification: magnification, cellSize: size)
                }
                .onEnded { _ in finish() },
            MagnificationGesture()
                .onChanged { value in
                    model.beginAdjusting(cell: index)
                    magnification = value
                    model.adjust(cell: index, translation: translation, magnification: magnification, cellSize: size)
                }
                .onEnded { _ in finish() }
        )
    }

    private func finish() {
        translation = .zero
        magnification = 1
        model.endAdjusting()
    }
}

/// A small drawing of a layout's cells.
struct CollageLayoutThumbnail: View {
    let layout: CollageLayout
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 6) {
            let height: CGFloat = 56
            let width = height * CGFloat(layout.canvasRatio)
            ZStack(alignment: .topLeading) {
                ForEach(Array(layout.frames(spacing: 0.04).enumerated()), id: \.offset) { _, r in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(isSelected ? AurumColor.accent.opacity(0.85) : AurumColor.textTertiary.opacity(0.6))
                        .frame(width: CGFloat(r.width) * width, height: CGFloat(r.height) * height)
                        .offset(x: CGFloat(r.x) * width, y: CGFloat(r.y) * height)
                }
            }
            .frame(width: width, height: height, alignment: .topLeading)
            .overlay(alignment: .topTrailing) {
                if layout.tier == .member { CrownBadge(size: 12).offset(x: 6, y: -6) }
            }
            Text(Localized.dynamic(layout.name)).aurumText(.caption, color: isSelected ? AurumColor.textPrimary : AurumColor.textTertiary)
        }
        .padding(Spacing.xs)
        .background(RoundedRectangle(cornerRadius: Radius.chip).fill(isSelected ? AurumColor.surfaceRaised : Color.clear))
    }
}
