import SwiftUI

struct ConversationView: View {
    @State private var model: ConversationModel
    @State private var sentInitial = false
    @State private var listening = false
    private let initialPrompt: String?
    private let delivery: AskCenter.Delivery?
    @Environment(Speaker.self) private var speaker
    @Environment(WatchSession.self) private var session
    private var ask: AskCenter { AskCenter.shared }

    init(model: ConversationModel, initialPrompt: String?, delivery: AskCenter.Delivery? = nil) {
        _model = State(initialValue: model)
        self.initialPrompt = initialPrompt
        self.delivery = delivery
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if model.isLoading {
                        ProgressView().frame(maxWidth: .infinity)
                    }
                    ForEach(model.messages.withoutTaskPrompts) { message in
                        MessageView(message: message)
                            .id(message.id)
                    }
                    if let live = model.live {
                        LiveTurnView(turn: live)
                            .id("live")
                    }
                    if let confirmation = model.confirmation {
                        ConfirmationCard(
                            title: confirmation.title, confirmLabel: confirmation.confirm.map { $0.name.isEmpty ? String(localized: "Confirm") : $0.name },
                            cancelLabel: confirmation.cancel.map { $0.name.isEmpty ? String(localized: "Cancel") : $0.name }, busy: model.isAnswering,
                            onConfirm: { if let option = confirmation.confirm { model.answer(option) } },
                            onCancel: { if let option = confirmation.cancel { model.answer(option) } })
                            .id("confirmation")
                    }
                    if let latency = model.latency, !model.isRunning {
                        LatencyRow(seconds: latency)
                    }
                    if let error = model.error {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundStyle(Color.accent)
                    }
                    if let notice = model.notice {
                        Label(notice, systemImage: "lock.iphone")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if listening, ask.isListening {
                        ListeningPanel(targetName: model.bot.displayName, level: ask.level, seconds: ask.seconds, capped: ask.phase == .capped,
                                       onSend: sendSpoken, onCancel: { ask.cancel(); listening = false })
                            .id("composer")
                    } else if ask.phase == .sending, listening {
                        HStack(spacing: 8) {
                            ProgressView().frame(width: 18)
                            Text("Transcribing…").font(.caption2).foregroundStyle(.secondary)
                        }
                        .id("composer")
                    } else if !model.isRunning {
                        if ask.phase == .queued, listening {
                            PendingAskRow(label: String(localized: "Waiting for iPhone"), detail: ask.queuedReason ?? String(localized: "Your request goes as soon as it answers."), waiting: true)
                        }
                        if case let .failed(message) = ask.phase, listening {
                            Label(message, systemImage: "exclamationmark.triangle.fill")
                                .font(.caption2)
                                .foregroundStyle(Color.accent)
                        }
                        HStack(spacing: 10) {
                            Spacer()
                            if usesNuoVoice {
                                VoiceButton(size: 50) {
                                    listening = true
                                    Task { await ask.listen(botId: model.bot.id, conversationId: model.conversationId) }
                                }
                                .accessibilityLabel("Reply to \(model.bot.displayName)")
                                MicButton(prompt: String(localized: "Write to \(model.bot.displayName)"), size: 34, symbol: "keyboard") { typed($0) }
                            } else {
                                // iPhone out of reach, a bot the watch may reach: the watch's own dictation, straight to the gateway.
                                MicButton(prompt: String(localized: "Reply to \(model.bot.displayName)"), size: 50) { typed($0) }
                            }
                            Spacer()
                        }
                        .padding(.top, 4)
                        .id("composer")
                    }
                }
                .padding(.horizontal, 2)
            }
            .simultaneousGesture(TapGesture().onEnded { speaker.stop() })
            .onChange(of: model.messages.count) { _, _ in scrollToEnd(proxy) }
            .onChange(of: model.live?.text) { _, _ in scrollToEnd(proxy) }
            .onChange(of: model.live == nil) { _, _ in scrollToEnd(proxy) }
            .onChange(of: model.confirmation) { _, confirmation in
                if confirmation != nil { withAnimation { proxy.scrollTo("confirmation", anchor: .bottom) } }
            }
        }
        .navigationTitle {
            HStack(spacing: 4) {
                Text(model.bot.emoji)
                Text(model.bot.displayName).foregroundStyle(Color.accent)
            }
        }
        .toolbar {
            if speaker.isSpeaking {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { speaker.stop() } label: { Image(systemName: "speaker.slash.fill") }
                        .accessibilityLabel("Stop reading aloud")
                }
            }
        }
        .task {
            if !sentInitial, let delivery {
                sentInitial = true
                model.follow(delivery)
                return
            }
            await model.load()
            if !sentInitial, let initialPrompt {
                sentInitial = true
                model.send(initialPrompt)
            }
        }
        .onDisappear {
            speaker.stop()
            if listening, ask.isListening { ask.cancel() }
            ask.resetPhase()
        }
        .onChange(of: ask.arrived) { _, delivery in
            // A request sent as a file from this conversation: its answer is followed here once the iPhone says where.
            guard let delivery, listening, delivery.conversationId == model.conversationId || model.conversationId == nil else { return }
            ask.consumeArrived()
            listening = false
            model.follow(delivery)
        }
    }

    /// Nuo's transcription through the iPhone when it is in reach, and always for the bots only the iPhone may reach.
    private var usesNuoVoice: Bool { ask.phoneReachable || model.bot.needsPhone || session.isDemo }

    private func sendSpoken() {
        Task {
            if let delivery = await ask.finish() {
                listening = false
                model.follow(delivery)
            }
        }
    }

    /// The keyboard: straight to the gateway when the watch may reach the bot, else through the iPhone's queue.
    private func typed(_ text: String) {
        if model.bot.needsPhone, !ask.phoneReachable, !session.isDemo {
            ask.queueTyped(text, botId: model.bot.id, conversationId: model.conversationId)
            listening = true
        } else {
            model.send(text)
        }
    }

    /// While streaming, follow the answer; once done, show the last exchange from its question so the
    /// work summary and the start of the answer are on screen.
    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        if model.live != nil {
            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("live", anchor: .bottom) }
        } else if WatchDemoDirector.scrollsToEnd {
            proxy.scrollTo("composer", anchor: UnitPoint(x: 0.5, y: 1.6))
        } else if let question = model.messages.last(where: { $0.role == .user }) ?? model.messages.last {
            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(question.id, anchor: .top) }
        }
    }
}

struct LiveTurnView: View {
    let turn: ConversationModel.LiveTurn

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if turn.showsPrompt {
            HStack {
                Spacer(minLength: 24)
                Text(turn.prompt)
                    .font(.footnote)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Color.userBubble, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            }
            if let tool = turn.currentTool {
                WorkRow(label: tool)
            }
            if turn.text.isEmpty {
                HStack(spacing: 8) {
                    PulsingDots()
                    Text(turn.steps > 0 ? String(localized: "Working…") : String(localized: "Thinking…"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else {
                AssistantContent(text: turn.text, streaming: true)
                PulsingDots()
            }
        }
    }
}
