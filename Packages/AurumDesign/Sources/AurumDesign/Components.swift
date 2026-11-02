import SwiftUI
import UIKit

// MARK: - Buttons

/// The gold primary action. Use at most one per screen.
public struct GoldButtonStyle: ButtonStyle {
    var compact: Bool
    public init(compact: Bool = false) { self.compact = compact }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(AurumTextStyle.headline.font)
            .tracking(0.4)
            .foregroundColor(AurumColor.onAccent)
            .padding(.horizontal, compact ? 18 : Spacing.l)
            .frame(maxWidth: compact ? nil : .infinity)
            .frame(height: compact ? 36 : Size.primaryButtonHeight)
            .background(Capsule().fill(AurumColor.accent))
            .opacity(configuration.isPressed ? 0.82 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(Motion.respectingReduceMotion(Motion.velvet), value: configuration.isPressed)
    }
}

/// A frosted secondary action.
public struct GlassButtonStyle: ButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(AurumTextStyle.body.font.weight(.medium))
            .foregroundColor(AurumColor.textPrimary)
            .padding(.horizontal, Spacing.l)
            .frame(maxWidth: .infinity)
            .frame(height: Size.primaryButtonHeight)
            .background(Capsule().fill(.ultraThinMaterial))
            .overlay(Capsule().stroke(AurumColor.textPrimary.opacity(0.18), lineWidth: 1))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// A small-caps text action in gold, such as "Refine".
public struct TextActionButtonStyle: ButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .aurumText(.label, color: AurumColor.accent)
            .frame(minHeight: Size.touch)
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

/// A round icon-only button with a 44 pt touch target.
public struct IconButton: View {
    let icon: AurumIcon
    let label: String
    let isEnabled: Bool
    let action: () -> Void

    public init(_ icon: AurumIcon, label: String, isEnabled: Bool = true, action: @escaping () -> Void) {
        self.icon = icon
        self.label = label
        self.isEnabled = isEnabled
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            IconView(icon, size: 22)
                .foregroundColor(isEnabled ? AurumColor.textPrimary : AurumColor.textTertiary.opacity(0.6))
                .frame(width: Size.touch, height: Size.touch)
                .contentShape(Rectangle())
        }
        .disabled(!isEnabled)
        .accessibilityLabel(label)
    }
}

// MARK: - Badges and chips

/// The small gold crown that marks premium items before they are tapped.
public struct CrownBadge: View {
    let size: CGFloat
    public init(size: CGFloat = 20) { self.size = size }
    public var body: some View {
        IconView(.crown, size: size * 0.6, lineWidth: 1.8)
            .foregroundColor(AurumColor.accent)
            .frame(width: size, height: size)
            .background(Circle().fill(AurumColor.background.opacity(0.72)))
            .accessibilityElement()
            .accessibilityLabel("Members only")
    }
}

/// A filter chip, for collections and categories.
public struct Chip: View {
    let title: String
    let isSelected: Bool
    let leadingIcon: AurumIcon?
    let action: () -> Void

    public init(_ title: String, isSelected: Bool, leadingIcon: AurumIcon? = nil, action: @escaping () -> Void) {
        self.title = title
        self.isSelected = isSelected
        self.leadingIcon = leadingIcon
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let leadingIcon { IconView(leadingIcon, size: 12, lineWidth: 1.6) }
                Text(title).font(AurumTextStyle.caption.font)
            }
            .padding(.horizontal, Spacing.s)
            .frame(minHeight: 34)
            .foregroundColor(isSelected ? AurumColor.onAccent : AurumColor.textSecondary)
            .background(
                RoundedRectangle(cornerRadius: Radius.chip)
                    .fill(isSelected ? AurumColor.textPrimary : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Radius.chip)
                    .stroke(isSelected ? Color.clear : AurumColor.hairline, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Slider

/// The AURUM slider: a hairline track, ivory thumb, haptic detents and an
/// optional centre detent for bipolar values. Double-tap resets.
public struct AurumSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let detentStep: Double
    let label: String
    let onEditingChanged: (Bool) -> Void

    @State private var lastDetent: Int = 0
    @State private var isDragging = false

    public init(value: Binding<Double>, in range: ClosedRange<Double> = 0...1, detentStep: Double = 0.1, label: String, onEditingChanged: @escaping (Bool) -> Void = { _ in }) {
        self._value = value
        self.range = range
        self.detentStep = detentStep
        self.label = label
        self.onEditingChanged = onEditingChanged
    }

    private var isBipolar: Bool { range.lowerBound < 0 && range.upperBound > 0 }
    private var neutral: Double { isBipolar ? 0 : range.lowerBound }

    private func fraction(_ v: Double) -> CGFloat {
        CGFloat((v - range.lowerBound) / (range.upperBound - range.lowerBound))
    }

    public var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let thumbX = fraction(value) * width
            let fillFrom = fraction(neutral) * width
            ZStack(alignment: .leading) {
                Capsule().fill(AurumColor.hairline).frame(height: 2)
                Capsule().fill(AurumColor.accent)
                    .frame(width: abs(thumbX - fillFrom), height: 2)
                    .offset(x: min(thumbX, fillFrom))
                if isBipolar {
                    Rectangle().fill(AurumColor.textTertiary).frame(width: 1, height: 10).offset(x: fillFrom)
                }
                Circle()
                    .fill(AurumColor.textPrimary)
                    .frame(width: 24, height: 24)
                    .shadow(color: .black.opacity(0.5), radius: 4, y: 2)
                    .scaleEffect(isDragging ? 1.12 : 1)
                    .offset(x: thumbX - 12)
            }
            .frame(height: Size.touch)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        if !isDragging { isDragging = true; onEditingChanged(true) }
                        let f = min(max(g.location.x / max(width, 1), 0), 1)
                        let newValue = range.lowerBound + Double(f) * (range.upperBound - range.lowerBound)
                        value = newValue
                        let detent = Int((newValue / detentStep).rounded())
                        if detent != lastDetent { lastDetent = detent; Haptics.detent() }
                    }
                    .onEnded { _ in
                        isDragging = false
                        onEditingChanged(false)
                    }
            )
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                onEditingChanged(true)
                value = neutral
                Haptics.detent()
                onEditingChanged(false)
            })
        }
        .frame(height: Size.touch)
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue("\(Int((value * 100).rounded()))")
        .accessibilityAdjustableAction { direction in
            onEditingChanged(true)
            switch direction {
            case .increment: value = min(value + detentStep, range.upperBound)
            case .decrement: value = max(value - detentStep, range.lowerBound)
            @unknown default: break
            }
            onEditingChanged(false)
        }
    }
}

// MARK: - Thumbnails and the tool rail

/// A look thumbnail: the user's photo with the look applied (or a swatch
/// placeholder while it renders), a gold ring when selected, and the crown
/// for premium looks.
public struct LookThumbnail: View {
    let name: String
    let image: Image?
    let swatch: [Color]
    let isSelected: Bool
    let isPremium: Bool

    public init(name: String, image: Image?, swatch: [Color], isSelected: Bool, isPremium: Bool) {
        self.name = name
        self.image = image
        self.swatch = swatch
        self.isSelected = isSelected
        self.isPremium = isPremium
    }

    public var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let image {
                        image.resizable().scaledToFill()
                    } else {
                        LinearGradient(colors: swatch, startPoint: .topLeading, endPoint: .bottomTrailing)
                    }
                }
                .frame(width: 62, height: 78)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                if isPremium { CrownBadge(size: 18).padding(5) }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(isSelected ? AurumColor.accent : .clear, lineWidth: 1.5)
                    .padding(-3)
            )
            Text(name)
                .font(AurumTextStyle.label.font)
                .foregroundColor(isSelected ? AurumColor.textPrimary : AurumColor.textTertiary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isPremium ? "\(name), members only" : name)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// One tool in the Studio's bottom rail.
public struct ToolRailItem: View {
    let icon: AurumIcon
    let title: String
    let isActive: Bool
    let isAvailable: Bool
    let action: () -> Void

    public init(icon: AurumIcon, title: String, isActive: Bool, isAvailable: Bool = true, action: @escaping () -> Void) {
        self.icon = icon
        self.title = title
        self.isActive = isActive
        self.isAvailable = isAvailable
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                IconView(icon, size: 24)
                Text(title).font(.caption2)
            }
            .frame(width: 64, height: 60)
            .foregroundColor(isActive ? AurumColor.accent : (isAvailable ? AurumColor.textSecondary : AurumColor.textTertiary.opacity(0.6)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isAvailable)
        .accessibilityLabel(isAvailable ? title : "\(title), coming soon")
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}

// MARK: - Sheet surface

/// The frosted bottom-sheet surface used by every Studio tool.
public struct ToolSheet<Content: View>: View {
    let content: Content
    public init(@ViewBuilder content: () -> Content) { self.content = content() }

    public var body: some View {
        content
            .frame(maxWidth: .infinity)
            .padding(.top, Spacing.m)
            .background(
                UnevenTopRoundedRectangle(radius: Radius.sheet)
                    .fill(AurumColor.surface.opacity(0.96))
                    .overlay(alignment: .top) {
                        UnevenTopRoundedRectangle(radius: Radius.sheet)
                            .stroke(AurumColor.goldHairline, lineWidth: 1)
                            .mask(Rectangle().frame(height: 2).frame(maxHeight: .infinity, alignment: .top))
                    }
                    .ignoresSafeArea(edges: .bottom)
            )
    }
}

/// A rectangle with only its top corners rounded (iOS 16 compatible).
public struct UnevenTopRoundedRectangle: Shape {
    let radius: CGFloat
    public init(radius: CGFloat) { self.radius = radius }
    public func path(in rect: CGRect) -> Path {
        let path = UIBezierPath(roundedRect: rect, byRoundingCorners: [.topLeft, .topRight], cornerRadii: CGSize(width: radius, height: radius))
        return Path(path.cgPath)
    }
}
