import SwiftUI
import UIKit
import UniformTypeIdentifiers
import AurumDesign

/// Images dragged onto the Salon or Vault (iPad drag and drop, or from
/// another app on iPhone). The image is added to Photos and opened in the
/// Studio, the same way the camera opens a photo it has just taken.
enum ImageDrop {
    static let types: [UTType] = [UTType.image]

    /// Starts loading the first image among `providers`. Returns false when
    /// none of them carries an image, so the drop is refused.
    static func handle(_ providers: [NSItemProvider], app: AppModel) -> Bool {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.image.identifier) }) else {
            return false
        }
        let typeID = imageTypeIdentifier(of: provider)
        _ = provider.loadDataRepresentation(forTypeIdentifier: typeID) { data, _ in
            var prepared: (data: Data, fileExtension: String)?
            if let data {
                prepared = ImageDrop.prepare(data, typeIdentifier: typeID)
            }
            let result = prepared
            Task { @MainActor in
                if let result {
                    await app.importDroppedImage(result.data, fileExtension: result.fileExtension)
                } else {
                    app.notice = String(localized: "This image couldn't be opened.")
                }
            }
        }
        return true
    }

    /// The most specific image type the provider offers.
    static func imageTypeIdentifier(of provider: NSItemProvider) -> String {
        for id in provider.registeredTypeIdentifiers {
            if let type = UTType(id), type.conforms(to: UTType.image) { return id }
        }
        return UTType.image.identifier
    }

    /// JPEG, PNG and HEIC go to Photos as they are; anything else is re-encoded as JPEG.
    static func prepare(_ data: Data, typeIdentifier: String) -> (data: Data, fileExtension: String)? {
        if let type = UTType(typeIdentifier) {
            if type.conforms(to: UTType.jpeg) { return (data, "jpg") }
            if type.conforms(to: UTType.png) { return (data, "png") }
            if type.conforms(to: UTType.heic) { return (data, "heic") }
        }
        guard let image = UIImage(data: data), let jpeg = image.jpegData(compressionQuality: 0.95) else { return nil }
        return (jpeg, "jpg")
    }
}

/// The quiet gold frame shown while an image is held over a drop area.
struct DropTargetHighlight: View {
    var body: some View {
        ZStack {
            AurumColor.background.opacity(0.55)
            RoundedRectangle(cornerRadius: Radius.card)
                .stroke(AurumColor.accent, style: StrokeStyle(lineWidth: 1.5, dash: [6, 6]))
                .padding(Spacing.m)
            VStack(spacing: Spacing.xs) {
                IconView(.plus, size: 28, lineWidth: 1.4)
                    .foregroundColor(AurumColor.accent)
                Text("Drop to edit in the Studio").aurumText(.headline)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
