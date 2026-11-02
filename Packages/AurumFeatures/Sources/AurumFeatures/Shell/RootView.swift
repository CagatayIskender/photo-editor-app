import SwiftUI
import UniformTypeIdentifiers
import AurumCore
import AurumDesign

/// The app's root: onboarding on first launch, then the Salon and Vault tabs
/// around a centre "+" that opens the photo picker. The Studio covers
/// everything while editing.
public struct RootView: View {
    @ObservedObject var app: AppModel

    public init(app: AppModel) {
        self.app = app
    }

    public var body: some View {
        Group {
            if app.hasCompletedOnboarding {
                MainTabsView(app: app)
            } else {
                OnboardingView(app: app)
                    .transition(.opacity)
            }
        }
        .animation(Motion.respectingReduceMotion(Motion.velvet), value: app.hasCompletedOnboarding)
        .background(AurumColor.background.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .task { await app.start() }
        .onOpenURL { app.handle(url: $0) }
    }
}

struct MainTabsView: View {
    @ObservedObject var app: AppModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var isDropTargeted = false

    var body: some View {
        layout
        .onDrop(of: ImageDrop.types, isTargeted: $isDropTargeted) { providers in
            ImageDrop.handle(providers, app: app)
        }
        .overlay {
            if isDropTargeted { DropTargetHighlight().transition(.opacity) }
        }
        .animation(Motion.respectingReduceMotion(Motion.velvet), value: isDropTargeted)
        .sheet(isPresented: $app.isPickerPresented, onDismiss: { app.pickerDidDismiss() }) {
            PickerView(app: app)
        }
        .fullScreenCover(item: Binding(get: { app.cover }, set: { if $0 == nil { app.coverDismissed() } })) { cover in
            switch cover {
            case .studio(let model):
                StudioView(model: model, onClose: { app.closeStudio() }, app: app)
            case .flow(.video(let model)):
                VideoEditorView(model: model, app: app, onClose: { app.closeVideoEditor() })
            case .flow(.templates):
                TemplatesView(app: app)
            case .flow(.camera):
                CameraView(app: app)
            case .flow(.mediaPicker):
                MediaPickerView(app: app, required: nil, title: String(localized: "Choose photos and clips")) { picked in
                    app.openVideo(MediaPickerView.project(from: picked), source: "picker")
                } onCancel: {
                    app.closeFlow()
                }
            case .flow(.aiStudio):
                AIStudioView(app: app)
            case .flow(.depthMotion):
                DepthMotionView(app: app)
            case .flow(.collage):
                CollageView(app: app)
            case .flow(.carousel):
                CarouselView(app: app)
            }
        }
        .overlay(alignment: .top) {
            if let notice = app.notice {
                NoticeBanner(text: notice) { app.notice = nil }
                    .padding(.top, Spacing.xs)
            }
        }
    }

    /// The phone's bottom tab bar on compact width; a leading sidebar on iPad.
    @ViewBuilder
    private var layout: some View {
        if horizontalSizeClass == .regular {
            HStack(spacing: 0) {
                AurumSidebar(app: app)
                tabContent
            }
        } else {
            ZStack(alignment: .bottom) {
                tabContent
                    .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 72) }

                AurumTabBar(selected: $app.selectedTab, onCreate: { app.startCreating() })
            }
        }
    }

    private var tabContent: some View {
        Group {
            switch app.selectedTab {
            case .salon: SalonView(app: app)
            case .vault: VaultView(app: app)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Salon, a gold "+", Vault. The "+" is the fastest way into an edit.
struct AurumTabBar: View {
    @Binding var selected: AppTab
    let onCreate: () -> Void

    var body: some View {
        HStack {
            tab(.salon, icon: .salon, id: "salon", title: String(localized: "Salon"))
            Spacer()
            Button(action: onCreate) {
                IconView(.plus, size: 26, lineWidth: 1.6)
                    .foregroundColor(AurumColor.onAccent)
                    .frame(width: 58, height: 58)
                    .background(Circle().fill(AurumColor.accent))
                    .shadow(color: AurumColor.accent.opacity(0.35), radius: 14, y: 4)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Create")
            .accessibilityHint("Pick a photo to edit")
            .accessibilityIdentifier("tab.create")
            Spacer()
            tab(.vault, icon: .vault, id: "vault", title: String(localized: "Vault"))
        }
        .padding(.horizontal, Spacing.xxl)
        .padding(.top, Spacing.xs)
        .background(
            AurumColor.background.opacity(0.94)
                .overlay(alignment: .top) { Rectangle().fill(AurumColor.hairline).frame(height: 0.5) }
                .ignoresSafeArea(edges: .bottom)
        )
    }

    private func tab(_ tab: AppTab, icon: AurumIcon, id: String, title: String) -> some View {
        let isSelected = selected == tab
        return Button {
            selected = tab
            Haptics.detent()
        } label: {
            VStack(spacing: 4) {
                IconView(icon, size: 24)
                Text(title).font(.caption2)
            }
            .foregroundColor(isSelected ? AurumColor.accent : AurumColor.textTertiary)
            .frame(minWidth: Size.touch, minHeight: Size.touch)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityIdentifier("tab.\(id)")
    }
}

struct NoticeBanner: View {
    let text: String
    let onDismiss: () -> Void

    var body: some View {
        Text(text)
            .aurumText(.caption)
            .multilineTextAlignment(.center)
            .padding(.horizontal, Spacing.m)
            .padding(.vertical, Spacing.s)
            .background(Capsule().fill(AurumColor.surfaceRaised))
            .overlay(Capsule().stroke(AurumColor.goldHairline, lineWidth: 1))
            .padding(.horizontal, Spacing.m)
            .onTapGesture(perform: onDismiss)
            .task {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                onDismiss()
            }
            .accessibilityAddTraits(.isStaticText)
    }
}
