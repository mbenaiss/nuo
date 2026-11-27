import SwiftUI

struct HomeView: View {
    @Binding var path: [WatchRoute]
    @Environment(WatchSession.self) private var session
    @State private var conversations: [Conversation] = []
    private var ask: AskCenter { AskCenter.shared }
    private var recorder: VoiceRecorder { VoiceRecorder.shared }

    var body: some View {
        List {
            HomeCapture(isRecording: recorder.isActive && !recorder.isTentative, isListening: recorder.isActive && recorder.isTentative) {
                path.append(.capture)
                // Also from the summary of the last recording.
                Task { await recorder.start() }
            }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 6, trailing: 0))
            if !ask.queue.failed.isEmpty {
                Section("Not sent") {
                    ForEach(ask.queue.failed) { item in
                        VStack(alignment: .leading, spacing: 6) {
                            PendingAskRow(label: item.text ?? item.transcript ?? String(localized: "Voice request"), detail: item.failure ?? String(localized: "Refused"), waiting: true)
                            HStack(spacing: 6) {
                                if item.text ?? item.transcript != nil {
                                    Button("Send now") { ask.sendAgain(item.id) }
                                        .font(.system(size: 12, weight: .semibold))
                                        .tint(.accent)
                                }
                                Button("Delete", role: .destructive) { ask.dismissFailure(item.id) }
                                    .font(.system(size: 12))
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
            }
            if !ask.queue.waiting.isEmpty {
                Section("Waiting") {
                    ForEach(ask.queue.waiting) { item in
                        PendingAskRow(label: item.text ?? String(localized: "Voice request of \(Int(item.seconds.rounded())) s"),
                                      detail: ask.phoneReachable ? String(localized: "Sending to iPhone…") : String(localized: "Waiting for iPhone"),
                                      waiting: !ask.phoneReachable)
                    }
                }
            }
            if !sendingRecordings.isEmpty {
                Section("Recordings") {
                    ForEach(sendingRecordings, id: \.id) { manifest in
                        PendingAskRow(label: "\(NoteFormat.clock(manifest.duration)) · " + String(localized: "\(manifest.markers.count) markers"),
                                      detail: RecordingUplink.shared.phoneReachable ? String(localized: "Sending to iPhone…") : String(localized: "Waiting for iPhone"),
                                      waiting: !RecordingUplink.shared.phoneReachable)
                    }
                }
            }
            if session.bots.isEmpty {
                emptyState
            }
            if let general, !recents.isEmpty {
                Section("Recent") {
                    ForEach(recents.prefix(5)) { conversation in
                        NavigationLink(value: WatchRoute.conversation(botId: general.id, conversationId: conversation.id, prompt: nil)) {
                            RecentRow(bot: general, conversation: conversation)
                        }
                    }
                }
            }
        }
        .navigationTitle("Nuo")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink(value: WatchRoute.settings) {
                    Image(systemName: "gearshape.fill")
                        .foregroundStyle(.white)
                }
                .accessibilityLabel("Settings")
            }
        }
        .task(id: general?.id) { await loadConversations() }
        .refreshable {
            await session.load()
            await loadConversations()
        }
    }

    /// Every request of the watch goes to the general bot: its conversations are the ones to read again.
    private var general: Bot? { AskTarget.defaultBot(in: session.bots) }

    private var recents: [Conversation] {
        guard let general else { return [] }
        return conversations.isEmpty ? session.recents.filter { $0.botId == general.id } : conversations
    }

    private func loadConversations() async {
        guard let general else { return }
        conversations = await session.conversations(botId: general.id)
    }

    private var sendingRecordings: [RecordingManifest] {
        recorder.history.filter { $0.isFinished && !RecordingUplink.shared.isDelivered($0.id) }
    }

    @ViewBuilder private var emptyState: some View {
        if session.isLoading {
            HStack {
                Spacer()
                ProgressView()
                Spacer()
            }
            .listRowBackground(Color.clear)
        } else if let error = session.loadError {
            VStack(alignment: .leading, spacing: 6) {
                MascotView(state: .sleep, size: 48)
                Label("Offline", systemImage: "wifi.slash")
                    .font(.headline)
                    .foregroundStyle(Color.accent)
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("Try again") { Task { await session.load() } }
            }
            .listRowBackground(Color.clear)
        } else {
            VStack(spacing: 6) {
                MascotView(state: .idle, size: 56)
                Text("No bots").font(.headline)
                Text("Create a bot on your iPhone.").font(.footnote).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .multilineTextAlignment(.center)
            .listRowBackground(Color.clear)
        }
    }
}
