import SwiftUI

/// The line above the composer: the running turn, then a short « done » beat once it ends (see `turnDoneBeat`).
struct TurnStatusArea: View {
    let botName: String
    let phase: TurnPhase?
    let tool: String?
    var toolDetail: String?
    let steps: Int
    let startedAt: Date?
    let finished: Bool
    /// Palette or tag picker on screen: the line steps aside.
    var hidden = false
    @State private var genericShown = false

    var body: some View {
        Group {
            if hidden {
                EmptyView()
            } else if let phase {
                if genericShown || !TurnLabels.isGeneric(phase: phase, tool: tool, detail: toolDetail, steps: steps) {
                    TurnStatusBar(botName: botName, phase: phase, tool: tool, toolDetail: toolDetail, steps: steps, startedAt: startedAt ?? Date())
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            } else if finished {
                TurnDoneBar(botName: botName)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .task(id: startedAt) {
            genericShown = false
            guard let startedAt else { return }
            let wait = TurnLabels.genericDelay - Date().timeIntervalSince(startedAt)
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            guard !Task.isCancelled else { return }
            withAnimation(.snappy(duration: 0.25)) { genericShown = true }
        }
    }
}

extension View {
    /// Sets `finishedAt` for a moment when a turn ends without an error. It lives on an always-present parent:
    /// the status line itself leaves the hierarchy when no turn runs, and would miss the change.
    func turnDoneBeat(_ finishedAt: Binding<Date?>, running: Bool, failed: Bool) -> some View {
        onChange(of: running) { _, running in
            guard !running, !failed else {
                finishedAt.wrappedValue = nil
                return
            }
            let mark = Date()
            finishedAt.wrappedValue = mark
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.8))
                guard finishedAt.wrappedValue == mark else { return }
                withAnimation(.snappy(duration: 0.3)) { finishedAt.wrappedValue = nil }
            }
        }
    }
}

/// Persistent line above the composer while a turn runs, so a long turn never looks idle.
struct TurnStatusBar: View {
    let botName: String
    let phase: TurnPhase
    let tool: String?
    var toolDetail: String?
    let steps: Int
    let startedAt: Date

    var body: some View {
        HStack(spacing: Spacing.xs) {
            TurnPhaseIcon(phase: phase)
            Text(TurnLabels.status(bot: botName, phase: phase, tool: tool, detail: toolDetail, steps: steps))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Color.ink)
                .lineLimit(1)
                .truncationMode(.middle)
                .contentTransition(.opacity)
            Spacer(minLength: 6)
            TimelineView(.periodic(from: startedAt, by: 1)) { context in
                Text(TurnLabels.elapsed(since: startedAt, now: context.date))
                    .font(.caption.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(Color.text2)
                    .contentTransition(.numericText())
            }
        }
        .turnStatusCapsule(highlighted: phase == .waitingPermission)
        .animation(.snappy(duration: 0.25), value: phase)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
    }
}

/// Shown for a moment after a turn ends, so the answer landing feels finished rather than cut off.
struct TurnDoneBar: View {
    let botName: String

    var body: some View {
        HStack(spacing: Spacing.xs) {
            MascotView(state: .done, size: MascotMetrics.turnStatus).accessibilityHidden(true)
            Text("\(botName) finished")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Color.ink)
                .lineLimit(1)
            Spacer(minLength: 6)
        }
        .turnStatusCapsule(highlighted: false)
        .accessibilityElement(children: .combine)
    }
}

private extension View {
    /// The mascot sits close to the rounded leading edge, so that side gets a smaller inset than the text side.
    func turnStatusCapsule(highlighted: Bool) -> some View {
        padding(.leading, Spacing.xs)
            .padding(.trailing, 14)
            .padding(.vertical, (36 - MascotMetrics.turnStatus) / 2)
            .background(Color.card, in: Capsule())
            .overlay(Capsule().strokeBorder(highlighted ? Color.accent.opacity(0.5) : Color.line))
    }
}

/// The mascot acting out the turn phase; a permission request keeps its hand, which reads as « waiting on you ».
struct TurnPhaseIcon: View {
    let phase: TurnPhase

    var body: some View {
        Group {
            switch phase {
            case .queued, .thinking: MascotView(state: .think, size: MascotMetrics.turnStatus)
            case .working: MascotView(state: .work, size: MascotMetrics.turnStatus)
            case .answering: MascotView(state: .talk, size: MascotMetrics.turnStatus)
            case .waitingPermission:
                Image(systemName: "hand.raised.fill")
                    .symbolEffect(.bounce, options: .repeating)
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(Color.accent)
                    .frame(width: MascotMetrics.turnStatus, height: MascotMetrics.turnStatus)
            }
        }
        .accessibilityHidden(true)
    }
}

/// « en cours » capsule on bot cards, sidebar rows and conversation rows.
struct RunningBadge: View {
    var label = String(localized: "running")
    @State private var lit = false

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(Color.accent)
                .frame(width: 6, height: 6)
                .opacity(lit ? 1 : 0.35)
                .scaleEffect(lit ? 1 : 0.75)
            Text(label).lineLimit(1)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(Color.accentInk)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.accentSoft, in: Capsule())
        .onAppear {
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { lit = true }
        }
        .accessibilityLabel("Reply in progress")
    }
}

/// « Envoi… » / « Envoyé » under the message just submitted.
struct OutgoingStatus: View {
    let sent: Bool

    var body: some View {
        HStack(spacing: 4) {
            if sent {
                Image(systemName: "checkmark").font(.caption2.weight(.bold))
            } else {
                ProgressView().controlSize(.mini)
            }
            Text(sent ? String(localized: "Sent") : String(localized: "Sending…"))
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(Color.text3)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.trailing, 6)
        .transition(.opacity)
        .animation(.snappy, value: sent)
    }
}
