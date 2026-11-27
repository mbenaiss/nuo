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

    struct VoiceSettings: Codable, Hashable, Sendable {
        var voiceId: String?
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
    let createdAt: Date

    enum Role: String, Codable, Sendable { case user, assistant }

    var isTaskPrompt: Bool { role == .user && task != nil }
}

struct MessageTask: Codable, Hashable, Sendable {
    let id: String
    let title: String
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
    /// `steer`: « Envoyer maintenant » during a running turn.
    case prompt(conversationId: String, text: String, attachments: [Attachment] = [], agent: AgentID? = nil, model: String? = nil, effort: String? = nil, voice: Bool = false, steer: Bool = false, folder: PromptFolder? = nil)
    case cancel(conversationId: String)
    case permission(requestId: String, optionId: String)
    /// Asks for a fresh `turns.snapshot`.
    case turnsSync
    /// The app came to the foreground or left it: while one device is in front, the others get no reply push.
    case presence(active: Bool)
    case ping
}

enum ServerEvent: Sendable {
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
    case permissionRequest(conversationId: String, requestId: String, title: String, options: [PermissionOption])
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
