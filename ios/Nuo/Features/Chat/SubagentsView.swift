import SwiftUI

/// The subagents the bot delegated to in this conversation, running ones first, and what each one does.
struct SubagentsView: View {
    let store: ConversationStore
    @Environment(\.dismiss) private var dismiss

    private var ordered: [SubagentInfo] {
        let all = store.subagents
        return all.filter(\.isActive) + all.filter { !$0.isActive }
    }

    var body: some View {
        NavigationStack {
            List {
                if ordered.isEmpty {
                    Text("No subagents launched in this conversation.")
                        .font(.footnote)
                        .foregroundStyle(Color.text2)
                } else {
                    ForEach(ordered) { subagent in
                        NavigationLink {
                            SubagentDetailView(store: store, id: subagent.id)
                        } label: {
                            SubagentRow(subagent: subagent)
                        }
                    }
                }
            }
            .navigationTitle("Subagents")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }
}

struct SubagentStateIcon: View {
    let state: SubagentInfo.State

    var body: some View {
        switch state {
        case .running: ProgressView().controlSize(.small)
        case .waiting: Image(systemName: "hand.raised.fill").foregroundStyle(Color(hex: 0xF59E0B))
        case .completed: Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.good)
        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        case .cancelled: Image(systemName: "stop.circle.fill").foregroundStyle(Color.text2)
        }
    }
}

extension SubagentInfo.State {
    var label: String {
        switch self {
        case .running: String(localized: "Running")
        case .waiting: String(localized: "Waiting for permission")
        case .completed: String(localized: "Completed")
        case .failed: String(localized: "Failed")
        case .cancelled: String(localized: "Stopped")
        }
    }
}

extension SubagentInfo {
    var durationLabel: String {
        let seconds = Int((endedAt ?? Date()).timeIntervalSince(startedAt))
        return seconds < 60 ? "\(max(seconds, 0)) s" : "\(seconds / 60) min \(seconds % 60) s"
    }
}

private struct SubagentRow: View {
    let subagent: SubagentInfo

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            SubagentStateIcon(state: subagent.state).frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(subagent.title).font(.body.weight(.semibold)).foregroundStyle(Color.ink).lineLimit(1)
                if let description = subagent.description {
                    Text(description).font(.footnote).foregroundStyle(Color.text2).lineLimit(2)
                }
                Text(summary).font(.caption).foregroundStyle(Color.text3)
            }
        }
        .padding(.vertical, 2)
    }

    private var summary: String {
        var parts = [subagent.state.label, subagent.durationLabel]
        if !subagent.steps.isEmpty { parts.append(String(localized: "\(subagent.steps.count) steps")) }
        return parts.joined(separator: " · ")
    }
}

/// Follows the subagent live while its turn runs.
struct SubagentDetailView: View {
    let store: ConversationStore
    let id: String

    var body: some View {
        if let subagent = store.subagents.first(where: { $0.id == id }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 8) {
                        SubagentStateIcon(state: subagent.state)
                        Text("\(subagent.state.label) · \(subagent.durationLabel)").font(.subheadline).foregroundStyle(Color.text2)
                    }
                    if let description = subagent.description {
                        section("Mission") {
                            Text(description).font(.callout).foregroundStyle(Color.ink).textSelection(.enabled)
                        }
                    }
                    if !subagent.steps.isEmpty {
                        section("Steps") {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(subagent.steps, id: \.toolCallId) { step in
                                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                                        Image(systemName: step.status == .running ? "circle.dotted" : step.status == .completed ? "checkmark" : "xmark")
                                            .font(.caption.weight(.bold))
                                            .foregroundStyle(step.status == .failed ? Color.red : Color.text2)
                                        Text(step.title).font(.footnote.monospaced()).foregroundStyle(Color.ink).lineLimit(3)
                                        Spacer(minLength: 0)
                                        if let ms = step.durationMs { Text("\(max(ms / 1000, 0)) s").font(.caption2).foregroundStyle(Color.text3) }
                                    }
                                }
                            }
                        }
                    }
                    if let text = subagent.text, !text.isEmpty {
                        section("Response") {
                            Text(inlineMarkdown(text)).font(.callout).foregroundStyle(Color.ink).textSelection(.enabled)
                        }
                    } else if subagent.steps.isEmpty {
                        Text(subagent.isActive
                             ? String(localized: "This agent does not pass on the details of its subagents' work: only the state is tracked.")
                             : String(localized: "The details of this subagent were not passed on by the agent."))
                            .font(.footnote).foregroundStyle(Color.text2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            .navigationTitle(subagent.title)
        } else {
            Text("Subagent not found.").foregroundStyle(Color.text2)
        }
    }

    private func section<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).textCase(.uppercase).font(.caption.weight(.bold)).tracking(0.7).foregroundStyle(Color.text3)
            content()
        }
    }
}

extension EnvironmentValues {
    /// Opens the conversation's subagents (set by the chat screen).
    @Entry var openSubagents: SubagentsOpener?
}

/// Equatable wrapper so the chat screen's new closure on each update does not re-render every message.
struct SubagentsOpener: Equatable {
    let open: @MainActor () -> Void
    static func == (lhs: Self, rhs: Self) -> Bool { true }
}

/// Under an answer that delegated: how many subagents, how many still running; opens the list.
struct SubagentsChip: View {
    let subagents: [SubagentInfo]
    @Environment(\.openSubagents) private var openSubagents

    var body: some View {
        let running = subagents.filter(\.isActive).count
        Button {
            Haptics.selection()
            openSubagents?.open()
        } label: {
            HStack(spacing: 7) {
                if running > 0 { ProgressView().controlSize(.mini) } else { Image(systemName: "person.2.wave.2").font(.caption.weight(.semibold)) }
                Text(label(running: running))
                Image(systemName: "chevron.right").font(.caption2.weight(.bold)).foregroundStyle(Color.text3)
            }
            .font(.footnote)
            .foregroundStyle(Color.text2)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Color.chip, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityHint("Shows what the subagents are doing")
    }

    private func label(running: Int) -> String {
        let total = String(localized: "\(subagents.count) subagents")
        return running > 0 ? String(localized: "\(total) · \(running) running") : total
    }
}
