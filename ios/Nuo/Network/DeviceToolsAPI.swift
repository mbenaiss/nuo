import Foundation

/// A bot's call that this device runs (docs/protocol.md, "Device tools"), from `POST /api/device/requests/:id/claim`.
struct DeviceRequest: Decodable, Sendable, Equatable {
    let id: String
    let tool: String
    let args: [String: JSONValue]
}

/// What this device lets the bots do; separate from `NuoAPI` so the demo backend opts in here.
protocol NuoDeviceAPI: Sendable {
    func setDeviceCapabilities(platform: String, tools: [String]) async throws
    /// Takes the request before running it; fails once another device took it, so a write never runs twice.
    func claimDeviceRequest(id: String) async throws -> DeviceRequest
    func answerDeviceRequest(id: String, result: Result<JSONValue, DeviceToolError>) async throws
}

extension NuoClient: NuoDeviceAPI {
    func setDeviceCapabilities(platform: String, tools: [String]) async throws {
        struct Body: Encodable { let platform: String; let tools: [String] }
        try await send("PUT", "/api/device/capabilities", body: Body(platform: platform, tools: tools))
    }

    func claimDeviceRequest(id: String) async throws -> DeviceRequest { try await request("POST", "/api/device/requests/\(id)/claim", body: Optional<String>.none) }

    func answerDeviceRequest(id: String, result: Result<JSONValue, DeviceToolError>) async throws {
        struct Body: Encodable { let ok: Bool; let result: JSONValue?; let error: String? }
        let body = switch result {
        case let .success(value): Body(ok: true, result: value, error: nil)
        case let .failure(error): Body(ok: false, result: nil, error: error.message)
        }
        try await send("POST", "/api/device/requests/\(id)/result", body: body)
    }
}
