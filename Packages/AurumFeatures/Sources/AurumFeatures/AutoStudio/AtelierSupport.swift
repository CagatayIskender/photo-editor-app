import CoreImage
import SwiftUI
import AurumCore
import AurumDesign
import AurumServices

/// Small pieces shared by the Phase 3 screens (Auto Studio, 3D Motion, collage
/// and carousel).
enum AtelierSupport {
    /// Saves encoded image data to Photos and returns the new photo, the same
    /// way the camera hands a capture to the Studio.
    static func saveAndFetch(_ data: Data, fileExtension: String = "jpg", photos: PhotoLibraryService) async throws -> LibraryPhoto? {
        try await photos.save(data, fileExtension: fileExtension)
        return await photos.recentPhotos(limit: 1).first
    }

    /// The message shown for a failed save.
    static func saveFailureMessage(_ error: Error) -> String {
        if (error as? PhotoLibraryError) == .notAuthorized {
            return String(localized: "AURUM needs permission to add photos. You can allow it in Settings.")
        }
        return String(localized: "The export didn't finish. Please try again.")
    }

    /// Picked items that are photos; videos are left out.
    static func photosOnly(_ picked: [PickedMedia]) -> [PickedMedia] {
        picked.filter { $0.kind == .photo }
    }

    /// A temporary movie URL for an export.
    static func movieURL(prefix: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString.prefix(8))")
            .appendingPathExtension("mp4")
    }
}

/// A header with a close button and a title, for full-screen Phase 3 flows.
struct AtelierHeader<Trailing: View>: View {
    let title: String
    let onClose: () -> Void
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: Spacing.xs) {
            IconButton(.close, label: String(localized: "Close"), action: onClose)
            Text(title).aurumText(.title).lineLimit(1).minimumScaleFactor(0.8)
            Spacer()
            trailing()
        }
        .padding(.horizontal, Spacing.s)
        .frame(minHeight: 52)
    }
}

extension AtelierHeader where Trailing == EmptyView {
    init(title: String, onClose: @escaping () -> Void) {
        self.init(title: title, onClose: onClose, trailing: { EmptyView() })
    }
}

/// A calm notice inside a card: a label line and a sentence.
struct AtelierNote: View {
    let title: String
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            Text(title).aurumText(.label, color: AurumColor.accent)
            Text(message).aurumText(.caption, color: AurumColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Spacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Radius.thumbnail).fill(AurumColor.surface))
        .overlay(RoundedRectangle(cornerRadius: Radius.thumbnail).stroke(AurumColor.goldHairline, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}

/// A picked photo shown at its aspect ratio, or a placeholder. Fades in when
/// it arrives; while `isScanning` a slow gold shimmer passes over it.
struct AtelierImage: View {
    let image: CGImage?
    var placeholder: String = ""
    var isScanning: Bool = false

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: Radius.chip))
                    .overlay(scanFrame)
                    .aurumShimmer(isScanning, intensity: 0.3, duration: 2.2)
                    .transition(.opacity)
            } else {
                RoundedRectangle(cornerRadius: Radius.card)
                    .fill(LinearGradient(colors: [AurumColor.surfaceRaised, AurumColor.surface], startPoint: .top, endPoint: .bottom))
                    .overlay(RoundedRectangle(cornerRadius: Radius.card).stroke(AurumColor.hairline, lineWidth: 1))
                    .overlay(Text(placeholder).aurumText(.caption, color: AurumColor.textTertiary).padding(Spacing.m))
                    .transition(.opacity)
            }
        }
        .animation(Motion.respectingReduceMotion(Motion.atelier), value: image != nil)
    }

    private var scanFrame: some View {
        RoundedRectangle(cornerRadius: Radius.chip)
            .stroke(AurumColor.accent.opacity(isScanning ? 0.45 : 0), lineWidth: 1)
            .animation(Motion.respectingReduceMotion(Motion.atelier), value: isScanning)
    }
}

/// The result revealed over the original with a gold edge that wipes across
/// once. Under Reduce Motion the result simply appears.
struct BeforeAfterReveal: View {
    let before: CGImage?
    let after: CGImage
    @State private var progress: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if let before {
                    Image(decorative: before, scale: 1)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: Radius.chip))
                }
                Image(decorative: after, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: Radius.chip))
                    .mask(alignment: .leading) {
                        Rectangle().frame(width: geo.size.width * progress)
                    }
                Rectangle()
                    .fill(AurumColor.accent)
                    .frame(width: 1.5)
                    .opacity(progress > 0 && progress < 1 ? 0.8 : 0)
                    .position(x: geo.size.width * progress, y: geo.size.height / 2)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .onAppear {
            if reduceMotion || before == nil {
                progress = 1
            } else {
                withAnimation(.easeInOut(duration: 0.8)) { progress = 1 }
            }
        }
    }
}
