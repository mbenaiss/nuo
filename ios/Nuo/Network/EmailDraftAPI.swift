import Foundation

/// The `::email` card's Gmail draft; separate from `NuoAPI` so the demo backend opts in here.
protocol NuoEmailDraftAPI: Sendable {
    /// The draft as Gmail has it now; `NuoError.notFound` once it was sent or deleted.
    func emailDraft(id: String, account: String?) async throws -> EmailDraftPayload
    func saveEmailDraft(id: String, account: String?, update: EmailDraftUpdate) async throws -> EmailDraftPayload
    func sendEmailDraft(id: String, account: String?) async throws
}

extension NuoClient: NuoEmailDraftAPI {
    func emailDraft(id: String, account: String?) async throws -> EmailDraftPayload {
        try await request("GET", Self.draftPath(id, account: account))
    }

    func saveEmailDraft(id: String, account: String?, update: EmailDraftUpdate) async throws -> EmailDraftPayload {
        try await request("PUT", Self.draftPath(id, account: account), body: update)
    }

    func sendEmailDraft(id: String, account: String?) async throws {
        try await send("POST", Self.draftPath(id, account: account, action: "/send"))
    }

    private static func draftPath(_ id: String, account: String?, action: String = "") -> String {
        let segment = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#%"))) ?? id
        var path = "/api/google/drafts/\(segment)\(action)"
        if let account, !account.isEmpty, let value = account.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: ".-_"))) {
            path += "?account=\(value)"
        }
        return path
    }
}
