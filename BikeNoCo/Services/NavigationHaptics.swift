import UIKit

@MainActor
enum NavigationHaptics {
    private static let notification = UINotificationFeedbackGenerator()
    private static let impactLight = UIImpactFeedbackGenerator(style: .light)
    private static let impactMedium = UIImpactFeedbackGenerator(style: .medium)
    private static let impactHeavy = UIImpactFeedbackGenerator(style: .heavy)

    static func play(_ kind: NavigationHapticKind) {
        switch kind {
        case .far:
            impactLight.prepare()
            impactLight.impactOccurred(intensity: 0.7)
        case .near:
            impactMedium.prepare()
            impactMedium.impactOccurred(intensity: 1.0)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                impactHeavy.impactOccurred(intensity: 0.9)
            }
        case .offRoute:
            notification.prepare()
            notification.notificationOccurred(.warning)
        }
    }
}
