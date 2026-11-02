import SwiftUI
import AurumDesign

/// The Salon's second row of create tiles: AI Studio, 3D Motion, collage and carousel.
struct AtelierCreateRow: View {
    @ObservedObject var app: AppModel

    var body: some View {
        VStack(spacing: Spacing.s) {
            HStack(spacing: Spacing.s) {
                CreateTile(icon: .ai, title: String(localized: "AI Studio"), subtitle: String(localized: "Enhance, relight, restyle")) {
                    app.openAIStudio()
                }
                .accessibilityIdentifier("salon.aiStudio")
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
