import SwiftUI

/// Groups of a collection as a table: count and money totals per group, the overall total last.
/// Double-click (or Return) opens the rows of a group.
struct CollectionGroupsTable: View {
    let grouping: DataGrouping
    let groups: DataGroups?
    let summed: [DataColumn]
    /// The groups could not be fetched.
    var error: String?
    var retry: () -> Void = {}
    let open: (DataGroup) -> Void
    @State private var selection: Set<DataGroup.ID> = []

    private struct Line: Identifiable {
        let id: String
        let label: String
        let count: Int
        let sums: [String: Double]
        let group: DataGroup?
    }

    private var lines: [Line] {
        guard let groups else { return [] }
        return groups.groups.map { Line(id: $0.id, label: grouping.label($0), count: $0.count, sums: $0.sums, group: $0) }
            + [Line(id: "\u{0}total", label: String(localized: "Total"), count: groups.total.count, sums: groups.total.sums, group: nil)]
    }

    var body: some View {
        Table(lines, selection: $selection) {
            TableColumn(grouping.title) { line in
                Text(line.label).fontWeight(line.group == nil ? .semibold : .regular)
            }
            .width(min: 160, ideal: 220)
            TableColumn("Items") { line in
                Text("\(line.count)").monospacedDigit().fontWeight(line.group == nil ? .semibold : .regular)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 70, ideal: 90, max: 120)
            TableColumnForEach(summed) { column in
                TableColumn(column.label) { line in
                    Text(ValueFormat.money(line.sums[column.name] ?? 0)).monospacedDigit()
                        .fontWeight(line.group == nil ? .semibold : .regular)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(min: 100, ideal: 130)
            }
        }
        .contextMenu(forSelectionType: Line.ID.self) { ids in
            if let line = lines.first(where: { ids.contains($0.id) }), let group = line.group {
                Button("Show \(line.count) items") { open(group) }
            }
        } primaryAction: { ids in
            if let group = lines.first(where: { ids.contains($0.id) })?.group { open(group) }
        }
        .overlay {
            if groups == nil, let error {
                VStack(spacing: 12) {
                    WorkspaceEmptyState(symbol: "icloud.slash", title: String(localized: "Groups unavailable"), message: error)
                    Button("Try again", action: retry)
                }
            } else if groups == nil {
                ProgressView()
            } else if groups?.groups.isEmpty == true {
                ContentUnavailableView("No items", systemImage: "square.stack.3d.up")
            }
        }
    }
}
