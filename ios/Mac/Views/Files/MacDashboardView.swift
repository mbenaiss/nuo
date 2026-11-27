import SwiftUI

/// Figures in a row of tiles, then charts and tables on a two-column grid that collapses when the window is narrow.
struct MacDashboardView: View {
    @Environment(SessionStore.self) private var session
    @Environment(MacNavigator.self) private var navigator
    @State private var store: DashboardStore

    init(slug: String) {
        _store = State(initialValue: DashboardStore(slug: slug))
    }

    private static let tileMinWidth: CGFloat = 160
    private static let blockMinWidth: CGFloat = 380

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let dashboard = store.dashboard {
                    header(dashboard)
                    if let error = store.error {
                        StaleBanner(message: error) { Task { await store.load() } }
                    }
                    let numbers = dashboard.blocks.filter { $0.type == .number && $0.error == nil }
                    let others = dashboard.blocks.filter { !($0.type == .number && $0.error == nil) }
                    if !numbers.isEmpty {
                        DashboardGrid(minColumnWidth: Self.tileMinWidth, maxColumns: 4, spacing: Spacing.md) {
                            ForEach(Array(numbers.enumerated()), id: \.offset) { index, block in
                                DashboardBlockView(block: block, hero: index == 0 && numbers.count == 1)
                            }
                        }
                    }
                    DashboardGrid(minColumnWidth: Self.blockMinWidth, maxColumns: 4, spacing: Spacing.md) {
                        ForEach(Array(others.enumerated()), id: \.offset) { _, block in
                            DashboardBlockView(block: block)
                        }
                    }
                } else if let error = store.error {
                    WorkspaceEmptyState(symbol: "chart.bar.xaxis", title: String(localized: "Dashboard unavailable"), message: error)
                } else {
                    VStack(alignment: .leading, spacing: 14) {
                        SkeletonBar(width: 260, height: 26)
                        HStack(spacing: 14) { ForEach(0..<3, id: \.self) { _ in SkeletonBar(height: 90) } }
                        SkeletonBar(height: 220)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 1280, alignment: .leading)
        }
        .background(Color.canvas)
        .navigationTitle(store.dashboard?.title ?? "")
        .toolbar {
            ToolbarItem {
                Button { Task { await store.load() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .help("Refresh (⌘R)")
                    .disabled(store.loading)
            }
        }
        .task(id: navigator.refreshTick) {
            store.attach(session.api)
            await store.load()
        }
    }

    private func header(_ dashboard: Dashboard) -> some View {
        HStack(alignment: .center, spacing: 14) {
            EmojiTile(emoji: dashboard.emoji ?? "📊", size: 46)
            VStack(alignment: .leading, spacing: 3) {
                Text(dashboard.title).font(.largeTitle.bold()).foregroundStyle(Color.ink)
                if let description = dashboard.description {
                    Text(description).font(.callout).foregroundStyle(Color.text2)
                }
            }
            Spacer()
            if store.loading { ProgressView().controlSize(.small) }
        }
    }
}
