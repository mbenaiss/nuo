import SwiftUI

struct HomeView: View {
    @Environment(SessionStore.self) private var session
    @Environment(BotsStore.self) private var bots
    @Environment(AppRouter.self) private var router
    @State private var pendingDelete: Bot?
    @State private var showsSchedules = SchedulesDemo.opensScreen
    @State private var showsMemory = MemoryDemo.opensScreen
    @State private var showsAlerts = false
    @State private var showsSearch = false
    @State private var showsRecordings = RecordingsDemo.opensScreen
    @State private var recordings = RecordingsStore.shared
    @State private var alerts = AlertsStore.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                if !bots.bots.isEmpty { searchField }
                if bots.isLoading && bots.bots.isEmpty {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 60)
                } else if let error = bots.loadError, bots.bots.isEmpty {
                    errorState(error)
                } else {
                    if bots.bots.isEmpty {
                        WorkspaceEmptyState(symbol: "sparkles", title: String(localized: "No bots yet"),
                                            message: String(localized: "Create your first bot to get started."), mascot: .idle)
                    }
                    lists
                }
            }
            .padding(.horizontal, Spacing.gutter)
            .padding(.bottom, 110)
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.immediately)
        .simultaneousGesture(TapGesture().onEnded { dismissKeyboard() })
        // A field left focused on a screen that is gone (a chat, the search sheet) keeps the keyboard up over the dock.
        .onAppear { dismissKeyboard() }
        .refreshable {
            async let health: Void = session.refreshHealth()
            await bots.load()
            await health
        }
        .background(Color.canvas)
        .toolbar(.hidden, for: .navigationBar)
        .safeAreaInset(edge: .bottom) { HomeDock() }
        .navigationDestination(isPresented: $showsSchedules) { SchedulesView() }
        .navigationDestination(isPresented: $showsRecordings) { RecordingsView() }
        .sheet(isPresented: $showsAlerts) {
            NavigationStack { AlertsView() }
        }
        .sheet(isPresented: $showsSearch) {
            NavigationStack { ConversationSearchView() }
        }
        .navigationDestination(isPresented: $showsMemory) { BotMemoriesView() }
        .confirmationDialog(
            "Delete \(pendingDelete?.config?.name ?? String(localized: "this bot"))?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete Bot", role: .destructive) {
                guard let bot = pendingDelete else { return }
                Task {
                    try? await bots.delete(bot)
                    Haptics.success()
                }
            }
        } message: {
            Text("Its conversations and versions will be deleted.")
        }
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        let base = hour >= 18 || hour < 5 ? String(localized: "Good evening") : String(localized: "Hello")
        let name = session.userName.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? base : "\(base) \(name)"
    }

    private var statusLine: String {
        let ready = bots.bots.count
        let botsPart = ready == 0 ? String(localized: "No bots") : String(localized: "\(ready) bots ready")
        let link: String = switch session.connectionState {
        case .connected: String(localized: "gateway online")
        case .connecting: String(localized: "connecting…")
        case .waiting, .idle: String(localized: "gateway offline")
        }
        return "\(botsPart) · \(link)"
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(greeting)
                    .font(.largeTitle.bold())
                    .foregroundStyle(Color.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                HStack(spacing: 6) {
                    Circle().fill(session.connectionState == .connected ? Color.good : Color.text3).frame(width: 7, height: 7)
                    Text(statusLine).font(.subheadline).foregroundStyle(Color.text2)
                        .contentTransition(.opacity)
                }
            }
            Spacer()
            Button {
                Haptics.tap()
                showsAlerts = true
            } label: {
                Image(systemName: alerts.unreadCount > 0 ? "bell.badge" : "bell")
                    .font(.body.weight(.medium))
                    .foregroundStyle(alerts.unreadCount > 0 ? Color.accentInk : Color.text2)
                    .frame(width: 44, height: 44)
                    .background(Color.card, in: Circle())
                    .overlay(Circle().strokeBorder(Color.line))
            }
            .accessibilityLabel(alerts.unreadCount > 0 ? String(localized: "Alerts, \(alerts.unreadCount) unread") : String(localized: "Alerts"))
            Button {
                Haptics.tap()
                showsSchedules = true
            } label: {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.body.weight(.medium))
                    .foregroundStyle(Color.text2)
                    .frame(width: 44, height: 44)
                    .background(Color.card, in: Circle())
                    .overlay(Circle().strokeBorder(Color.line))
            }
            .accessibilityLabel("Scheduled Tasks")
            Button {
                Haptics.tap()
                showsRecordings = true
            } label: {
                Image(systemName: recordings.inProgress > 0 ? "waveform.badge.mic" : "waveform")
                    .font(.body.weight(.medium))
                    .foregroundStyle(recordings.inProgress > 0 ? Color.accentInk : Color.text2)
                    .frame(width: 44, height: 44)
                    .background(Color.card, in: Circle())
                    .overlay(Circle().strokeBorder(Color.line))
            }
            .accessibilityLabel(recordings.inProgress > 0 ? String(localized: "Recordings, \(recordings.inProgress) in progress") : String(localized: "Recordings"))
            Button {
                router.path.append(.settings)
            } label: {
                Image(systemName: "gearshape")
                    .font(.body.weight(.medium))
                    .foregroundStyle(Color.text2)
                    .frame(width: 44, height: 44)
                    .background(Color.card, in: Circle())
                    .overlay(Circle().strokeBorder(Color.line))
            }
            .accessibilityLabel("Settings")
        }
        .padding(.top, 12)
    }

    private var searchField: some View {
        Button {
            Haptics.tap()
            showsSearch = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Color.text3)
                Text("Search conversations").foregroundStyle(Color.text3)
                Spacer(minLength: 0)
            }
            .font(.body)
            .padding(.horizontal, 14)
            .frame(height: 44)
            .background(Color.card, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.line))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .padding(.top, -8)
    }

    @ViewBuilder
    private var lists: some View {
        let listed = bots.listed
        if !listed.pinned.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                SectionHeader(title: "Pinned")
                rows(listed.pinned)
            }
        }
        VStack(alignment: .leading, spacing: 4) {
            if !listed.others.isEmpty { SectionHeader(title: listed.pinned.isEmpty ? String(localized: "Bots") : String(localized: "Other bots")) }
            rows(listed.others)
            Button {
                Haptics.tap()
                router.showsNewBot = true
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "plus")
                        .font(.body.weight(.medium))
                        .frame(width: 38, height: 38)
                        .overlay(Circle().strokeBorder(Color.text3.opacity(0.6), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])))
                    Text("New bot").font(.subheadline.weight(.semibold))
                    Spacer()
                }
                .foregroundStyle(Color.text2)
                .padding(.vertical, 11)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private func rows(_ list: [Bot]) -> some View {
        VStack(spacing: 0) {
            ForEach(list) { bot in
                Button {
                    Haptics.tap()
                    Task { await openLatest(bot) }
                } label: {
                    BotRow(bot: bot)
                }
                .buttonStyle(.plain)
                .contextMenu { menu(bot) }
                Divider().overlay(Color.line).padding(.leading, 50)
            }
        }
    }

    @ViewBuilder
    private func menu(_ bot: Bot) -> some View {
        let pinned = bots.isPinned(bot)
        Button {
            withAnimation(.snappy) { bots.setPinned(bot, !pinned) }
        } label: {
            Label(pinned ? String(localized: "Unpin") : String(localized: "Pin"), systemImage: pinned ? "pin.slash" : "pin")
        }
        Button { router.openChat(botId: bot.id) } label: { Label("New Conversation", systemImage: "square.and.pencil") }
        Button { router.path.append(.conversations(botId: bot.id)) } label: { Label("Conversations", systemImage: "bubble.left.and.bubble.right") }
        Button { router.editor = EditorTarget(botId: bot.id) } label: { Label("Edit", systemImage: "slider.horizontal.3") }
        Divider()
        Button(role: .destructive) { pendingDelete = bot } label: { Label("Delete", systemImage: "trash") }
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 12) {
            MascotView(state: .sleep, size: MascotMetrics.hero)
            Text("Gateway unreachable").font(.headline).foregroundStyle(Color.ink)
            Text(message).font(.subheadline).foregroundStyle(Color.text2).multilineTextAlignment(.center)
            Button("Try Again") { Task { await bots.load() } }.buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    private func dismissKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    private func openLatest(_ bot: Bot) async {
        if let running = session.turns.runningConversation(for: bot) {
            router.openChat(botId: bot.id, conversationId: running)
            return
        }
        let latest = try? await session.api.conversations(botId: bot.id).first
        router.openChat(botId: bot.id, conversationId: latest?.id)
    }
}

struct BotRow: View {
    let bot: Bot
    @Environment(SessionStore.self) private var session

    var body: some View {
        let config = bot.config
        HStack(spacing: 12) {
            BotAvatar(config: config, size: 38)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(config?.name ?? String(localized: "Unnamed")).font(.subheadline.weight(.semibold)).foregroundStyle(Color.ink).lineLimit(1)
                    if bot.draft != nil && bot.published != nil {
                        Badge(text: String(localized: "Draft"), tint: Color.accentInk, fill: Color.accentSoft)
                    }
                    Spacer()
                    if session.turns.isRunning(bot) {
                        RunningBadge().transition(.scale(scale: 0.8).combined(with: .opacity))
                    } else if let date = bot.lastMessageAt {
                        Text(date.relativeLabel).font(.caption).foregroundStyle(Color.text3)
                    }
                }
                Text(bot.lastMessagePreview ?? config?.description ?? "").font(.subheadline).foregroundStyle(Color.text2).lineLimit(1)
            }
        }
        .padding(.vertical, 11)
        .contentShape(Rectangle())
        .animation(.snappy, value: session.turns.isRunning(bot))
    }
}
