import SwiftUI

/// ⌘, : one pane per topic in a sidebar, like System Settings. A toolbar of tabs pushed the last ones into its
/// overflow menu, where macOS shows them disabled.
struct MacSettingsView: View {
    @State private var pane = SettingsPane(rawValue: DemoDirector.argument("-demoSettingsTab") ?? "") ?? .general

    var body: some View {
        NavigationSplitView {
            List(SettingsPane.allCases, selection: $pane) { pane in
                Label(pane.title, systemImage: pane.icon).tag(pane)
            }
            .navigationSplitViewColumnWidth(200)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            NavigationStack { pane.content.navigationTitle(pane.title) }
                .id(pane)
        }
        .frame(minWidth: 760, idealWidth: 800, minHeight: 540, idealHeight: 620)
    }
}

private enum SettingsPane: String, CaseIterable, Identifiable {
    case general, gateway, calendars, botAccess, google, secrets, security, notifications, dictation, tools, speed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: String(localized: "General")
        case .gateway: String(localized: "Gateway")
        case .calendars: String(localized: "Calendars")
        case .botAccess: String(localized: "Bot Access")
        case .google: String(localized: "Google")
        case .secrets: String(localized: "Secrets")
        case .security: String(localized: "Security")
        case .notifications: String(localized: "Notifications")
        case .dictation: String(localized: "Dictation")
        case .tools: String(localized: "Tools")
        case .speed: String(localized: "Bot Speed")
        }
    }

    var icon: String {
        switch self {
        case .general: "gearshape"
        case .gateway: "server.rack"
        case .calendars: "calendar"
        case .botAccess: "hand.raised"
        case .google: "person.crop.circle.badge.checkmark"
        case .secrets: "key"
        case .security: "lock.shield"
        case .notifications: "bell.badge"
        case .dictation: "mic"
        case .tools: "wrench.and.screwdriver"
        case .speed: "gauge.with.dots.needle.67percent"
        }
    }

    @MainActor @ViewBuilder var content: some View {
        switch self {
        case .general: GeneralSettings()
        case .gateway: GatewaySettings()
        case .calendars: CalendarSettingsView()
        case .botAccess: BotAccessSettingsView()
        case .google: GoogleAccountsView()
        case .secrets: SecretsView()
        case .security: Form { SecuritySettingsSection() }.formStyle(.grouped)
        case .notifications: NotificationSettings()
        case .dictation: DictationSettingsView()
        case .tools: MachineToolsView()
        case .speed: BotLatencyView()
        }
    }
}

private struct GeneralSettings: View {
    @Environment(SessionStore.self) private var session

    var body: some View {
        @Bindable var session = session
        Form {
            TextField("Your first name", text: $session.userName, prompt: Text("So Nuo can greet you"))
            Picker("Appearance", selection: $session.appearance) {
                ForEach(AppearanceMode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            LabeledContent("Version", value: appVersion)
            if session.isDemo {
                LabeledContent("Mode", value: String(localized: "Demo (sample data)"))
            }
        }
        .formStyle(.grouped)
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
    }
}

private struct GatewaySettings: View {
    @Environment(SessionStore.self) private var session
    @State private var showsUnpair = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Address", value: session.gatewayDisplay)
                if let profile = session.profile {
                    LabeledContent("Profile", value: profile.name)
                }
                LabeledContent("Connection") {
                    HStack(spacing: 6) {
                        Circle().fill(statusColor).frame(width: 8, height: 8)
                        Text(session.connectionState.label)
                    }
                }
                if let version = session.health?.version {
                    LabeledContent("Gateway version", value: version)
                }
            }
            if let agents = session.health?.agents, !agents.isEmpty {
                Section("Agents") {
                    ForEach(agents) { agent in
                        LabeledContent(agent.displayName) {
                            Text(!agent.available ? String(localized: "Unavailable") : agent.authenticated ? String(localized: "Ready") : String(localized: "Sign-in required"))
                                .foregroundStyle(!agent.available ? Color.text3 : agent.authenticated ? Color.good : Color(hex: 0xE58A00))
                        }
                    }
                }
            }
            Section {
                Button("Pair Again…", role: .destructive) { showsUnpair = true }
            } footer: {
                Text("To change the address, pair this Mac again with a code generated on the gateway.")
            }
        }
        .formStyle(.grouped)
        .task {
            await session.refreshProfile()
            await session.refreshHealth()
        }
        .confirmationDialog("Pair again?", isPresented: $showsUnpair) {
            Button("Forget this gateway", role: .destructive) { session.unpair() }
        } message: {
            Text("This Mac's token will be deleted. You will need a new pairing code.")
        }
    }

    private var statusColor: Color {
        switch session.connectionState {
        case .connected: .good
        case .connecting: Color(hex: 0xF5A623)
        case .waiting, .idle: .bad
        }
    }
}

private struct NotificationSettings: View {
    @Environment(PushManager.self) private var push
    @AppStorage(MeetingPrompts.settingKey) private var suggestMeetings = true

    var body: some View {
        Form {
            Section {
                Toggle("Notifications", isOn: Binding(get: { push.enabled }, set: { value in Task { await push.setEnabled(value) } }))
                if push.authorizationDenied {
                    Text("Allow Nuo notifications in System Settings › Notifications.").font(.callout).foregroundStyle(Color.bad)
                }
                if let error = push.lastError {
                    Text(error).font(.callout).foregroundStyle(.secondary)
                }
            } footer: {
                Text("Replies that arrive while Nuo is in the background, completed scheduled tasks and your reminders. Reply or snooze straight from the notification.")
            }
            Section {
                Toggle("Offer to transcribe when a meeting starts", isOn: $suggestMeetings)
            } footer: {
                Text("When a video call from your calendar starts, or when a meeting app uses the microphone, Nuo offers to transcribe. Detection happens on this Mac.")
            }
        }
        .formStyle(.grouped)
    }
}
