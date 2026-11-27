import AppKit
import CoreAudio
import Foundation
import UserNotifications

/// Suggests transcribing when a meeting starts: a video call of the agenda begins, or another app (a known meeting
/// app or a browser) keeps the microphone busy. Everything is decided on the Mac; nothing leaves it.
@MainActor
enum MeetingPrompts {
    nonisolated static let category = NotificationDestination.meetingCategory
    nonisolated static let transcribeAction = "nuo.meeting.action.transcribe"
    nonisolated static let ignoreAction = "nuo.meeting.action.ignore"
    nonisolated static let micIdentifier = "meeting-mic"
    nonisolated static let eventPrefix = "meeting-event-"
    static let settingKey = AppIdentity.local(.meetingSuggest)

    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: settingKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: settingKey) }
    }

    nonisolated static var notificationCategory: UNNotificationCategory {
        // Not `.foreground`: transcribing starts quietly, without bringing Nuo in front of a shared screen.
        let transcribe = UNNotificationAction(identifier: transcribeAction, title: String(localized: "Transcribe"), options: [],
                                              icon: UNNotificationActionIcon(systemImageName: "waveform"))
        let ignore = UNNotificationAction(identifier: ignoreAction, title: String(localized: "Ignore"), options: [])
        return UNNotificationCategory(identifier: category, actions: [transcribe, ignore], intentIdentifiers: [],
                                      hiddenPreviewsBodyPlaceholder: String(localized: "Meeting"), options: [.customDismissAction])
    }

    private static var started = false
    private static var notifiedEvents: Set<String> = []
    private static var lastEventPrompt: Date?
    private static var micBusySince: Date?
    private static var micPrompted = false
    private static var inputDevice = AudioObjectID(kAudioObjectUnknown)
    private static var runningListener: AudioObjectPropertyListenerBlock?
    private static var micCheck: Task<Void, Never>?

    static func start() {
        guard !started, !ProcessInfo.processInfo.arguments.contains("-demo") else { return }
        started = true
        Task {
            while true {
                checkCalendar()
                try? await Task.sleep(for: .seconds(30))
            }
        }
        var address = CoreAudioQuery.address(kAudioHardwarePropertyDefaultInputDevice)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main) { _, _ in
            MainActor.assumeIsolated { watchDefaultInput() }
        }
        watchDefaultInput()
    }

    /// « Transcrire » and « Ignorer »; false for a tap, which `NotificationResponder` routes, and other notifications.
    static func handle(_ response: UNNotificationResponse) -> Bool {
        let content = response.notification.request.content
        guard content.categoryIdentifier == category, response.actionIdentifier != UNNotificationDefaultActionIdentifier else { return false }
        switch response.actionIdentifier {
        case transcribeAction:
            let event = (content.userInfo["eventId"] as? String).flatMap { CalendarStore.shared.item(id: $0) }
            MeetingRecorder.shared.requestStart(event: event)
        default:
            break
        }
        return true
    }

    // MARK: Calendar

    private static func checkCalendar(now: Date = Date()) {
        guard enabled, !MeetingRecorder.shared.isRecording else { return }
        for item in CalendarStore.shared.items where item.kind == .event && !item.allDay && !item.isCancelled && !item.isBusyOnly
            && item.conference != nil && item.start >= now.addingTimeInterval(-120) && item.start <= now.addingTimeInterval(60) {
            let key = "\(item.id)-\(Int(item.start.timeIntervalSince1970 / 60))"
            guard notifiedEvents.insert(key).inserted else { continue }
            lastEventPrompt = now
            post(identifier: eventPrefix + key, title: String(localized: "Meeting starting: \(item.displayTitle)"),
                 body: String(localized: "Transcribe it with Nuo, on this Mac. Tell the participants that you are transcribing."),
                 info: ["eventId": item.id])
        }
    }

    // MARK: Microphone

    private static func watchDefaultInput() {
        var address = CoreAudioQuery.address(kAudioDevicePropertyDeviceIsRunningSomewhere)
        if inputDevice != kAudioObjectUnknown, let runningListener {
            AudioObjectRemovePropertyListenerBlock(inputDevice, &address, .main, runningListener)
        }
        inputDevice = CoreAudioQuery.objectID(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice) ?? AudioObjectID(kAudioObjectUnknown)
        guard inputDevice != kAudioObjectUnknown else { return }
        let listener: AudioObjectPropertyListenerBlock = { _, _ in
            MainActor.assumeIsolated { micChanged() }
        }
        runningListener = listener
        AudioObjectAddPropertyListenerBlock(inputDevice, &address, .main, listener)
        micChanged()
    }

    private static func micChanged() {
        let running = (CoreAudioQuery.uint32(inputDevice, kAudioDevicePropertyDeviceIsRunningSomewhere) ?? 0) != 0
        guard running else {
            micBusySince = nil
            micPrompted = false
            micCheck?.cancel()
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [micIdentifier])
            return
        }
        guard micBusySince == nil else { return }
        micBusySince = Date()
        micCheck?.cancel()
        // A mic grabbed for a few seconds (a voice memo, a dictation) is not a meeting.
        micCheck = Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            suggestFromMic()
        }
    }

    private static func suggestFromMic() {
        guard enabled, !micPrompted, micBusySince != nil, !MeetingRecorder.shared.isRecording,
              DictationController.shared.phase == .idle else { return }
        if let lastEventPrompt, Date().timeIntervalSince(lastEventPrompt) < 10 * 60 { return }
        guard let app = meetingApp() else { return }
        micPrompted = true
        post(identifier: micIdentifier, title: String(localized: "Meeting detected"),
             body: String(localized: "\(app) is using the microphone. Transcribe the meeting with Nuo? Tell the participants that you are transcribing."),
             info: [:])
    }

    /// The meeting app holding the microphone, other than Nuo.
    private static func meetingApp() -> String? {
        let own = getpid()
        let processes = CoreAudioQuery.objectList(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList)
        let inputs = processes.filter {
            (CoreAudioQuery.uint32($0, kAudioProcessPropertyIsRunningInput) ?? 0) != 0 && CoreAudioQuery.pid($0) != own
        }
        if !processes.isEmpty {
            for process in inputs {
                if let bundle = CoreAudioQuery.string(process, kAudioProcessPropertyBundleID), let name = appName(bundle) { return name }
            }
            return nil
        }
        // No per-process view of the HAL: settle for a meeting app being open.
        let running = NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
        return running.lazy.compactMap { appName($0, browsers: false) }.first
    }

    private static let meetingApps: [(prefix: String, name: String)] = [
        ("us.zoom.", "Zoom"),
        ("com.microsoft.teams", "Microsoft Teams"),
        ("com.apple.FaceTime", "FaceTime"),
        ("com.apple.avconferenced", "FaceTime"),
        ("com.tinyspeck.slackmacgap", "Slack"),
        ("com.cisco.webex", "Webex"),
        ("com.webex.", "Webex"),
        ("Cisco-Systems.Spark", "Webex"),
        ("com.hnc.Discord", "Discord"),
        ("com.skype.", "Skype"),
    ]

    private static let browsers = [
        "com.google.Chrome", "com.apple.Safari", "com.apple.WebKit", "company.thebrowser.", "org.mozilla.firefox",
        "com.microsoft.edgemac", "com.brave.Browser", "com.operasoftware.", "com.vivaldi.", "app.zen-browser",
    ]

    private static func appName(_ bundle: String, browsers includeBrowsers: Bool = true) -> String? {
        if let app = meetingApps.first(where: { bundle.hasPrefix($0.prefix) }) { return app.name }
        if includeBrowsers, browsers.contains(where: { bundle.hasPrefix($0) }) { return String(localized: "Your browser") }
        return nil
    }

    // MARK: Posting

    private static func post(identifier: String, title: String, body: String, info: [String: String]) {
        Task {
            let center = UNUserNotificationCenter.current()
            guard await center.notificationSettings().authorizationStatus.allowsDelivery else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.categoryIdentifier = category
            content.threadIdentifier = category
            content.userInfo = info
            try? await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
        }
    }
}
