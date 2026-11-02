import SwiftUI
import AurumCore
import AurumDesign

/// Face retouching, one control at a time, like Adjust. "Natural" sets a
/// subtle starting point in one tap. Settings apply to every face. Retouch
/// is for members: it can be tried freely, and membership is asked for
/// only at export.
struct RetouchSheet: View {
    @ObservedObject var model: StudioViewModel
    @State private var control: RetouchControl = .smoothing

    struct RetouchGroup: Identifiable {
        let id: String
        let title: String
        let controls: [RetouchControl]
    }

    static var groups: [RetouchGroup] {
        [
            RetouchGroup(id: "skin", title: String(localized: "Skin"), controls: [.smoothing, .blemishRemoval, .underEye]),
            RetouchGroup(id: "features", title: String(localized: "Features"), controls: [.teethWhitening, .eyeBrightening]),
            RetouchGroup(id: "shape", title: String(localized: "Shape"), controls: [.jaw, .cheeks, .nose, .eyes, .lips, .forehead])
        ]
    }

    var body: some View {
        VStack(spacing: Spacing.s) {
            HStack(spacing: Spacing.xs) {
                Text(Localized.dynamic(control.displayName)).aurumText(.headline)
                Text(Self.format(model.retouchValue(control), control: control))
                    .aurumText(.caption, color: AurumColor.textSecondary)
                    .monospacedDigit()
                Spacer()
                Button("Natural") {
                    model.applyNaturalRetouch()
                    Haptics.apply()
                }
                .buttonStyle(TextActionButtonStyle())
                .accessibilityHint("Applies a light, natural retouch")
                Button("Reset") { model.resetRetouch() }
                    .buttonStyle(TextActionButtonStyle())
                    .disabled(model.retouch.isNeutral)
            }
            .padding(.horizontal, Spacing.m)

            AurumSlider(
                value: model.binding({ model.retouchValue(control) }, { model.setRetouch(control, $0) }),
                in: control.range,
                detentStep: 0.1,
                label: Localized.dynamic(control.displayName),
                onEditingChanged: model.sliderEditing
            )
            .padding(.horizontal, Spacing.m)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Spacing.xs) {
                    Chip(String(localized: "All faces"), isSelected: true, leadingIcon: .retouch) {}
                        .accessibilityHint("Retouch applies to every face in the photo")
                    Rectangle().fill(AurumColor.hairline).frame(width: 1, height: 22).accessibilityHidden(true)
                    ForEach(Self.groups) { group in
                        Text(group.title)
                            .aurumText(.label, color: AurumColor.textTertiary)
                            .padding(.leading, Spacing.xxs)
                            .accessibilityAddTraits(.isHeader)
                        ForEach(group.controls, id: \.self) { c in
                            Chip(Localized.dynamic(c.displayName), isSelected: c == control) {
                                control = c
                                Haptics.detent()
                            }
                            .overlay(alignment: .topTrailing) {
                                if model.retouchValue(c) != 0 {
                                    Circle().fill(AurumColor.accent).frame(width: 5, height: 5).offset(x: -4, y: 4)
                                        .accessibilityHidden(true)
                                }
                            }
                            .accessibilityValue(model.retouchValue(c) != 0 ? String(localized: "Changed") : "")
                        }
                    }
                }
                .padding(.horizontal, Spacing.m)
            }

            HStack(spacing: Spacing.xxs) {
                CrownBadge(size: 14)
                Text("Retouch is for members. Try it freely; you'll be asked only when you export.")
                    .aurumText(.caption, color: AurumColor.textTertiary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Spacing.m)
            .accessibilityElement(children: .combine)
        }
        .padding(.bottom, Spacing.s)
    }

    /// Strengths read 0…100; reshape controls −100…+100.
    static func format(_ value: Double, control: RetouchControl) -> String {
        let scaled = Int((value * 100).rounded())
        return control.isReshape && scaled > 0 ? "+\(scaled)" : "\(scaled)"
    }
}
