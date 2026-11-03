import SwiftUI
import AurumDesign

/// The iPad's leading sidebar, in place of the phone's bottom tab bar: the
/// gold Create action, Salon and Vault, then every create flow. Uses the
/// tab bar's accessibility identifiers so the same UI test drives both.
struct AurumSidebar: View {
    @ObservedObject var app: AppModel

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(verbatim: "AURUM")
                    .aurumText(.title, color: AurumColor.accent)
                    .padding(.horizontal, Spacing.xs)
                    .padding(.bottom, Spacing.l)
                    .accessibilityAddTraits(.isHeader)
                createButton
                    .padding(.bottom, Spacing.m)
                tabRow(.salon, icon: .salon, id: "salon", title: String(localized: "Salon"))
                tabRow(.vault, icon: .vault, id: "vault", title: String(localized: "Vault"))
                Text("Create")
                    .aurumText(.label, color: AurumColor.textTertiary)
                    .padding(.horizontal, Spacing.xs)
                    .padding(.top, Spacing.l)
                    .padding(.bottom, Spacing.xxs)
                    .accessibilityAddTraits(.isHeader)
                flowRow(icon: .layers, title: String(localized: "Video"), id: "video") { app.startVideo() }
                flowRow(icon: .sparkle, title: String(localized: "Templates"), id: "templates") { app.openTemplates() }
                flowRow(icon: .camera, title: String(localized: "Camera"), id: "camera") { app.openCamera() }
                flowRow(icon: .wand, title: String(localized: "Auto Studio"), id: "autoStudio") { app.openAutoStudio() }
                flowRow(icon: .threeD, title: String(localized: "3D Motion"), id: "depthMotion") { app.openDepthMotion() }
                flowRow(icon: .compare, title: String(localized: "Collage"), id: "collage") { app.openCollage() }
                flowRow(icon: .crop, title: String(localized: "Carousel"), id: "carousel") { app.openCarousel() }
            }
            .padding(.horizontal, Spacing.s)
            .padding(.vertical, Spacing.l)
        }
        .frame(width: RegularLayout.sidebarWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(
            AurumColor.surface
                .overlay(alignment: .trailing) {
                    Rectangle().fill(AurumColor.hairline).frame(width: 0.5)
                }
                .ignoresSafeArea()
        )
    }

    private var createButton: some View {
        Button {
            Haptics.detent()
            app.startCreating()
        } label: {
            HStack(spacing: Spacing.xs) {
                IconView(.plus, size: 18, lineWidth: 1.6)
                Text("Create")
            }
        }
        .buttonStyle(GoldButtonStyle())
        .accessibilityLabel("Create")
        .accessibilityHint("Pick a photo to edit")
        .accessibilityIdentifier("tab.create")
        .keyboardShortcut("n", modifiers: .command)
    }

    private func tabRow(_ tab: AppTab, icon: AurumIcon, id: String, title: String) -> some View {
        let isSelected = app.selectedTab == tab
        return Button {
            app.selectedTab = tab
            Haptics.detent()
        } label: {
            SidebarRowLabel(icon: icon, title: title, isSelected: isSelected)
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityIdentifier("tab.\(id)")
    }

    private func flowRow(icon: AurumIcon, title: String, id: String, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.detent()
            action()
        } label: {
            SidebarRowLabel(icon: icon, title: title, isSelected: false)
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityIdentifier("sidebar.\(id)")
    }
}

/// One sidebar row: icon and title, gold and raised when it is the current tab.
private struct SidebarRowLabel: View {
    let icon: AurumIcon
    let title: String
    let isSelected: Bool

    var body: some View {
        HStack(spacing: Spacing.s) {
            IconView(icon, size: 20)
                .frame(width: 24)
            Text(title)
                .font(AurumTextStyle.body.font)
            Spacer(minLength: 0)
        }
        .foregroundColor(isSelected ? AurumColor.accent : AurumColor.textSecondary)
        .padding(.horizontal, Spacing.xs)
        .frame(minHeight: Size.touch)
        .background(
            RoundedRectangle(cornerRadius: Radius.chip)
                .fill(isSelected ? AurumColor.surfaceRaised : Color.clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: Radius.chip))
    }
}
