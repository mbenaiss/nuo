import Foundation

/// What the pending local reminder notifications should become, decided from identifiers rather than categories:
/// the category name is shared with the server and may differ in requests scheduled by an older version.
struct ReminderPendingPlan: Equatable {
    struct Entry: Equatable {
        let identifier: String
        let fire: Date?
        let title: String
    }

    static let prefix = "reminder-"
    static let locationPrefix = "reminder-loc-"

    let stale: [String]
    let toSchedule: [String]

    static func isTimeReminder(_ identifier: String) -> Bool {
        identifier.hasPrefix(prefix) && !identifier.hasPrefix(locationPrefix)
    }

    static func make(pending: [Entry], wanted: [Entry]) -> ReminderPendingPlan {
        let wantedById = Dictionary(wanted.map { ($0.identifier, $0) }, uniquingKeysWith: { first, _ in first })
        var current: Set<String> = []
        var stale: [String] = []
        for request in pending where isTimeReminder(request.identifier) {
            if let entry = wantedById[request.identifier], let fire = request.fire, let due = entry.fire,
               abs(fire.timeIntervalSince(due)) < 60, request.title == entry.title {
                current.insert(request.identifier)
            } else {
                stale.append(request.identifier)
            }
        }
        return ReminderPendingPlan(stale: stale, toSchedule: wanted.map(\.identifier).filter { !current.contains($0) })
    }
}
