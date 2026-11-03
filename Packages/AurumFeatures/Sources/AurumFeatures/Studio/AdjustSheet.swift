import SwiftUI
import AurumCore
import AurumDesign

/// One control at a time: pick it from the row of names, then drag the
/// slider. Changed controls are marked with a gold dot.
struct AdjustSheet: View {
    @ObservedObject var model: StudioViewModel
    @State private var control: AdjustmentControl = .exposure

    var body: some View {
        VStack(spacing: Spacing.s) {
            HStack {
                Text(control.localizedName).aurumText(.headline)
                Spacer()
                Text(Self.format(model.adjustment(control), control: control))
                    .aurumText(.caption, color: AurumColor.textSecondary)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Button("Reset all") { model.resetAdjustments() }
                    .buttonStyle(TextActionButtonStyle())
                    .disabled(model.document.adjustments.isNeutral)
            }
            .padding(.horizontal, Spacing.m)

            AurumSlider(
                value: model.binding({ model.adjustment(control) }, { model.setAdjustment(control, $0) }),
                in: control.range,
                detentStep: control.isBipolar ? 0.1 : 0.1,
                label: control.localizedName,
                onEditingChanged: model.sliderEditing
            )
            .padding(.horizontal, Spacing.m)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Spacing.xs) {
                    ForEach(AdjustmentSet.sliderControls, id: \.self) { c in
                        Chip(c.localizedName, isSelected: c == control) {
                            withAnimation(Motion.respectingReduceMotion(Motion.atelier)) { control = c }
                            Haptics.detent()
                        }
                            .overlay(alignment: .topTrailing) {
                                if model.adjustment(c) != 0 {
                                    Circle().fill(AurumColor.accent).frame(width: 5, height: 5).offset(x: -4, y: 4)
                                        .accessibilityHidden(true)
                                }
                            }
                            .accessibilityValue(model.adjustment(c) != 0 ? String(localized: "Changed") : "")
                    }
                }
                .padding(.horizontal, Spacing.m)
            }
        }
        .padding(.bottom, Spacing.s)
        .animation(Motion.respectingReduceMotion(Motion.atelier), value: model.document.adjustments.isNeutral)
    }

    /// Bipolar controls read −100…+100; others 0…100.
    static func format(_ value: Double, control: AdjustmentControl) -> String {
        let scaled = Int((value / max(abs(control.range.upperBound), 0.0001) * 100).rounded())
        return control.isBipolar && scaled > 0 ? "+\(scaled)" : "\(scaled)"
    }
}
