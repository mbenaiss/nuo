import SwiftUI

/// Placeholder bar that pulses while content loads.
struct SkeletonBar: View {
    var width: CGFloat?
    var height: CGFloat = 12
    @State private var dim = false

    var body: some View {
        RoundedRectangle(cornerRadius: height / 2, style: .continuous)
            .fill(Color.chip)
            .frame(width: width, height: height)
            .opacity(dim ? 0.55 : 1)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { dim = true }
            }
    }
}

struct SkeletonRows: View {
    var count = 6

    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<count, id: \.self) { index in
                HStack(spacing: Spacing.sm) {
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        SkeletonBar(width: [190, 150, 220, 170, 200, 140][index % 6], height: 13)
                        SkeletonBar(width: [110, 90, 130, 80, 120, 100][index % 6], height: 10)
                    }
                    Spacer()
                    SkeletonBar(width: 64, height: 13)
                }
                .padding(.vertical, Spacing.md)
                .padding(.horizontal, CardMetrics.rowInset)
                if index < count - 1 { Divider().overlay(Color.line).padding(.leading, CardMetrics.rowInset) }
            }
        }
        .groupCard()
        .accessibilityLabel("Loading")
    }
}

struct WorkspaceEmptyState: View {
    let symbol: String
    let title: String
    var message: String?
    /// Shown instead of the symbol tile on the friendly empty states (all done, nothing planned, first use).
    var mascot: MascotState?

    var body: some View {
        VStack(spacing: Spacing.sm) {
            if let mascot {
                MascotView(state: mascot, size: MascotMetrics.emptyState)
            } else {
                Image(systemName: symbol)
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(Color.text3)
                    .frame(width: 64, height: 64)
                    .background(Color.chip, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
            }
            Text(title).font(.headline).foregroundStyle(Color.ink)
            if let message {
                Text(message).font(.subheadline).foregroundStyle(Color.text2).multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Spacing.xxl + Spacing.xs)
        .padding(.horizontal, Spacing.xl)
    }
}

/// Discreet line shown when a refresh failed but cached content is still on screen.
struct StaleBanner: View {
    let message: String
    var retry: (() -> Void)?

    var body: some View {
        HStack(spacing: Spacing.xs) {
            Image(systemName: "icloud.slash").font(.footnote.weight(.semibold))
            Text(message).font(.footnote).lineLimit(2)
            Spacer(minLength: Spacing.xxs)
            if let retry {
                Button("Try Again", action: retry).font(.footnote.weight(.semibold))
            }
        }
        .foregroundStyle(Color.text2)
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
        .background(Color.chip, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
    }
}

/// Filter or sort chip of the collection screen.
struct FilterChip: View {
    let title: String
    var symbol: String?
    var active = false
    var tint: Color?

    var body: some View {
        HStack(spacing: Spacing.xxs) {
            if let tint { Circle().fill(tint).frame(width: 7, height: 7) }
            if let symbol { Image(systemName: symbol).font(.caption.weight(.bold)) }
            Text(title).lineLimit(1)
        }
        .font(.subheadline.weight(.medium))
        .foregroundStyle(active ? Color.onInk : Color.ink)
        .padding(.horizontal, Spacing.sm)
        .frame(minHeight: 34)
        .background(active ? Color.inkFill : Color.card, in: Capsule())
        .overlay(Capsule().strokeBorder(active ? Color.clear : Color.line))
        .contentShape(Capsule())
    }
}

extension View {
    /// Rounded card container for a group of rows.
    func groupCard() -> some View {
        background(Color.card, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous).strokeBorder(Color.line))
    }
}

/// Debounces a text so search requests only go out when typing pauses.
@MainActor
@Observable
final class Debouncer {
    private(set) var value = ""
    @ObservationIgnored private var task: Task<Void, Never>?

    func send(_ text: String, delay: Duration = .milliseconds(250)) {
        task?.cancel()
        task = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.value = text
        }
    }
}
