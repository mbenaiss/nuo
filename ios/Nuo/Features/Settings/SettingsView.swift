import SwiftUI

struct SettingsView: View {
    @Environment(SessionStore.self) private var session
    @Environment(PushManager.self) private var push
    @State private var showsUnpair = false
    @State private var showsTools = MachineToolsDemo.opensScreen
    @State private var showsDictation = DictationDemo.opensSettings
    @State private var showsGoogle = GoogleAccountsDemo.opensScreen
    @State private var showsSecrets = SecretsDemo.opensScreen

    var body: some View {
        @Bindable var session = session
        List {
            Section {
                HStack {
                    Text("Your first name")
                    TextField("So Nuo can greet you", text: $session.userName)
                        .multilineTextAlignment(.trailing)
                        .foregroundStyle(Color.text2)
                }
            }
            .listRowBackground(Color.card)

            Section {
                LabeledContent("Address") {
                    Text(session.gatewayDisplay).foregroundStyle(Color.text2).lineLimit(1)
                }
                if let profile = session.profile {
                    LabeledContent("Profile") {
                        Text(profile.name).foregroundStyle(Color.text2).lineLimit(1)
                    }
                }
                LabeledContent("Connection") {
                    HStack(spacing: 6) {
                        Circle().fill(statusColor).frame(width: 8, height: 8)
                        Text(session.connectionState.label).foregroundStyle(Color.text2)
                    }
                }
                if let version = session.health?.version {
                    LabeledContent("Version", value: version)
                }
                if let agents = session.health?.agents, !agents.isEmpty {
                    ForEach(agents) { agent in
                        LabeledContent(agent.displayName) {
                            Text(!agent.available ? String(localized: "Unavailable") : agent.authenticated ? String(localized: "Ready") : String(localized: "Sign-in required"))
                                .foregroundStyle(!agent.available ? Color.text3 : agent.authenticated ? Color.good : Color(hex: 0xE58A00))
                        }
                    }
                }
                Button("Pair Again", role: .destructive) { showsUnpair = true }
            } header: {
                SectionHeader(title: "Gateway")
            } footer: {
                Text("To change the address, pair the iPhone again with a code generated on the gateway host.")
            }
            .listRowBackground(Color.card)

            Section {
                NavigationLink {
                    CalendarSettingsView()
                } label: {
                    Label {
                        Text(String(localized: "nav.calendar", defaultValue: "Calendar"))
                    } icon: {
                        Image(systemName: "calendar").foregroundStyle(Color.ink)
                    }
                }
            } footer: {
                Text("Synced calendars, bot access, event alerts and “Leave now”.")
            }
            .listRowBackground(Color.card)

            Section {
                NavigationLink {
                    BotAccessSettingsView()
                } label: {
                    Label {
                        Text("Bot Access")
                    } icon: {
                        Image(systemName: "hand.raised").foregroundStyle(Color.ink)
                    }
                }
            } footer: {
                Text("This iPhone's location, weather, Maps, Health and workouts, for your bots.")
            }
            .listRowBackground(Color.card)

            Section {
                NavigationLink {
                    GoogleAccountsView()
                } label: {
                    Label {
                        Text("Google Accounts")
                    } icon: {
                        Image(systemName: "person.crop.circle.badge.checkmark").foregroundStyle(Color.ink)
                    }
                }
            } footer: {
                Text("Gmail, Drive and Calendar from your Google accounts, for your bots.")
            }
            .listRowBackground(Color.card)

            Section {
                NavigationLink {
                    SecretsView()
                } label: {
                    Label {
                        Text("Secrets")
                    } icon: {
                        Image(systemName: "key").foregroundStyle(Color.ink)
                    }
                }
            } footer: {
                Text("The gateway host's .env files (~/.secrets): show, copy, add, edit and delete, with Face ID every time.")
            }
            .listRowBackground(Color.card)

            Section {
                NavigationLink {
                    DictationSettingsView()
                } label: {
                    Label {
                        Text("Dictation")
                    } icon: {
                        Image(systemName: "mic").foregroundStyle(Color.ink)
                    }
                }
            } footer: {
                Text("The message mic button transcribes your voice on the iPhone, without sending anything.")
            }
            .listRowBackground(Color.card)

            Section {
                NavigationLink {
                    SchedulesView()
                } label: {
                    Label {
                        Text("Scheduled Tasks")
                    } icon: {
                        Image(systemName: "clock.arrow.circlepath").foregroundStyle(Color.ink)
                    }
                }
            } footer: {
                Text("Prompts sent to your bots and commands run on the gateway, at set times.")
            }
            .listRowBackground(Color.card)

            Section {
                NavigationLink {
                    BotMemoriesView()
                } label: {
                    Label {
                        Text("Bot Memory")
                    } icon: {
                        Image(systemName: "brain").foregroundStyle(Color.ink)
                    }
                }
            } footer: {
                Text("What each bot remembers about you, to review and correct.")
            }
            .listRowBackground(Color.card)

            Section {
                NavigationLink {
                    BotLatencyView()
                } label: {
                    Label {
                        Text("Bot Speed")
                    } icon: {
                        Image(systemName: "gauge.with.dots.needle.67percent").foregroundStyle(Color.ink)
                    }
                }
            } footer: {
                Text("Time to first word and answer length for each bot, day by day.")
            }
            .listRowBackground(Color.card)

            Section {
                Button {
                    WorkspaceRouter.shared.showsBrowser = true
                } label: {
                    Label {
                        Text("Browser").foregroundStyle(Color.ink)
                    } icon: {
                        Image(systemName: "safari").foregroundStyle(Color.ink)
                    }
                }
            } footer: {
                Text("The gateway's browser: sign in to the sites (LinkedIn…) your agents use. You type your passwords yourself.")
            }
            .listRowBackground(Color.card)

            Section {
                NavigationLink {
                    MachineToolsView()
                } label: {
                    Label {
                        Text("Machine Tools")
                    } icon: {
                        Image(systemName: "wrench.and.screwdriver").foregroundStyle(Color.ink)
                    }
                }
            } footer: {
                Text("CLIs, MCP servers and skills installed on the machine, to mention with # in a message.")
            }
            .listRowBackground(Color.card)

            Section {
                Toggle("Notifications", isOn: Binding(get: { push.enabled }, set: { value in Task { await push.setEnabled(value) } }))
                    .tint(Color.accent)
                if push.authorizationDenied {
                    Text("Allow Nuo notifications in iOS Settings.").font(.footnote).foregroundStyle(Color.bad)
                }
                if let error = push.lastError {
                    Text(error).font(.footnote).foregroundStyle(Color.text2)
                }
            } header: {
                SectionHeader(title: "Notifications")
            } footer: {
                Text("Your bots can let you know when a long task is done.")
            }
            .listRowBackground(Color.card)

            SecuritySettingsSection()

            Section {
                Picker("Theme", selection: $session.appearance) {
                    ForEach(AppearanceMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            } header: {
                SectionHeader(title: "Appearance")
            }
            .listRowBackground(Color.card)

            Section {
                LabeledContent("Nuo", value: appVersion)
                if session.isDemo {
                    LabeledContent("Mode", value: String(localized: "Demo (sample data)"))
                }
            } header: {
                SectionHeader(title: "About")
            }
            .listRowBackground(Color.card)
        }
        .scrollContentBackground(.hidden)
        .background(Color.canvas)
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $showsTools) { MachineToolsView() }
        .navigationDestination(isPresented: $showsDictation) { DictationSettingsView() }
        .navigationDestination(isPresented: $showsGoogle) { GoogleAccountsView() }
        .navigationDestination(isPresented: $showsSecrets) { SecretsView() }
        .task {
            await session.refreshProfile()
            await session.refreshHealth()
        }
        .confirmationDialog("Pair again?", isPresented: $showsUnpair, titleVisibility: .visible) {
            Button("Forget This Gateway", role: .destructive) { session.unpair() }
        } message: {
            Text("This iPhone's token will be deleted. You'll need a new pairing code.")
        }
    }

    private var statusColor: Color {
        switch session.connectionState {
        case .connected: .good
        case .connecting: Color(hex: 0xF5A623)
        case .waiting, .idle: .bad
        }
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}
