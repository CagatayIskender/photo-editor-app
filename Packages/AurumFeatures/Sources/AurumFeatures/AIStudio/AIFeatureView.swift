import SwiftUI
import AurumCore
import AurumDesign
import AurumRender
import AurumServices

/// One AI feature: pick a photo, set its options, see the cost, run it, and
/// open the result in the Studio.
struct AIFeatureView: View {
    @ObservedObject var model: AIStudioViewModel
    @ObservedObject var app: AppModel
    let feature: AIFeature
    @State private var isPicking = false

    private var mode: AIFeatureMode { model.mode(for: feature) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.m) {
                Text(AIStudioViewModel.subtitle(for: feature))
                    .aurumText(.body, color: AurumColor.textSecondary)
                stage
                    .frame(maxWidth: .infinity)
                    .frame(height: 380)
                photoButton
                if mode == .comingSoon {
                    AtelierNote(
                        title: String(localized: "Coming soon"),
                        message: String(localized: "This tool runs on AURUM's servers, which open soon. Nothing is uploaded and no credits are used until then.")
                    )
                }
                if !model.inputs.isEmpty, model.phase != .result {
                    options
                }
                status
                actions
            }
            .padding(Spacing.m)
        }
        .background(AurumColor.background.ignoresSafeArea())
        .navigationTitle(AIStudioViewModel.title(for: feature))
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(AurumColor.background, for: .navigationBar)
        .sheet(isPresented: $isPicking) {
            MediaPickerView(app: app, required: feature.inputCount, title: feature.inputCount == 1 ? String(localized: "Choose a photo") : String(localized: "Choose \(feature.inputCount) photos")) { picked in
                isPicking = false
                Task { await model.setInputs(picked) }
            } onCancel: {
                isPicking = false
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
            if feature.requiresMask && mode != .comingSoon {
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
            .accessibilityIdentifier("ai.choosePhoto")
        }
    }

    private var photoButton: some View {
        HStack {
            Button(model.inputs.isEmpty ? String(localized: "Choose a photo") : String(localized: "Change photo")) { isPicking = true }
                .buttonStyle(TextActionButtonStyle())
                .disabled(model.isBusy)
            Spacer()
            Text(AIStudioViewModel.costText(feature))
                .aurumText(.label, color: AurumColor.accent)
                .accessibilityLabel(String(localized: "Cost, \(AIStudioViewModel.costText(feature))"))
        }
    }

    // MARK: Options

    @ViewBuilder
    private var options: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            if feature.requiresStyle {
                section(String(localized: "Style")) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: Spacing.xs) {
                            ForEach(model.styles) { style in
                                Chip(Localized.dynamic(style.name), isSelected: model.styleID == style.id, leadingIcon: style.tier == .member ? .crown : nil) {
                                    model.styleID = style.id
                                }
                            }
                        }
                    }
                }
            }
            if feature.acceptsPrompt && mode == .server {
                section(feature.requiresPrompt ? String(localized: "Describe the scene") : String(localized: "Description (optional)")) {
                    TextField(String(localized: "For example, a quiet terrace at golden hour"), text: $model.prompt, axis: .vertical)
                        .lineLimit(1...3)
                        .font(AurumTextStyle.body.font)
                        .foregroundColor(AurumColor.textPrimary)
                        .padding(Spacing.s)
                        .background(RoundedRectangle(cornerRadius: Radius.chip).fill(AurumColor.surface))
                    if let issue = model.promptIssue {
                        Text(issue).aurumText(.caption, color: AurumColor.textSecondary)
                    }
                }
            }
            if feature == .replaceBackground {
                section(String(localized: "Background")) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: Spacing.s) {
                            ForEach(AIBackgroundChoice.allCases) { choice in
                                backgroundSwatch(choice)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            if feature == .relight {
                section(String(localized: "Light from")) {
                    HStack(spacing: Spacing.xs) {
                        ForEach(OnDeviceAI.LightDirection.allCases, id: \.self) { direction in
                            Chip(Self.title(for: direction), isSelected: model.lightDirection == direction) {
                                model.lightDirection = direction
                            }
                        }
                    }
                    AurumSlider(value: $model.lightIntensity, in: 0...1, label: String(localized: "Light intensity"))
                }
            }
            if feature.requiresMask && mode != .comingSoon {
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
                }
            }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(title).aurumText(.label, color: AurumColor.textTertiary)
            content()
        }
    }

    private func backgroundSwatch(_ choice: AIBackgroundChoice) -> some View {
        let isSelected = model.background == choice
        return Button { model.background = choice; Haptics.detent() } label: {
            VStack(spacing: 6) {
                LinearGradient(colors: choice.swatch.map(Color.init(hex:)), startPoint: .top, endPoint: .bottom)
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.chip))
                    .overlay(RoundedRectangle(cornerRadius: Radius.chip).stroke(isSelected ? AurumColor.accent : AurumColor.hairline, lineWidth: isSelected ? 2 : 1))
                Text(choice.title).aurumText(.caption, color: isSelected ? AurumColor.textPrimary : AurumColor.textTertiary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    static func title(for direction: OnDeviceAI.LightDirection) -> String {
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
        case .working(let progress):
            HStack(spacing: Spacing.s) {
                if let progress {
                    ProgressView(value: progress).tint(AurumColor.accent)
                } else {
                    ProgressView().tint(AurumColor.accent)
                }
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
                    .accessibilityIdentifier("ai.openInStudio")
                Button("Discard") { model.discardResult() }
                    .buttonStyle(TextActionButtonStyle())
            }
        } else if case .working = model.phase, mode == .server || (mode == .onDevice && model.isServerAvailable) {
            Button("Cancel") { model.cancelJob() }
                .buttonStyle(TextActionButtonStyle())
        } else if !model.inputs.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.s) {
                if mode == .onDevice {
                    Button("Preview on device") { Task { await model.runOnDevice() } }
                        .buttonStyle(GoldButtonStyle())
                        .disabled(model.isBusy)
                        .accessibilityIdentifier("ai.runOnDevice")
                    Text("Free. Your photo stays on your iPhone.").aurumText(.caption, color: AurumColor.textTertiary)
                }
                if mode == .server || (mode == .onDevice && model.isServerAvailable) {
                    Button(String(localized: "Generate · \(AIStudioViewModel.costText(feature))")) { Task { await model.generate() } }
                        .buttonStyle(mode == .server ? AnyButtonStyle(GoldButtonStyle()) : AnyButtonStyle(GlassButtonStyle()))
                        .disabled(model.isBusy || model.generateIssue != nil)
                        .accessibilityIdentifier("ai.generate")
                    if let issue = model.generateIssue {
                        Text(issue).aurumText(.caption, color: AurumColor.textSecondary)
                    } else {
                        Text("Your photo is sent to AURUM's servers for this job only. Credits come back if it doesn't finish.")
                            .aurumText(.caption, color: AurumColor.textTertiary)
                    }
                }
            }
        }
    }
}

/// Type-erases a button style so one button can switch styles.
struct AnyButtonStyle: ButtonStyle {
    private let make: (Configuration) -> AnyView

    init<S: ButtonStyle>(_ style: S) {
        make = { AnyView(style.makeBody(configuration: $0)) }
    }

    func makeBody(configuration: Configuration) -> some View {
        make(configuration)
    }
}

/// The photo with brush strokes painted over it. Drag to paint (or erase).
struct MaskCanvas: View {
    let image: CGImage
    @Binding var editor: AIMaskEditor

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
                        strokes.append(AIMask.Stroke(points: editor.current, radius: editor.radius, isEraser: editor.isEraser))
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
                        editor.extend(to: NormalizedPoint(
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
