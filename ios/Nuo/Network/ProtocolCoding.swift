import Foundation

// Wire coding for the types in Protocol.swift (docs/protocol.md).

enum NuoJSON {
    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            if let date = parseDate(text) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO-8601 date: \(text)")
        }
        return decoder
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(formatDate(date))
        }
        return encoder
    }

    static func parseDate(_ text: String) -> Date? { ISO8601Wire.parse(text) }

    static func formatDate(_ date: Date) -> String { ISO8601Wire.format(date) }
}

extension ClientEvent: Encodable {
    private enum Keys: String, CodingKey {
        case type, conversationId, text, attachments, agent, model, effort, voice, steer, folder, goal, requestId, optionId, rule, active
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case let .prompt(conversationId, text, attachments, agent, model, effort, voice, steer, folder, goal):
            try c.encode("prompt", forKey: .type)
            try c.encode(conversationId, forKey: .conversationId)
            try c.encode(text, forKey: .text)
            if !attachments.isEmpty { try c.encode(attachments, forKey: .attachments) }
            try c.encodeIfPresent(agent, forKey: .agent)
            try c.encodeIfPresent(model, forKey: .model)
            try c.encodeIfPresent(effort, forKey: .effort)
            if voice { try c.encode(true, forKey: .voice) }
            if steer { try c.encode(true, forKey: .steer) }
            try c.encodeIfPresent(folder, forKey: .folder)
            if goal { try c.encode(true, forKey: .goal) }
        case let .cancel(conversationId):
            try c.encode("cancel", forKey: .type)
            try c.encode(conversationId, forKey: .conversationId)
        case let .permission(requestId, optionId, rule):
            try c.encode("permission", forKey: .type)
            try c.encode(requestId, forKey: .requestId)
            try c.encode(optionId, forKey: .optionId)
            try c.encodeIfPresent(rule, forKey: .rule)
        case .turnsSync:
            try c.encode("turns.sync", forKey: .type)
        case let .presence(active):
            try c.encode("presence", forKey: .type)
            try c.encode(active, forKey: .active)
        case .ping:
            try c.encode("ping", forKey: .type)
        }
    }
}

extension ServerEvent: Decodable {
    private enum Keys: String, CodingKey {
        case type, conversationId, messageId, at, text, toolCallId, title, kind, detail, status, durationMs, steps
        case stopReason, requestId, options, message, body, botId, context, beforeTokens, afterTokens, phase, turns, agent, model, scheduled
        case tool, args, subagent, alert, rules
    }

    struct UnknownType: Error { let type: String }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let type = try c.decode(String.self, forKey: .type)
        func conv() throws -> String { try c.decode(String.self, forKey: .conversationId) }
        func mid() throws -> String { try c.decode(String.self, forKey: .messageId) }
        switch type {
        case "message.user":
            self = .messageUser(conversationId: try conv(), message: try c.decode(Message.self, forKey: .message))
        case "message.start":
            self = .messageStart(
                conversationId: try conv(), messageId: try mid(), at: try c.decodeIfPresent(Date.self, forKey: .at) ?? Date(),
                botId: try c.decodeIfPresent(String.self, forKey: .botId),
                phase: try? c.decodeIfPresent(TurnPhase.self, forKey: .phase))
        case "turn.phase":
            guard let phase = try? c.decode(TurnPhase.self, forKey: .phase) else { throw UnknownType(type: type) }
            self = .turnPhase(conversationId: try conv(), messageId: try mid(), phase: phase)
        case "turns.snapshot":
            self = .turnsSnapshot(try c.decode([TurnSnapshot].self, forKey: .turns))
        case "message.delta":
            self = .messageDelta(conversationId: try conv(), messageId: try mid(), text: try c.decode(String.self, forKey: .text))
        case "thought.delta":
            self = .thoughtDelta(conversationId: try conv(), messageId: try mid(), text: try c.decode(String.self, forKey: .text))
        case "tool.start":
            self = .toolStart(
                conversationId: try conv(), messageId: try mid(),
                toolCallId: try c.decode(String.self, forKey: .toolCallId),
                title: try c.decode(String.self, forKey: .title),
                kind: try c.decodeIfPresent(String.self, forKey: .kind))
        case "tool.detail":
            self = .toolDetail(
                conversationId: try conv(), messageId: try mid(),
                toolCallId: try c.decode(String.self, forKey: .toolCallId),
                detail: try c.decode(String.self, forKey: .detail))
        case "tool.end":
            self = .toolEnd(
                conversationId: try conv(), messageId: try mid(),
                toolCallId: try c.decode(String.self, forKey: .toolCallId),
                status: try c.decode(ToolStep.Status.self, forKey: .status),
                durationMs: try c.decodeIfPresent(Int.self, forKey: .durationMs) ?? 0)
        case "subagent":
            self = .subagent(conversationId: try conv(), messageId: try mid(), subagent: try c.decode(SubagentInfo.self, forKey: .subagent))
        case "message.end":
            self = .messageEnd(
                conversationId: try conv(), messageId: try mid(),
                durationMs: try c.decodeIfPresent(Int.self, forKey: .durationMs) ?? 0,
                steps: try c.decodeIfPresent(Int.self, forKey: .steps) ?? 0,
                stopReason: try c.decodeIfPresent(StopReason.self, forKey: .stopReason) ?? .endTurn,
                agent: try c.decodeIfPresent(AgentID.self, forKey: .agent),
                model: try c.decodeIfPresent(String.self, forKey: .model),
                scheduled: try c.decodeIfPresent(Bool.self, forKey: .scheduled) ?? false)
        case "permission.request":
            self = .permissionRequest(
                conversationId: try conv(),
                requestId: try c.decode(String.self, forKey: .requestId),
                title: try c.decode(String.self, forKey: .title),
                options: try c.decode([PermissionOption].self, forKey: .options),
                offer: ToolRuleOffer(
                    tool: try c.decodeIfPresent(String.self, forKey: .tool),
                    rules: (try? c.decodeIfPresent([String].self, forKey: .rules))?.compactMap(ToolRule.init(rawValue:))))
        case "error":
            self = .error(conversationId: try c.decodeIfPresent(String.self, forKey: .conversationId), message: try c.decode(String.self, forKey: .message))
        case "context":
            self = .context(conversationId: try conv(), context: try c.decode(ContextUsage.self, forKey: .context))
        case "notice":
            self = .notice(
                conversationId: try conv(),
                kind: try c.decodeIfPresent(String.self, forKey: .kind) ?? "info",
                text: try c.decodeIfPresent(String.self, forKey: .text) ?? "",
                beforeTokens: try c.decodeIfPresent(Int.self, forKey: .beforeTokens),
                afterTokens: try c.decodeIfPresent(Int.self, forKey: .afterTokens))
        case "notification":
            self = .notification(
                title: try c.decode(String.self, forKey: .title),
                body: try c.decodeIfPresent(String.self, forKey: .body) ?? "",
                botId: try c.decodeIfPresent(String.self, forKey: .botId),
                conversationId: try c.decodeIfPresent(String.self, forKey: .conversationId))
        case "alert":
            self = .alert(try c.decode(AlertItem.self, forKey: .alert))
        case "device.request":
            self = .deviceRequest(
                requestId: try c.decode(String.self, forKey: .requestId),
                tool: try c.decode(String.self, forKey: .tool),
                args: try c.decodeIfPresent([String: JSONValue].self, forKey: .args) ?? [:])
        case "pong":
            self = .pong
        default:
            throw UnknownType(type: type)
        }
    }

    var conversationId: String? {
        switch self {
        case let .messageUser(id, _), let .messageStart(id, _, _, _, _), let .turnPhase(id, _, _), let .messageDelta(id, _, _), let .thoughtDelta(id, _, _),
             let .toolStart(id, _, _, _, _), let .toolDetail(id, _, _, _), let .toolEnd(id, _, _, _, _), let .messageEnd(id, _, _, _, _, _, _, _), let .subagent(id, _, _),
             let .permissionRequest(id, _, _, _, _), let .context(id, _), let .notice(id, _, _, _, _):
            id
        case let .error(id, _), let .notification(_, _, _, id):
            id
        case .pong, .turnsSnapshot, .deviceRequest, .alert:
            nil
        }
    }
}
