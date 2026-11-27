import Foundation

/// A way to group a collection: a column, by year or month for a date.
struct DataGrouping: Hashable, Identifiable, Sendable {
    enum Unit: String, Sendable { case year, month }

    let column: DataColumn
    let unit: Unit?

    var id: String { by }
    /// The gateway's `by` parameter.
    var by: String { unit.map { "\(column.name):\($0.rawValue)" } ?? column.name }

    var title: String {
        switch unit {
        case .year: String(localized: "\(column.label) · year")
        case .month: String(localized: "\(column.label) · month")
        case nil: column.label
        }
    }

    static func options(_ collection: DataCollection?) -> [DataGrouping] {
        (collection?.visibleColumns ?? []).filter { !$0.isComputed || [.date, .datetime].contains($0.type) }.flatMap { column -> [DataGrouping] in
            switch column.type {
            case .date, .datetime: [DataGrouping(column: column, unit: .year), DataGrouping(column: column, unit: .month)]
            case .select, .bool, .ref: [DataGrouping(column: column, unit: nil)]
            default: []
            }
        }
    }

    static func find(_ by: String?, in collection: DataCollection?) -> DataGrouping? {
        options(collection).first { $0.by == by }
    }

    /// Money columns to total, the list's figure first.
    static func summed(_ collection: DataCollection?) -> [DataColumn] {
        let money = (collection?.visibleColumns ?? []).filter { $0.type == .money }
        let first = RowLayout(collection).trailing.flatMap { lead in money.first { $0 == lead } }
        return (first.map { [$0] } ?? []) + money.filter { $0 != first }
    }

    func label(_ group: DataGroup) -> String {
        if group.key.isNull { return String(localized: "No \(column.label.lowercased())") }
        switch unit {
        case .year: return group.key.string ?? "—"
        case .month:
            guard let text = group.key.string, let date = ValueFormat.parseDate(text + "-01") else { return group.key.string ?? "—" }
            return date.formatted(Date.FormatStyle(locale: ValueFormat.locale).month(.wide).year()).capitalized(with: ValueFormat.locale)
        case nil: return ValueFormat.text(group.key, column: column, refTitle: group.label)
        }
    }

    /// The filters that narrow the rows to one group.
    func filters(_ group: DataGroup) -> [DataFilter] {
        guard let key = group.key.string, !group.key.isNull else { return [DataFilter(column: column.name, op: .empty, value: "")] }
        if column.type == .bool { return [DataFilter(column: column.name, op: .eq, value: group.key.bool == true ? "1" : "0")] }
        guard let unit else { return [DataFilter(column: column.name, op: .eq, value: key)] }
        // Dates are ISO text: "2026" <= "2026-07-31" < "2027", the same for "2026-07" and "2026-08".
        return [DataFilter(column: column.name, op: .gte, value: key), DataFilter(column: column.name, op: .lt, value: Self.next(key, unit))]
    }

    private static func next(_ key: String, _ unit: Unit) -> String {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        switch unit {
        case .year: return String(format: "%04d", (parts.first ?? 0) + 1)
        case .month:
            let (year, month) = (parts.first ?? 0, parts.count > 1 ? parts[1] : 1)
            return month == 12 ? String(format: "%04d-01", year + 1) : String(format: "%04d-%02d", year, month + 1)
        }
    }
}
