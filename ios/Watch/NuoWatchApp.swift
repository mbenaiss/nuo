import SwiftUI
import UserNotifications

enum WatchRoute: Hashable {
    case bot(String)
    case conversation(botId: String, conversationId: String?, prompt: String?)
    case settings
    /// The watch's one button: a request to the general bot under a minute, a recorded meeting past it.
    case capture
    case answer(AskCenter.Delivery)
}

@main
struct NuoWatchApp: App {
    @State private var session = WatchSession(demo: ProcessInfo.processInfo.arguments.contains("-demo"))
    @State private var speaker = Speaker()

    init() {
        UNUserNotificationCenter.current().delegate = WatchNotificationPresenter.shared
        #if DEBUG
        ComplicationSnapshotRenderer.renderIfRequested()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            WatchRootView()
                .environment(session)
                .environment(speaker)
                .tint(.accent)
        }
    }
}

struct WatchRootView: View {
    @Environment(WatchSession.self) private var session
    @Environment(Speaker.self) private var speaker
    @Environment(\.scenePhase) private var scenePhase
    @State private var path: [WatchRoute] = []
    @State private var showsRest = false

    var body: some View {
        Group {
            if session.isPaired {
                NavigationStack(path: $path) {
                    HomeView(path: $path)
                        .navigationDestination(for: WatchRoute.self) { route in
                            switch route {
                            case let .bot(id):
                                if let bot = session.bot(id: id) {
                                    BotView(bot: bot, path: $path)
                                }
                            case let .conversation(botId, conversationId, prompt):
                                if let bot = session.bot(id: botId) {
                                    ConversationView(
                                        model: ConversationModel(bot: bot, conversationId: conversationId, session: session, speaker: speaker),
                                        initialPrompt: prompt)
                                }
                            case .settings:
                                WatchSettingsView()
                            case .capture:
                                CaptureView(path: $path)
                            case let .answer(delivery):
                                if let bot = session.bot(id: delivery.botId) {
                                    ConversationView(
                                        model: ConversationModel(bot: bot, conversationId: delivery.conversationId, session: session, speaker: speaker),
                                        initialPrompt: nil, delivery: delivery)
                                } else {
                                    // The bots are not loaded yet (a launch from a complication): they come, then the answer.
                                    VStack(spacing: 8) {
                                        ProgressView()
                                        Text(delivery.text).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                                    }
                                    .task { await session.load() }
                                }
                            }
                        }
                }
            } else {
                PairingPromptView()
            }
        }
        .task(id: session.isPaired) {
            VoiceRecorder.shared.recoverAtLaunch()
            await session.load()
            if session.isDemo { path = WatchDemoDirector.initialPath() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await session.load() }
                AskCenter.shared.pump()
                RecordingUplink.shared.pump()
            } else if phase == .background {
                // A reply being spoken in a conversation does not go on behind the user's back. The button's capture
                // does: past the minute it is a meeting, recorded screen off.
                AskCenter.shared.cancel()
            }
        }
        .onChange(of: AskCenter.shared.arrived) { _, delivery in
            // The capture and conversation screens follow their own answers; anywhere else, a late one opens here.
            guard let delivery, path.last.map({ $0 == .settings }) ?? true else { return }
            AskCenter.shared.consumeArrived()
            path = [.answer(delivery)]
        }
        .onChange(of: VoiceRecorder.shared.startRequested, initial: true) { _, requested in
            guard requested else { return }
            VoiceRecorder.shared.startRequested = false
            // Not paired: the screen that explains it stays, nothing records for an iPhone that will not take it.
            guard session.isPaired else { return }
            openCapture()
        }
        // The iPhone's Muscu screen is resting: the countdown comes up over whatever is on screen.
        .onChange(of: WatchRest.shared.rest, initial: true) { _, rest in showsRest = rest != nil }
        .sheet(isPresented: $showsRest, onDismiss: { WatchRest.shared.dismiss() }) {
            if let rest = WatchRest.shared.rest {
                WatchRestView(rest: rest) { showsRest = false }
            }
        }
        .onOpenURL { url in
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            let botId = components?.queryItems?.first(where: { $0.name == "bot" })?.value
            switch url.path() {
            // `/record` and `/mic` come from faces set up before the one button: they open it too.
            case "/ask", "/record", "/mic":
                guard session.isPaired else { return }
                openCapture()
            default: path = botId.map { [.bot($0)] } ?? []
            }
        }
    }

    private func openCapture() {
        if path.last != .capture { path = [.capture] }
        // Also from the summary of the last recording still on screen.
        Task { await VoiceRecorder.shared.start() }
    }
}

/// `-demo -watchScreen bot|conversation [-watchBot id] [-watchConversation id] [-watchPrompt "…"] [-watchScroll end]`
/// opens a screen directly, so simulator screenshots need no taps.
enum WatchDemoDirector {
    static func argument(_ name: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    static var scrollsToEnd: Bool { argument("-watchScroll") == "end" }

    @MainActor static func initialPath() -> [WatchRoute] {
        let bot = argument("-watchBot") ?? "coach"
        switch argument("-watchScreen") {
        case "bot": return [.bot(bot)]
        case "conversation":
            return [.bot(bot), .conversation(botId: bot, conversationId: argument("-watchConversation"), prompt: argument("-watchPrompt"))]
        case "settings": return [.settings]
        case "ask":
            VoiceRecorder.shared.playDemoListening(seconds: 4.2)
            return [.capture]
        case "answer", "confirm":
            let prompt = argument("-watchPrompt") ?? (argument("-watchScreen") == "confirm" ? AskDemoScript.email : AskDemoScript.reminders)
            let delivery = AskCenter.Delivery(askId: "demo", conversationId: "c-general-demo", botId: "general", text: prompt,
                                              speechEndedAt: Date())
            return [.answer(delivery)]
        case "recorder":
            VoiceRecorder.shared.playDemo(elapsed: 754, markers: [312, 754, 1501].filter { $0 <= 754 })
            return [.capture]
        case "recorderDone":
            VoiceRecorder.shared.playDemo(elapsed: 1862, markers: [312, 754, 1501], finished: true)
            return [.capture]
        default: return []
        }
    }
}
