import Foundation
import Observation
import UIKit

@Observable
@MainActor
final class ShareModel {
    enum SlotState {
        case loading(Double)
        case ready(SharedContent)
        case failed(String)
    }

    struct Slot: Identifiable {
        let id: Int
        var state: SlotState
    }

    enum Phase: Equatable {
        case composing
        case sending(Double)
        case sent(conversationId: String, botId: String)
        case failed(String)
    }

    enum BotsState: Equatable { case loading, loaded, failed(String) }

    var slots: [Slot]
    var bots: [Bot]
    var botsState: BotsState = .loading
    var selectedBotId: String? {
        didSet { if let selectedBotId { ShareDefaults.lastBotId = selectedBotId } }
    }
    var message = ""
    var continueLast: Bool {
        didSet { ShareDefaults.continueLast = continueLast }
    }
    var phase: Phase = .composing
    let isPaired: Bool

    var onFinish: () -> Void = {}
    var onCancel: () -> Void = {}
    var onOpenURL: (URL) -> Void = { _ in }

    private let inputs: [ShareInput]
    private let gateway: ShareGateway?
    private let loader: ShareItemLoader
    private var dismissTask: Task<Void, Never>?

    init(inputs: [ShareInput], gateway: ShareGateway?, workDirectory: URL) {
        self.inputs = inputs
        self.gateway = gateway
        isPaired = gateway != nil
        loader = ShareItemLoader(workDirectory: workDirectory)
        slots = inputs.indices.map { Slot(id: $0, state: .loading(0)) }
        bots = ShareDefaults.cachedBots
        continueLast = ShareDefaults.continueLast
        selectedBotId = Self.initialSelection(in: bots)
    }

    #if DEBUG
    init(previewSlots: [SlotState], bots: [Bot], selectedBotId: String?, message: String = "", phase: Phase = .composing, paired: Bool = true) {
        inputs = []
        gateway = nil
        isPaired = paired
        loader = ShareItemLoader(workDirectory: FileManager.default.temporaryDirectory)
        slots = previewSlots.enumerated().map { Slot(id: $0.offset, state: $0.element) }
        self.bots = bots
        botsState = .loaded
        self.selectedBotId = selectedBotId
        self.message = message
        continueLast = false
        self.phase = phase
    }
    #endif

    // MARK: Derived state

    var selectedBot: Bot? { bots.first { $0.id == selectedBotId } }

    var contents: [SharedContent] {
        slots.compactMap { if case let .ready(content) = $0.state { content } else { nil } }
    }

    var isLoadingItems: Bool {
        slots.contains { if case .loading = $0.state { true } else { false } }
    }

    var loadingFraction: Double {
        guard !slots.isEmpty else { return 1 }
        let total = slots.reduce(0.0) { sum, slot in
            switch slot.state {
            case let .loading(fraction): sum + fraction
            default: sum + 1
            }
        }
        return total / Double(slots.count)
    }

    var hasSendableContent: Bool {
        !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !outgoingAttachments.isEmpty
            || contents.contains { if case .link = $0 { true } else if case .text = $0 { true } else { false } }
    }

    var isBusy: Bool {
        switch phase {
        case .sending, .sent: true
        default: false
        }
    }

    var canSend: Bool { isPaired && selectedBot != nil && !isLoadingItems && hasSendableContent && !isBusy }

    var errorMessage: String? {
        if case let .failed(message) = phase { message } else { nil }
    }

    /// Message first, then shared links and text, as plain prompt text (docs/protocol.md, "Attachments").
    var composedText: String {
        var parts: [String] = []
        let typed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty { parts.append(typed) }
        for content in contents {
            switch content {
            case let .link(link): parts.append(link.title.map { "\($0)\n\(link.url.absoluteString)" } ?? link.url.absoluteString)
            case let .text(text): parts.append(text)
            default: break
            }
        }
        return parts.joined(separator: "\n\n")
    }

    var outgoingAttachments: [OutgoingAttachment] {
        contents.compactMap { content in
            switch content {
            case let .image(image):
                OutgoingAttachment(kind: "image", mime: "image/jpeg", name: nil, byteCount: image.byteCount, fileURL: image.fileURL)
            case let .file(file):
                file.fileURL.map { OutgoingAttachment(kind: "file", mime: file.mime, name: file.name, byteCount: file.byteCount, fileURL: $0) }
            default: nil
            }
        }
    }

    // MARK: Actions

    func start() {
        for (index, input) in inputs.enumerated() {
            Task {
                do {
                    let content = try await loader.load(input) { fraction in
                        Task { @MainActor in self.updateProgress(index, fraction) }
                    }
                    slots[index].state = .ready(content)
                } catch {
                    slots[index].state = .failed((error as? LocalizedError)?.errorDescription ?? ShareLoadError.unreadable.errorDescription ?? "")
                }
            }
        }
        refreshBots()
    }

    func refreshBots() {
        guard let gateway else { return }
        if bots.isEmpty { botsState = .loading }
        Task {
            do {
                let fresh = try await gateway.bots().filter { $0.config != nil }
                bots = fresh
                botsState = .loaded
                ShareDefaults.cachedBots = fresh
                if selectedBot == nil { selectedBotId = Self.initialSelection(in: fresh) }
            } catch {
                botsState = bots.isEmpty ? .failed(Self.describe(error)) : .loaded
            }
        }
    }

    func select(_ bot: Bot) {
        guard !isBusy else { return }
        selectedBotId = bot.id
        UISelectionFeedbackGenerator().selectionChanged()
    }

    func send() {
        guard canSend, let gateway, let bot = selectedBot else { return }
        let text = composedText
        let attachments = outgoingAttachments
        let reuse = continueLast
        let bodyFile = loader.workDirectory.appending(path: "prompt-\(UUID().uuidString).json")
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        phase = .sending(0.02)
        Task {
            defer { try? FileManager.default.removeItem(at: bodyFile) }
            do {
                var conversationId: String?
                if reuse { conversationId = try await gateway.latestConversation(botId: bot.id)?.id }
                if conversationId == nil { conversationId = try await gateway.createConversation(botId: bot.id).id }
                guard let conversationId else { return }
                phase = .sending(0.08)
                try await Task.detached(priority: .userInitiated) {
                    try PromptBodyWriter.write(text: text, attachments: attachments, to: bodyFile)
                }.value
                try await gateway.prompt(conversationId: conversationId, bodyFile: bodyFile) { fraction in
                    Task { @MainActor in
                        guard case .sending = self.phase else { return }
                        self.phase = .sending(0.1 + 0.88 * fraction)
                    }
                }
                phase = .sent(conversationId: conversationId, botId: bot.id)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                scheduleDismiss()
            } catch {
                phase = .failed(Self.describe(error))
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
        }
    }

    func openConversation() {
        guard case let .sent(conversationId, botId) = phase else { return }
        dismissTask?.cancel()
        var components = URLComponents()
        components.scheme = "nuo"
        components.host = "conversation"
        components.path = "/\(conversationId)"
        components.queryItems = [URLQueryItem(name: "bot", value: botId)]
        if let url = components.url { onOpenURL(url) }
        onFinish()
    }

    func openApp() {
        if let url = URL(string: "nuo://") { onOpenURL(url) }
        onCancel()
    }

    func cancel() {
        dismissTask?.cancel()
        onCancel()
    }

    private func scheduleDismiss() {
        dismissTask = Task {
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled else { return }
            onFinish()
        }
    }

    private func updateProgress(_ index: Int, _ fraction: Double) {
        guard slots.indices.contains(index), case .loading = slots[index].state else { return }
        slots[index].state = .loading(fraction)
    }

    private static func initialSelection(in bots: [Bot]) -> String? {
        if let last = ShareDefaults.lastBotId, bots.contains(where: { $0.id == last }) { return last }
        return bots.count == 1 ? bots.first?.id : nil
    }

    static func describe(_ error: any Error) -> String {
        switch error as? ShareGateway.Failure {
        case .offline: String(localized: "Gateway unreachable. Check your connection or that dev is online.")
        case .unauthorized: String(localized: "Session expired. Open Nuo to sign in again.")
        case .tooLarge: String(localized: "Upload too large for the gateway (images 10 MB, files 50 MB max).")
        case let .rejected(status, message): message.map { String(localized: "The gateway refused the upload (\(status)): \($0)") } ?? String(localized: "The gateway refused the upload (\(status)).")
        case nil: String(localized: "The upload failed. Try again.")
        }
    }
}

/// Preferences and cache kept in the app group so the sheet opens with the bots already listed.
enum ShareDefaults {
    private static let suiteName = AppIdentity.appGroup
    private static let botsKey = "share.bots"
    private static let lastBotKey = "share.lastBotId"
    private static let continueKey = "share.continueLast"

    private static var store: UserDefaults { UserDefaults(suiteName: suiteName) ?? .standard }

    static var lastBotId: String? {
        get { store.string(forKey: lastBotKey) }
        set { store.set(newValue, forKey: lastBotKey) }
    }

    static var continueLast: Bool {
        get { store.bool(forKey: continueKey) }
        set { store.set(newValue, forKey: continueKey) }
    }

    static var cachedBots: [Bot] {
        get { store.data(forKey: botsKey).flatMap { try? JSONDecoder().decode([Bot].self, from: $0) } ?? [] }
        set { store.set(try? JSONEncoder().encode(newValue), forKey: botsKey) }
    }
}
