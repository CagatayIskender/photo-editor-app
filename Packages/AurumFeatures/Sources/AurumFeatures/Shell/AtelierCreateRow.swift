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
                .aurumEntrance(0, distance: 10)
                .accessibilityIdentifier("salon.autoStudio")
                CreateTile(icon: .threeD, title: String(localized: "3D Motion"), subtitle: String(localized: "Depth for a still")) {
                    app.openDepthMotion()
                }
                .aurumEntrance(1, distance: 10)
                .accessibilityIdentifier("salon.depthMotion")
            }
            HStack(spacing: Spacing.s) {
                CreateTile(icon: .compare, title: String(localized: "Collage"), subtitle: String(localized: "Photos, composed")) {
                    app.openCollage()
                }
                .aurumEntrance(2, distance: 10)
                .accessibilityIdentifier("salon.collage")
                CreateTile(icon: .crop, title: String(localized: "Carousel"), subtitle: String(localized: "One photo, many panels")) {
                    app.openCarousel()
                }
                .aurumEntrance(3, distance: 10)
                .accessibilityIdentifier("salon.carousel")
            }
        }
        .padding(.horizontal, Spacing.m)
    }
}
