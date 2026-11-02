import SwiftUI
import AurumCore
import AurumDesign
import AurumRender
import AurumServices

/// One Auto Studio tool: the photo, the tool's settings, a free preview, and
/// opening the result in the Studio.
struct AutoFeatureView: View {
    @ObservedObject var model: AutoStudioViewModel
    @ObservedObject var app: AppModel
    let feature: AutoFeature
    @State private var isPicking = false
    @State private var isPickingBackground = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.m) {
                Text(AutoStudioViewModel.subtitle(for: feature))
                    .aurumText(.body, color: AurumColor.textSecondary)
                stage
                    .frame(maxWidth: .infinity)
                    .frame(height: 380)
                photoButton
                if feature.tier == .member {
                    AtelierNote(
                        title: String(localized: "Members' tool"),
                        message: String(localized: "Preview it as often as you like. Membership is needed only to keep the result.")
                    )
                }
                if model.photo != nil, model.phase != .result {
                    options
                }
                status
                actions
            }
            .padding(Spacing.m)
        }
        .background(AurumColor.background.ignoresSafeArea())
        .navigationTitle(AutoStudioViewModel.title(for: feature))
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(AurumColor.background, for: .navigationBar)
        .sheet(isPresented: $isPicking) {
            MediaPickerView(app: app, required: 1, title: String(localized: "Choose a photo")) { picked in
                isPicking = false
                Task { await model.setPhoto(picked) }
            } onCancel: {
                isPicking = false
            }
        }
        .sheet(isPresented: $isPickingBackground) {
            MediaPickerView(app: app, required: 1, title: String(localized: "Choose a background")) { picked in
                isPickingBackground = false
                Task { await model.setBackgroundPhoto(picked) }
            } onCancel: {
                isPickingBackground = false
            }
        }
        .sheet(isPresented: $model.isPaywallPresented) {
            PaywallView(app: app, trigger: "autoStudio") {
                model.isPaywallPresented = false
            }
        }
    }

    // MARK: Stage

    @ViewBuilder
    private var stage: some View {
        if let result = model.resultPreview {
            AtelierImage(image: result)
                .accessibilityLabel(String(localized: "Result"))
                .accessibilityAddTraits(.isImage)
        } else if let source = model.sourcePreview {
            if feature.requiresMask {
                MaskCanvas(image: source, editor: $model.maskEditor)
            } else {
                AtelierImage(image: source)
                    .accessibilityLabel(String(localized: "Your photo"))
                    .accessibilityAddTraits(.isImage)
            }
        } else {
            Button { isPicking = true } label: {
                AtelierImage(image: nil, placeholder: String(localized: "Choose a photo to begin"))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("auto.feature.choosePhoto")
        }
    }

    private var photoButton: some View {
        HStack {
            Button(model.photo == nil ? String(localized: "Choose a photo") : String(localized: "Change photo")) { isPicking = true }
                .buttonStyle(TextActionButtonStyle())
                .disabled(model.isBusy)
            Spacer()
            if model.isAnalysing {
                ProgressView().tint(AurumColor.accent)
                    .accessibilityLabel(String(localized: "Looking at your photo…"))
            }
        }
    }

    // MARK: Options

    @ViewBuilder
    private var options: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            switch feature {
            case .enhance:
                enhanceOptions
            case .portraitBlur:
                section(String(localized: "Blur")) {
                    AurumSlider(value: $model.blurAmount, in: 0.1...1, label: String(localized: "Blur amount"))
                }
            case .replaceBackground:
                section(String(localized: "Background")) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: Spacing.s) {
                            ForEach(AutoBackgroundChoice.allCases) { choice in
                                backgroundSwatch(choice)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            case .relight:
                section(String(localized: "Light from")) {
                    HStack(spacing: Spacing.xs) {
                        ForEach(OnDeviceImaging.LightDirection.allCases, id: \.self) { direction in
                            Chip(Self.title(for: direction), isSelected: model.lightDirection == direction) {
                                model.lightDirection = direction
                            }
                        }
                    }
                    AurumSlider(value: $model.lightIntensity, in: 0...1, label: String(localized: "Light intensity"))
                }
            case .retouch:
                section(String(localized: "Strength")) {
                    AurumSlider(value: $model.retouchStrength, in: 0...1, label: String(localized: "Retouch strength"))
                }
            case .removeObject:
                section(String(localized: "Brush")) {
                    HStack(spacing: Spacing.xs) {
                        Chip(String(localized: "Paint"), isSelected: !model.maskEditor.isEraser) { model.maskEditor.isEraser = false }
                        Chip(String(localized: "Erase"), isSelected: model.maskEditor.isEraser) { model.maskEditor.isEraser = true }
                        Spacer()
                        IconButton(.undo, label: String(localized: "Undo stroke"), isEnabled: model.maskEditor.canUndo) { model.maskEditor.undo() }
                        Button("Clear") { model.maskEditor.clear() }
                            .buttonStyle(TextActionButtonStyle())
                            .disabled(!model.maskEditor.canUndo)
                    }
                    AurumSlider(value: $model.maskEditor.radius, in: 0.01...0.12, detentStep: 0.01, label: String(localized: "Brush size"))
                    Text("Works best on small things against plain or repeating backgrounds, such as sky, sand, walls or grass.")
                        .aurumText(.caption, color: AurumColor.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            case .portraitLooks:
                section(String(localized: "Look")) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: Spacing.xs) {
                            ForEach(PortraitLook.library) { look in
                                Chip(Localized.dynamic(look.name), isSelected: model.portraitLookID == look.id, leadingIcon: look.tier == .member ? .crown : nil) {
                                    model.portraitLookID = look.id
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var enhanceOptions: some View {
        section(String(localized: "Include")) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Spacing.xs) {
                    Chip(String(localized: "Auto tone"), isSelected: model.enhanceOptions.autoTone) { model.enhanceOptions.autoTone.toggle() }
                    Chip(String(localized: "White balance"), isSelected: model.enhanceOptions.whiteBalance) { model.enhanceOptions.whiteBalance.toggle() }
                    Chip(straightenTitle, isSelected: model.enhanceOptions.straighten) { model.enhanceOptions.straighten.toggle() }
                    Chip(String(localized: "Red eye"), isSelected: model.enhanceOptions.redEye) { model.enhanceOptions.redEye.toggle() }
                    Chip(String(localized: "Clarity"), isSelected: model.enhanceOptions.clarity) { model.enhanceOptions.clarity.toggle() }
                }
            }
        }
    }

    /// "Straighten 2.3°" when a tilted horizon was found, otherwise "Straighten".
    private var straightenTitle: String {
        if let degrees = model.analysis?.horizonDegrees, Straighten.isWorthCorrecting(degrees: degrees) {
            return AutoStudioViewModel.title(for: AutoSuggestion(kind: .straighten, score: 0, degrees: degrees))
        }
        return String(localized: "Straighten")
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(title).aurumText(.label, color: AurumColor.textTertiary)
            content()
        }
    }

    private func backgroundSwatch(_ choice: AutoBackgroundChoice) -> some View {
        let isSelected = model.background == choice
        return Button {
            if choice == .photo && !model.hasBackgroundPhoto {
                isPickingBackground = true
            } else {
                model.background = choice
            }
            Haptics.detent()
        } label: {
            VStack(spacing: 6) {
                ZStack {
                    LinearGradient(colors: choice.swatch.map(Color.init(hex:)), startPoint: .top, endPoint: .bottom)
                    if choice == .photo {
                        IconView(.camera, size: 20).foregroundColor(AurumColor.textSecondary)
                    }
                }
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: Radius.chip))
                .overlay(RoundedRectangle(cornerRadius: Radius.chip).stroke(isSelected ? AurumColor.accent : AurumColor.hairline, lineWidth: isSelected ? 2 : 1))
                Text(choice.title).aurumText(.caption, color: isSelected ? AurumColor.textPrimary : AurumColor.textTertiary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .contextMenu {
            if choice == .photo && model.hasBackgroundPhoto {
                Button(String(localized: "Choose another photo")) { isPickingBackground = true }
            }
        }
    }

    static func title(for direction: OnDeviceImaging.LightDirection) -> String {
        switch direction {
        case .front: return String(localized: "Front")
        case .left: return String(localized: "Left")
        case .right: return String(localized: "Right")
        case .above: return String(localized: "Above")
        }
    }

    // MARK: Status and actions

    @ViewBuilder
    private var status: some View {
        switch model.phase {
        case .loading, .saving:
            HStack(spacing: Spacing.s) {
                ProgressView().tint(AurumColor.accent)
                Text(model.phase == .saving ? String(localized: "Saving to Photos…") : String(localized: "Opening your photo…"))
                    .aurumText(.caption, color: AurumColor.textSecondary)
            }
        case .working:
            HStack(spacing: Spacing.s) {
                ProgressView().tint(AurumColor.accent)
                Text("Working…").aurumText(.caption, color: AurumColor.textSecondary)
            }
        case .failed(let message):
            Text(message).aurumText(.caption, color: AurumColor.textSecondary)
        case .idle, .result:
            EmptyView()
        }
    }

    @ViewBuilder
    private var actions: some View {
        if model.phase == .result {
            VStack(spacing: Spacing.s) {
                Button("Open in Studio") { Task { await model.openResultInStudio(app: app) } }
                    .buttonStyle(GoldButtonStyle())
                    .accessibilityIdentifier("auto.openInStudio")
                Button("Discard") { model.discardResult() }
                    .buttonStyle(TextActionButtonStyle())
            }
        } else if model.photo != nil {
            VStack(alignment: .leading, spacing: Spacing.s) {
                Button("Preview") { Task { await model.run() } }
                    .buttonStyle(GoldButtonStyle())
                    .disabled(model.isBusy || model.runIssue != nil)
                    .accessibilityIdentifier("auto.preview")
                if let issue = model.runIssue {
                    Text(issue).aurumText(.caption, color: AurumColor.textSecondary)
                } else {
                    Text("Free to preview. Your photo stays on your iPhone.").aurumText(.caption, color: AurumColor.textTertiary)
                }
            }
        }
    }
}

/// The photo with brush strokes painted over it. Drag to paint (or erase).
struct MaskCanvas: View {
    let image: CGImage
    @Binding var editor: BrushMaskEditor

    var body: some View {
        GeometryReader { geo in
            let frame = StudioCanvas.fittedRect(imageSize: CGSize(width: image.width, height: image.height), in: geo.frame(in: .local))
            ZStack(alignment: .topLeading) {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .frame(width: frame.width, height: frame.height)
                    .position(x: frame.midX, y: frame.midY)
                Canvas { context, _ in
                    let side = min(frame.width, frame.height)
                    var strokes = editor.mask.strokes
                    if !editor.current.isEmpty {
                        strokes.append(BrushMask.Stroke(points: editor.current, radius: editor.radius, isEraser: editor.isEraser))
                    }
                    for stroke in strokes {
                        var path = Path()
                        for (i, p) in stroke.points.enumerated() {
                            let point = CGPoint(x: frame.minX + CGFloat(p.x) * frame.width, y: frame.minY + CGFloat(p.y) * frame.height)
                            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
                            if stroke.points.count == 1 { path.addLine(to: point) }
                        }
                        context.blendMode = stroke.isEraser ? .destinationOut : .normal
                        context.stroke(path, with: .color(AurumColor.accent), style: StrokeStyle(lineWidth: CGFloat(stroke.radius) * 2 * side, lineCap: .round, lineJoin: .round))
                    }
                }
                .opacity(0.55)
                .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard frame.width > 0, frame.height > 0 else { return }
                        editor.extend(to: AurumCore.NormalizedPoint(
                            x: Double((value.location.x - frame.minX) / frame.width),
                            y: Double((value.location.y - frame.minY) / frame.height)
                        ))
                    }
                    .onEnded { _ in
                        editor.endStroke()
                        Haptics.detent()
                    }
            )
        }
        .accessibilityElement()
        .accessibilityLabel(String(localized: "Your photo. Drag to brush over what should be removed."))
        .accessibilityValue(editor.hasPaint ? String(localized: "Brushed") : String(localized: "Nothing brushed yet"))
    }
}
