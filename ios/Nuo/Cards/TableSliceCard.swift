import SwiftUI
#if canImport(UIKit)
import UIKit
private typealias CellFont = UIFont
#else
import AppKit
private typealias CellFont = NSFont
#endif

/// A row's part of a long table: one card across the slices, the header on the first, the same columns in all, and
/// when the table is wider than the screen, one sideways scroll.
struct TableSliceCard: View {
    let slice: TableSlice
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let widths = TableColumnCache.widths(slice, typeSize: typeSize)
        ViewThatFits(in: .horizontal) {
            grid(widths, stretch: true)
            SlicesHorizontalScroll(key: slice.key) { grid(widths, stretch: false) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.card)
        .clipShape(CardSlice(top: slice.isFirst, bottom: slice.isLast))
        .overlay(CardSlice(top: slice.isFirst, bottom: slice.isLast, outline: true).strokeBorder(Color.line, lineWidth: 1))
    }

    private func grid(_ widths: [CGFloat], stretch: Bool) -> some View {
        let header = slice.table.header
        return Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
            if slice.isFirst {
                GridRow {
                    ForEach(header.indices, id: \.self) { column in
                        cell(header[column], width: widths[column], stretch: stretch && column == header.count - 1)
                            .font(.footnote.weight(.semibold)).foregroundStyle(Color.text2)
                    }
                }
            }
            ForEach(slice.rows, id: \.self) { index in
                // Above the first row of a later slice, it is the line under the last row of the slice above.
                Divider().overlay(Color.line).gridCellUnsizedAxes(.horizontal)
                row(slice.table.rows[index], widths: widths, stretch: stretch)
            }
        }
        .fixedSize(horizontal: !stretch, vertical: false)
    }

    private func row(_ cells: [String], widths: [CGFloat], stretch: Bool) -> some View {
        GridRow {
            ForEach(widths.indices, id: \.self) { column in
                cell(column < cells.count ? cells[column] : "", width: widths[column], stretch: stretch && column == widths.count - 1)
                    .font(.subheadline).foregroundStyle(Color.ink)
            }
        }
    }

    private func cell(_ text: String, width: CGFloat, stretch: Bool) -> some View {
        Text(inlineMarkdown(text))
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.xs)
            .frame(minWidth: width, maxWidth: stretch ? .infinity : width, alignment: .leading)
    }
}

/// Column widths of the tables the chat cut into rows, measured once per table and text size.
@MainActor
private enum TableColumnCache {
    private static var entries: [String: TableColumns] = [:]
    /// Tables of the conversations read lately; past it the cache starts over.
    private static let capacity = 64

    static func widths(_ slice: TableSlice, typeSize: DynamicTypeSize) -> [CGFloat] {
        let key = "\(slice.key)#\(typeSize)"
        let measure = TableCellWidth(typeSize: typeSize)
        var columns = entries[key].flatMap { $0.header == slice.table.header ? $0 : nil }
            ?? TableColumns(header: slice.table.header, measure: measure.callAsFunction)
        let widths = columns.widths(rows: slice.table.rows, measure: measure.callAsFunction)
        if entries[key] == nil, entries.count >= capacity { entries.removeAll() }
        entries[key] = columns
        return widths
    }
}

/// Width of a cell, padding included, in the fonts `TableSliceCard` draws it with.
private struct TableCellWidth {
    private let header: CellFont
    private let body: CellFont
    private let code: CellFont

    init(typeSize: DynamicTypeSize) {
        #if canImport(UIKit)
        let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(typeSize))
        func size(_ style: UIFont.TextStyle) -> CGFloat { UIFont.preferredFont(forTextStyle: style, compatibleWith: traits).pointSize }
        #else
        func size(_ style: NSFont.TextStyle) -> CGFloat { NSFont.preferredFont(forTextStyle: style).pointSize }
        #endif
        header = .systemFont(ofSize: size(.footnote), weight: .semibold)
        body = .systemFont(ofSize: size(.subheadline))
        code = .monospacedSystemFont(ofSize: size(.callout), weight: .regular)
    }

    func callAsFunction(_ text: String, isHeader: Bool) -> CGFloat {
        let markdown = inlineMarkdown(text)
        let string = NSMutableAttributedString()
        for run in markdown.runs {
            let intent = run.inlinePresentationIntent ?? []
            let font = intent.contains(.code) ? code
                : styled(isHeader ? header : body, bold: intent.contains(.stronglyEmphasized), italic: intent.contains(.emphasized))
            string.append(NSAttributedString(string: String(markdown[run.range].characters), attributes: [.font: font]))
        }
        // A point to spare: the cell's padding takes a rounding difference with SwiftUI's own layout.
        return ceil(string.size().width) + 2 * Spacing.sm + 1
    }

    private func styled(_ font: CellFont, bold: Bool, italic: Bool) -> CellFont {
        var result = bold ? CellFont.systemFont(ofSize: font.pointSize, weight: .bold) : font
        guard italic else { return result }
        #if canImport(UIKit)
        if let descriptor = result.fontDescriptor.withSymbolicTraits(result.fontDescriptor.symbolicTraits.union(.traitItalic)) {
            result = UIFont(descriptor: descriptor, size: font.pointSize)
        }
        #else
        let descriptor = result.fontDescriptor.withSymbolicTraits(result.fontDescriptor.symbolicTraits.union(.italic))
        result = NSFont(descriptor: descriptor, size: font.pointSize) ?? result
        #endif
        return result
    }
}
