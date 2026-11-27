import Foundation
import Testing

/// The test bundle's Info.plist has none of the Nuo keys: the neutral values of a fresh clone apply.
struct AppIdentityTests {
    @Test func identifiersFallBackToTheNeutralBuild() {
        #expect(AppIdentity.identifier == "com.example.nuo")
        #expect(AppIdentity.appGroup == "group.com.example.nuo")
        #expect(AppIdentity.scoped("reminders.lock") == "com.example.nuo.reminders.lock")
        #expect(AppIdentity.storagePrefix == "nuo")
        #expect(AppIdentity.extraURLScheme == "nuo")
    }

    /// Frozen: a device keeps what it stored only while these stay the same, so a renamed identifier fails here.
    static let defaultLocalIdentifiers = [
        "nuo.gatewayURL", "nuo.pushEnabled", "nuo.deviceId", "nuo.userName", "nuo.appearance",
        "nuo.lock.enabled", "nuo.lock.delay", "nuo.routeChoices", "nuo.pinnedBots", "nuo.editor.monospace",
        "nuo.calendar.mode", "nuo.calendar.default", "nuo.calendar.hidden", "nuo.calendar.showsReminders",
        "nuo.calendar.accessDismissed", "nuo.eventAlerts.events", "nuo.eventAlerts.leave",
        "nuo.eventAlerts.defaultAlert", "nuo.eventAlerts.origin", "nuo.eventAlerts.mode",
        "nuo.eventAlerts.margin", "nuo.eventAlerts.overrides", "nuo.eventAlerts.leaveLog",
        "nuo.recordings.keepAudio", "nuo.recordings.template", "nuo.recordings.botId",
        "nuo.recordings.deleted", "nuo.recordings.pendingStops", "nuo.relay.declined", "nuo.watchAsk.recent",
        "nuo.dictation.model", "nuo.dictation.language", "nuo.dictation.cloud", "nuo.dictation.ready",
        "nuo.dictation.compiledCacheBuild", "nuo.voice.voiceIdentifier", "nuo.leave.marginMin",
        "nuo.mac.calendar.mode", "nuo.folders", "nuo.folders.byConversation", "nuo.meeting.template",
        "nuo.meeting.engine", "nuo.meeting.language", "nuo.meeting.cloud", "nuo.meeting.botId",
        "nuo.meeting.showWindow", "nuo.meeting.suggest", "nuo.watch.speaksAnswers", "nuo.complication.bots",
        "nuo.complication.lastReply", "nuo.watch.lastReply", "nuo.watch.talk", "nuo.watch.quick",
        "nuo.watch.agenda", "nuo.watch.reminders", "nuo.watch.control.talk", "nuo.event", "nuo.event.join",
        "nuo.leave", "nuo.meeting", "nuo.recording.paused", "nuo.turn", "nuo.dictation.finish",
        "nuo.dictation.network", "nuo.watch.ask", "nuo.recording",
    ]

    @Test func localIdentifiersOfANewInstall() {
        #expect(LocalIdentifier.allCases.map { AppIdentity.local($0) } == Self.defaultLocalIdentifiers)
        #expect(AppIdentity.local(.deviceTools, "health") == "nuo.deviceTools.health")
        #expect(AppIdentity.local(.dictationGPUOnly, "large-v3") == "nuo.dictation.gpuOnly.large-v3")
        #expect(AppIdentity.local(.docsPins, "profile-alex") == "nuo.docs.pins.profile-alex")
    }

    /// A build that keeps an earlier install's prefix finds every identifier that install wrote.
    @Test func anotherPrefixReplacesOnlyTheFirstSegment() {
        let kept = Self.defaultLocalIdentifiers.map { "atelier" + $0.dropFirst("nuo".count) }
        #expect(LocalIdentifier.allCases.map { AppIdentity.local($0, prefix: "atelier") } == kept)
        #expect(kept.contains("atelier.watch.control.talk") && kept.contains("atelier.leave.marginMin"))
        #expect(AppIdentity.local(.deviceTools, "calendar", prefix: "atelier") == "atelier.deviceTools.calendar")
        #expect(AppIdentity.local(.dictationGPUOnly, "large-v3", prefix: "atelier") == "atelier.dictation.gpuOnly.large-v3")
        #expect(AppIdentity.local(.docsPins, "profile-alex", prefix: "atelier") == "atelier.docs.pins.profile-alex")
    }

    @Test func identifiersSharedWithTheGatewayDoNotFollowThePrefix() {
        #expect(NotificationDestination.securityCategory == "nuo.security")
        #expect(NotificationDestination.meetingCategory == AppIdentity.local(.meetingCategory))
    }

    @Test func linksOpenUnderTheExtraSchemeToo() {
        #expect(AppIdentity.isAppScheme("nuo"))
        #expect(!AppIdentity.isAppScheme("atelier"))
        #expect(AppIdentity.isAppScheme("atelier", extra: "atelier"))
        #expect(AppIdentity.isAppScheme("Atelier", extra: "atelier"))
        #expect(AppIdentity.isAppScheme("nuo", extra: "atelier"))
        #expect(!AppIdentity.isAppScheme("https", extra: "atelier"))
        #expect(!AppIdentity.isAppScheme(nil, extra: "atelier"))
    }

    @Test func storedGatewayWinsOverTheBuildDefault() {
        let url = AppIdentity.gatewayURL(stored: "https://nuo.example.com", configured: "https://192.0.2.10:8443")
        #expect(url.absoluteString == "https://nuo.example.com")
    }

    @Test func buildDefaultAppliesBeforeAnyPairing() {
        #expect(AppIdentity.gatewayURL(stored: nil, configured: "https://192.0.2.10:8443").host() == "192.0.2.10")
    }

    @Test func noGatewayAtAllGivesAnAddressThatNeverResolves() {
        #expect(AppIdentity.gatewayURL(stored: "", configured: "").host() == "gateway.invalid")
        #expect(AppIdentity.gatewayURL(stored: "nuo", configured: "").host() == "gateway.invalid")
    }
}
