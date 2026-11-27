import Foundation

extension NuoClient {
    private func query(_ items: [(String, String?)]) -> String {
        let parts = items.compactMap { name, value -> String? in
            guard let value, !value.isEmpty else { return nil }
            return "\(name)=\(value.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? value)"
        }
        return parts.isEmpty ? "" : "?" + parts.joined(separator: "&")
    }

    private func segment(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? value
    }

    // MARK: Data

    func collections() async throws -> [DataCollection] { try await request("GET", "/api/data/collections") }

    func rows(collection: String, query dataQuery: DataQuery, limit: Int, cursor: String?) async throws -> DataRowsPage {
        var items: [(String, String?)] = [("q", dataQuery.search), ("sort", dataQuery.sort), ("limit", String(limit)), ("cursor", cursor)]
        items += dataQuery.filters.map { ("filter", "\($0.column):\($0.op.rawValue):\($0.value)") }
        return try await request("GET", "/api/data/collections/\(segment(collection))/rows" + query(items))
    }

    func groups(collection: String, by: String, query dataQuery: DataQuery) async throws -> DataGroups {
        var items: [(String, String?)] = [("by", by), ("q", dataQuery.search)]
        items += dataQuery.filters.map { ("filter", "\($0.column):\($0.op.rawValue):\($0.value)") }
        return try await request("GET", "/api/data/collections/\(segment(collection))/groups" + query(items))
    }

    func row(collection: String, id: String) async throws -> DataRowDetail {
        try await request("GET", "/api/data/collections/\(segment(collection))/rows/\(segment(id))")
    }

    func createRow(collection: String, values: [String: JSONValue]) async throws -> DataRow {
        try await request("POST", "/api/data/collections/\(segment(collection))/rows", body: ["values": JSONValue.object(values)])
    }

    func updateRow(collection: String, id: String, values: [String: JSONValue]) async throws -> DataRow {
        try await request("PATCH", "/api/data/collections/\(segment(collection))/rows/\(segment(id))", body: ["values": JSONValue.object(values)])
    }

    func archiveRow(collection: String, id: String, archived: Bool) async throws -> DataRow {
        try await request("POST", "/api/data/collections/\(segment(collection))/rows/\(segment(id))/\(archived ? "archive" : "unarchive")", body: Optional<String>.none)
    }

    func attachFile(collection: String, id: String, column: String, name: String, data: Data, contentType: String) async throws -> DataRow {
        let path = "/api/data/collections/\(segment(collection))/rows/\(segment(id))/files/\(segment(column))" + query([("name", name)])
        var request = try makeRequest("POST", path, body: Optional<String>.none)
        request.httpBody = data
        request.timeoutInterval = 300
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        let (reply, _) = try await perform(request)
        do {
            return try NuoJSON.decoder().decode(DataRow.self, from: reply)
        } catch {
            throw NuoError.decoding(String(describing: error).prefix(160).description)
        }
    }

    func revertChange(id: String) async throws -> DataChange {
        try await request("POST", "/api/data/history/\(segment(id))/revert", body: Optional<String>.none)
    }

    func searchData(_ text: String) async throws -> [DataSearchHit] {
        try await request("GET", "/api/data/search" + query([("q", text)]))
    }

    // MARK: Reminders

    func reminders(scope: ReminderScope, list: String?) async throws -> [Reminder] {
        try await request("GET", "/api/reminders" + query([("scope", scope.rawValue), ("list", list)]))
    }

    func createReminder(_ draft: ReminderDraft) async throws -> Reminder { try await request("POST", "/api/reminders", body: draft) }

    func updateReminder(id: String, patch: [String: JSONValue]) async throws -> Reminder {
        try await request("PATCH", "/api/reminders/\(segment(id))", body: patch)
    }

    func setReminderDone(id: String, done: Bool) async throws -> Reminder {
        try await request("POST", "/api/reminders/\(segment(id))/\(done ? "done" : "undone")", body: Optional<String>.none)
    }

    func snoozeReminder(id: String, until: Date) async throws -> Reminder {
        try await request("POST", "/api/reminders/\(segment(id))/snooze", body: ["until": NuoJSON.formatDate(until)])
    }

    func deleteReminder(id: String) async throws { try await send("DELETE", "/api/reminders/\(segment(id))") }

    // MARK: Areas and projects

    func reminderAreas() async throws -> [ReminderArea] { try await request("GET", "/api/areas") }

    func createArea(title: String, emoji: String?) async throws -> ReminderArea {
        try await request("POST", "/api/areas", body: ["title": JSONValue.string(title), "emoji": emoji.map(JSONValue.string) ?? .null])
    }

    func updateArea(id: String, patch: [String: JSONValue]) async throws -> ReminderArea {
        try await request("PATCH", "/api/areas/\(segment(id))", body: patch)
    }

    func deleteArea(id: String) async throws { try await send("DELETE", "/api/areas/\(segment(id))") }

    func reminderProjects(status: String) async throws -> [ReminderProject] {
        try await request("GET", "/api/projects" + query([("status", status)]))
    }

    func project(id: String) async throws -> ProjectDetail { try await request("GET", "/api/projects/\(segment(id))") }

    func createProject(_ draft: ProjectDraft) async throws -> ReminderProject { try await request("POST", "/api/projects", body: draft) }

    func updateProject(id: String, patch: [String: JSONValue]) async throws -> ReminderProject {
        try await request("PATCH", "/api/projects/\(segment(id))", body: patch)
    }

    func finishProject(id: String, cancel: Bool, keepOpenReminders: Bool) async throws -> ReminderProject {
        try await request("POST", "/api/projects/\(segment(id))/\(cancel ? "cancel" : "done")", body: ["openReminders": keepOpenReminders ? "keep" : "done"])
    }

    func reopenProject(id: String) async throws -> ReminderProject {
        try await request("POST", "/api/projects/\(segment(id))/reopen", body: Optional<String>.none)
    }

    func deleteProject(id: String) async throws { try await send("DELETE", "/api/projects/\(segment(id))") }

    func createHeading(projectId: String, title: String) async throws -> ProjectHeading {
        try await request("POST", "/api/projects/\(segment(projectId))/headings", body: ["title": title])
    }

    func updateHeading(id: String, patch: [String: JSONValue]) async throws -> ProjectHeading {
        try await request("PATCH", "/api/headings/\(segment(id))", body: patch)
    }

    func deleteHeading(id: String) async throws { try await send("DELETE", "/api/headings/\(segment(id))") }

    // MARK: Places

    func places() async throws -> [Place] { try await request("GET", "/api/places") }
    func createPlace(_ draft: PlaceDraft) async throws -> Place { try await request("POST", "/api/places", body: draft) }
    func updatePlace(id: String, patch: [String: JSONValue]) async throws -> Place {
        try await request("PATCH", "/api/places/\(segment(id))", body: patch)
    }
    func deletePlace(id: String) async throws { try await send("DELETE", "/api/places/\(segment(id))") }

    // MARK: Dashboards

    func dashboards() async throws -> [DashboardSummary] { try await request("GET", "/api/dashboards") }
    func dashboard(slug: String) async throws -> Dashboard { try await request("GET", "/api/dashboards/\(segment(slug))") }

    // MARK: Docs

    func docsTree() async throws -> [DocNode] { try await request("GET", "/api/docs/tree") }
    func doc(path: String) async throws -> DocFile { try await request("GET", "/api/docs/file" + query([("path", path)])) }

    func saveDoc(path: String, content: String, baseSha: String?) async throws -> DocSaveResult {
        struct Body: Encodable { let path: String; let content: String; let baseSha: String? }
        return try await request("PUT", "/api/docs/file", body: Body(path: path, content: content, baseSha: baseSha))
    }

    func createDoc(path: String, content: String) async throws -> DocSaveResult {
        try await request("POST", "/api/docs/file", body: ["path": path, "content": content])
    }

    func uploadDocFile(path: String, data: Data, contentType: String) async throws -> DocUploadResult {
        var request = try makeRequest("POST", "/api/docs/upload" + query([("path", path)]), body: Optional<String>.none)
        request.httpBody = data
        request.timeoutInterval = 300
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        let (reply, _) = try await perform(request)
        do {
            return try NuoJSON.decoder().decode(DocUploadResult.self, from: reply)
        } catch {
            throw NuoError.decoding(String(describing: error).prefix(160).description)
        }
    }

    func dropDoc(path: String, ttlMinutes: Int) async throws -> DocDropLink {
        struct Body: Encodable { let path: String; let ttl: Int }
        return try await request("POST", "/api/docs/drop", body: Body(path: path, ttl: ttlMinutes))
    }

    func deleteDoc(path: String) async throws { try await send("DELETE", "/api/docs/file" + query([("path", path)])) }

    func moveDoc(from: String, to: String) async throws -> DocMoveResult {
        try await request("POST", "/api/docs/move", body: ["from": from, "to": to])
    }

    func createDocFolder(path: String) async throws { try await send("POST", "/api/docs/folder", body: ["path": path]) }

    func deleteDocFolder(path: String) async throws { try await send("DELETE", "/api/docs/folder" + query([("path", path)])) }

    func docPins() async throws -> [String] {
        let pins: DocPins = try await request("GET", "/api/docs/pins")
        return pins.paths
    }

    func setDocPins(_ paths: [String]) async throws -> [String] {
        let pins: DocPins = try await request("PUT", "/api/docs/pins", body: DocPins(paths: paths))
        return pins.paths
    }

    func searchDocs(_ text: String) async throws -> [DocSearchHit] {
        try await request("GET", "/api/docs/search" + query([("q", text)]))
    }
}
