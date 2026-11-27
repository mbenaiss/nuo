import SwiftUI

/// Wording for command tasks (shell commands the gateway runs on its machine, without a bot).
enum CommandText {
    static var notifyOptions: [(value: String, label: String, symbol: String)] { [
        ("failure", String(localized: "On failure"), "exclamationmark.triangle"),
        ("always", String(localized: "Always"), "bell"),
        ("never", String(localized: "Never"), "bell.slash"),
    ] }

    static func notifyLabel(_ value: String?) -> String {
        notifyOptions.first { $0.value == (value ?? "failure") }?.label ?? String(localized: "On failure")
    }

    static func notifyHint(_ value: String?) -> String {
        switch value ?? "failure" {
        case "always": String(localized: "A notification on every run, with the end of the output.")
        case "never": String(localized: "No notification: the script sends its own alerts.")
        default: String(localized: "One notification per outage, then one when it works again.")
        }
    }

    /// "45 s", "10 min", "1 h 30".
    static func duration(seconds: Int) -> String {
        if seconds < 60 { return "\(seconds) s" }
        if seconds < 3600 { return seconds % 60 == 0 ? "\(seconds / 60) min" : "\(seconds / 60) min \(seconds % 60) s" }
        let minutes = (seconds % 3600) / 60
        return minutes == 0 ? "\(seconds / 3600) h" : "\(seconds / 3600) h \(String(format: "%02d", minutes))"
    }

    /// "820 ms", "2.4 s", "1 min 05".
    static func runDuration(ms: Int) -> String {
        if ms < 1000 { return "\(ms) ms" }
        if ms < 60_000 { return "\((Double(ms) / 1000).formatted(.number.precision(.fractionLength(1)).locale(.current))) s" }
        let seconds = ms / 1000
        return "\(seconds / 60) min \(String(format: "%02d", seconds % 60))"
    }
}

struct CommandGlyph: View {
    var size: CGFloat = 40

    var body: some View {
        Image(systemName: "terminal")
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(Color.onInk)
            .frame(width: size, height: size)
            .background(Color.inkFill, in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// One run of a command task: status, exit code, duration and, when expanded, the tail of its output.
struct CommandRunRow: View {
    let run: TaskRun
    @State private var expanded: Bool

    init(run: TaskRun, expanded: Bool = false) {
        self.run = run
        _expanded = State(initialValue: expanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.snappy(duration: 0.25)) { expanded.toggle() }
            } label: {
                header
            }
            .buttonStyle(.plain)
            if expanded {
                if let output = run.output, !output.isEmpty {
                    ScrollView([.vertical, .horizontal]) {
                        Text(output)
                            .font(.caption.monospaced())
                            .foregroundStyle(Color.ink)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: true, vertical: true)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .defaultScrollAnchor(.bottomLeading)
                    .frame(maxHeight: 180)
                    .background(Color.chip, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                } else if run.status != "running" {
                    Text("No output.").font(.footnote).foregroundStyle(Color.text3)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            ScheduleStatusDot(status: run.status).padding(.top, 6)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(ScheduleText.runDate(run.startedAt)).font(.subheadline.weight(.semibold)).foregroundStyle(Color.ink)
                    if let code = run.exitCode {
                        Badge(text: String(localized: "exit code \(code)"), tint: code == 0 ? Color.good : Color.bad, fill: Color.chip)
                    }
                    Spacer()
                    if let ms = run.durationMs ?? run.endedAt.map({ Int($0.timeIntervalSince(run.startedAt) * 1000) }) {
                        Text(CommandText.runDuration(ms: ms)).font(.caption.monospacedDigit()).foregroundStyle(Color.text3)
                    } else if run.status == "running" {
                        Text("Running…").font(.caption).foregroundStyle(Color.text3)
                    }
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.text3)
                        .rotationEffect(.degrees(expanded ? 0 : -90))
                }
                if let error = run.error {
                    Text(error).font(.footnote).foregroundStyle(Color.bad).lineLimit(2)
                } else if !expanded, let preview = run.preview {
                    Text(preview).font(.footnote.monospaced()).foregroundStyle(Color.text2).lineLimit(1)
                }
            }
        }
        .contentShape(Rectangle())
    }
}
