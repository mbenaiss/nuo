import SwiftUI

/// "Machine Tools": what the gateway machine has installed, grouped by kind.
struct MachineToolsView: View {
    @Environment(SessionStore.self) private var session
    @Environment(BotsStore.self) private var bots
    @State private var store = MachineToolsStore.shared
    @State private var selected: MachineTool?

    var body: some View {
        List {
            if store.tools.isEmpty {
                Section {
                    if store.isLoading {
                        ProgressView().frame(maxWidth: .infinity).padding(.vertical, 24)
                    } else {
                        ContentUnavailableView {
                            Label("No Tools", systemImage: "wrench.and.screwdriver")
                        } description: {
                            Text(store.loadError ?? String(localized: "The gateway found no tools on the machine."))
                        }
                    }
                }
                .listRowBackground(Color.card)
            } else {
                Section {
                    summary
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                ForEach(MachineToolKind.allCases) { kind in
                    let tools = store.tools.filter { $0.toolKind == kind }
                    if !tools.isEmpty {
                        Section {
                            ForEach(tools) { tool in
                                Button { selected = tool } label: { MachineToolRow(tool: tool) }
                                    .buttonStyle(.plain)
                            }
                        } header: {
                            HStack {
                                SectionHeader(title: kind.title)
                                Spacer()
                                Text(verbatim: "\(tools.count)").font(.caption.weight(.bold)).monospacedDigit().foregroundStyle(Color.text3)
                            }
                        } footer: {
                            Text(kind.footer)
                        }
                        .listRowBackground(Color.card)
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.canvas)
        .navigationTitle("Machine Tools")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await store.refresh(api: session.api) }
        .task {
            await store.refresh(api: session.api)
            if let id = MachineToolsDemo.toolId, selected == nil { selected = store.tool(id: id) }
        }
        .sheet(item: $selected) { tool in
            MachineToolDetail(tool: tool, bots: bots.bots)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
    }

    private var summary: some View {
        HStack(spacing: 10) {
            Image(systemName: "number")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(Color.accentInk)
                .frame(width: 34, height: 34)
                .background(Color.accentSoft, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            Text("Type **#** in a message to show a tool to the bot, for example **#gog what meetings do I have tomorrow?**")
                .font(.footnote)
                .foregroundStyle(Color.text2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
    }
}

struct MachineToolGlyph: View {
    let tool: MachineTool
    var size: CGFloat = 36
    var highlighted = false

    var body: some View {
        Group {
            switch tool.glyph {
            case let .symbol(name):
                Image(systemName: name).font(.system(size: size * 0.42, weight: .semibold))
            case let .emoji(emoji):
                Text(emoji).font(.system(size: size * 0.46))
            }
        }
        .foregroundStyle(highlighted ? Color.accentInk : Color.ink)
        .frame(width: size, height: size)
        .background(highlighted ? Color.accentSoft : Color.chip, in: RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
    }
}

struct ShellBadge: View {
    var body: some View {
        Badge(text: "Shell", tint: Color.accentInk, fill: Color.accentSoft)
    }
}

private struct MachineToolRow: View {
    let tool: MachineTool

    var body: some View {
        HStack(spacing: 12) {
            MachineToolGlyph(tool: tool)
                .opacity(tool.available ? 1 : 0.5)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(tool.name).font(.body.weight(.semibold)).foregroundStyle(Color.ink)
                    if tool.needsShell { ShellBadge() }
                }
                Text(tool.description).font(.footnote).foregroundStyle(Color.text2).lineLimit(1)
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 4) {
                Circle()
                    .fill(tool.available ? Color.good : Color.text3)
                    .frame(width: 8, height: 8)
                    .accessibilityLabel(tool.available ? String(localized: "Available") : String(localized: "Unavailable"))
                if let version = tool.version {
                    Text(version).font(.caption2.monospaced()).foregroundStyle(Color.text3)
                } else if !tool.available {
                    Text("missing").font(.caption2).foregroundStyle(Color.text3)
                }
            }
        }
        .padding(.vertical, 1)
        .contentShape(Rectangle())
    }
}

struct MachineToolDetail: View {
    let tool: MachineTool
    let bots: [Bot]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 14) {
                        MachineToolGlyph(tool: tool, size: 54, highlighted: true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("#\(tool.id)").font(.title3.weight(.bold).monospaced()).foregroundStyle(Color.ink)
                            Text(tool.description).font(.subheadline).foregroundStyle(Color.text2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.vertical, 4)
                    LabeledContent("Type", value: tool.toolKind == .mcp ? String(localized: "MCP server") : tool.toolKind == .skill ? String(localized: "Skill") : "CLI")
                    if let version = tool.version { LabeledContent("Version") { Text(version).monospaced() } }
                    LabeledContent(String(localized: "tool.status", defaultValue: "Status")) {
                        HStack(spacing: 6) {
                            Circle().fill(tool.available ? Color.good : Color.text3).frame(width: 8, height: 8)
                            Text(tool.available ? String(localized: "Available") : String(localized: "Not found on the machine"))
                        }
                    }
                    if tool.needsShell {
                        LabeledContent("Access") { ShellBadge() }
                    }
                }
                .listRowBackground(Color.card)

                if let usage = tool.usage, !usage.isEmpty {
                    Section {
                        Text(usage)
                            .font(.footnote.monospaced())
                            .foregroundStyle(Color.ink)
                            .lineSpacing(3)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 6)
                    } header: {
                        SectionHeader(title: "Usage")
                    }
                    .listRowBackground(Color.chip)
                }

                Section {
                    let allowed = tool.allowedBots(in: bots)
                    if allowed.isEmpty {
                        Text("No bots yet.").foregroundStyle(Color.text2)
                    }
                    ForEach(allowed) { bot in
                        HStack(spacing: 10) {
                            BotAvatar(config: bot.config, size: 30)
                            Text(bot.config?.name ?? "Bot").foregroundStyle(Color.ink)
                            Spacer()
                            if tool.needsShell {
                                Text("Auto permissions").font(.caption).foregroundStyle(Color.text3)
                            }
                        }
                    }
                } header: {
                    SectionHeader(title: "Bots that can use it")
                } footer: {
                    if tool.needsShell {
                        Text("This tool goes through the shell: it needs a bot with permissions set to Auto.")
                    } else {
                        Text("All your bots can use it with #\(tool.id).")
                    }
                }
                .listRowBackground(Color.card)
            }
            .scrollContentBackground(.hidden)
            .background(Color.canvas)
            .navigationTitle(tool.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("OK") { dismiss() } } }
        }
    }
}

/// `-demo -demoScreen settings -demoTools [gog]` opens the tools screen (and a tool's detail) for screenshots.
enum MachineToolsDemo {
    private static var arguments: [String] { ProcessInfo.processInfo.arguments }
    static var opensScreen: Bool { arguments.contains("-demo") && arguments.contains("-demoTools") }
    static var toolId: String? {
        guard opensScreen, let index = arguments.firstIndex(of: "-demoTools"), index + 1 < arguments.count,
              !arguments[index + 1].hasPrefix("-") else { return nil }
        return arguments[index + 1]
    }
}
