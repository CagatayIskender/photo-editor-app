import SwiftUI
import AurumDesign

/// Measurements for the regular-width (iPad) layouts. Compact width keeps the
/// phone layout, so nothing here applies to it.
enum RegularLayout {
    /// The trailing inspector that replaces bottom tool sheets.
    static let inspectorWidth: CGFloat = 360
    /// The leading sidebar that replaces the bottom tab bar.
    static let sidebarWidth: CGFloat = 248
    /// The widest a sheet's content grows inside an iPad form sheet.
    static let sheetMaxWidth: CGFloat = 560
}

/// The trailing column that holds a tool's controls on iPad, in place of the
/// bottom tool sheet. Controls scroll when they are taller than the screen.
struct InspectorColumn<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .aurumText(.label, color: AurumColor.textTertiary)
                .padding(.horizontal, Spacing.m)
                .padding(.top, Spacing.m)
                .padding(.bottom, Spacing.xs)
                .accessibilityAddTraits(.isHeader)
            ScrollView(.vertical, showsIndicators: false) {
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, Spacing.m)
            }
        }
        .frame(width: RegularLayout.inspectorWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(
            AurumColor.surface.opacity(0.96)
                .overlay(alignment: .leading) {
                    Rectangle().fill(AurumColor.goldHairline).frame(width: 0.5)
                }
                .ignoresSafeArea(edges: .bottom)
        )
    }
}

/// A vertical hairline between regular-width columns.
struct ColumnHairline: View {
    var body: some View {
        Rectangle()
            .fill(AurumColor.hairline)
            .frame(width: 0.5)
            .accessibilityHidden(true)
    }
}

extension View {
    /// Caps sheet content at a readable width and centres it. iPad form sheets
    /// can be wider than a phone; every iPhone is narrower, so it has no effect there.
    func formSheetWidth() -> some View {
        self
            .frame(maxWidth: RegularLayout.sheetMaxWidth)
            .frame(maxWidth: .infinity)
    }
}
