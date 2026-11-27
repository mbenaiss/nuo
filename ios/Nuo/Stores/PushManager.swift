import Foundation
import Observation
import UserNotifications
#if os(iOS)
import UIKit
#endif

@MainActor
@Observable
final class PushManager {
    static let shared = PushManager()

    private(set) var enabled: Bool
    private(set) var authorizationDenied = false
    private(set) var lastError: String?
    @ObservationIgnored var api: (any NuoAPI)?
    @ObservationIgnored private var deviceToken: String?

    private init() {
        enabled = UserDefaults.standard.bool(forKey: AppIdentity.local(.pushEnabled))
    }

    func setEnabled(_ value: Bool) async {
        if value {
            let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
            authorizationDenied = !granted
            enabled = granted
            if granted { PlatformApp.registerForRemoteNotifications() }
        } else {
            enabled = false
            PlatformApp.unregisterForRemoteNotifications()
        }
        UserDefaults.standard.set(enabled, forKey: AppIdentity.local(.pushEnabled))
    }

    /// Re-registers on every launch: APNs tokens can change and the gateway may have been reset.
    /// Push follows the notification permission unless the user turned it off in settings.
    func refreshRegistration() {
        Task {
            if UserDefaults.standard.object(forKey: AppIdentity.local(.pushEnabled)) == nil {
                let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
                guard status == .authorized || status == .provisional else { return }
                enabled = true
                UserDefaults.standard.set(true, forKey: AppIdentity.local(.pushEnabled))
            }
            guard enabled else { return }
            PlatformApp.registerForRemoteNotifications()
        }
    }

    func didRegister(token: Data) {
        let hex = token.map { String(format: "%02x", $0) }.joined()
        deviceToken = hex
        Task { await upload() }
    }

    func didFail(_ error: any Error) {
        lastError = error.localizedDescription
    }

    func upload() async {
        guard let api, let deviceToken else { return }
        do {
            try await api.registerDevice(apnsToken: deviceToken, environment: APNSEnvironment.current)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }
}

/// Taps and actions on every notification, shared by the iOS and macOS app delegates.
enum NotificationResponder {
    /// True when the tap opened a screen, false for an action handled in place.
    @discardableResult
    @MainActor static func handle(_ response: UNNotificationResponse) async -> Bool {
        let content = response.notification.request.content
        let info = content.userInfo
        let action = response.actionIdentifier
        if action == UNNotificationDismissActionIdentifier { return false }
        if let reminderId = info["reminderId"] as? String,
           await ReminderNotifications.perform(action: action, reminderId: reminderId) {
            return false
        }
        if action != UNNotificationDefaultActionIdentifier, info["eventId"] is String,
           content.categoryIdentifier != NotificationDestination.meetingCategory,
           await EventNotifications.perform(response) {
            return false
        }
        if action == AnswerNotifier.replyAction, let conversationId = info["conversationId"] as? String,
           let text = (response as? UNTextInputNotificationResponse)?.userText {
            await AnswerNotifier.shared.reply(conversationId: conversationId, botId: info["botId"] as? String, text: text)
            return false
        }
        NotificationRouter.open(NotificationDestination(userInfo: info, category: content.categoryIdentifier))
        return true
    }
}

/// Applies a tap's destination to the shared routers. The screens resolve it once their data is loaded, so it also
/// works on a cold launch, behind the app lock or before pairing completes.
@MainActor
enum NotificationRouter {
    static func open(_ destination: NotificationDestination) {
        let workspace = WorkspaceRouter.shared
        let router = AppRouter.shared
        switch destination {
        case let .conversation(id, botId):
            workspace.tab = .bots
            router.pendingDeepLink = .conversation(id: id, botId: botId)
        case let .bot(id):
            workspace.tab = .bots
            router.openNotification(conversationId: nil, botId: id)
        case let .task(id, _, runId):
            workspace.tab = .bots
            router.openTask(id: id, runId: runId)
        case let .reminder(id):
            workspace.openReminder(id: id)
        case let .event(id):
            workspace.openAgendaItem(id: id)
        case let .meeting(eventId):
            #if os(macOS)
            if let eventId { MeetingRecorder.shared.showEvent(id: eventId) } else { workspace.showsMeetings = true }
            #else
            if let eventId { workspace.openAgendaItem(id: eventId) } else { workspace.showsMeetings = true }
            #endif
        case .bookings:
            workspace.openBookings()
        case .browser:
            workspace.showsBrowser = true
        case .settings:
            workspace.tab = .bots
            router.path = [.settings]
        case let .link(url):
            if !workspace.open(url: url) { router.open(url: url) }
        case .home:
            workspace.tab = .bots
            router.path = []
        }
    }
}

#if os(iOS)
final class AppDelegate: NSObject, UIApplicationDelegate, @preconcurrency UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        AnswerNotifier.registerCategories()
        CalendarBridge.registerBackgroundTask()
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        PushManager.shared.didRegister(token: deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        PushManager.shared.didFail(error)
    }

    /// Silent pushes: a bot waiting for this iPhone (calendar, position, maps).
    func application(
        _ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        nonisolated(unsafe) let info = userInfo
        Task { @MainActor in
            let handled = await DeviceToolsCenter.shared.handlePush(info)
            completionHandler(handled ? .newData : .noData)
        }
    }

    // The async variants call UIKit's completion off the main thread, which aborts when the app is opened from a notification.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        Task {
            await NotificationResponder.handle(response)
            completionHandler()
        }
    }
}
#endif
