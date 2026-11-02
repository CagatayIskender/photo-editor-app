import SwiftUI
import AurumCore
import AurumDesign

/// Aspect presets, straighten, rotate and flip. The preview updates live,
/// so the photo itself shows the result.
struct CropSheet: View {
    @ObservedObject var model: StudioViewModel

    var body: some View {
        VStack(spacing: Spacing.s) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Spacing.xs) {
                    ForEach(AspectPreset.allCases.filter { $0 != .free }, id: \.self) { aspect in
                        Chip(Localized.dynamic(aspect.label), isSelected: model.document.crop.aspect == aspect) {
                            model.setAspect(aspect)
                        }
                    }
                }
                .padding(.horizontal, Spacing.m)
            }

            AurumSlider(
                value: model.binding({ model.document.crop.straightenDegrees }, { model.setStraighten($0) }),
                in: -45...45,
                detentStep: 5,
                label: String(localized: "Straighten"),
                onEditingChanged: model.sliderEditing
            )
            .padding(.horizontal, Spacing.m)

            HStack(spacing: Spacing.l) {
                IconButton(.rotate, label: String(localized: "Rotate 90 degrees")) { model.rotateQuarterTurn() }
                IconButton(.flip, label: String(localized: "Flip horizontally")) { model.flipHorizontal() }
                Spacer()
                Button("Reset") { model.resetCrop() }
                    .buttonStyle(TextActionButtonStyle())
                    .disabled(model.document.crop.isIdentity)
            }
            .padding(.horizontal, Spacing.m)
        }
        .padding(.bottom, Spacing.s)
    }
}
