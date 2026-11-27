import SwiftUI

struct BotConversationsView: View {
    let botId: String
    @Environment(SessionStore.self) private var session
    @Environment(BotsStore.self) private var bots
    @Environment(AppRouter.self) private var router
    @State private var conversations: [Conversation] = []
    @State private var loading = true
    @State private var error: String?
    @State private var showsSchedules = false
    @State private var showsMemory = false

    private var bot: Bot? { bots.bot(id: botId) }

    var body: some View {
        List {
            Section {
                VStack(spacing: 12) {
                    BotAvatar(config: bot?.config, size: 64)
                    Text(bot?.config?.name ?? "Bot").font(.title2.bold()).foregroundStyle(Color.ink)
                    if let description = bot?.config?.description, !description.isEmpty {
                        Text(description).font(.subheadline).foregroundStyle(Color.text2).multilineTextAlignment(.center)
                    }
                    HStack(spacing: 10) {
                        Button {
                            router.openChat(botId: botId)
                        } label: {
                            Label(String(localized: "conversation.new", defaultValue: "New"), systemImage: "square.and.pencil")
                        }
                        .buttonStyle(InkButtonStyle())
                        Button {
                            router.editor = EditorTarget(botId: botId)
                        } label: {
                            Label("Edit", systemImage: "slider.horizontal.3")
                        }
                        .buttonStyle(InkButtonStyle(prominent: false))
                    }
                    .padding(.top, 6)
                    HStack(spacing: 18) {
                        Button {
                            showsSchedules = true
                        } label: {
                            Label("Tasks", systemImage: "clock.arrow.circlepath")
                        }
                        Button {
                            showsMemory = true
                        } label: {
                            Label("Memory", systemImage: "brain")
                        }
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.text2)
                    .buttonStyle(.plain)
                    .frame(minHeight: 44)
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                // Buttons span the same width as the conversation cards below.
                .listRowInsets(EdgeInsets(top: Spacing.xs, leading: 0, bottom: 0, trailing: 0))
            }

            Section {
                if loading && conversations.isEmpty {
                    ProgressView().frame(maxWidth: .infinity)
                } else if conversations.isEmpty {
                    Text(error ?? String(localized: "No conversations yet.")).font(.subheadline).foregroundStyle(Color.text2)
                }
                ForEach(conversations) { conversation in
                    Button {
                        router.openChat(botId: botId, conversationId: conversation.id, useDraft: conversation.useDraft)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text(conversation.title.isEmpty ? String(localized: "Conversation") : conversation.title)
                                        .font(.body.weight(.medium)).foregroundStyle(Color.ink).lineLimit(1)
                                    if conversation.useDraft { Badge(text: String(localized: "Draft"), tint: Color.accentInk, fill: Color.accentSoft) }
                                }
                                HStack(spacing: 8) {
                                    if let turn = session.turns.badge(for: conversation) {
                                        RunningBadge()
                                        Text(TurnLabels.short(phase: turn.phase, tool: turn.currentTool, detail: turn.currentToolDetail))
                                            .font(.caption).foregroundStyle(Color.text2).lineLimit(1)
                                    } else {
                                        Text(conversation.updatedAt.relativeLabel).font(.caption).foregroundStyle(Color.text3)
                                    }
                                    if conversation.context?.fraction != nil {
                                        ContextGauge(context: conversation.context, compact: true)
                                    }
                                }
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Color.text3)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Color.card)
                    .swipeActions {
                        Button(role: .destructive) {
                            Task { await delete(conversation) }
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            } header: {
                SectionHeader(title: "Conversations")
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.canvas)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
        .onChange(of: bot?.lastMessageAt) { _, _ in Task { await load() } }
        .navigationDestination(isPresented: $showsSchedules) { SchedulesView(botId: botId) }
        .navigationDestination(isPresented: $showsMemory) { BotMemoryView(botId: botId) }
    }

    private func load() async {
        do {
            conversations = try await session.api.conversations(botId: botId)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }

    private func delete(_ conversation: Conversation) async {
        withAnimation { conversations.removeAll { $0.id == conversation.id } }
        do {
            try await session.api.deleteConversation(id: conversation.id)
            Haptics.success()
        } catch {
            Haptics.error()
            await load()
        }
    }
}

/// "Nouveau bot": start from scratch or clone an existing bot.
struct NewBotSheet: View {
    @Environment(BotsStore.self) private var bots
    @Environment(AppRouter.self) private var router
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var source: Bot?
    @State private var creating = false
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Bot name", text: $name)
                        .font(.title3.weight(.semibold))
                        .focused($focused)
                        .submitLabel(.done)
                        .onSubmit { Task { await create() } }
                }
                Section {
                    sourceRow(nil, title: String(localized: "Start from scratch"), subtitle: String(localized: "Blank instructions"))
                    ForEach(bots.bots) { bot in
                        sourceRow(bot, title: bot.config?.name ?? "Bot", subtitle: bot.config?.description ?? "")
                    }
                } header: {
                    SectionHeader(title: "Start from…")
                }
                if let error {
                    Section { Text(error).foregroundStyle(Color.bad) }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.canvas)
            .navigationTitle("New Bot")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if creating {
                        ProgressView()
                    } else {
                        Button("Create") { Task { await create() } }
                            .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
            .onAppear { focused = true }
        }
    }

    private func sourceRow(_ bot: Bot?, title: String, subtitle: String) -> some View {
        Button {
            Haptics.selection()
            source = bot
            if name.isEmpty, let bot { name = String(localized: "\(bot.config?.name ?? "Bot") (copy)") }
        } label: {
            HStack(spacing: 12) {
                if let bot {
                    BotAvatar(config: bot.config, size: 36)
                } else {
                    Image(systemName: "sparkles").frame(width: 36, height: 36).background(Color.chip, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).foregroundStyle(Color.ink)
                    if !subtitle.isEmpty { Text(subtitle).font(.caption).foregroundStyle(Color.text2).lineLimit(1) }
                }
                Spacer()
                if source?.id == bot?.id {
                    Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(Color.accent)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func create() async {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !creating else { return }
        creating = true
        defer { creating = false }
        do {
            let bot = try await bots.create(name: trimmed, from: source)
            Haptics.success()
            dismiss()
            try? await Task.sleep(for: .milliseconds(350))
            router.editor = EditorTarget(botId: bot.id)
        } catch {
            Haptics.error()
            self.error = error.localizedDescription
        }
    }
}
