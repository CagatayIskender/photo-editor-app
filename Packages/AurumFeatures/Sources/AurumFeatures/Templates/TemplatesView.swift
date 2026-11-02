import SwiftUI
import AurumCore
import AurumDesign

/// One-tap video templates. Pick one, pick its photos and clips, and the
/// edit is built on the beat and opened in the video editor.
struct TemplatesView: View {
    @ObservedObject var app: AppModel
    @StateObject private var model: TemplatesViewModel
    @State private var path: [String] = []
    @State private var hasAppeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let columns = [GridItem(.flexible(), spacing: Spacing.s), GridItem(.flexible(), spacing: Spacing.s)]

    init(app: AppModel) {
        self.app = app
        _model = StateObject(wrappedValue: TemplatesViewModel(deps: app.deps))
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.m) {
                    Text("Choose a template, add your photos and clips, and AURUM cuts them to the beat.")
                        .aurumText(.body, color: AurumColor.textSecondary)
                        .padding(.horizontal, Spacing.m)
                    if model.templates.isEmpty {
                        Text("No templates yet.")
                            .aurumText(.body, color: AurumColor.textTertiary)
                            .padding(Spacing.xl)
                            .frame(maxWidth: .infinity)
                    }
                    LazyVGrid(columns: columns, spacing: Spacing.s) {
                        ForEach(Array(model.templates.enumerated()), id: \.element.id) { index, template in
                            NavigationLink(value: template.id) {
                                TemplateCard(template: template, swatch: model.swatch(for: template).map(Color.init(hex:)))
                            }
                            .buttonStyle(.plain)
                            .opacity(hasAppeared || reduceMotion ? 1 : 0)
                            .offset(y: hasAppeared || reduceMotion ? 0 : 16)
                            .animation(Motion.respectingReduceMotion(Motion.atelier.delay(Double(index) * 0.05)), value: hasAppeared)
                            .accessibilityIdentifier("templates.card.\(index)")
                        }
                    }
                    .padding(.horizontal, Spacing.m)
                }
                .padding(.vertical, Spacing.m)
            }
            .background(AurumColor.background.ignoresSafeArea())
            .navigationTitle("Templates")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { app.closeFlow() }
                        .foregroundColor(AurumColor.textSecondary)
                }
            }
            .toolbarBackground(AurumColor.background, for: .navigationBar)
            .navigationDestination(for: String.self) { id in
                if let template = model.templates.first(where: { $0.id == id }) {
                    MediaPickerView(app: app, required: template.mediaCount, title: template.name, embedded: true) { picked in
                        if let project = model.build(template, media: picked) {
                            app.openVideo(project, source: "template")
                        }
                    }
                }
            }
            .alert("Couldn't build the video", isPresented: Binding(get: { model.failure != nil }, set: { if !$0 { model.failure = nil } })) {
                Button("Done", role: .cancel) {}
            } message: {
                Text(model.failure ?? "")
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { hasAppeared = true }
    }
}

/// A template's card: its grade as a gradient, name, tagline, how many
/// photos or clips it takes, its length, and the crown if it's for members.
struct TemplateCard: View {
    let template: TemplateDefinition
    let swatch: [Color]

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            Spacer(minLength: 0)
            Text(template.name).aurumText(.editorial).lineLimit(2)
            Text(template.tagline).aurumText(.caption, color: AurumColor.textSecondary).lineLimit(2)
            HStack(spacing: Spacing.xs) {
                Text(TemplatesViewModel.mediaCountText(template.mediaCount))
                Text(verbatim: "·")
                Text(verbatim: VideoEditorView.timecode(TemplatesViewModel.length(of: template)))
            }
            .aurumText(.label, color: AurumColor.textSecondary)
            .padding(.top, Spacing.xxs)
            Text("Use")
                .font(AurumTextStyle.caption.font.weight(.semibold))
                .foregroundColor(AurumColor.onAccent)
                .padding(.horizontal, Spacing.s)
                .frame(height: 28)
                .background(Capsule().fill(AurumColor.accent))
                .padding(.top, Spacing.xs)
        }
        .padding(Spacing.s)
        .frame(maxWidth: .infinity, minHeight: 220, alignment: .leading)
        .background(
            LinearGradient(colors: swatch.isEmpty ? [AurumColor.surfaceRaised, AurumColor.surface] : swatch, startPoint: .topTrailing, endPoint: .bottomLeading)
                .overlay(LinearGradient(colors: [.clear, AurumColor.background.opacity(0.92)], startPoint: .top, endPoint: .bottom))
        )
        .clipShape(RoundedRectangle(cornerRadius: Radius.card))
        .overlay(RoundedRectangle(cornerRadius: Radius.card).stroke(AurumColor.hairline, lineWidth: 1))
        .overlay(alignment: .topTrailing) {
            if template.tier == .member { CrownBadge(size: 22).padding(Spacing.xs) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(.isButton)
    }

    private var accessibilityText: String {
        let base = "\(template.name), \(template.tagline), \(TemplatesViewModel.mediaCountText(template.mediaCount))"
        return template.tier == .member ? String(localized: "\(base), members only") : base
    }
}
