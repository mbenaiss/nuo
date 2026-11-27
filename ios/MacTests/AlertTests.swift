import Foundation
import Testing

struct AlertTests {
    private func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            guard let date = ISO8601Wire.parse(text) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: text)
            }
            return date
        }
        return decoder
    }

    @Test func theHistoryKeepsAFailedCommandAndTheRunItLeadsTo() throws {
        let alerts = try decoder().decode([AlertItem].self, from: Data("""
        [
          {"id": "alert-api-watch", "title": "⚠️ Lumen API prod", "body": "Échec : 3 erreurs 500 sur /api/training-plan-jobs",
           "botId": "bot-infra", "destination": {"kind": "task", "id": "task-api-watch", "botId": "bot-infra", "runId": "run-20261113-0815"},
           "createdAt": "2026-11-13T08:15:04.000Z"},
          {"id": "alert-colis", "title": "📦 Colis arrivé", "body": "Mondial Relay 48213906 t'attend au relais Pickup.",
           "destination": {"kind": "link", "url": "nuo://data/colis/48213906"},
           "createdAt": "2026-11-12T16:02:00.000Z", "readAt": "2026-11-12T18:30:00.000Z"}
        ]
        """.utf8))
        #expect(alerts[0].readAt == nil)
        #expect(NotificationDestination(alerts[0].destination) == .task(id: "task-api-watch", botId: "bot-infra", runId: "run-20261113-0815"))
        #expect(alerts[1].readAt != nil)
        #expect(NotificationDestination(alerts[1].destination) == .link(URL(string: "nuo://data/colis/48213906")!))
    }

    @Test func anAlertWithNowhereToGoOpensHome() {
        #expect(NotificationDestination(AlertDestination(kind: "home")) == .home)
        #expect(NotificationDestination(AlertDestination(kind: "conversation")) == .home)
    }

    @Test func aCommandFailurePushOpensItsRun() {
        let info: [AnyHashable: Any] = [
            "destination": ["kind": "task", "id": "task-gcp-billing", "botId": "bot-infra", "runId": "run-20261113-0745"],
        ]
        #expect(NotificationDestination(userInfo: info, category: "nuo.answer")
            == .task(id: "task-gcp-billing", botId: "bot-infra", runId: "run-20261113-0745"))
        let legacy: [AnyHashable: Any] = ["taskId": "task-gcp-billing", "botId": "bot-infra", "runId": "run-20261113-0745"]
        #expect(NotificationDestination(userInfo: legacy, category: "nuo.answer")
            == .task(id: "task-gcp-billing", botId: "bot-infra", runId: "run-20261113-0745"))
    }

    @Test func theSocketAnnouncesANewAlert() throws {
        let event = try decoder().decode(ServerEvent.self, from: Data("""
        {"type": "alert", "alert": {"id": "alert-hyrox", "title": "🏃 HYROX Paris", "body": "2 places libérées en Open Men samedi 14h.",
         "botId": "bot-sport", "destination": {"kind": "bot", "id": "bot-sport"}, "createdAt": "2026-11-13T09:40:00.000Z"}}
        """.utf8))
        guard case let .alert(alert) = event else {
            Issue.record("expected alert, got \(event)")
            return
        }
        #expect(alert.id == "alert-hyrox")
        #expect(event.conversationId == nil)
    }

    private func alert(_ id: String, read: Bool = false) -> AlertItem {
        AlertItem(
            id: id, title: id, body: "", destination: AlertDestination(kind: "home"),
            createdAt: Date(timeIntervalSince1970: 1_794_560_000), readAt: read ? Date(timeIntervalSince1970: 1_794_563_600) : nil)
    }

    @Test func deletingTheSelectedAlertSelectsTheNextOneThenTheOneAbove() {
        let list = [alert("alert-hyrox"), alert("alert-api-watch"), alert("alert-colis", read: true), alert("alert-sauvegarde")]
        #expect(list.selection(afterDeleting: ["alert-api-watch"], selected: "alert-api-watch") == "alert-colis")
        #expect(list.selection(afterDeleting: ["alert-colis", "alert-sauvegarde"], selected: "alert-sauvegarde") == "alert-api-watch")
        #expect(list.selection(afterDeleting: ["alert-colis"], selected: "alert-hyrox") == "alert-hyrox")
        #expect(list.selection(afterDeleting: Set(list.map(\.id)), selected: "alert-hyrox") == nil)
        #expect(list.selection(afterDeleting: ["alert-hyrox"], selected: nil) == nil)
    }

    @Test func deletingTheReadAlertsKeepsTheUnreadOnes() {
        let list = [alert("alert-hyrox"), alert("alert-colis", read: true), alert("alert-sauvegarde")]
        #expect(list.unread.map(\.id) == ["alert-hyrox", "alert-sauvegarde"])
    }
}
