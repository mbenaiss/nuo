import Foundation

/// A spoken request made on the watch (« Parler à Nuo »), kept on disk until the iPhone has sent it to the bot.
struct WatchAsk: Codable, Hashable, Sendable, Identifiable {
    enum State: String, Codable, Sendable {
        /// Neither the iPhone nor the network answers: it leaves as soon as one does.
        case waiting
        /// Handed to the iPhone, live or through the system's transfer queue.
        case sending
        /// The iPhone sent it to the bot.
        case delivered
        /// The iPhone refused it (nothing heard, no bot, too old): shown, never sent again.
        case failed
    }

    var id: String
    var createdAt: Date
    /// The bot picked on the watch; nil lets the iPhone choose (a bot named first, else the default one).
    var botId: String?
    /// A conversation to continue; nil starts a new one.
    var conversationId: String?
    /// The recording, in the asks folder; nil for a request typed with the watch's keyboard.
    var audioFile: String?
    var text: String?
    var seconds: Double
    var state: State = .waiting
    var attempts = 0
    /// Filled in by the iPhone once sent: where the answer lands.
    var deliveredConversationId: String?
    var deliveredBotId: String?
    var transcript: String?
    /// When the system finished delivering it (or the iPhone said it keeps it), to hand it over again if no word
    /// comes back.
    var sentAt: Date?
    var failure: String?

    init(id: String = UUID().uuidString.lowercased(), createdAt: Date, botId: String?, conversationId: String? = nil,
         audioFile: String?, text: String? = nil, seconds: Double) {
        self.id = id
        self.createdAt = createdAt
        self.botId = botId
        self.conversationId = conversationId
        self.audioFile = audioFile
        self.text = text
        self.seconds = seconds
    }
}

/// The watch's requests not yet delivered, oldest first. Nothing leaves the queue before the iPhone confirms it sent
/// the request to the bot, so a dropped connection, a dead battery or a relaunch never loses one.
struct AskQueue: Codable, Equatable, Sendable {
    private(set) var items: [WatchAsk] = []
    /// Delivered requests kept a while, so the home screen can link to their answer.
    static let keepDelivered = 5

    /// A request delivered with no word back is handed over again after 10, 20, 40 minutes… (the iPhone ignores a
    /// second copy), never waiting more than this.
    static let resendAfter: TimeInterval = 10 * 60
    static let maxResendDelay: TimeInterval = 2 * 3600

    static func resendDelay(attempts: Int) -> TimeInterval {
        min(maxResendDelay, resendAfter * pow(2, Double(max(0, min(attempts, 16) - 1))))
    }

    var waiting: [WatchAsk] { items.filter { $0.state == .waiting || $0.state == .sending } }
    var delivered: [WatchAsk] { items.filter { $0.state == .delivered } }
    var failed: [WatchAsk] { items.filter { $0.state == .failed } }

    mutating func enqueue(_ ask: WatchAsk) {
        guard !items.contains(where: { $0.id == ask.id }) else { return }
        items.append(ask)
    }

    func ask(id: String) -> WatchAsk? { items.first { $0.id == id } }

    /// The requests to hand over now, oldest first: those waiting, and those handed over long ago with no word back.
    func due(now: Date = Date(), excluding inFlight: Set<String> = []) -> [WatchAsk] {
        items.filter { ask in
            guard !inFlight.contains(ask.id) else { return false }
            switch ask.state {
            case .waiting: return true
            // No end of transfer known and not in the system's queue any more: it vanished, it goes again.
            case .sending: return ask.sentAt.map { now.timeIntervalSince($0) >= Self.resendDelay(attempts: ask.attempts) } ?? true
            case .delivered, .failed: return false
            }
        }
    }

    /// When the next request handed over without a word back is due again, to wake up then.
    func nextResend(now: Date = Date()) -> Date? {
        items.compactMap { ask -> Date? in
            guard ask.state == .sending, let sentAt = ask.sentAt else { return nil }
            let due = sentAt.addingTimeInterval(Self.resendDelay(attempts: ask.attempts))
            return due > now ? due : nil
        }.min()
    }

    /// The system delivered it, or the iPhone said it keeps it: the wait for the word starts now.
    mutating func markTransferred(_ id: String, at now: Date = Date()) {
        update(id) { if $0.state == .sending { $0.sentAt = now } }
    }

    /// Typed requests older than six hours are not sent any more; their text stays readable in « Non envoyées ».
    /// A spoken one keeps its audio until the iPhone has turned it into text.
    mutating func expireTyped(now: Date = Date()) -> [WatchAsk] {
        let expired = items.filter { ($0.state == .waiting || $0.state == .sending) && $0.audioFile == nil && $0.text != nil
            && AskExpiry.isExpired(createdAt: $0.createdAt, now: now) }
        for ask in expired { markFailed(ask.id, message: AskExpiry.message) }
        return expired
    }

    /// « Envoyer maintenant » on a request that was not sent: a new request with its text, sent from now.
    mutating func requeue(_ id: String, now: Date = Date(), newId: String = UUID().uuidString.lowercased()) -> WatchAsk? {
        guard let old = ask(id: id), old.state == .failed, let text = old.text ?? old.transcript, !text.isEmpty else { return nil }
        remove(id)
        let ask = WatchAsk(id: newId, createdAt: now, botId: old.botId, conversationId: old.conversationId, audioFile: nil, text: text, seconds: 0)
        enqueue(ask)
        return ask
    }

    func next(now: Date = Date(), excluding inFlight: Set<String> = []) -> WatchAsk? {
        due(now: now, excluding: inFlight).first
    }

    mutating func markSending(_ id: String) {
        update(id) {
            $0.state = .sending
            $0.attempts += 1
            $0.sentAt = nil
        }
    }

    /// Returns the refused request so its audio can be deleted.
    struct Failed {
        /// The request as it was, its audio file included.
        var ask: WatchAsk?
        /// Audio of older refused requests dropped from the list, to delete.
        var droppedAudio: [String]
        var audioFile: String? { ask?.audioFile }
    }

    /// `transcript`: what the iPhone heard, so a request it would not send stays readable.
    @discardableResult
    mutating func markFailed(_ id: String, message: String, transcript: String? = nil) -> Failed {
        let before = ask(id: id)
        update(id) {
            $0.state = .failed
            $0.failure = message
            if let transcript, !transcript.isEmpty { $0.transcript = transcript }
            // The audio goes only once there is text to read instead.
            if $0.text != nil || $0.transcript != nil { $0.audioFile = nil }
        }
        let failed = items.filter { $0.state == .failed }
        var droppedAudio: [String] = []
        if failed.count > Self.keepDelivered {
            let drop = failed.prefix(failed.count - Self.keepDelivered)
            droppedAudio = drop.compactMap(\.audioFile)
            let ids = Set(drop.map(\.id))
            items.removeAll { ids.contains($0.id) }
        }
        return Failed(ask: before, droppedAudio: droppedAudio)
    }

    /// The handover failed (iPhone out of reach, error): it waits for the next chance. Only a request on its way goes
    /// back: a late failure report never undoes a delivery or a refusal.
    mutating func markWaiting(_ id: String) {
        update(id) { if $0.state == .sending { $0.state = .waiting } }
    }

    /// Returns the delivered request so its audio can be deleted.
    @discardableResult
    mutating func markDelivered(_ id: String, conversationId: String?, botId: String?, transcript: String?) -> WatchAsk? {
        update(id) {
            $0.state = .delivered
            $0.deliveredConversationId = conversationId
            $0.deliveredBotId = botId
            $0.transcript = transcript
            $0.audioFile = nil
        }
        let delivered = items.filter { $0.state == .delivered }
        if delivered.count > Self.keepDelivered {
            let drop = Set(delivered.prefix(delivered.count - Self.keepDelivered).map(\.id))
            items.removeAll { drop.contains($0.id) }
        }
        return ask(id: id)
    }

    /// A refused request that will never have text: its audio goes, its reason stays.
    mutating func dropAudio(_ id: String) {
        update(id) { $0.audioFile = nil }
    }

    /// Returns the request, so its audio can be deleted with it.
    @discardableResult
    mutating func remove(_ id: String) -> WatchAsk? {
        let removed = ask(id: id)
        items.removeAll { $0.id == id }
        return removed
    }

    private mutating func update(_ id: String, _ change: (inout WatchAsk) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[index])
    }
}

/// Which bot gets a spoken request, and the words meant for it.
enum AskTarget {
    struct Choice: Equatable {
        var botId: String
        var text: String
    }

    /// The bot picked on the watch first; else one named at the start (« @Coach … », « Coach, … », « Demande à Coach … »);
    /// else the one chosen in the settings; else the general bot (`overview`), which can hand the request to any other.
    static func resolve(text: String, bots: [Bot], explicitBotId: String?, preferredBotId: String?) -> Choice? {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let explicitBotId, bots.contains(where: { $0.id == explicitBotId }) { return Choice(botId: explicitBotId, text: clean) }
        if let named = mention(in: clean, bots: bots) { return named }
        if let preferredBotId, bots.contains(where: { $0.id == preferredBotId }) { return Choice(botId: preferredBotId, text: clean) }
        if let general = defaultBot(in: bots) { return Choice(botId: general.id, text: clean) }
        return nil
    }

    static func defaultBot(in bots: [Bot]) -> Bot? {
        bots.first { $0.config?.overview == true } ?? bots.first { $0.published != nil } ?? bots.first
    }

    private static let leads = ["demande a ", "dis a ", "pour ", "@"]

    private static func mention(in text: String, bots: [Bot]) -> Choice? {
        let folded = fold(text)
        // Longest names first: « Coach sportif » before « Coach ».
        let named = bots.compactMap { bot -> (Bot, String)? in
            guard let name = bot.config?.name, !name.isEmpty else { return nil }
            return (bot, fold(name))
        }.sorted { $0.1.count > $1.1.count }
        for lead in [""] + leads {
            guard lead.isEmpty || folded.hasPrefix(lead) else { continue }
            let afterLead = folded.dropFirst(lead.count)
            for (bot, name) in named where afterLead.hasPrefix(name) {
                let rest = afterLead.dropFirst(name.count)
                // « Coach, … » or « @Coach … »; a bare « Coach » at the start of a sentence needs a comma or a colon.
                guard let first = rest.first else { continue }
                let next = rest.drop { $0 == " " }.first
                let separator = next == "," || next == ":"
                guard separator || (!lead.isEmpty && first == " ") else { continue }
                let consumed = lead.count + name.count
                var remainder = String(text.dropFirst(consumed)).trimmingCharacters(in: CharacterSet(charactersIn: " ,:").union(.whitespaces))
                // « Demande à Coach de me préparer… »
                if !lead.isEmpty, lead != "@" {
                    if remainder.lowercased().hasPrefix("de ") { remainder = String(remainder.dropFirst(3)) }
                    else if remainder.lowercased().hasPrefix("d'") || remainder.lowercased().hasPrefix("d’") { remainder = String(remainder.dropFirst(2)) }
                }
                guard !remainder.isEmpty else { continue }
                return Choice(botId: bot.id, text: remainder.prefix(1).uppercased() + remainder.dropFirst())
            }
        }
        return nil
    }

    /// Lowercased without accents, the same length as the text so offsets carry over.
    private static func fold(_ text: String) -> String {
        String(text.map { character -> Character in
            let folded = String(character).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "fr")).lowercased()
            return folded.count == 1 ? Character(folded) : character
        })
    }
}

/// The two buttons of a confirmation on the watch, out of the options the agent offers. The watch only ever allows
/// once: with no such option, the yes is given on the iPhone, where the choice can be read in full.
enum ConfirmationChoice {
    static func pick(_ options: [PermissionOption]) -> (confirm: PermissionOption?, cancel: PermissionOption?) {
        let confirm = options.first { $0.kind == "allow_once" }
        let cancel = options.first { $0.kind == "reject_once" }
        return (confirm, cancel)
    }

    /// The only answers the iPhone relays from the watch: once, either way.
    static func isRelayable(_ option: PermissionOption) -> Bool {
        option.kind == "allow_once" || option.kind == "reject_once"
    }
}

/// A spoken request is for now: one the gateway could not take for hours is not sent to the bot any more.
enum AskExpiry {
    static let lifetime: TimeInterval = 6 * 3600

    static func isExpired(createdAt: Date, now: Date = Date()) -> Bool {
        now.timeIntervalSince(createdAt) > lifetime
    }

    static var message: String { String(localized: "Request older than 6 h, not sent: ask again if it still applies.") }
}

/// What the relay (the locked iPhone's narrow access, which can only add) does not pass on: such a request waits for
/// the unlock and then goes through the app (docs/security.md, « Relay access »).
enum RelayScope {
    /// The gateway's limit for a relayed prompt (`RELAY_MAX_PROMPT`).
    static let maxText = 4000
    static var waitingText: String { String(localized: "Waiting for unlock: request outside the locked scope") }
    static var newConversationText: String { String(localized: "New conversation (iPhone locked)") }
    static var limitText: String { String(localized: "Too many requests went through the locked iPhone this hour: yours will go once it's unlocked.") }
    /// Sent through the app at the unlock, in the conversation the relay opened: the bot already has the request.
    static let unlockFollowUp = "L'iPhone est déverrouillé : fais maintenant ce qui avait été refusé dans ma demande précédente."

    /// Too long, or a `/` command however it is padded: the gateway refuses it to the relay.
    static func waitsForUnlock(_ text: String) -> Bool {
        if text.count > maxText { return true }
        let start = text.unicodeScalars.drop { $0.properties.isWhitespace || $0.properties.generalCategory == .format }
        return start.first == "/"
    }

    /// The answer to the prompt whose user message is `messageId`: the first stored assistant message after it.
    static func answer(to messageId: String, in messages: [Message]) -> Message? {
        guard let index = messages.firstIndex(where: { $0.id == messageId }) else { return nil }
        return messages[(index + 1)...].first { $0.role == .assistant && $0.stopReason != nil }
    }
}

/// The last requests sent, oldest first, so a request delivered twice reaches its bot once.
struct RecentlyDone<Value: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
    struct Entry: Codable, Equatable, Sendable {
        var id: String
        var value: Value
    }

    private(set) var entries: [Entry] = []
    var limit = 100

    func value(for id: String) -> Value? { entries.last { $0.id == id }?.value }

    mutating func insert(_ id: String, _ value: Value) {
        entries.removeAll { $0.id == id }
        entries.append(Entry(id: id, value: value))
        if entries.count > limit { entries.removeFirst(entries.count - limit) }
    }
}

/// Time from the end of speech to the answer on screen, as the watch shows it under a spoken request.
enum AskLatency {
    static func label(_ seconds: TimeInterval, locale: Locale = .current) -> String {
        let tenths = (seconds * 10).rounded() / 10
        let value = tenths.formatted(.number.precision(.fractionLength(1)).locale(locale))
        return String(localized: "Answered in \(value) s")
    }
}

/// The answers of `-demo`: what the general bot does with the demo requests, cards and confirmation included.
enum AskDemoScript {
    struct Reply: Equatable {
        var text: String
        var tools: [String]
        /// Set when the bot asks before acting; `text` is then the answer once confirmed.
        var confirmation: String?
        var refusal: String?
    }

    /// The demo's timeline, in seconds: the iPhone's transcription, the bot's first words, each tool it runs.
    static let transcription: Double = 0.65
    static let thinking: Double = 0.5
    static let tool: Double = 0.9

    /// From the end of speech to the first words of the answer on screen, in the demo.
    static func latency(for prompt: String) -> Double {
        let reply = reply(to: prompt)
        return transcription + thinking + (reply.confirmation == nil ? Double(reply.tools.count) * tool : 0)
    }

    static var reminders: String { String(localized: "Add buy bread and call Julie Martin tomorrow at 9 am") }
    static var event: String { String(localized: "Put the Lyon trade show quote meeting on the calendar, Thursday at 2 pm") }
    static var email: String { String(localized: "Send the Lyon trade show quote to Julie Martin") }

    static func reply(to prompt: String, now: Date = Date()) -> Reply {
        let folded = prompt.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "fr")).lowercased()
        let calendar = Calendar(identifier: .gregorian)
        if folded.contains("calendrier") || folded.contains("reunion") || folded.contains("calendar") || folded.contains("meeting") {
            let thursday = calendar.nextDate(after: now, matching: DateComponents(hour: 14, weekday: 5), matchingPolicy: .nextTime) ?? now
            return Reply(
                text: String(localized: "It's on the calendar.") + "\n::event {\"title\":\"\(String(localized: "Lyon trade show quote meeting"))\",\"start\":\"\(stamp(thursday))\",\"end\":\"\(stamp(thursday.addingTimeInterval(3600)))\",\"location\":\"\(String(localized: "Video call"))\"}",
                tools: ["calendar_create_event"])
        }
        if folded.contains("envoie") || folded.contains("mail") || folded.contains("send") {
            return Reply(
                text: String(localized: "Email sent to Julie Martin with the Lyon trade show quote.") + "\n::callout {\"style\":\"success\",\"title\":\"\(String(localized: "Email sent"))\",\"text\":\"julie.martin@example.com · \(String(localized: "Lyon trade show quote"))\"}",
                tools: ["gmail_send"],
                confirmation: String(localized: "Send an email to julie.martin@example.com: “Lyon trade show quote”"),
                refusal: String(localized: "OK, I won't send anything."))
        }
        return Reply(
            text: String(localized: "Noted.") + "\n::callout {\"style\":\"success\",\"title\":\"\(String(localized: "Buy bread"))\",\"text\":\"\(String(localized: "Reminder · Groceries"))\"}\n::callout {\"style\":\"success\",\"title\":\"\(String(localized: "Call Julie Martin"))\",\"text\":\"\(String(localized: "Reminder tomorrow at 9 am · Work"))\"}",
            tools: ["reminders_add", "reminders_add"])
    }

    private static func stamp(_ date: Date) -> String {
        let parts = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return String(format: "%04d-%02d-%02dT%02d:%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0, parts.hour ?? 0, parts.minute ?? 0)
    }
}
