import Foundation
import Observation

/// Cached `GET /api/machine/tools`, shared by the tools screen and the `#` palettes.
@MainActor
@Observable
final class MachineToolsStore {
    static let shared = MachineToolsStore()

    private(set) var tools: [MachineTool] = []
    private(set) var isLoading = false
    private(set) var loadError: String?
    private(set) var loaded = false

    func refresh(api: any NuoAPI) async {
        if tools.isEmpty { isLoading = true }
        defer { if isLoading { isLoading = false } }
        do {
            // Refreshed each time a chat opens: an unchanged list must not re-render every message bubble.
            let fetched = try await api.machineTools()
            if fetched != tools { tools = fetched }
            if loadError != nil { loadError = nil }
            if !loaded { loaded = true }
        } catch is CancellationError {
        } catch {
            loadError = error.localizedDescription
        }
    }

    func tool(id: String) -> MachineTool? { tools.first { $0.id == id } }

    var ids: Set<String> { Set(tools.map(\.id)) }

    /// Available tools matching the text typed after `#`: id/name prefix first, then contains or description.
    func matches(_ query: String) -> [MachineTool] {
        let available = tools.filter(\.available)
        let q = query.lowercased().folding(options: .diacriticInsensitive, locale: nil)
        guard !q.isEmpty else { return available }
        func fold(_ s: String) -> String { s.lowercased().folding(options: .diacriticInsensitive, locale: nil) }
        let prefix = available.filter { $0.id.hasPrefix(q) || fold($0.name).hasPrefix(q) }
        let other = available.filter {
            !($0.id.hasPrefix(q) || fold($0.name).hasPrefix(q))
                && ($0.id.contains(q) || fold($0.name).contains(q) || (q.count >= 2 && fold($0.description).contains(q)))
        }
        return prefix + other
    }
}

enum MachineToolKind: String, CaseIterable, Identifiable {
    case cli, mcp, skill

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cli: "CLI"
        case .mcp: String(localized: "MCP servers")
        case .skill: String(localized: "Skills")
        }
    }

    var footer: String {
        switch self {
        case .cli: String(localized: "Commands installed on the machine. They go through the shell: only bots with Auto permissions can run them.")
        case .mcp: String(localized: "MCP servers declared on the gateway.")
        case .skill: String(localized: "Packaged agent know-how, called by name.")
        }
    }
}

extension MachineTool {
    var toolKind: MachineToolKind { MachineToolKind(rawValue: kind) ?? .cli }

    func usable(by config: BotConfig?) -> Bool {
        !needsShell || config?.permissionPolicy == .auto
    }

    /// Bots that may use this tool: any bot for plain tools, only `auto` bots when the shell is needed.
    func allowedBots(in bots: [Bot]) -> [Bot] {
        bots.filter { usable(by: $0.config) }
    }

    enum Glyph {
        case symbol(String)
        case emoji(String)
    }

    var glyph: Glyph {
        switch id {
        case "gog": .symbol("calendar")
        case "ntn", "notion": .symbol("doc.text")
        case "gh", "github": .symbol("arrow.triangle.branch")
        case "docker": .symbol("shippingbox")
        case "pvesh", "proxmox": .symbol("server.rack")
        case "playwright-cli", "playwright": .symbol("globe")
        case "whisper": .symbol("waveform")
        case "ffmpeg": .symbol("film")
        case "codex": .symbol("chevron.left.forwardslash.chevron.right")
        case "grok": .symbol("sparkle.magnifyingglass")
        case "claude": .symbol("asterisk")
        case "travel", "flights": .emoji("✈️")
        case "flight-status": .symbol("airplane.departure")
        case "whoop": .symbol("heart.text.square")
        case "mr": .symbol("arrow.triangle.merge")
        default:
            switch toolKind {
            case .cli: .symbol("terminal")
            case .mcp: .symbol("puzzlepiece.extension")
            case .skill: .symbol("wand.and.stars")
            }
        }
    }
}

/// Bot names as a sentence list, for "Only Cobot" style notes.
func machineToolBotNames(_ bots: [Bot]) -> String {
    let names = bots.compactMap { $0.config?.name }
    return names.isEmpty ? String(localized: "No bot") : names.formatted(.list(type: .and))
}
