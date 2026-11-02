import SwiftUI
import AurumCore
import AurumDesign
import AurumServices

/// Recent photos in a grid. One tap opens the photo in the Studio.
/// Limited access is respected and explained, never nagged about.
struct PickerView: View {
    @ObservedObject var app: AppModel
    @State private var items: [LibraryPhoto] = []
    @State private var access: LibraryAccess = .notDetermined
    @State private var isLoading = true

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    /// Fixed columns on a phone; on iPad as many as the width allows.
    private var columns: [GridItem] {
        if horizontalSizeClass == .regular {
            return [GridItem(.adaptive(minimum: 128), spacing: 2)]
        }
        return Array(repeating: GridItem(.flexible(), spacing: 2), count: 3)
    }

    var body: some View {
        NavigationStack {
            content
                .background(AurumColor.background.ignoresSafeArea())
                .navigationTitle("Choose a photo")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            app.isPickerPresented = false
                            app.queuedLookID = nil
                        }
                        .foregroundColor(AurumColor.textSecondary)
                    }
                }
                .toolbarBackground(AurumColor.background, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
        .task { await load() }
    }

    @ViewBuilder
    private var content: some View {
        switch access {
        case .denied:
            deniedState
        default:
            ScrollView {
                if access == .limited {
                    Text("AURUM can see only the photos you selected. You can change this in Settings.")
                        .aurumText(.caption, color: AurumColor.textSecondary)
                        .padding(Spacing.m)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if isLoading && items.isEmpty {
                    skeletonGrid
                }
                LazyVGrid(columns: columns, spacing: 2) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        PickerCell(item: item, photos: app.deps.photos) { app.openPhoto(item) }
                            .accessibilityLabel(cellLabel(item, index: index))
                            .accessibilityIdentifier("picker.cell.\(index)")
                    }
                }
                if !isLoading && items.isEmpty {
                    VStack(spacing: Spacing.s) {
                        IconView(.camera, size: 28).foregroundColor(AurumColor.textTertiary)
                        Text("No photos yet.").aurumText(.body, color: AurumColor.textTertiary)
                    }
                    .padding(Spacing.xl)
                    .frame(maxWidth: .infinity)
                    .transition(.opacity)
                }
            }
        }
    }

    /// Placeholder tiles shown until the library answers.
    private var skeletonGrid: some View {
        LazyVGrid(columns: columns, spacing: 2) {
            ForEach(0..<18, id: \.self) { _ in
                SkeletonBlock(cornerRadius: 0)
                    .aspectRatio(1, contentMode: .fill)
            }
        }
        .transition(.identity) // leave at once so the real grid never sits below it
        .accessibilityHidden(true)
    }

    private var deniedState: some View {
        VStack(spacing: Spacing.m) {
            IconView(.camera, size: 32).foregroundColor(AurumColor.textTertiary)
            Text("Photo access is off").aurumText(.title)
            Text("To edit a photo, allow AURUM to access your photos in Settings.")
                .aurumText(.body, color: AurumColor.textSecondary)
                .multilineTextAlignment(.center)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
            .buttonStyle(GoldButtonStyle(compact: true))
        }
        .padding(Spacing.xl)
        .frame(maxHeight: .infinity)
    }

    private func cellLabel(_ item: LibraryPhoto, index: Int) -> String {
        if let date = item.creationDate {
            return String(localized: "Photo, \(date.formatted(date: .abbreviated, time: .shortened))")
        }
        return String(localized: "Photo \(index + 1)")
    }

    private func load() async {
        access = app.deps.photos.access()
        if access == .notDetermined { access = await app.deps.photos.requestAccess() }
        guard access == .full || access == .limited else { isLoading = false; return }
        let loaded = await app.deps.photos.recentPhotos(limit: 300)
        withAnimation(Motion.respectingReduceMotion(Motion.velvet)) {
            items = loaded
            isLoading = false
        }
    }
}

struct PickerCell: View {
    let item: LibraryPhoto
    let photos: PhotoLibraryService
    let onSelect: () -> Void
    @State private var image: UIImage?

    var body: some View {
        Button(action: onSelect) {
            AurumColor.surface
                .aspectRatio(1, contentMode: .fill)
                .overlay {
                    if let image {
                        Image(uiImage: image).resizable().scaledToFill()
                            .transition(.opacity)
                    }
                }
                .clipped()
                .animation(Motion.respectingReduceMotion(Motion.velvet), value: image != nil)
                .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .accessibilityAddTraits(.isButton)
        .task(id: item.id) {
            image = await photos.thumbnail(for: item.id, side: 240)
        }
    }
}
