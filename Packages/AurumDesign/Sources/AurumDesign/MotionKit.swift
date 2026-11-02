import SwiftUI
import UIKit

// The AURUM motion kit. Every modifier here reads the system "Reduce Motion"
// setting and falls back to a plain cross-fade or to no motion at all, so a
// screen can use them freely without its own checks.

extension Motion {
    /// False under UI tests: endless animations keep XCTest waiting for the
    /// app to go idle, so looping effects (shimmer, glow, drift) stay still.
    public static let loopsEnabled: Bool = !ProcessInfo.processInfo.arguments.contains("-uiTesting")
}

// MARK: - Entrance

/// Fades and lifts a view in when it first appears. Pass increasing `index`
/// values to stagger a list or grid. With Reduce Motion the view only fades.
public struct AurumEntrance: ViewModifier {
    let index: Int
    let distance: CGFloat
    let baseDelay: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    public func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : distance)
            .scaleEffect(shown || reduceMotion ? 1 : 0.985, anchor: .top)
            .onAppear {
                guard !shown else { return }
                let step = min(Double(index), 12) * 0.045
                let animation = reduceMotion
                    ? Animation.easeOut(duration: 0.2)
                    : Motion.atelier.delay(baseDelay + step)
                withAnimation(animation) { shown = true }
            }
    }
}

extension View {
    /// Fades and lifts the view in on first appearance, staggered by `index`.
    public func aurumEntrance(_ index: Int = 0, distance: CGFloat = 14, delay: Double = 0) -> some View {
        modifier(AurumEntrance(index: index, distance: distance, baseDelay: delay))
    }
}

// MARK: - Press feedback

/// A plain button style that sinks slightly under the finger. Use it for
/// cards, tiles and thumbnails that would otherwise have no press state.
public struct PressableStyle: ButtonStyle {
    let scale: CGFloat
    public init(scale: CGFloat = 0.965) { self.scale = scale }

    public func makeBody(configuration: Configuration) -> some View {
        PressableBody(configuration: configuration, scale: scale)
    }

    private struct PressableBody: View {
        let configuration: Configuration
        let scale: CGFloat
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            configuration.label
                .scaleEffect(configuration.isPressed && !reduceMotion ? scale : 1)
                .brightness(configuration.isPressed ? -0.04 : 0)
                .animation(.spring(response: 0.28, dampingFraction: 0.72), value: configuration.isPressed)
        }
    }
}

extension ButtonStyle where Self == PressableStyle {
    /// A tile or card that sinks slightly when pressed.
    public static var pressable: PressableStyle { PressableStyle() }
}

// MARK: - Shimmer

/// A slow diagonal sheen of champagne light across the view, masked to its
/// shape. Used for premium items and loading skeletons. Static with Reduce
/// Motion.
public struct Shimmer: ViewModifier {
    let isActive: Bool
    let intensity: Double
    let duration: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = -1

    public func body(content: Content) -> some View {
        content
            .overlay {
                if isActive && !reduceMotion && Motion.loopsEnabled {
                    GeometryReader { geo in
                        let w = geo.size.width
                        LinearGradient(
                            colors: [.clear, Color.white.opacity(intensity), .clear],
                            startPoint: .leading, endPoint: .trailing
                        )
                        .frame(width: max(w * 0.6, 40))
                        .rotationEffect(.degrees(18))
                        .offset(x: phase * (w * 1.6))
                        .frame(width: w, height: geo.size.height, alignment: .center)
                    }
                    .blendMode(.plusLighter)
                    .mask(content)
                    .allowsHitTesting(false)
                    .onAppear {
                        phase = -1
                        withAnimation(.easeInOut(duration: duration).delay(0.6).repeatForever(autoreverses: false)) {
                            phase = 1
                        }
                    }
                }
            }
    }
}

extension View {
    /// Sweeps a soft sheen of light across the view.
    public func aurumShimmer(_ isActive: Bool = true, intensity: Double = 0.22, duration: Double = Motion.shimmerDuration) -> some View {
        modifier(Shimmer(isActive: isActive, intensity: intensity, duration: duration))
    }
}

// MARK: - Skeleton

/// A rounded placeholder that breathes while content loads.
public struct SkeletonBlock: View {
    let cornerRadius: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dim = false

    public init(cornerRadius: CGFloat = Radius.thumbnail) { self.cornerRadius = cornerRadius }

    public var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(AurumColor.surfaceRaised)
            .opacity(dim ? 0.55 : 1)
            .aurumShimmer(intensity: 0.08, duration: 1.6)
            .onAppear {
                guard !reduceMotion, Motion.loopsEnabled else { return }
                withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { dim = true }
            }
            .accessibilityHidden(true)
    }
}

// MARK: - Ambient light

/// A slow-drifting champagne glow over the onyx background. Gives hero
/// screens (welcome, Salon, membership) depth without competing with photos.
/// Still with Reduce Motion.
public struct AmbientGlow: View {
    let intensity: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drift = false

    public init(intensity: Double = 1) { self.intensity = intensity }

    public var body: some View {
        GeometryReader { geo in
            let s = max(geo.size.width, geo.size.height)
            ZStack {
                Circle()
                    .fill(RadialGradient(colors: [AurumColor.accent.opacity(0.20 * intensity), .clear], center: .center, startRadius: 0, endRadius: s * 0.45))
                    .frame(width: s * 0.9, height: s * 0.9)
                    .offset(x: drift ? s * 0.18 : -s * 0.22, y: drift ? -s * 0.30 : -s * 0.38)
                Circle()
                    .fill(RadialGradient(colors: [AurumColor.textPrimary.opacity(0.07 * intensity), .clear], center: .center, startRadius: 0, endRadius: s * 0.35))
                    .frame(width: s * 0.7, height: s * 0.7)
                    .offset(x: drift ? -s * 0.20 : s * 0.24, y: drift ? s * 0.30 : s * 0.18)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .blur(radius: 30)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear {
            guard !reduceMotion, Motion.loopsEnabled else { return }
            withAnimation(.easeInOut(duration: 14).repeatForever(autoreverses: true)) { drift = true }
        }
    }
}

// MARK: - Gold sheen on the primary button

/// The gold primary button with a slow sheen and a soft glow that breathes.
/// Use for the single most important action on hero screens (paywall, export).
public struct GoldSheenButtonStyle: ButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        SheenBody(configuration: configuration)
    }

    private struct SheenBody: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var glow = false

        var body: some View {
            configuration.label
                .font(AurumTextStyle.headline.font)
                .tracking(0.4)
                .foregroundColor(AurumColor.onAccent)
                .padding(.horizontal, Spacing.l)
                .frame(maxWidth: .infinity)
                .frame(height: Size.primaryButtonHeight)
                .background(
                    Capsule().fill(
                        LinearGradient(
                            colors: [AurumColor.accent.opacity(0.92), AurumColor.accent, AurumColor.accent.opacity(0.85)],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                    )
                )
                .aurumShimmer(isEnabled, intensity: 0.35, duration: 2.8)
                .shadow(color: AurumColor.accent.opacity(isEnabled ? (glow ? 0.40 : 0.18) : 0), radius: glow ? 18 : 10, y: 4)
                .contentShape(.hoverEffect, Capsule())
                .hoverEffect(.lift)
                .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.5)
                .scaleEffect(configuration.isPressed && !reduceMotion ? 0.975 : 1)
                .animation(.spring(response: 0.28, dampingFraction: 0.72), value: configuration.isPressed)
                .onAppear {
                    guard !reduceMotion, Motion.loopsEnabled else { return }
                    withAnimation(.easeInOut(duration: 2.2).repeatForever(autoreverses: true)) { glow = true }
                }
        }
    }
}

// MARK: - Transitions

extension AnyTransition {
    /// Rise and fade, for cards and panels. A plain fade with Reduce Motion.
    public static var aurumRise: AnyTransition {
        UIAccessibility.isReduceMotionEnabled
            ? .opacity
            : .asymmetric(
                insertion: .opacity.combined(with: .offset(y: 18)).combined(with: .scale(scale: 0.98, anchor: .bottom)),
                removal: .opacity.combined(with: .scale(scale: 0.98))
            )
    }

    /// Pop in, for badges, checkmarks and small confirmations.
    public static var aurumPop: AnyTransition {
        UIAccessibility.isReduceMotionEnabled ? .opacity : .scale(scale: 0.6).combined(with: .opacity)
    }

    /// Slides up from the bottom edge, for tool sheets.
    public static var aurumSheet: AnyTransition {
        UIAccessibility.isReduceMotionEnabled ? .opacity : .move(edge: .bottom).combined(with: .opacity)
    }
}

// MARK: - Success mark

/// A gold check that draws itself, for "Saved" and purchase confirmations.
public struct DrawnCheckmark: View {
    let size: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var progress: CGFloat = 0
    @State private var ring: CGFloat = 0

    public init(size: CGFloat = 56) { self.size = size }

    public var body: some View {
        ZStack {
            Circle()
                .trim(from: 0, to: ring)
                .stroke(AurumColor.accent.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            CheckShape()
                .trim(from: 0, to: progress)
                .stroke(AurumColor.accent, style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
                .padding(size * 0.3)
        }
        .frame(width: size, height: size)
        .onAppear {
            if reduceMotion { ring = 1; progress = 1; return }
            withAnimation(.easeOut(duration: 0.45)) { ring = 1 }
            withAnimation(.easeOut(duration: 0.35).delay(0.3)) { progress = 1 }
        }
        .accessibilityHidden(true)
    }

    private struct CheckShape: Shape {
        func path(in rect: CGRect) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: rect.minX, y: rect.midY + rect.height * 0.05))
            p.addLine(to: CGPoint(x: rect.minX + rect.width * 0.38, y: rect.maxY - rect.height * 0.1))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.1))
            return p
        }
    }
}

// MARK: - Progress

/// A thin gold progress ring with a soft trailing glow. Pass nil for an
/// indeterminate spinner.
public struct GoldProgressRing: View {
    let progress: Double?
    let size: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spin = false

    public init(progress: Double?, size: CGFloat = 44) {
        self.progress = progress
        self.size = size
    }

    public var body: some View {
        ZStack {
            Circle().stroke(AurumColor.hairline, lineWidth: 2)
            Circle()
                .trim(from: 0, to: progress.map { CGFloat(max(0.02, min($0, 1))) } ?? 0.28)
                .stroke(
                    AngularGradient(colors: [AurumColor.accent.opacity(0.1), AurumColor.accent], center: .center),
                    style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .rotationEffect(.degrees(progress == nil && spin ? 360 : 0))
                .animation(.easeOut(duration: 0.25), value: progress)
        }
        .frame(width: size, height: size)
        .onAppear {
            guard progress == nil else { return }
            if reduceMotion || !Motion.loopsEnabled { return }
            withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) { spin = true }
        }
        .accessibilityElement()
        .accessibilityLabel("Working")
        .accessibilityValue(progress.map { "\(Int($0 * 100)) percent" } ?? "")
    }
}
