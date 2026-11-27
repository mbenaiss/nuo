import SwiftUI

/// 4-point spacing scale shared by cards, dashboards and docs.
enum Spacing {
    static let xxs: CGFloat = 4
    static let xs: CGFloat = 8
    static let sm: CGFloat = 12
    static let md: CGFloat = 16
    static let lg: CGFloat = 20
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
    /// Horizontal margin between the screen edge and its content on iPhone.
    static let gutter = md
}

enum Radius {
    /// Thumbnails, inline tiles inside a card.
    static let xs: CGFloat = 8
    static let sm: CGFloat = 12
    static let md: CGFloat = 16
    static let lg: CGFloat = 22
    static let xl: CGFloat = 28
}

/// Insets of card surfaces and of the rows they hold.
enum CardMetrics {
    static let padding = Spacing.md
    static let compactPadding = Spacing.sm
    /// Horizontal inset of list rows inside a card: same as the card padding so titles and rows share one edge.
    static let rowInset = Spacing.md
    static let rowVertical = Spacing.sm
    /// Gap between a card's header and its body.
    static let headerGap = Spacing.sm
    /// Prose in a chat message is inset by this much; text-like cards (code, table) align on it too.
    static let textInset = Spacing.xxs
    /// Width of a card in a horizontal carousel.
    static let carouselWidth: CGFloat = 280
    /// Inner tiles (metrics, flight facts, product macros).
    static let tileRadius = Radius.sm
}

enum DashboardMetrics {
    static let gutter = Spacing.sm
    static let sectionGap = Spacing.md
    /// A number tile needs this much to show "180 150 €" without shrinking.
    static let tileMinWidth: CGFloat = 150
    /// Charts and tables below this width get a single column.
    static let blockMinWidth: CGFloat = 340
    static let chartHeight: CGFloat = 200
    static let donutSize: CGFloat = 140
    static let donutMaxSize: CGFloat = 240
}

enum TextMetrics {
    /// Extra leading of body prose (chat answers, docs).
    static let lineSpacing: CGFloat = 3
    /// Vertical gap between items of a bullet or numbered list.
    static let listItemGap: CGFloat = 6
    /// Indent per nesting level of a list.
    static let listIndent = Spacing.lg
    /// A bullet dot is centred on the x-height: this far above the baseline at body size.
    static let bulletLift: CGFloat = 4
    static let bulletSize: CGFloat = 5
    static let quoteBarWidth: CGFloat = 3
}

/// Agenda, time grids and the day strip.
enum CalendarMetrics {
    static let hourHeight: CGFloat = 56
    /// Mac week grid: more hours on screen.
    static let compactHourHeight: CGFloat = 48
    static let timeColumnWidth: CGFloat = 46
    static let colorBarWidth: CGFloat = 4
    static let eventRadius: CGFloat = 6
    /// Gap between side-by-side events and around an event in its column.
    static let eventGap: CGFloat = 2
    static let minEventHeight: CGFloat = 20
    /// Below this width (a week on a phone) an event shows only its title, small and wrapped.
    static let narrowEventWidth: CGFloat = 64
    static let narrowEventFont: CGFloat = 10
    static let firstVisibleHour = 8
    /// Share of a day column a reminder pill may cover, so the event under it stays readable.
    static let reminderPillShare: CGFloat = 0.6
    static let allDayRowHeight: CGFloat = 24
    static let allDayMaxRows = 3
    static let dayHeaderHeight: CGFloat = 44
    static let tickerCellWidth: CGFloat = 44
    static let tickerCellHeight: CGFloat = 58
    static let busyDot: CGFloat = 5
    static let nowLineWidth: CGFloat = 1.5
    static let nowDot: CGFloat = 8
    static let snapMinutes = 15
    static let defaultDurationMinutes = 60
    static let miniMonthCell: CGFloat = 30
    /// Month view on iPhone and iPad: a day of the grid, and how wide the grid may get beside the day list.
    static let monthGridCell: CGFloat = 44
    static let monthGridMaxWidth: CGFloat = 460
    static let monthCellMinHeight: CGFloat = 96
    static let monthMaxChips = 4
    static let hatchSpacing: CGFloat = 6
    /// Agenda row: leading column holding the start and end times.
    static let timeLabelWidth: CGFloat = 52
    static let mapPreviewHeight: CGFloat = 150
    static let qrSize: CGFloat = 220
}

/// Sizes of the mascot.
enum MascotMetrics {
    /// Running-turn line above the composer.
    static let turnStatus: CGFloat = 30
    /// Mac menu bar panel header.
    static let menuBar: CGFloat = 28
    /// Beside a one-line empty message inside a card.
    static let inline: CGFloat = 44
    static let emptyState: CGFloat = 88
    /// Welcome, pairing and unreachable gateway screens.
    static let hero: CGFloat = 104
}

extension Font {
    /// Title of a dashboard block or card section.
    static let sectionTitle = Font.subheadline.weight(.semibold)
}

struct SectionTitle<Trailing: View>: View {
    let text: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
            Text(text).font(.sectionTitle).foregroundStyle(Color.ink).lineLimit(2)
            Spacer(minLength: Spacing.xs)
            trailing
        }
        .accessibilityAddTraits(.isHeader)
    }
}

extension SectionTitle where Trailing == EmptyView {
    init(text: String) {
        self.init(text: text) { EmptyView() }
    }
}
