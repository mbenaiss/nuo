#if os(iOS)
import AppIntents
import SwiftUI
import WidgetKit

/// Circle of a reminder row: checks it off on the gateway, then redraws the widgets.
struct CompleteReminderIntent: AppIntent {
    static let title: LocalizedStringResource = "Complete reminder"
    static let isDiscoverable = false

    @Parameter(title: "Reminder")
    var reminderId: String

    init() {}

    init(reminderId: String) {
        self.reminderId = reminderId
    }

    func perform() async throws -> some IntentResult {
        RemindersLoader.markDone(reminderId)
        try? await WidgetGateway.current()?.setReminderDone(id: reminderId, done: true)
        WidgetCenter.shared.reloadTimelines(ofKind: AppIdentity.scoped("reminders"))
        WidgetCenter.shared.reloadTimelines(ofKind: AppIdentity.scoped("reminders.lock"))
        return .result()
    }
}

struct RemindersWidgetView: View {
    let family: WidgetFamily
    let entry: RemindersEntry

    var body: some View {
        let snapshot = entry.snapshot
        if snapshot.status == .signedOut {
            WidgetSignedOutView(compact: family == .systemSmall)
        } else {
            Group {
                switch family {
                case .systemSmall: small
                case .systemMedium: medium
                case .systemExtraLarge: extraLarge
                default: large
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .widgetURL(URL(string: "nuo://reminders"))
        }
    }

    private var snapshot: WidgetRemindersSnapshot { entry.snapshot }
    private var date: Date { entry.date }
    private var scope: ReminderWidgetScope { entry.scope }

    private var small: some View {
        VStack(alignment: .leading, spacing: 8) {
            ReminderCountHeader(snapshot: snapshot, date: date, compact: true)
            let items = snapshot.visible(at: date, limit: 3, scope: scope)
            ForEach(items) { item in
                ReminderWidgetRow(item: item, date: date, compact: true)
            }
            if items.isEmpty { ReminderAllDone(compact: true) }
            Spacer(minLength: 0)
        }
    }

    private var medium: some View {
        HStack(alignment: .top, spacing: 14) {
            ReminderCountHeader(snapshot: snapshot, date: date, compact: false)
                .frame(width: 64, alignment: .leading)
            VStack(alignment: .leading, spacing: 8) {
                let items = snapshot.visible(at: date, limit: 4, scope: scope)
                ForEach(items) { item in
                    ReminderWidgetRow(item: item, date: date, compact: false)
                }
                if items.isEmpty { ReminderAllDone(compact: false) }
                Spacer(minLength: 0)
            }
        }
    }

    private var large: some View {
        let overdue = snapshot.overdue(at: date)
        let today = snapshot.today(at: date).filter { item in !overdue.contains(item) }
        let upcoming = snapshot.upcoming(at: date, scope: scope)
        var budget = 9
        func take(_ items: [ReminderWireItem]) -> [ReminderWireItem] {
            let shown = Array(items.prefix(max(budget, 0)))
            budget -= shown.count + (shown.isEmpty ? 0 : 1)
            return shown
        }
        let sections = [(String(localized: "Overdue"), take(overdue), WPalette.bad), (String(localized: "Today"), take(today), WPalette.accent), (String(localized: "Upcoming"), take(upcoming), WPalette.text3)]
        return VStack(alignment: .leading, spacing: 10) {
            ReminderTitleBar(snapshot: snapshot, date: date)
            if sections.allSatisfy({ $0.1.isEmpty }) { ReminderAllDone(compact: false) }
            ForEach(sections.filter { !$0.1.isEmpty }, id: \.0) { title, items, tint in
                ReminderSection(title: title, tint: tint, items: items, date: date)
            }
            Spacer(minLength: 0)
        }
    }

    private var extraLarge: some View {
        let today = snapshot.today(at: date)
        // With today's alone, the right column carries on today's list instead of staying empty.
        let (right, rightTitle, rightTint) = scope == .today
            ? (Array(today.dropFirst(9).prefix(9)), String(localized: "Today (continued)"), WPalette.accent)
            : (Array(snapshot.upcoming(at: date, scope: scope).prefix(9)), String(localized: "Upcoming"), WPalette.text3)
        return VStack(alignment: .leading, spacing: 12) {
            ReminderTitleBar(snapshot: snapshot, date: date)
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    if today.isEmpty { ReminderAllDone(compact: false) }
                    if !today.isEmpty { ReminderSection(title: String(localized: "Today"), tint: WPalette.accent, items: Array(today.prefix(9)), date: date) }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                VStack(alignment: .leading, spacing: 8) {
                    if !right.isEmpty || scope == .todayAndUpcoming {
                        ReminderSection(title: rightTitle, tint: rightTint, items: right, date: date)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            Spacer(minLength: 0)
        }
    }
}

private struct ReminderCountHeader: View {
    let snapshot: WidgetRemindersSnapshot
    let date: Date
    let compact: Bool

    var body: some View {
        let count = snapshot.today(at: date).count
        let overdue = snapshot.overdue(at: date).count
        VStack(alignment: .leading, spacing: 2) {
            Group {
                if compact {
                    HStack(spacing: 4) {
                        Image(systemName: "checklist").font(.caption2.weight(.bold))
                        Text(count > 0 ? String(localized: "TODAY · \(count)") : String(localized: "TODAY")).font(.caption2.weight(.bold)).tracking(0.5)
                        if snapshot.status == .offline { Image(systemName: "wifi.slash").font(.caption2) }
                    }
                } else {
                    Image(systemName: snapshot.status == .offline ? "wifi.slash" : "checklist").font(.footnote.weight(.bold))
                    Text("TODAY").font(.caption2.weight(.bold)).lineLimit(1).minimumScaleFactor(0.7)
                }
            }
            .foregroundStyle(WPalette.accent)
            if !compact {
                Text("\(count)")
                    .font(.system(.largeTitle, design: .rounded).weight(.semibold).monospacedDigit())
                    .foregroundStyle(WPalette.ink)
            }
            if !compact, overdue > 0 {
                Text("\(overdue) overdue").font(.caption2.weight(.semibold)).foregroundStyle(WPalette.bad)
            }
        }
    }
}

private struct ReminderTitleBar: View {
    let snapshot: WidgetRemindersSnapshot
    let date: Date

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "checklist").font(.subheadline.weight(.bold)).foregroundStyle(WPalette.accent)
            Text("Reminders").font(.headline).foregroundStyle(WPalette.ink)
            Spacer(minLength: 0)
            if snapshot.status == .offline { Image(systemName: "wifi.slash").font(.caption2).foregroundStyle(WPalette.text3) }
            Text(ReminderWidgetText.count(snapshot.today(at: date).count))
                .font(.caption.weight(.semibold))
                .foregroundStyle(WPalette.text2)
        }
    }
}

private struct ReminderSection: View {
    let title: String
    let tint: Color
    let items: [ReminderWireItem]
    let date: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title.uppercased()).font(.caption2.weight(.bold)).tracking(0.5).foregroundStyle(tint)
            ForEach(items) { item in ReminderWidgetRow(item: item, date: date, compact: false) }
        }
    }
}

struct ReminderWidgetRow: View {
    let item: ReminderWireItem
    let date: Date
    let compact: Bool

    var body: some View {
        let overdue = (item.effectiveDate ?? .distantFuture) < date
        HStack(alignment: .top, spacing: 8) {
            Button(intent: CompleteReminderIntent(reminderId: item.id)) {
                Image(systemName: "circle")
                    .font((compact ? Font.footnote : .subheadline).weight(.semibold))
                    .foregroundStyle(item.priority >= 2 ? WPalette.accent : WPalette.text3)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Complete \(item.title)")
            Link(destination: item.link) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title)
                        .font((compact ? Font.caption : .footnote).weight(.semibold))
                        .foregroundStyle(WPalette.ink)
                        .lineLimit(compact ? 2 : 1)
                        .multilineTextAlignment(.leading)
                    if !compact, let due = ReminderWidgetText.due(item, now: date) {
                        HStack(spacing: 3) {
                            if item.place != nil { Image(systemName: "location.fill") }
                            Text(due)
                            if let filed = item.filedUnder { Text("· \(filed)").foregroundStyle(WPalette.text3) }
                        }
                        .font(.caption2)
                        .foregroundStyle(overdue ? WPalette.bad : WPalette.text2)
                        .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct ReminderAllDone: View {
    let compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            WidgetMascot(state: .done, size: compact ? 40 : 48)
            Text("All done").font(compact ? .footnote.weight(.semibold) : .subheadline.weight(.semibold)).foregroundStyle(WPalette.ink)
            if !compact { Text("No reminders for today.").font(.caption2).foregroundStyle(WPalette.text2) }
        }
    }
}
#endif
