import SwiftUI

/// "Mémoire des bots": every bot with how many facts it remembers.
struct BotMemoriesView: View {
    @Environment(SessionStore.self) private var session
    @Environment(BotsStore.self) private var bots
    @State private var memories: [String: BotMemory] = [:]
    @State private var selected: String? = MemoryDemo.botId

    var body: some View {
        List {
            Section {
                ForEach(bots.bots) { bot in
                    Button {
                        selected = bot.id
                    } label: {
                        HStack(spacing: 12) {
                            BotAvatar(config: bot.config, size: 36)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(bot.config?.name ?? "Bot").font(.body.weight(.semibold)).foregroundStyle(Color.ink)
                                Text(detail(bot.id)).font(.caption).foregroundStyle(Color.text3)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Color.text3)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } footer: {
                Text("Each bot keeps its lasting facts from one conversation to the next, and rereads them at the start of each.")
            }
            .listRowBackground(Color.card)
        }
        .scrollContentBackground(.hidden)
        .background(Color.canvas)
        .navigationTitle("Bot memory")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $selected) { BotMemoryView(botId: $0) }
        .task(id: bots.bots.map(\.id)) { await load() }
        .refreshable { await load() }
        .onChange(of: selected) { _, value in
            if value == nil { Task { await load() } }
        }
    }

    private func detail(_ botId: String) -> String {
        guard let memory = memories[botId] else { return "…" }
        let count = MemoryDocument(memory.content).facts.count
        let facts = count == 0 ? String(localized: "Empty") : String(localized: "\(count) facts")
        guard count > 0, let updated = memory.updatedAt else { return facts }
        return "\(facts) · \(MemoryDocument.updatedLabel(updated))"
    }

    private func load() async {
        await withTaskGroup(of: (String, BotMemory?).self) { group in
            for bot in bots.bots {
                group.addTask { [api = session.api] in (bot.id, try? await api.memory(botId: bot.id)) }
            }
            for await (id, memory) in group {
                if let memory { memories[id] = memory }
            }
        }
    }
}
