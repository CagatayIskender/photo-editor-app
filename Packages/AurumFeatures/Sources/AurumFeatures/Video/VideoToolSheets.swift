import SwiftUI
import UniformTypeIdentifiers
import AurumCore
import AurumDesign

/// The sheet for the active video tool.
struct VideoToolSheet: View {
    let tool: VideoTool
    @ObservedObject var model: VideoEditorViewModel

    var body: some View {
        Group {
            switch tool {
            case .trim: TrimSheet(model: model)
            case .speed: SpeedSheet(model: model)
            case .volume: VolumeSheet(model: model)
            case .transition: TransitionSheet(model: model)
            case .music: MusicSheet(model: model)
            case .text: VideoTextSheet(model: model)
            case .effects: EffectsSheet(model: model)
            case .look: VideoLookSheet(model: model)
            case .bookends: BookendsSheet(model: model)
            case .aspect: VideoAspectSheet(model: model)
            case .split, .reverse: EmptyView()
            }
        }
        .padding(.bottom, Spacing.s)
    }
}

/// A caption shown when a tool needs a clip and none is selected.
private struct SelectClipHint: View {
    var body: some View {
        Text("Tap a clip on the timeline first.")
            .aurumText(.caption, color: AurumColor.textTertiary)
            .padding(.horizontal, Spacing.m)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Trim

/// Precise in and out points, plus moving and deleting the clip.
struct TrimSheet: View {
    @ObservedObject var model: VideoEditorViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            if let clip = model.selectedClip, let index = model.selectedClipIndex {
                HStack {
                    Text(clip.kind == .video ? String(localized: "Clip \(index + 1)") : String(localized: "Photo \(index + 1)"))
                        .aurumText(.headline)
                    Spacer()
                    Text(verbatim: Self.seconds(clip.duration))
                        .aurumText(.caption, color: AurumColor.textSecondary)
                        .monospacedDigit()
                }
                .padding(.horizontal, Spacing.m)

                if clip.kind == .video {
                    labelled(String(localized: "Start")) {
                        AurumSlider(
                            value: model.binding({ clip.trimStart }, { model.trimSelected(start: $0, end: model.selectedClip?.trimEnd ?? clip.trimEnd) }),
                            in: 0...max(clip.sourceDuration, Clip.minimumDuration * 2),
                            detentStep: 1,
                            label: String(localized: "Start"),
                            onEditingChanged: model.sliderEditing
                        )
                    }
                    labelled(String(localized: "End")) {
                        AurumSlider(
                            value: model.binding({ clip.trimEnd }, { model.trimSelected(start: model.selectedClip?.trimStart ?? clip.trimStart, end: $0) }),
                            in: 0...max(clip.sourceDuration, Clip.minimumDuration * 2),
                            detentStep: 1,
                            label: String(localized: "End"),
                            onEditingChanged: model.sliderEditing
                        )
                    }
                } else {
                    labelled(String(localized: "Length")) {
                        AurumSlider(
                            value: model.binding({ min(max(clip.trimEnd - clip.trimStart, 0.5), 10) }, { value in
                                guard let id = model.selectedClipID else { return }
                                model.edit { $0.updateClip(id: id) { photo in
                                    photo.sourceDuration = max(value, Clip.minimumDuration)
                                    photo.trim(start: 0, end: value)
                                } }
                            }),
                            in: 0.5...10,
                            detentStep: 0.5,
                            label: String(localized: "Length"),
                            onEditingChanged: model.sliderEditing
                        )
                    }
                }

                HStack(spacing: Spacing.l) {
                    Button("Move earlier") { model.moveSelectedClip(by: -1) }
                        .buttonStyle(TextActionButtonStyle())
                        .disabled(index == 0)
                    Button("Move later") { model.moveSelectedClip(by: 1) }
                        .buttonStyle(TextActionButtonStyle())
                        .disabled(index >= model.project.clips.count - 1)
                    Spacer()
                    Button("Delete") { model.deleteSelectedClip(); Haptics.warning() }
                        .buttonStyle(TextActionButtonStyle())
                        .disabled(!model.canDeleteClip)
                }
                .padding(.horizontal, Spacing.m)
            } else {
                SelectClipHint()
            }
        }
    }

    private func labelled<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: Spacing.s) {
            Text(title).aurumText(.label, color: AurumColor.textTertiary).frame(width: 64, alignment: .leading)
            content()
        }
        .padding(.horizontal, Spacing.m)
    }

    static func seconds(_ value: Seconds) -> String {
        String(localized: "\(value.formatted(.number.precision(.fractionLength(1)))) s")
    }
}

// MARK: - Speed

struct SpeedSheet: View {
    @ObservedObject var model: VideoEditorViewModel
    static let speeds: [Double] = [0.25, 0.5, 1, 1.5, 2, 4]

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            if let clip = model.selectedClip {
                Text("Speed").aurumText(.headline).padding(.horizontal, Spacing.m)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Spacing.xs) {
                        ForEach(Self.speeds, id: \.self) { speed in
                            Chip("\(speed.formatted(.number.precision(.fractionLength(0...2))))×", isSelected: abs(clip.speed - speed) < 0.001) {
                                model.setSpeed(speed)
                                Haptics.detent()
                            }
                        }
                    }
                    .padding(.horizontal, Spacing.m)
                }
                Text("Slower clips last longer on the timeline.")
                    .aurumText(.caption, color: AurumColor.textTertiary)
                    .padding(.horizontal, Spacing.m)
            } else {
                SelectClipHint()
            }
        }
    }
}

// MARK: - Volume

struct VolumeSheet: View {
    @ObservedObject var model: VideoEditorViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            if let clip = model.selectedClip {
                if clip.kind == .video {
                    row(String(localized: "Clip sound"), value: clip.volume) {
                        AurumSlider(
                            value: model.binding({ model.selectedClip?.volume ?? 0 }, { model.setVolume($0) }),
                            in: 0...1,
                            label: String(localized: "Clip sound"),
                            onEditingChanged: model.sliderEditing
                        )
                    }
                    if clip.isReversed {
                        Text("Reversed clips play without sound.")
                            .aurumText(.caption, color: AurumColor.textTertiary)
                            .padding(.horizontal, Spacing.m)
                    }
                } else {
                    Text("Photos have no sound.")
                        .aurumText(.caption, color: AurumColor.textTertiary)
                        .padding(.horizontal, Spacing.m)
                }
            } else {
                SelectClipHint()
            }
            if let music = model.project.music {
                row(String(localized: "Music"), value: music.volume) {
                    AurumSlider(
                        value: model.binding({ model.project.music?.volume ?? 0 }, { model.setMusicVolume($0) }),
                        in: 0...1,
                        label: String(localized: "Music"),
                        onEditingChanged: model.sliderEditing
                    )
                }
            }
        }
    }

    private func row<Content: View>(_ title: String, value: Double, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title).aurumText(.headline)
                Spacer()
                Text(verbatim: "\(Int((value * 100).rounded()))")
                    .aurumText(.caption, color: AurumColor.textSecondary)
                    .monospacedDigit()
            }
            content()
        }
        .padding(.horizontal, Spacing.m)
    }
}

// MARK: - Transition

struct TransitionSheet: View {
    @ObservedObject var model: VideoEditorViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            if let clip = model.selectedClip, let index = model.selectedClipIndex {
                if index == 0 {
                    Text("The first clip opens the video, so it has no transition. Select a later clip.")
                        .aurumText(.caption, color: AurumColor.textTertiary)
                        .padding(.horizontal, Spacing.m)
                } else {
                    Text("Into clip \(index + 1)").aurumText(.headline).padding(.horizontal, Spacing.m)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: Spacing.xs) {
                            ForEach(TransitionChoice.allCases) { choice in
                                Chip(choice.title, isSelected: TransitionChoice(clip.transitionIn) == choice) {
                                    model.setTransition(choice)
                                    Haptics.detent()
                                }
                            }
                        }
                        .padding(.horizontal, Spacing.m)
                    }
                }
            } else {
                SelectClipHint()
            }
        }
    }
}

// MARK: - Music

/// Library tracks, songs the user imported, and the music volume.
struct MusicSheet: View {
    @ObservedObject var model: VideoEditorViewModel
    @State private var imported: [URL] = []
    @State private var isImporting = false
    @State private var importFailed = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack {
                Text(model.project.music?.title ?? String(localized: "No music")).aurumText(.headline).lineLimit(1)
                Spacer()
                if model.project.music != nil {
                    Button("Remove") { model.setMusic(nil) }.buttonStyle(TextActionButtonStyle())
                }
                Button("Import a song") { isImporting = true }.buttonStyle(TextActionButtonStyle())
            }
            .padding(.horizontal, Spacing.m)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Spacing.xs) {
                    ForEach(model.content.music) { track in
                        Chip(track.title, isSelected: isSelected(.library(trackID: track.id))) {
                            model.useLibraryTrack(track)
                            Haptics.detent()
                        }
                        .overlay(alignment: .topTrailing) {
                            if track.tier == .member { CrownBadge(size: 14).offset(x: 4, y: -4) }
                        }
                    }
                    ForEach(imported, id: \.self) { url in
                        Chip(url.deletingPathExtension().lastPathComponent, isSelected: isSelected(.imported(fileName: url.lastPathComponent)), leadingIcon: .music) {
                            model.useImportedSong(fileName: url.lastPathComponent)
                            Haptics.detent()
                        }
                    }
                }
                .padding(.horizontal, Spacing.m)
                .padding(.vertical, 4)
            }

            if model.content.music.isEmpty && imported.isEmpty {
                Text("Import a song from Files to play under your video.")
                    .aurumText(.caption, color: AurumColor.textTertiary)
                    .padding(.horizontal, Spacing.m)
            }
            if importFailed {
                Text("That song couldn't be imported.")
                    .aurumText(.caption, color: AurumColor.textSecondary)
                    .padding(.horizontal, Spacing.m)
            }
            if model.project.music != nil {
                AurumSlider(
                    value: model.binding({ model.project.music?.volume ?? 0 }, { model.setMusicVolume($0) }),
                    in: 0...1,
                    label: String(localized: "Music volume"),
                    onEditingChanged: model.sliderEditing
                )
                .padding(.horizontal, Spacing.m)
            }
        }
        .onAppear { imported = LibraryMediaSource.importedSongs() }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.audio], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                do {
                    let name = try LibraryMediaSource.importSong(from: url)
                    imported = LibraryMediaSource.importedSongs()
                    importFailed = false
                    model.useImportedSong(fileName: name)
                } catch {
                    importFailed = true
                }
            case .failure:
                importFailed = true
            }
        }
    }

    private func isSelected(_ source: MusicSelection.Source) -> Bool {
        model.project.music?.source == source
    }
}

// MARK: - Text

/// Adds timed text and sets its words, in and out animation and timing.
struct VideoTextSheet: View {
    @ObservedObject var model: VideoEditorViewModel
    @FocusState private var isEditingWords: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            if let layer = model.selectedLayer, case .text(let text) = layer.overlay.content {
                editor(layer, text: text)
            } else {
                Button {
                    model.addText()
                    isEditingWords = true
                } label: {
                    Label { Text("Add text") } icon: { IconView(.text, size: 18) }
                }
                .buttonStyle(GoldButtonStyle(compact: true))
                .padding(.horizontal, Spacing.m)
                Text("Text appears at the playhead for three seconds. Tap its bar under the timeline to edit it.")
                    .aurumText(.caption, color: AurumColor.textTertiary)
                    .padding(.horizontal, Spacing.m)
            }
        }
    }

    @ViewBuilder
    private func editor(_ layer: TimedLayer, text: TextOverlay) -> some View {
        HStack(spacing: Spacing.xs) {
            TextField("Your words", text: Binding(
                get: { text.text },
                set: { value in model.updateSelectedText { $0.text = value } }
            ))
            .focused($isEditingWords)
            .font(AurumTextStyle.body.font)
            .foregroundColor(AurumColor.textPrimary)
            .padding(.horizontal, Spacing.s)
            .frame(height: 40)
            .background(RoundedRectangle(cornerRadius: Radius.chip).fill(AurumColor.surfaceRaised))
            IconButton(.close, label: String(localized: "Delete text")) { model.removeSelectedLayer() }
        }
        .padding(.horizontal, Spacing.m)

        animationRow(String(localized: "In"), selected: layer.animationIn) { value in model.updateSelectedLayer { $0.animationIn = value } }
        animationRow(String(localized: "Out"), selected: layer.animationOut) { value in model.updateSelectedLayer { $0.animationOut = value } }

        HStack(spacing: Spacing.l) {
            Button("Start here") { model.setSelectedLayerBound(atPlayhead: true) }
                .buttonStyle(TextActionButtonStyle())
            Button("End here") { model.setSelectedLayerBound(atPlayhead: false) }
                .buttonStyle(TextActionButtonStyle())
            Spacer()
            Text(verbatim: "\(VideoEditorView.timecode(layer.start)) – \(VideoEditorView.timecode(layer.end))")
                .aurumText(.caption, color: AurumColor.textTertiary)
                .monospacedDigit()
        }
        .padding(.horizontal, Spacing.m)
    }

    private func animationRow(_ title: String, selected: LayerAnimation, set: @escaping (LayerAnimation) -> Void) -> some View {
        HStack(spacing: Spacing.xs) {
            Text(title).aurumText(.label, color: AurumColor.textTertiary).frame(width: 36, alignment: .leading)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Spacing.xs) {
                    ForEach(LayerAnimation.allCases, id: \.self) { animation in
                        Chip(Localized.dynamic(animation.displayName), isSelected: animation == selected) {
                            set(animation)
                            Haptics.detent()
                        }
                    }
                }
            }
        }
        .padding(.leading, Spacing.m)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}

// MARK: - Effects

/// Animated effects over the whole video. Member effects carry a crown and
/// can be tried freely; membership is asked for only at export.
struct EffectsSheet: View {
    @ObservedObject var model: VideoEditorViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Spacing.xs) {
                    ForEach(AnimatedEffect.Kind.allCases, id: \.self) { kind in
                        let effect = model.effect(of: kind)
                        Chip(Localized.dynamic(kind.displayName), isSelected: effect != nil, leadingIcon: .effects) {
                            if let effect, model.selectedEffectID != effect.id {
                                model.selectedEffectID = effect.id
                            } else {
                                model.toggleEffect(kind)
                            }
                            Haptics.apply()
                        }
                        .overlay(alignment: .topTrailing) {
                            if VideoEditorViewModel.tier(for: kind) == .member {
                                CrownBadge(size: 14).offset(x: 4, y: -4)
                            }
                        }
                        .accessibilityHint(effect == nil ? String(localized: "Adds the effect") : String(localized: "Selects the effect; tap again to remove it"))
                    }
                }
                .padding(.horizontal, Spacing.m)
                .padding(.vertical, 4)
            }
            if let id = model.selectedEffectID, let effect = model.project.effects.first(where: { $0.id == id }) {
                HStack(spacing: Spacing.s) {
                    AurumSlider(
                        value: model.binding({ model.project.effects.first { $0.id == id }?.intensity ?? 0 }, { model.setEffectIntensity($0) }),
                        in: 0...1,
                        label: String(localized: "\(Localized.dynamic(effect.kind.displayName)) intensity"),
                        onEditingChanged: model.sliderEditing
                    )
                    Button("Remove") { model.removeEffect(id: id) }
                        .buttonStyle(TextActionButtonStyle())
                }
                .padding(.horizontal, Spacing.m)
            } else {
                Text("Tap an effect to add it to the whole video.")
                    .aurumText(.caption, color: AurumColor.textTertiary)
                    .padding(.horizontal, Spacing.m)
            }
        }
    }
}

// MARK: - Look

/// One look graded over every clip, from the same catalogue as photos.
struct VideoLookSheet: View {
    @ObservedObject var model: VideoEditorViewModel
    @State private var collectionID: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Spacing.xs) {
                    ForEach(model.catalog.collections) { collection in
                        Chip(collection.name, isSelected: currentCollection == collection.id) {
                            collectionID = collection.id
                        }
                    }
                }
                .padding(.horizontal, Spacing.m)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: Spacing.s) {
                    ForEach(model.catalog.looks(in: currentCollection)) { look in
                        Button { model.selectLook(look.id); Haptics.apply() } label: {
                            LookThumbnail(
                                name: look.name,
                                image: nil,
                                swatch: look.swatch.map(Color.init(hex:)),
                                isSelected: model.activeLook?.lookID == look.id,
                                isPremium: look.tier == .member
                            )
                        }
                        .buttonStyle(.pressable)
                    }
                }
                .padding(.horizontal, Spacing.m)
                .padding(.vertical, 4)
            }
            .frame(height: 112)
            if model.activeLook != nil {
                AurumSlider(
                    value: model.binding({ model.activeLook?.intensity ?? 0 }, { model.setLookIntensity($0) }),
                    in: 0...1,
                    label: String(localized: "Intensity"),
                    onEditingChanged: model.sliderEditing
                )
                .padding(.horizontal, Spacing.m)
            }
        }
    }

    private var currentCollection: String {
        if !collectionID.isEmpty { return collectionID }
        if let id = model.activeLook?.lookID, let look = model.catalog.look(id: id) { return look.collection }
        return model.catalog.collections.first?.id ?? ""
    }
}

// MARK: - Intro and outro

struct BookendsSheet: View {
    @ObservedObject var model: VideoEditorViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            row(String(localized: "Intro"), presets: model.introPresets, current: model.project.intro, isIntro: true)
            row(String(localized: "Outro"), presets: model.outroPresets, current: model.project.outro, isIntro: false)
        }
    }

    @ViewBuilder
    private func row(_ title: String, presets: [BookendPreset], current: BookendEffect?, isIntro: Bool) -> some View {
        Text(title).aurumText(.label, color: AurumColor.textTertiary).padding(.horizontal, Spacing.m)
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Spacing.xs) {
                Chip(String(localized: "None"), isSelected: current == nil) {
                    if isIntro { model.setIntro(nil) } else { model.setOutro(nil) }
                }
                ForEach(presets) { preset in
                    Chip(preset.name, isSelected: current?.presetID == preset.id) {
                        if isIntro { model.setIntro(preset) } else { model.setOutro(preset) }
                        Haptics.apply()
                    }
                    .overlay(alignment: .topTrailing) {
                        if preset.tier == .member { CrownBadge(size: 14).offset(x: 4, y: -4) }
                    }
                }
            }
            .padding(.horizontal, Spacing.m)
            .padding(.vertical, 4)
        }
        if current != nil {
            TextField(isIntro ? String(localized: "Opening title (optional)") : String(localized: "Closing title (optional)"), text: Binding(
                get: { current?.title ?? "" },
                set: { model.setBookendTitle($0, intro: isIntro) }
            ))
            .font(AurumTextStyle.body.font)
            .foregroundColor(AurumColor.textPrimary)
            .padding(.horizontal, Spacing.s)
            .frame(height: 36)
            .background(RoundedRectangle(cornerRadius: Radius.chip).fill(AurumColor.surfaceRaised))
            .padding(.horizontal, Spacing.m)
        }
    }
}

// MARK: - Aspect

struct VideoAspectSheet: View {
    @ObservedObject var model: VideoEditorViewModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Spacing.xs) {
                ForEach(VideoEditorViewModel.aspects, id: \.self) { aspect in
                    Chip(Localized.dynamic(aspect.label), isSelected: model.project.aspect == aspect) {
                        model.setAspect(aspect)
                        Haptics.detent()
                    }
                }
            }
            .padding(.horizontal, Spacing.m)
        }
    }
}
