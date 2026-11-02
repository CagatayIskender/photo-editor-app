import SwiftUI
import AurumCore
import AurumDesign

extension StudioViewModel {
    /// A slider binding. Pair it with `sliderEditing` so a drag is one undo step.
    func binding(_ get: @escaping () -> Double, _ set: @escaping (Double) -> Void) -> Binding<Double> {
        Binding(get: get, set: set)
    }

    func sliderEditing(_ isEditing: Bool) {
        if isEditing { beginInteraction() } else { endInteraction() }
    }
}

/// Collections, a strip of live thumbnails rendered from the user's own
/// photo, and the intensity of the chosen look. Member looks can be tried
/// freely; they carry a crown, and membership is only asked for at export.
struct LooksSheet: View {
    @ObservedObject var model: StudioViewModel
    @State private var isSearching = false
    @State private var showsRefine = false
    @State private var isNamingPreset = false
    @State private var presetName = ""
    @State private var savedPreset: Preset?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            collectionBar
            thumbnails
            if let look = model.activeLook {
                intensity(look)
                if showsRefine { refine(look) }
            }
        }
        .padding(.bottom, Spacing.s)
        .alert("Save preset", isPresented: $isNamingPreset) {
            TextField("Name", text: $presetName)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                Task { savedPreset = await model.saveAsPreset(named: presetName.isEmpty ? String(localized: "My preset") : presetName) }
            }
        } message: {
            Text("Saves this edit's looks and adjustments so you can use them on any photo.")
        }
    }

    // MARK: Collections and search

    private var collectionBar: some View {
        HStack(spacing: Spacing.xs) {
            Button {
                isSearching.toggle()
                if !isSearching { model.lookQuery = "" }
            } label: {
                IconView(isSearching ? .close : .search, size: 20)
                    .foregroundColor(AurumColor.textSecondary)
                    .frame(width: Size.touch, height: 36)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isSearching ? String(localized: "Close search") : String(localized: "Search looks"))

            if isSearching {
                TextField("Warm, film, noir…", text: $model.lookQuery)
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)
                    .font(AurumTextStyle.body.font)
                    .foregroundColor(AurumColor.textPrimary)
                    .padding(.horizontal, Spacing.s)
                    .frame(height: 36)
                    .background(Capsule().fill(AurumColor.surfaceRaised))
                    .padding(.trailing, Spacing.m)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Spacing.xs) {
                        if !model.favouriteLookIDs.isEmpty {
                            Chip(String(localized: "Saved"), isSelected: model.selectedCollectionID == StudioViewModel.favouritesID) {
                                model.selectedCollectionID = StudioViewModel.favouritesID
                            }
                        }
                        ForEach(model.catalog.collections) { collection in
                            Chip(collection.name, isSelected: model.selectedCollectionID == collection.id) {
                                model.selectedCollectionID = collection.id
                            }
                        }
                    }
                    .padding(.trailing, Spacing.m)
                }
            }
        }
        .padding(.leading, Spacing.xs)
    }

    private var thumbnails: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: Spacing.s) {
                    ForEach(model.visibleLooks) { look in
                        Button { model.selectLook(look.id); Haptics.apply() } label: {
                            LookThumbnail(
                                name: look.name,
                                image: model.thumbnails[look.id].map { Image(decorative: $0, scale: 1) },
                                swatch: look.swatch.map(Color.init(hex:)),
                                isSelected: model.activeLook?.lookID == look.id,
                                isPremium: look.tier == .member
                            )
                        }
                        .buttonStyle(.plain)
                        .id(look.id)
                        .onAppear { model.requestThumbnail(for: look.id) }
                        .contextMenu {
                            Button { model.toggleFavourite(look.id) } label: {
                                Label(model.favouriteLookIDs.contains(look.id) ? String(localized: "Remove from Saved") : String(localized: "Save look"), systemImage: "bookmark")
                            }
                        }
                        .accessibilityAction(named: model.favouriteLookIDs.contains(look.id) ? String(localized: "Remove from Saved") : String(localized: "Save look")) {
                            model.toggleFavourite(look.id)
                        }
                    }
                }
                .padding(.horizontal, Spacing.m)
                .padding(.vertical, 4)
            }
            .frame(height: 112)
            .onChange(of: model.activeLook?.lookID) { id in
                guard let id else { return }
                withAnimation(Motion.respectingReduceMotion(Motion.velvet)) { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }

    // MARK: Intensity and refine

    private func intensity(_ look: LookApplication) -> some View {
        HStack(spacing: Spacing.s) {
            AurumSlider(
                value: model.binding({ model.activeLook?.intensity ?? 0 }, { model.setLookIntensity($0) }),
                in: 0...1,
                label: String(localized: "Intensity"),
                onEditingChanged: model.sliderEditing
            )
            Button(showsRefine ? String(localized: "Done") : String(localized: "Refine")) { showsRefine.toggle() }
                .buttonStyle(TextActionButtonStyle())
            Menu {
                Button("Save as preset") {
                    presetName = model.activeLookRecipe?.name ?? ""
                    isNamingPreset = true
                }
                if let savedPreset, let url = model.shareLink(for: savedPreset) {
                    ShareLink("Share “\(savedPreset.name)”", item: url)
                }
            } label: {
                IconView(.layers, size: 20).foregroundColor(AurumColor.textSecondary).frame(width: Size.touch, height: Size.touch)
            }
            .accessibilityLabel("Preset options")
        }
        .padding(.horizontal, Spacing.m)
    }

    private func refine(_ look: LookApplication) -> some View {
        VStack(spacing: Spacing.xs) {
            refineSlider(String(localized: "Grain"), \.grain, base: model.activeLookRecipe?.params.grain ?? 0, look: look)
            refineSlider(String(localized: "Fade"), \.fade, base: model.activeLookRecipe?.params.fade ?? 0, look: look)
            refineSlider(String(localized: "Vignette"), \.vignette, base: model.activeLookRecipe?.params.vignette ?? 0, look: look)
            refineSlider(String(localized: "Light leak"), \.lightLeak, base: model.activeLookRecipe?.params.lightLeak ?? 0, look: look)
        }
        .padding(.horizontal, Spacing.m)
    }

    /// Refine values override the recipe's own; the slider starts at the recipe value.
    private func refineSlider(_ label: String, _ key: WritableKeyPath<RefineOverrides, Double?>, base: Double, look: LookApplication) -> some View {
        AurumSlider(
            value: model.binding(
                { model.activeLook?.refine[keyPath: key] ?? base },
                { value in
                    var refine = model.activeLook?.refine ?? RefineOverrides()
                    refine[keyPath: key] = value
                    model.setRefine(refine)
                }
            ),
            in: 0...1,
            label: label,
            onEditingChanged: model.sliderEditing
        )
    }
}
