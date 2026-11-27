import Foundation

extension [AlertItem] {
    var unread: [AlertItem] { filter { $0.readAt == nil } }

    /// The alert to select once `deleted` are gone: the next one down the list, else the closest one above, so the
    /// Mac keeps a selection while alerts are deleted one after the other with the Delete key.
    func selection(afterDeleting deleted: Set<String>, selected: String?) -> String? {
        guard let selected else { return nil }
        guard deleted.contains(selected) else { return selected }
        guard let index = firstIndex(where: { $0.id == selected }) else { return nil }
        if let below = self[(index + 1)...].first(where: { !deleted.contains($0.id) }) { return below.id }
        return self[..<index].last(where: { !deleted.contains($0.id) })?.id
    }
}
