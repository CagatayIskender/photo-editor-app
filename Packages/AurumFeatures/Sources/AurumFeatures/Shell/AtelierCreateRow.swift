import SwiftUI
import AurumDesign

/// The Salon's second row of create tiles: Auto Studio, 3D Motion, collage and carousel.
struct AtelierCreateRow: View {
    @ObservedObject var app: AppModel

    var body: some View {
        VStack(spacing: Spacing.s) {
            HStack(spacing: Spacing.s) {
                CreateTile(icon: .wand, title: String(localized: "Auto Studio"), subtitle: String(localized: "Enhance, retouch, remove")) {
                    app.openAutoStudio()
                }
                .accessibilityIdentifier("salon.autoStudio")
                CreateTile(icon: .threeD, title: String(localized: "3D Motion"), subtitle: String(localized: "Depth for a still")) {
                    app.openDepthMotion()
                }
                .accessibilityIdentifier("salon.depthMotion")
            }
            HStack(spacing: Spacing.s) {
                CreateTile(icon: .compare, title: String(localized: "Collage"), subtitle: String(localized: "Photos, composed")) {
                    app.openCollage()
                }
                .accessibilityIdentifier("salon.collage")
                CreateTile(icon: .crop, title: String(localized: "Carousel"), subtitle: String(localized: "One photo, many panels")) {
                    app.openCarousel()
                }
                .accessibilityIdentifier("salon.carousel")
            }
        }
        .padding(.horizontal, Spacing.m)
    }
}
