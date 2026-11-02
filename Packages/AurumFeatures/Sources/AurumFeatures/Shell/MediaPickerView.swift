import SwiftUI
import AurumCore
import AurumDesign
import AurumServices

/// A photo or video picked for a video or template.
public struct PickedMedia: Identifiable, Hashable, Sendable {
    public enum Kind: Hashable, Sendable { case photo, video }

    public let id: String
    public let kind: Kind
    public let pixelSize: PixelSize
    /// Video length in seconds; 0 for photos.
    public let duration: Double
    public let creationDate: Date?

    public init(id: String, kind: Kind, pixelSize: PixelSize, duration: Double = 0, creationDate: Date? = nil) {
        self.id = id
        self.kind = kind
        self.pixelSize = pixelSize
        self.duration = duration
        self.creationDate = creationDate
    }

    public var source: SourceAsset { SourceAsset(localIdentifier: id, pixelSize: pixelSize) }

    /// The clip this item becomes on a plain timeline.
    public var clip: Clip {
        switch kind {
        case .photo: return Clip.photo(source)
        case .video: return Clip(kind: .video, source: source, sourceDuration: duration)
        }
    }

    /// The item as template media.
    public var templateMedia: TemplateMedia {
        TemplateMedia(source: source, kind: kind == .video ? .video : .photo, duration: duration)
    }
}

/// Recent photos and videos in one grid, picked in order. The order of
/// picking is the order on the timeline, shown as a number on each pick.
struct MediaPickerView: View {
    enum Filter: Hashable { case all, photos, videos }

    @ObservedObject var app: AppModel
    /// How many items a template asks for, or nil for any number.
    let required: Int?
    let title: String
    let onDone: ([PickedMedia]) -> Void
    let onCancel: () -> Void
    /// True when pushed inside another navigation stack, such as Templates.
    let embedded: Bool

    @State private var items: [PickedMedia] = []
    @State private var picked: [PickedMedia] = []
    @State private var access: LibraryAccess = .notDetermined
    @State private var isLoading = true
    @State private var filter: Filter = .all

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 3)

    init(app: AppModel, required: Int?, title: String, embedded: Bool = false, onDone: @escaping ([PickedMedia]) -> Void, onCancel: @escaping () -> Void = {}) {
        self.app = app
        self.required = required
        self.title = title
        self.embedded = embedded
        self.onDone = onDone
        self.onCancel = onCancel
    }

    var body: some View {
        if embedded {
            page
        } else {
            NavigationStack {
                page
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel", action: onCancel)
                                .foregroundColor(AurumColor.textSecondary)
                        }
                    }
            }
            .preferredColorScheme(.dark)
        }
    }

    private var page: some View {
        content
            .background(AurumColor.background.ignoresSafeArea())
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(AurumColor.background, for: .navigationBar)
            .task { await load() }
    }

    @ViewBuilder
    private var content: some View {
        switch access {
        case .denied:
            MediaAccessDeniedView()
        default:
            VStack(spacing: 0) {
                filterBar
                ScrollView {
                    if access == .limited {
                        Text("AURUM can see only the photos you selected. You can change this in Settings.")
                            .aurumText(.caption, color: AurumColor.textSecondary)
                            .padding(Spacing.m)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    LazyVGrid(columns: columns, spacing: 2) {
                        ForEach(Array(visibleItems.enumerated()), id: \.element.id) { index, item in
                            MediaPickerCell(item: item, photos: app.deps.photos, order: picked.firstIndex(of: item).map { $0 + 1 }) {
                                toggle(item)
                            }
                            .accessibilityLabel(cellLabel(item, index: index))
                            .accessibilityIdentifier("mediaPicker.cell.\(index)")
                        }
                    }
                    if !isLoading && visibleItems.isEmpty {
                        Text("Nothing here yet.").aurumText(.body, color: AurumColor.textTertiary).padding(Spacing.xl)
                    }
                }
                footer
            }
        }
    }

    private var filterBar: some View {
        HStack(spacing: Spacing.xs) {
            Chip(String(localized: "All"), isSelected: filter == .all) { filter = .all }
            Chip(String(localized: "Photos"), isSelected: filter == .photos) { filter = .photos }
            Chip(String(localized: "Videos"), isSelected: filter == .videos) { filter = .videos }
            Spacer()
        }
        .padding(.horizontal, Spacing.m)
        .padding(.vertical, Spacing.xs)
    }

    private var footer: some View {
        HStack(spacing: Spacing.s) {
            Text(countText)
                .aurumText(.caption, color: AurumColor.textSecondary)
                .monospacedDigit()
            Spacer()
            Button("Continue") { onDone(picked) }
                .buttonStyle(GoldButtonStyle(compact: true))
                .disabled(picked.isEmpty)
                .accessibilityIdentifier("mediaPicker.continue")
        }
        .padding(.horizontal, Spacing.m)
        .padding(.vertical, Spacing.s)
        .background(
            AurumColor.surface
                .overlay(alignment: .top) { Rectangle().fill(AurumColor.hairline).frame(height: 0.5) }
                .ignoresSafeArea(edges: .bottom)
        )
    }

    private var countText: String {
        if let required {
            return String(localized: "\(picked.count) of \(required) picked")
        }
        return picked.count == 1 ? String(localized: "1 picked") : String(localized: "\(picked.count) picked")
    }

    private var visibleItems: [PickedMedia] {
        switch filter {
        case .all: return items
        case .photos: return items.filter { $0.kind == .photo }
        case .videos: return items.filter { $0.kind == .video }
        }
    }

    private func toggle(_ item: PickedMedia) {
        if let i = picked.firstIndex(of: item) {
            picked.remove(at: i)
        } else {
            if let required, picked.count >= required { return Haptics.warning() }
            picked.append(item)
        }
        Haptics.detent()
    }

    private func cellLabel(_ item: PickedMedia, index: Int) -> String {
        var label = item.kind == .video
            ? String(localized: "Video, \(VideoEditorView.timecode(item.duration))")
            : String(localized: "Photo \(index + 1)")
        if let order = picked.firstIndex(of: item) {
            label += ", " + String(localized: "picked \(order + 1)")
        }
        return label
    }

    private func load() async {
        let photos = app.deps.photos
        access = photos.access()
        if access == .notDetermined { access = await photos.requestAccess() }
        guard access == .full || access == .limited else { isLoading = false; return }
        async let stills = photos.recentPhotos(limit: 300)
        async let clips = photos.recentVideos(limit: 150)
        let merged = (await stills).map { PickedMedia(id: $0.id, kind: .photo, pixelSize: $0.pixelSize, creationDate: $0.creationDate) }
            + (await clips).map { PickedMedia(id: $0.id, kind: .video, pixelSize: $0.pixelSize, duration: $0.duration, creationDate: $0.creationDate) }
        items = merged.sorted { ($0.creationDate ?? .distantPast) > ($1.creationDate ?? .distantPast) }
        isLoading = false
    }

    /// A plain timeline of the picked items, in picking order.
    nonisolated static func project(from picked: [PickedMedia]) -> VideoProject {
        var project = VideoProject()
        for item in picked { project.append(item.clip) }
        // Match the first item's shape so a landscape clip isn't cropped to a story.
        if let first = picked.first, first.pixelSize.aspectRatio > 1.2 { project.aspect = .landscape }
        return project
    }
}

struct MediaPickerCell: View {
    let item: PickedMedia
    let photos: PhotoLibraryService
    let order: Int?
    let onSelect: () -> Void
    @State private var image: UIImage?

    var body: some View {
        Button(action: onSelect) {
            AurumColor.surface
                .aspectRatio(1, contentMode: .fill)
                .overlay {
                    if let image {
                        Image(uiImage: image).resizable().scaledToFill()
                    }
                }
                .clipped()
                .overlay(alignment: .bottomTrailing) {
                    if item.kind == .video {
                        Text(verbatim: VideoEditorView.timecode(item.duration))
                            .font(AurumTextStyle.label.font)
                            .foregroundColor(AurumColor.textPrimary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(.black.opacity(0.55)))
                            .padding(5)
                    }
                }
                .overlay {
                    if order != nil {
                        Rectangle().stroke(AurumColor.accent, lineWidth: 3)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if let order {
                        Text(verbatim: "\(order)")
                            .font(AurumTextStyle.caption.font.weight(.semibold))
                            .foregroundColor(AurumColor.onAccent)
                            .frame(width: 24, height: 24)
                            .background(Circle().fill(AurumColor.accent))
                            .padding(6)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .animation(Motion.respectingReduceMotion(Motion.atelier), value: order)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(order != nil ? [.isButton, .isSelected] : .isButton)
        .task(id: item.id) {
            image = await photos.thumbnail(for: item.id, side: 240)
        }
    }
}

/// Shown when photo access is off: what's needed, and a way to fix it.
struct MediaAccessDeniedView: View {
    var body: some View {
        VStack(spacing: Spacing.m) {
            Text("Photo access is off").aurumText(.title)
            Text("To make a video, allow AURUM to access your photos and videos in Settings.")
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
}
