import CoreGraphics

/// Column widths shared by the slices of a table the chat cut into rows: a `Grid` sizes its columns from its own cells
/// only, so each slice would get columns of its own.
struct TableColumns: Equatable {
    let header: [String]
    /// Widest cell of each column among the header and the rows folded in so far.
    private(set) var folded: [CGFloat]
    private(set) var foldedRows = 0

    init(header: [String], measure: (String, _ isHeader: Bool) -> CGFloat) {
        self.header = header
        folded = header.map { measure($0, true) }
    }

    /// The widths over all `rows`. Rows are measured once; the last one is measured each time, as it grows while an
    /// answer streams.
    mutating func widths(rows: [[String]], measure: (String, _ isHeader: Bool) -> CGFloat) -> [CGFloat] {
        let complete = max(0, rows.count - 1)
        if complete < foldedRows { self = TableColumns(header: header, measure: measure) }
        while foldedRows < complete {
            Self.fold(rows[foldedRows], into: &folded, measure: measure)
            foldedRows += 1
        }
        var result = folded
        if let last = rows.last { Self.fold(last, into: &result, measure: measure) }
        return result
    }

    private static func fold(_ row: [String], into widths: inout [CGFloat], measure: (String, Bool) -> CGFloat) {
        for column in widths.indices where column < row.count {
            widths[column] = max(widths[column], measure(row[column], false))
        }
    }
}
