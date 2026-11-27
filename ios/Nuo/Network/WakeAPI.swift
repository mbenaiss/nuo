import Foundation

/// Webhooks and mail address of a bot; separate from `NuoAPI` so the demo backend opts in here.
protocol NuoWakeAPI: Sendable {
    func botWake(botId: String) async throws -> BotWake
    func createWakeHook(botId: String, name: String) async throws -> CreatedWakeHook
    func revokeWakeHook(botId: String, hookId: String) async throws
}

extension NuoClient: NuoWakeAPI {
    func botWake(botId: String) async throws -> BotWake { try await request("GET", "/api/bots/\(botId)/wake") }

    func createWakeHook(botId: String, name: String) async throws -> CreatedWakeHook {
        struct Body: Encodable { let name: String }
        return try await request("POST", "/api/bots/\(botId)/hooks", body: Body(name: name))
    }

    func revokeWakeHook(botId: String, hookId: String) async throws {
        try await send("DELETE", "/api/bots/\(botId)/hooks/\(hookId)")
    }
}
