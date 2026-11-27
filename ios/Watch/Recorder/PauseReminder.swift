import Foundation
import UserNotifications

/// Shows the « Enregistrement en pause » reminder as a banner with its sound even with Nuo on screen.
final class WatchNotificationPresenter: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = WatchNotificationPresenter()

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
