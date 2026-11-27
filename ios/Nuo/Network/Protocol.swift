import Foundation

// Mirror of gateway/src/protocol.ts. Keep both in sync (see docs/protocol.md).

/// The gateway profile a device belongs to (`profile` of `POST /api/pair`, `GET /api/me`).
struct GatewayProfile: Codable, Hashable, Sendable {
    var id: String
    var name: String
}

/// A struct rather than an enum so an agent the gateway adds later still decodes in an older app.
struct AgentID: RawRepresentable, Codable, Hashable, Sendable {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }

    static let claude = AgentID(rawValue: "claude")
    static let codex = AgentID(rawValue: "codex")
    static let grok = AgentID(rawValue: "grok")
    static let gemini = AgentID(rawValue: "gemini")
}

struct ModelInfo: Codable, Hashable, Sendable, Identifiable {
    let id: String
    let name: String
    var isDefault: Bool?
    var efforts: [String]?
}

struct AgentInfo: Codable, Hashable, Sendable, Identifiable {
    let id: AgentID
    let name: String
    let available: Bool
    let authenticated: Bool
    let models: [ModelInfo]
    var note: String?
}

struct ToolServer: Codable, Hashable, Sendable, Identifiable {
    let id: String
    let name: String
    let description: String
    let tools: [String]
}

/// Something installed on the gateway machine (CLI, MCP server or skill) that can be tagged with "#".
struct MachineTool: Codable, Hashable, Sendable, Identifiable {
    let id: String
    let name: String
    let kind: String // cli | mcp | skill
    let description: String
    var version: String?
    var usage: String?
    let needsShell: Bool
    let available: Bool
}

enum PermissionPolicy: String, Codable, CaseIterable, Sendable {
    case ask, auto, readonly

    var label: String {
        switch self {
        case .ask: String(localized: "Ask")
        case .auto: "Auto"
        case .readonly: String(localized: "Read-only")
        }
    }
}

struct BotConfig: Codable, Hashable, Sendable {
    var name: String
    var emoji: String
    var color: String
    var description: String
    var agent: AgentID
    var model: String
    var effort: String?
    var instructions: String
    var toolServers: [String]
    var workdir: String?
    var permissionPolicy: PermissionPolicy
    var voice: VoiceSettings?
    var commands: [BotCommand]?
    /// Published on: the gateway runs a daily "Propositions du jour" task. Off is `nil`, as the gateway stores it.
    var proactive: Bool?
    /// Sees every bot and conversation: it finds and reads them, and asks another bot. Off is `nil`.
    var overview: Bool?
    /// No tool at all, not even reading a file. Set on the gateway only; kept here so saving the bot keeps it. Off is `nil`.
    var noTools: Bool?
    /// The language the bot writes in, French when `nil`. Set on the gateway only; kept here so saving the bot keeps it.
    var language: String?
    /// What the user decided for good about a tool, keyed `server/name` (`nuo/gmail_search`) or by a built-in's name
    /// (`Bash`). Changed on the gateway only (a permission card, `DELETE /api/bots/:id/tool-rules/:key`). None is `nil`.
    var toolRules: [String: ToolRule]?

    struct VoiceSettings: Codable, Hashable, Sendable {
        var voiceId: String?
    }
}

/// `allow`: no card for that tool while the bot asks; `block`: refused whatever the bot's permissions.
enum ToolRule: String, Codable, Hashable, Sendable {
    case allow, block

    /// The card's option that goes with this rule, “once” first; the gateway answers the agent with its own anyway.
    func answer(in options: [PermissionOption]) -> PermissionOption? {
        let kinds = self == .allow ? ["allow_once", "allow_always"] : ["reject_once", "reject_always"]
        return kinds.lazy.compactMap { kind in options.first { $0.kind == kind } }.first
    }
}

/// What a permission card may remember for its tool: the rule key and the rules the gateway offers for it.
struct ToolRuleOffer: Hashable, Sendable {
    let tool: String
    let rules: [ToolRule]

    init?(tool: String?, rules: [ToolRule]?) {
        guard let tool, let rules, !rules.isEmpty else { return nil }
        self.tool = tool
        self.rules = rules
    }

    /// The agent's own options the card still shows. Its “Always allow” only lasts the agent's session: next to
    /// “Always for this tool” the two read as the same choice, so the remembered one replaces it.
    func cardOptions(_ options: [PermissionOption]) -> [PermissionOption] {
        rules.contains(.allow) ? options.filter { $0.kind != "allow_always" } : options
    }
}

/// A rule as the bot's settings list it: “Search emails (Gmail): always allowed”.
enum ToolRuleLabel {
    static func line(_ key: String, _ rule: ToolRule) -> String {
        String(localized: "\(name(key)): \(state(rule).lowercased())")
    }

    /// What the tool does, in words, and where it acts: “Send an email (Gmail)”, “Terminal commands”.
    static func name(_ key: String) -> String {
        let parts = key.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return builtIn[key] ?? key }
        let (server, tool) = (parts[0], parts[1])
        if server == "nuo", let known = nuo[tool] { return "\(known.0) (\(known.1))" }
        if let known = servers[server], let label = known.tools[tool] { return "\(label) (\(known.name))" }
        return String(localized: "\(display(server)): \(words(tool, droppingPrefix: server))")
    }

    static func state(_ rule: ToolRule) -> String {
        switch rule {
        case .allow: String(localized: "Always allowed")
        case .block: String(localized: "Blocked")
        }
    }

    private static let builtIn: [String: String] = [
        "Bash": String(localized: "Terminal commands"),
        "Edit": String(localized: "Edit files"),
        "MultiEdit": String(localized: "Edit files"),
        "Write": String(localized: "Create or replace files"),
        "Read": String(localized: "Read files"),
        "Glob": String(localized: "Search for files"),
        "Grep": String(localized: "Search in files"),
        "NotebookEdit": String(localized: "Edit a notebook"),
        "WebFetch": String(localized: "Open a web page"),
        "WebSearch": String(localized: "Search the web"),
        "Task": String(localized: "Start a subagent"),
        "Agent": String(localized: "Start a subagent"),
    ]

    private static let nuo: [String: (String, String)] = [
        "gmail_search": (String(localized: "Search emails"), "Gmail"),
        "gmail_read": (String(localized: "Read an email"), "Gmail"),
        "gmail_draft": (String(localized: "Prepare a draft"), "Gmail"),
        "gmail_send": (String(localized: "Send an email"), "Gmail"),
        "calendar_list": (String(localized: "View calendars"), String(localized: "Google Calendar")),
        "calendar_events": (String(localized: "Read events"), String(localized: "Google Calendar")),
        "calendar_create": (String(localized: "Create an event"), String(localized: "Google Calendar")),
        "calendar_delete": (String(localized: "Delete an event"), String(localized: "Google Calendar")),
        "drive_search": (String(localized: "Search for files"), "Google Drive"),
        "drive_read": (String(localized: "Read a file"), "Google Drive"),
        "google_accounts": (String(localized: "View connected accounts"), "Google"),
        "apple_calendars": (String(localized: "View calendars"), String(localized: "Calendar")),
        "apple_calendar_create": (String(localized: "Create a calendar"), String(localized: "Calendar")),
        "apple_calendar_update": (String(localized: "Edit a calendar"), String(localized: "Calendar")),
        "apple_calendar_delete": (String(localized: "Delete a calendar"), String(localized: "Calendar")),
        "apple_events": (String(localized: "Read events"), String(localized: "Calendar")),
        "apple_event_create": (String(localized: "Create an event"), String(localized: "Calendar")),
        "apple_event_update": (String(localized: "Edit an event"), String(localized: "Calendar")),
        "apple_event_delete": (String(localized: "Delete an event"), String(localized: "Calendar")),
        "health_summary": (String(localized: "Read the health summary"), String(localized: "Health")),
        "health_activity": (String(localized: "Read activity"), String(localized: "Health")),
        "health_body": (String(localized: "Read body measurements"), String(localized: "Health")),
        "health_heart": (String(localized: "Read heart data"), String(localized: "Health")),
        "health_sleep": (String(localized: "Read sleep"), String(localized: "Health")),
        "health_workouts": (String(localized: "Read workouts"), String(localized: "Health")),
        "workout_schedule": (String(localized: "Schedule a workout"), "Apple Watch"),
        "workout_scheduled": (String(localized: "View scheduled workouts"), "Apple Watch"),
        "workout_cancel": (String(localized: "Remove a workout"), "Apple Watch"),
        "device_location": (String(localized: "Know where you are"), "iPhone"),
        "maps_search": (String(localized: "Search for a place"), String(localized: "Maps")),
        "maps_route": (String(localized: "Plan a route"), String(localized: "Maps")),
        "weather": (String(localized: "Check the weather"), String(localized: "Weather")),
        "mac_folders": (String(localized: "View folders"), "Mac"),
        "mac_files_list": (String(localized: "List files"), "Mac"),
        "mac_files_search": (String(localized: "Search for files"), "Mac"),
        "mac_file_read": (String(localized: "Read a file"), "Mac"),
        "mac_file_write": (String(localized: "Write a file"), "Mac"),
        "memory_read": (String(localized: "Read its memory"), "Nuo"),
        "memory_add": (String(localized: "Add to its memory"), "Nuo"),
        "memory_write": (String(localized: "Rewrite its memory"), "Nuo"),
        "notify_user": (String(localized: "Send you a notification"), "Nuo"),
        "schedule_list": (String(localized: "View scheduled tasks"), "Nuo"),
        "schedule_create": (String(localized: "Schedule a task"), "Nuo"),
        "schedule_update": (String(localized: "Edit a scheduled task"), "Nuo"),
        "schedule_delete": (String(localized: "Delete a scheduled task"), "Nuo"),
        "bots_list": (String(localized: "View other bots"), "Nuo"),
        "bot_ask": (String(localized: "Ask another bot"), "Nuo"),
        "conversations_search": (String(localized: "Search conversations"), "Nuo"),
        "conversation_read": (String(localized: "Read a conversation"), "Nuo"),
    ]

    /// Tools from servers a deployment may add in gateway/config/tools.json.
    private static let servers: [String: (name: String, tools: [String: String])] = [
        "fitness": (String(localized: "Fitness coach"), [
            "log_meal": String(localized: "Log a meal"), "delete_meal": String(localized: "Delete a meal"), "log_workout": String(localized: "Log a workout"),
            "save_wod": String(localized: "Save a planned workout"), "list_wods": String(localized: "View planned workouts"), "delete_wod": String(localized: "Delete a planned workout"),
            "day_summary": String(localized: "Daily summary"), "week_summary": String(localized: "Weekly summary"), "next_workout": String(localized: "Next workout"),
            "week_plan": String(localized: "Weekly plan"), "lookup_barcode": String(localized: "Look up a barcode"), "get_series": String(localized: "Read the history"),
            "whoop_today": String(localized: "Today's WHOOP recovery"), "whoop_runs": String(localized: "WHOOP runs"), "sync_whoop": String(localized: "Sync WHOOP"),
            "send_line_chart": String(localized: "Send a line chart"), "send_bar_chart": String(localized: "Send a bar chart"), "send_stat_card": String(localized: "Send a stats card"),
            "send_day_macros": String(localized: "Send today's macros"), "set_setting": String(localized: "Change a setting"), "get_settings": String(localized: "Read settings"),
            "ask_expert": String(localized: "Ask the expert"),
        ]),
        "travel": (String(localized: "Travel"), [
            "search_activities": String(localized: "Search for activities"), "my_flights": String(localized: "View my flights"), "save_flight": String(localized: "Save a flight"),
            "flight_status": String(localized: "Flight status"), "flight_card": String(localized: "Flight card"), "ask_expert": String(localized: "Ask the expert"),
        ]),
        "forma": ("Forma", [
            "guide": String(localized: "Read the guide"), "list_designs": String(localized: "View designs"), "get_design": String(localized: "Open a design"),
            "create_design": String(localized: "Create a design"), "update_design": String(localized: "Edit a design"), "set_parameters": String(localized: "Set parameters"),
            "preview": String(localized: "Preview"), "measure": String(localized: "Measure"), "check_printability": String(localized: "Check printability"), "export": String(localized: "Export"),
            "slice": String(localized: "Slice for printing"), "printer_status": String(localized: "Printer status"), "request_print": String(localized: "Start a print"),
            "list_assets": String(localized: "View files"),
        ]),
    ]

    /// `whoop_today` of the `whoop` server reads “today”, not “whoop today”.
    private static func words(_ tool: String, droppingPrefix server: String) -> String {
        var name = tool
        if name.lowercased().hasPrefix(server.lowercased() + "_") { name.removeFirst(server.count + 1) }
        return name.replacingOccurrences(of: "_", with: " ")
    }

    private static func display(_ server: String) -> String {
        server == "nuo" ? "Nuo" : server.prefix(1).uppercased() + server.dropFirst()
    }
}

/// Slash command of a bot (see `BotCommandAction` in gateway/src/protocol.ts).
struct BotCommand: Codable, Hashable, Sendable, Identifiable {
    var name: String
    var description: String
    var args: String?
    var action: Action
    var id: String { name }

    struct Action: Codable, Hashable, Sendable {
        var type: String // tool | prompt | open | app
        var server: String?
        var tool: String?
        var params: [String]?
        var fixedArgs: [String: JSONValue]?
        var template: String?
        var model: String?
        var effort: String?
        var url: String?
        var action: String? // app: new_conversation | barcode | voice
    }
}

/// Arbitrary JSON (tool `fixedArgs`), kept so editing a command in the app does not drop it.
enum JSONValue: Codable, Hashable, Sendable {
    case string(String), number(Double), bool(Bool), array([JSONValue]), object([String: JSONValue]), null

    init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case let .string(v): try c.encode(v)
        case let .number(v): try c.encode(v)
        case let .bool(v): try c.encode(v)
        case let .array(v): try c.encode(v)
        case let .object(v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
}

struct BotVersion: Codable, Hashable, Sendable, Identifiable {
    let version: Int
    let config: BotConfig
    var note: String?
    let publishedAt: Date
    var id: Int { version }
}

struct Bot: Codable, Hashable, Sendable, Identifiable {
    let id: String
    /// Folder name on the gateway machine, fixed at creation; older gateways do not send it.
    var slug: String?
    var published: BotVersion?
    var draft: BotConfig?
    let createdAt: Date
    var updatedAt: Date
    var lastMessageAt: Date?
    var lastMessagePreview: String?
    /// Conversations with a running turn and the one started last (`GET /api/bots` only; older gateways omit them).
    var activeTurns: Int?
    var activeConversationId: String?

    var config: BotConfig? { published?.config ?? draft }

    /// The tool rules the gateway keeps, by key. Not the draft being edited: rules change in place, both configs alike.
    var toolRuleList: [(key: String, rule: ToolRule)] {
        (config?.toolRules ?? [:]).sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }
}

/// A bot's persistent memory (`memory/<slug>/MEMORY.md`), one fact per line: `- YYYY-MM-DD fact`.
struct BotMemory: Codable, Hashable, Sendable {
    var content: String
    var updatedAt: Date?
}

/// How fast the bots answered (`GET /api/metrics/latency`), per bot and per local day of the gateway. A figure is
/// nil when no answer had that part (no visible text, no completed answer).
struct LatencyReport: Codable, Hashable, Sendable {
    var days: Int
    var scheduled: Bool
    var bots: [BotLatency]
}

struct BotLatency: Codable, Hashable, Sendable, Identifiable {
    var botId: String
    var name: String
    var emoji: String
    var color: String?
    var responses: Int
    /// From the start of the turn to the first visible word.
    var firstTextMedianMs: Int?
    var firstTextP90Ms: Int?
    /// To the first sign of the agent (thought, tool, text).
    var firstEventMedianMs: Int?
    /// Whole answer, completed answers only.
    var durationMedianMs: Int?
    var toolMedianMs: Int?
    var avgSteps: Double
    /// Days with at least one answer, oldest first.
    var daily: [LatencyDay]

    var id: String { botId }
}

struct LatencyDay: Codable, Hashable, Sendable, Identifiable {
    /// `YYYY-MM-DD`.
    var day: String
    var responses: Int
    var firstTextMedianMs: Int?
    var firstTextP90Ms: Int?
    var durationMedianMs: Int?
    var avgSteps: Double

    var id: String { day }
}

/// How full the agent's context window is for a conversation.
struct ContextUsage: Codable, Hashable, Sendable {
    var usedTokens: Int
    var maxTokens: Int?
    var compactions: Int
    var updatedAt: Date
}

/// When a scheduled task runs (see `TaskSchedule` in gateway/src/protocol.ts).
struct TaskSchedule: Codable, Hashable, Sendable {
    var kind: String // cron | once
    var expr: String?
    var timezone: String?
    var at: Date?
}

/// What a scheduled run does (see `TaskAction` in gateway/src/protocol.ts).
struct TaskAction: Codable, Hashable, Sendable {
    var type: String // prompt | command
    var command: String?
    var cwd: String?
    var envFile: String?
    var env: [String: String]?
    var timeoutSec: Int?
    var notifyOn: String? // failure | always | never

    static let prompt = TaskAction(type: "prompt")
    static let defaultTimeoutSec = 600
}

/// A prompt the gateway sends to a bot, or a shell command it runs, on a schedule; the outcome is pushed to the user.
struct ScheduledTask: Codable, Hashable, Sendable, Identifiable {
    let id: String
    var botId: String
    var title: String
    /// Older gateways do not send it: every task is then a prompt task.
    var action: TaskAction?
    var prompt: String
    var schedule: TaskSchedule
    var enabled: Bool
    var conversation: String // dedicated | new
    var conversationId: String?
    var notify: Bool
    var createdBy: String // user | bot | gateway
    var nextRunAt: Date?
    var lastRunAt: Date?
    var lastStatus: String?
    let createdAt: Date
    var updatedAt: Date

    var isCommand: Bool { action?.type == "command" }
}

/// Where a notification led; the Alertes screen opens it again.
struct AlertDestination: Codable, Hashable, Sendable {
    var kind: String
    var id: String?
    var botId: String?
    var runId: String?
    var url: String?
}

/// A notification the gateway sent (GET /api/alerts), so the ones no chat keeps (scripts, failed commands, parcels,
/// reminders, security…) can be found again.
struct AlertItem: Codable, Hashable, Sendable, Identifiable {
    let id: String
    var title: String
    var body: String
    var botId: String?
    var destination: AlertDestination
    var createdAt: Date
    var readAt: Date?
}

struct TaskRun: Codable, Hashable, Sendable, Identifiable {
    let id: String
    let taskId: String
    let conversationId: String
    let startedAt: Date
    var endedAt: Date?
    var status: String
    var preview: String?
    var error: String?
    var exitCode: Int?
    var output: String?
    var durationMs: Int?
}

struct Conversation: Codable, Hashable, Sendable, Identifiable {
    let id: String
    let botId: String
    var title: String
    var useDraft: Bool
    /// Agent picked in the chat; the bot's own when nil. `model` belongs to it.
    var agent: AgentID?
    var model: String?
    var effort: String?
    var context: ContextUsage?
    /// The turn running right now (conversation endpoints only).
    var activeTurn: ActiveTurn?
    /// The running turn in full (`GET /api/conversations/:id` only).
    var turn: TurnSnapshot?
    let createdAt: Date
    var updatedAt: Date
}

/// A conversation found by its title or by what was said in it (`GET /api/conversations/search`).
struct ConversationSearchHit: Codable, Hashable, Sendable, Identifiable {
    let conversation: Conversation
    /// The message that matched best, cut around the words found; nil when only the title matched.
    var messageId: String?
    var role: Message.Role?
    var snippet: String?

    var id: String { conversation.id }
}

/// Where a running turn is (see `TurnPhase` in gateway/src/protocol.ts).
enum TurnPhase: String, Codable, Hashable, Sendable {
    case queued, thinking, working, answering
    case waitingPermission = "waiting_permission"
}

struct ActiveTurn: Codable, Hashable, Sendable {
    var messageId: String
    var startedAt: Date
    var phase: TurnPhase
    var currentTool: String?
    var steps: Int
    var partialText: String?
}

/// Everything streamed so far for a running turn (`turns.snapshot`, `GET /api/conversations/:id`).
struct TurnSnapshot: Codable, Hashable, Sendable {
    var conversationId: String
    var botId: String
    var messageId: String
    var startedAt: Date
    var phase: TurnPhase
    var currentTool: String?
    var text: String
    var thoughts: String?
    var steps: [ToolStep]
    var subagents: [SubagentInfo]?
    var permission: Permission?

    struct Permission: Codable, Hashable, Sendable {
        var requestId: String
        var title: String
        var options: [PermissionOption]
        var tool: String?
        var rules: [ToolRule]?

        var offer: ToolRuleOffer? { ToolRuleOffer(tool: tool, rules: rules) }
    }
}

struct ToolStep: Codable, Hashable, Sendable, Identifiable {
    let toolCallId: String
    var title: String
    var kind: String?
    var status: Status
    var durationMs: Int?
    /// What the step does, in words (a shell command's description), when the agent says it.
    var detail: String?
    var id: String { toolCallId }

    /// The step as a person reads it: "Terminal" alone says nothing of a two-minute wait.
    var label: String {
        if let detail, !detail.isEmpty { detail } else { title }
    }

    enum Status: String, Codable, Sendable { case running, completed, failed }
}

struct Attachment: Codable, Hashable, Sendable {
    var kind: String = "image" // image | file
    var mime: String
    var name: String?
    var size: Int?
    var dataBase64: String?
    var url: String?
}

enum StopReason: String, Codable, Sendable {
    case endTurn = "end_turn", cancelled, error
}

struct Message: Codable, Hashable, Sendable, Identifiable {
    let id: String
    let conversationId: String
    let role: Role
    var text: String
    var thoughts: String?
    var attachments: [Attachment]?
    var steps: [ToolStep]?
    var subagents: [SubagentInfo]?
    var durationMs: Int?
    var stopReason: StopReason?
    /// Assistant messages an agent wrote: the agent and model that answered.
    var agent: AgentID?
    var model: String?
    /// User messages a scheduled task sent: its prompt is instructions for the bot, the chat shows the task instead.
    var task: MessageTask?
    /// User messages a webhook or a mail wrote: its text is the prompt written for the bot, the chat shows this instead.
    var wake: MessageWake?
    let createdAt: Date

    enum Role: String, Codable, Sendable { case user, assistant }

    var isTaskPrompt: Bool { role == .user && task != nil }
}

struct MessageTask: Codable, Hashable, Sendable {
    let id: String
    let title: String
}

/// What woke the bot (docs/protocol.md, « What the apps show »): clipped copies of what came in, never the prompt.
enum MessageWake: Hashable, Sendable {
    case mail(Mail)
    case hook(Hook)
    /// A kind this app does not know: the message shows its text, as before.
    case unknown

    struct Mail: Codable, Hashable, Sendable {
        let from: String
        var fromName: String?
        let to: String
        let subject: String
        let text: String
        /// The owner's own mail, checked by the gateway.
        let verified: Bool
        var attachments: [String]?
    }

    struct Hook: Codable, Hashable, Sendable {
        let name: String
        var event: String?
        var contentType: String?
        let body: String
    }

    var isShown: Bool {
        if case .unknown = self { false } else { true }
    }

    var title: String {
        switch self {
        case let .mail(mail): mail.verified ? String(localized: "Email from you") : String(localized: "Email from \(mail.fromName ?? mail.from)")
        case let .hook(hook): String(localized: "\(hook.name) webhook")
        case .unknown: ""
        }
    }

    /// One line for small screens: who or what, then the subject or the event.
    var summary: String {
        switch self {
        case let .mail(mail): mail.subject.isEmpty ? title : "\(title) · \(mail.subject)"
        case let .hook(hook): hook.event.map { "\(title) · \($0)" } ?? title
        case .unknown: ""
        }
    }

    /// What “Copy” takes: what came in, not the prompt.
    var copyText: String {
        switch self {
        case let .mail(mail): mail.subject.isEmpty ? mail.text : "\(mail.subject)\n\n\(mail.text)"
        case let .hook(hook): hook.body
        case .unknown: ""
        }
    }
}

extension MessageWake: Codable {
    private enum Keys: String, CodingKey { case kind }

    init(from decoder: any Decoder) throws {
        let kind = try decoder.container(keyedBy: Keys.self).decodeIfPresent(String.self, forKey: .kind)
        switch kind {
        case "mail": self = (try? Mail(from: decoder)).map(MessageWake.mail) ?? .unknown
        case "hook": self = (try? Hook(from: decoder)).map(MessageWake.hook) ?? .unknown
        default: self = .unknown
        }
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case let .mail(mail):
            try c.encode("mail", forKey: .kind)
            try mail.encode(to: encoder)
        case let .hook(hook):
            try c.encode("hook", forKey: .kind)
            try hook.encode(to: encoder)
        case .unknown:
            try c.encode("unknown", forKey: .kind)
        }
    }
}

extension Array where Element == Message {
    /// A scheduled task's prompt is instructions for the bot: chats show only what it answered.
    var withoutTaskPrompts: [Message] { filter { !$0.isTaskPrompt } }
}

/// A subagent the bot delegated to during a turn; steps and text only for agents that stream its work.
struct SubagentInfo: Codable, Hashable, Sendable, Identifiable {
    let id: String
    var title: String
    var description: String?
    var state: State
    var startedAt: Date
    var endedAt: Date?
    var steps: [ToolStep]
    var text: String?

    enum State: String, Codable, Sendable {
        case running, waiting, completed, failed, cancelled

        init(from decoder: any Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = State(rawValue: raw) ?? .running
        }
    }

    var isActive: Bool { state == .running || state == .waiting }
}

struct PermissionOption: Codable, Hashable, Sendable, Identifiable {
    let id: String
    let name: String
    let kind: String
}

/// The folder of the user's Mac a conversation works in; the bot reaches it through the `mac_*` device tools.
struct PromptFolder: Codable, Hashable, Sendable {
    let name: String
    let path: String
}

enum ClientEvent: Sendable {
    /// `steer`: “Send now” during a running turn. `goal`: the Goal toggle, the bot works without asking at each
    /// step; the gateway still has the user confirm what sends, invites or deletes.
    case prompt(conversationId: String, text: String, attachments: [Attachment] = [], agent: AgentID? = nil, model: String? = nil, effort: String? = nil, voice: Bool = false, steer: Bool = false, folder: PromptFolder? = nil, goal: Bool = false)
    case cancel(conversationId: String)
    /// `rule`: also remembered for the card's tool (one it offered); the gateway answers the agent once accordingly.
    case permission(requestId: String, optionId: String, rule: ToolRule? = nil)
    /// Asks for a fresh `turns.snapshot`.
    case turnsSync
    /// The app came to the foreground or left it: while one device is in front, the others get no reply push.
    case presence(active: Bool)
    case ping
}

enum ServerEvent: Sendable {
    /// A user message the gateway wrote itself (a webhook or a mail woke the bot), as stored.
    case messageUser(conversationId: String, message: Message)
    case messageStart(conversationId: String, messageId: String, at: Date, botId: String?, phase: TurnPhase?)
    case turnPhase(conversationId: String, messageId: String, phase: TurnPhase)
    case turnsSnapshot([TurnSnapshot])
    case messageDelta(conversationId: String, messageId: String, text: String)
    case thoughtDelta(conversationId: String, messageId: String, text: String)
    case toolStart(conversationId: String, messageId: String, toolCallId: String, title: String, kind: String?)
    case toolDetail(conversationId: String, messageId: String, toolCallId: String, detail: String)
    case toolEnd(conversationId: String, messageId: String, toolCallId: String, status: ToolStep.Status, durationMs: Int)
    case subagent(conversationId: String, messageId: String, subagent: SubagentInfo)
    /// `agent`/`model`: who answered, for turns an agent ran. `scheduled`: a scheduled task ran it; the gateway notifies
    /// for it (or stays silent) on its own.
    case messageEnd(conversationId: String, messageId: String, durationMs: Int, steps: Int, stopReason: StopReason, agent: AgentID? = nil, model: String? = nil, scheduled: Bool = false)
    case permissionRequest(conversationId: String, requestId: String, title: String, options: [PermissionOption], offer: ToolRuleOffer? = nil)
    case error(conversationId: String?, message: String)
    case context(conversationId: String, context: ContextUsage)
    case notice(conversationId: String, kind: String, text: String, beforeTokens: Int?, afterTokens: Int?)
    /// `conversationId`: the conversation that now holds the alert as a message.
    case notification(title: String, body: String, botId: String?, conversationId: String? = nil)
    /// A notification the gateway just recorded in its history.
    case alert(AlertItem)
    /// A bot needs this device (calendar, position, maps…): `DeviceToolsCenter` runs it.
    case deviceRequest(requestId: String, tool: String, args: [String: JSONValue])
    case pong
}

/// Live channel to the gateway. The chat screen and the voice mode both talk through it.
@MainActor
protocol ChatTransport: AnyObject {
    func send(_ event: ClientEvent) async throws
    /// Each call returns a fresh stream that receives every server event from now on.
    func events() -> AsyncStream<ServerEvent>
}
