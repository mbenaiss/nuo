import Foundation

/// Identifiers that depend on who signs the build, read from the Info.plist keys project.yml fills from
/// Base.xcconfig and Local.xcconfig. Keychain services, widget kinds and queue labels derive from them so that
/// a build signed for another team keeps the same items as before only when it keeps the same identifiers.
enum AppIdentity {
    /// The iPhone and Mac app bundle identifier (`NUO_BUNDLE_ID`), shared by every target as their base.
    static let identifier = value(for: "NuoAppIdentifier") ?? "com.example.nuo"

    /// App group of the app and its extensions (`NUO_APP_GROUP`).
    static let appGroup = value(for: "NuoAppGroup") ?? "group.com.example.nuo"

    /// Gateway address prefilled on the pairing screen (`NUO_DEFAULT_GATEWAY`), empty when the build sets none.
    static let defaultGateway = value(for: "NuoDefaultGateway") ?? ""

    /// The stored gateway, else the build's default; a placeholder that never resolves when neither is set, for
    /// code paths that only run once paired and need a URL to ask the keychain whether they are.
    static var gatewayURL: URL {
        gatewayURL(stored: UserDefaults.standard.string(forKey: local(.gatewayURL)), configured: defaultGateway)
    }

    static func gatewayURL(stored: String?, configured: String) -> URL {
        func usable(_ text: String?) -> URL? { URL(string: text ?? "").flatMap { $0.host() == nil ? nil : $0 } }
        return usable(stored) ?? usable(configured) ?? URL(string: "https://gateway.invalid")!
    }

    /// `<identifier>.<suffix>`, for keychain services, widget kinds and dispatch queue labels.
    static func scoped(_ suffix: String) -> String { "\(identifier).\(suffix)" }

    /// Prefix of every `LocalIdentifier` (`NUO_STORAGE_PREFIX`). A device keeps the settings, complications and
    /// pending notifications of an earlier install only when the new build uses the prefix that install used.
    static let storagePrefix = value(for: "NuoStoragePrefix") ?? "nuo"

    static func local(_ id: LocalIdentifier, prefix: String = storagePrefix) -> String { "\(prefix).\(id.rawValue)" }

    /// One key of a family stored per item, such as one per device tool group.
    static func local(_ family: LocalIdentifier.Family, _ member: String, prefix: String = storagePrefix) -> String {
        "\(prefix).\(family.rawValue).\(member)"
    }

    /// Scheme of the links the apps build (widgets, notifications, documents).
    static let urlScheme = "nuo"

    /// A second scheme the apps open like `nuo://` (`NUO_EXTRA_URL_SCHEME`), for links written under an earlier
    /// name: in documents, bot memory and widgets rendered before an update.
    static let extraURLScheme = value(for: "NuoExtraURLScheme") ?? urlScheme

    static func isAppScheme(_ scheme: String?, extra: String = extraURLScheme) -> Bool {
        guard let scheme = scheme?.lowercased() else { return false }
        return scheme == urlScheme || scheme == extra.lowercased()
    }

    private static func value(for key: String) -> String? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: key) as? String else { return nil }
        let value = raw.trimmingCharacters(in: .whitespaces)
        // An unexpanded `$(…)` means the Info.plist was not preprocessed with the build settings.
        return value.isEmpty || value.hasPrefix("$(") ? nil : value
    }
}

/// Identifiers the apps keep on the device or register with the system under their own name, all derived from
/// `AppIdentity.storagePrefix`: renaming one loses what a device stored under it. Identifiers shared with the
/// gateway (pushed notification categories, signed headers) are not here: they do not follow the prefix.
enum LocalIdentifier: String, CaseIterable, Sendable {
    // iPhone settings (standard defaults).
    case gatewayURL
    case pushEnabled
    case deviceId
    case userName
    case appearance
    case lockEnabled = "lock.enabled"
    case lockDelay = "lock.delay"
    case routeChoices
    case pinnedBots
    case editorMonospace = "editor.monospace"
    case calendarMode = "calendar.mode"
    case calendarDefault = "calendar.default"
    case calendarHidden = "calendar.hidden"
    case calendarShowsReminders = "calendar.showsReminders"
    case calendarAccessDismissed = "calendar.accessDismissed"
    case eventAlertsEvents = "eventAlerts.events"
    case eventAlertsLeave = "eventAlerts.leave"
    case eventAlertsDefaultAlert = "eventAlerts.defaultAlert"
    case eventAlertsOrigin = "eventAlerts.origin"
    case eventAlertsMode = "eventAlerts.mode"
    case eventAlertsMargin = "eventAlerts.margin"
    case eventAlertsOverrides = "eventAlerts.overrides"
    case eventAlertsLeaveLog = "eventAlerts.leaveLog"
    case recordingsKeepAudio = "recordings.keepAudio"
    case recordingsTemplate = "recordings.template"
    case recordingsBotId = "recordings.botId"
    case recordingsDeleted = "recordings.deleted"
    case recordingsPendingStops = "recordings.pendingStops"
    case relayDeclined = "relay.declined"
    case watchAskRecent = "watchAsk.recent"
    case dictationModel = "dictation.model"
    case dictationLanguage = "dictation.language"
    case dictationCloud = "dictation.cloud"
    case dictationReady = "dictation.ready"
    case dictationCompiledCacheBuild = "dictation.compiledCacheBuild"
    case voiceIdentifier = "voice.voiceIdentifier"
    // Also read by the widgets, in the app group.
    case leaveMarginMinutes = "leave.marginMin"

    // Mac settings.
    case macCalendarMode = "mac.calendar.mode"
    case folders
    case foldersByConversation = "folders.byConversation"
    case meetingTemplate = "meeting.template"
    case meetingEngine = "meeting.engine"
    case meetingLanguage = "meeting.language"
    case meetingCloud = "meeting.cloud"
    case meetingBotId = "meeting.botId"
    case meetingShowWindow = "meeting.showWindow"
    case meetingSuggest = "meeting.suggest"

    // Watch settings, and the complications' data in the app group.
    case watchSpeaksAnswers = "watch.speaksAnswers"
    case complicationBots = "complication.bots"
    case complicationLastReply = "complication.lastReply"

    // Watch complication and control kinds, which the watch faces keep.
    case watchLastReplyKind = "watch.lastReply"
    case watchTalkKind = "watch.talk"
    case watchQuickKind = "watch.quick"
    case watchAgendaKind = "watch.agenda"
    case watchRemindersKind = "watch.reminders"
    case watchTalkControlKind = "watch.control.talk"

    // Categories and identifiers of notifications scheduled on the device.
    case eventCategory = "event"
    case eventJoinCategory = "event.join"
    case leaveCategory = "leave"
    case meetingCategory = "meeting"
    case recordingPausedNotification = "recording.paused"

    // Background task and queue names.
    case turnTask = "turn"
    case dictationFinishTask = "dictation.finish"
    case dictationNetworkQueue = "dictation.network"
    case watchAskTask = "watch.ask"
    case recordingTask = "recording"

    enum Family: String, CaseIterable, Sendable {
        case deviceTools
        case dictationGPUOnly = "dictation.gpuOnly"
        case docsPins = "docs.pins"
    }
}
