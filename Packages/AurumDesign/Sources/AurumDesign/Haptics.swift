import UIKit

/// The app's haptic vocabulary. Every slider detent, look application and
/// export gets a light, consistent touch.
@MainActor
public enum Haptics {
    private static let selection = UISelectionFeedbackGenerator()
    private static let soft = UIImpactFeedbackGenerator(style: .soft)
    private static let notification = UINotificationFeedbackGenerator()

    /// A slider crossed a detent or a segmented choice changed.
    public static func detent() {
        selection.selectionChanged()
    }

    /// A look or tool was applied.
    public static func apply() {
        soft.impactOccurred(intensity: 0.7)
    }

    /// An export or purchase finished.
    public static func success() {
        notification.notificationOccurred(.success)
    }

    public static func warning() {
        notification.notificationOccurred(.warning)
    }
}
