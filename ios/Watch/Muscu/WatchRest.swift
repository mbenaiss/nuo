import SwiftUI
import WatchKit

/// The rest of the iPhone's Muscu screen, counted down on the wrist with a tap when it ends.
@MainActor
@Observable
final class WatchRest {
    static let shared = WatchRest()

    private(set) var rest: MuscuRestLink.Rest?
    /// Messages come live or queued, possibly out of order: an older one never undoes a newer one.
    @ObservationIgnored private var lastSentAt = Date.distantPast
    @ObservationIgnored private var alarm: Task<Void, Never>?

    /// True when the payload was the Muscu screen's.
    @discardableResult
    func receive(_ payload: [String: Any]) -> Bool {
        guard let message = MuscuRestLink.decode(payload) else { return false }
        guard message.sentAt > lastSentAt else { return true }
        lastSentAt = message.sentAt
        switch message {
        case let .start(rest, _) where rest.until > .now:
            show(rest)
        default:
            dismiss()
        }
        return true
    }

    func dismiss() {
        alarm?.cancel()
        alarm = nil
        rest = nil
    }

    private func show(_ rest: MuscuRestLink.Rest) {
        self.rest = rest
        alarm?.cancel()
        alarm = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, rest.until.timeIntervalSinceNow)))
            guard !Task.isCancelled, let self, self.rest == rest else { return }
            WKInterfaceDevice.current().play(.notification)
            // "Back to it" stays a moment, then the screen goes back where it was.
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, self.rest == rest else { return }
            self.rest = nil
        }
    }
}

struct WatchRestView: View {
    let rest: MuscuRestLink.Rest
    let onClose: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let over = rest.until <= context.date
            VStack(spacing: 6) {
                Text(over ? String(localized: "Back to it") : rest.title)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.accent)
                ZStack {
                    Circle().stroke(Color.white.opacity(0.15), lineWidth: 8)
                    Circle()
                        .trim(from: 0, to: progress(at: context.date))
                        .stroke(Color.accent, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    if over {
                        Image(systemName: "figure.strengthtraining.traditional").font(.title)
                    } else {
                        Text(timerInterval: context.date...rest.until, countsDown: true)
                            .font(.system(size: 34, weight: .bold, design: .rounded))
                            .monospacedDigit()
                    }
                }
                .padding(.horizontal, 12)
                Text(rest.next)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("OK", action: onClose)
            }
        }
    }

    /// Part of the rest already gone, for the ring.
    private func progress(at date: Date) -> Double {
        guard rest.total > 0 else { return 1 }
        let left = max(0, rest.until.timeIntervalSince(date))
        return min(1, max(0, 1 - left / Double(rest.total)))
    }
}
