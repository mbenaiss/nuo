import Foundation

enum DemoSeed {
    static let agents: [AgentInfo] = [
        AgentInfo(id: .claude, name: "Claude", available: true, authenticated: true, models: [
            ModelInfo(id: "claude-opus-5-5", name: "Claude Opus 5.5", efforts: ["low", "medium", "high", "max"]),
            ModelInfo(id: "claude-sonnet-5", name: "Claude Sonnet 5", isDefault: true, efforts: ["low", "medium", "high"]),
            ModelInfo(id: "claude-haiku-5", name: "Claude Haiku 5", efforts: ["low", "medium"]),
        ]),
        AgentInfo(id: .codex, name: "Codex", available: true, authenticated: false, models: [
            ModelInfo(id: "gpt-6.1", name: "GPT-6.1", isDefault: true, efforts: ["low", "medium", "high"]),
        ], note: String(localized: "Sign-in needed on dev")),
        AgentInfo(id: .gemini, name: "Gemini", available: true, authenticated: true, models: [
            ModelInfo(id: "gemini-3.1-pro", name: "Gemini 3.1 Pro", isDefault: true, efforts: ["low", "high"]),
        ]),
        AgentInfo(id: .grok, name: "Grok", available: false, authenticated: false, models: [], note: String(localized: "CLI not installed")),
    ]

    static let tools: [ToolServer] = [
        ToolServer(id: "travel", name: "MCP travel", description: String(localized: "Flight status, bookings, boarding passes"), tools: ["flight_status", "booking_lookup", "favorites", "flight_mode", "boarding_pass", "airport_info", "seat_map"]),
        ToolServer(id: "web", name: "Web", description: String(localized: "Search and read web pages"), tools: ["search", "fetch"]),
        ToolServer(id: "whoop", name: "WHOOP", description: String(localized: "Recovery, sleep, workouts"), tools: ["whoop_today", "whoop_week", "session_today", "week_plan", "day_summary", "macros"]),
        ToolServer(id: "github", name: "GitHub", description: String(localized: "Issues, PRs, deployments"), tools: ["list_prs", "merge_pr", "create_issue", "workflow_runs", "services_status"]),
        ToolServer(id: "home", name: String(localized: "demo.tools.home.name", defaultValue: "Home"), description: String(localized: "Lights, plugs, scenes"), tools: ["list_devices", "set_power", "run_scene"]),
    ]

    static let machineTools: [MachineTool] = [
        MachineTool(id: "gog", name: "gog", kind: "cli", description: String(localized: "Google Calendar, Gmail and Drive from the command line"), version: "0.9.2",
                    usage: String(localized: "demo.tools.gog.usage", defaultValue: "gog calendar events --from tomorrow --to tomorrow\ngog gmail search 'is:unread newer_than:1d'\ngog drive ls --query 'name contains \"invoice\"'"), needsShell: true, available: true),
        MachineTool(id: "ntn", name: "ntn", kind: "cli", description: String(localized: "Notion pages and databases"), version: "1.4.0",
                    usage: "ntn pages create --parent <id> --title \"…\"\nntn datasources query <id> --filter '…'\nntn api GET /v1/users/me", needsShell: true, available: true),
        MachineTool(id: "gh", name: "gh", kind: "cli", description: String(localized: "GitHub issues, PRs and workflows"), version: "2.81.0",
                    usage: "gh pr list --author @me\ngh run list --limit 5\ngh issue create --title \"…\"", needsShell: true, available: true),
        MachineTool(id: "docker", name: "docker", kind: "cli", description: String(localized: "Containers and images on dev"), version: "28.4.0",
                    usage: String(localized: "demo.tools.docker.usage", defaultValue: "docker ps --format '{{.Names}}\\t{{.Status}}'\ndocker logs --tail 100 <container>\ndocker compose -f <file> up -d"), needsShell: true, available: true),
        MachineTool(id: "pvesh", name: "pvesh", kind: "cli", description: String(localized: "VMs and containers on the Proxmox server"), version: "9.0.6",
                    usage: "pvesh get /cluster/resources --type vm\npvesh create /nodes/pve/qemu/<vmid>/status/start", needsShell: true, available: true),
        MachineTool(id: "playwright-cli", name: "playwright-cli", kind: "cli", description: String(localized: "Automated browser: pages, forms, screenshots"), version: "1.56.0",
                    usage: "playwright-cli open <url>\nplaywright-cli snapshot\nplaywright-cli click <ref>", needsShell: true, available: true),
        MachineTool(id: "whisper", name: "whisper", kind: "cli", description: String(localized: "Local audio transcription"), version: "1.8.0",
                    usage: String(localized: "demo.tools.whisper.usage", defaultValue: "whisper <file.m4a> --language en --output_format txt"), needsShell: true, available: true),
        MachineTool(id: "ffmpeg", name: "ffmpeg", kind: "cli", description: String(localized: "Convert and trim audio and video"), version: "8.0",
                    usage: String(localized: "demo.tools.ffmpeg.usage", defaultValue: "ffmpeg -i <input> -ss 00:01:00 -t 30 <output.mp4>"), needsShell: true, available: true),
        MachineTool(id: "codex", name: "codex", kind: "cli", description: String(localized: "Codex coding agent in exec mode"), version: "0.48.0",
                    usage: String(localized: "demo.tools.codex.usage", defaultValue: "codex exec \"<instructions>\" --cd <folder>"), needsShell: true, available: true),
        MachineTool(id: "grok", name: "grok", kind: "cli", description: String(localized: "Real-time search with Grok"), version: nil,
                    usage: "grok ask \"<question>\"", needsShell: true, available: false),
        MachineTool(id: "travel", name: "travel", kind: "mcp", description: String(localized: "Flight status, bookings, boarding passes"), version: "2.3.1",
                    usage: String(localized: "demo.tools.travel.usage", defaultValue: "Tools: flight_status, booking_lookup, favorites, boarding_pass, seat_map"), needsShell: false, available: true),
        MachineTool(id: "whoop", name: "whoop", kind: "mcp", description: String(localized: "WHOOP recovery, sleep and workouts"), version: "1.2.0",
                    usage: String(localized: "demo.tools.whoop.usage", defaultValue: "Tools: whoop_today, whoop_week, session_today, macros"), needsShell: false, available: true),
        MachineTool(id: "flights", name: "flights", kind: "skill", description: String(localized: "Flight search with Google Flights"), version: nil,
                    usage: String(localized: "Describe the trip: “Paris → Lisbon on 10/20, back on the 27th, one adult”"), needsShell: false, available: true),
        MachineTool(id: "flight-status", name: "flight-status", kind: "skill", description: String(localized: "Live status card for a flight"), version: nil,
                    usage: String(localized: "Give the flight number and date: “TO8285 on 10/19”"), needsShell: false, available: true),
        MachineTool(id: "mr", name: "mr", kind: "skill", description: String(localized: "Reviews the changes, pushes and opens a GitLab MR"), version: nil,
                    usage: String(localized: "“open the MR” or “fix the MR comments”"), needsShell: true, available: true),
    ]

    static func blankConfig(name: String) -> BotConfig {
        BotConfig(
            name: name, emoji: "✨", color: "#F1E8FF", description: "", agent: .claude, model: "claude-sonnet-5",
            effort: "medium", instructions: String(localized: "You're a personal assistant. Keep your answers short."),
            toolServers: [], workdir: nil, permissionPolicy: .ask, voice: nil)
    }

    /// The ::flight card of the demo trip; English statuses need `statusKind` to get the card's green tint.
    static func flightCard(_ flight: String = "TO8285", airline: Bool = true) -> String {
        let status = String(localized: "On time")
        let track = String(localized: "Track live")
        let mode = String(localized: "Flight mode")
        let carrier = airline ? #","airline":"Transavia""# : ""
        return #"::flight {"flight":"\#(flight)"\#(carrier),"from":{"code":"FCO","city":"Rome","time":"14:40","terminal":"1"},"to":{"code":"ORY","city":"Paris Orly","time":"17:05","terminal":"3"},"date":"2026-10-19","status":"\#(status)","statusKind":"on_time","gate":"F32","seats":["6D","6E","6F"],"actions":["\#(track)","\#(mode)"]}"#
    }

    private static func tool(_ name: String, _ description: String, args: String? = nil, server: String, tool: String, params: [String]? = nil) -> BotCommand {
        BotCommand(name: name, description: description, args: args, action: .init(type: "tool", server: server, tool: tool, params: params))
    }

    private static func prompt(_ name: String, _ description: String, args: String? = nil, template: String, model: String? = nil, effort: String? = nil) -> BotCommand {
        BotCommand(name: name, description: description, args: args, action: .init(type: "prompt", template: template, model: model, effort: effort))
    }

    private static func app(_ name: String, _ description: String, _ action: AppCommandAction) -> BotCommand {
        BotCommand(name: name, description: description, action: .init(type: "app", action: action.rawValue))
    }

    /// Command names are what people type after `/`: French in French, so the scripted answers accept both spellings.
    enum Command {
        static var flight: String { String(localized: "demo.command.flight", defaultValue: "flight") }
        static var flights: String { String(localized: "demo.command.flights", defaultValue: "flights") }
        static var favorites: String { String(localized: "demo.command.favorites", defaultValue: "favorites") }
        static var flightMode: String { String(localized: "demo.command.flightMode", defaultValue: "flightmode") }
        static var workout: String { String(localized: "demo.command.workout", defaultValue: "workout") }
        static var plan: String { String(localized: "demo.command.plan", defaultValue: "plan") }
        static var day: String { String(localized: "demo.command.day", defaultValue: "day") }
        static var week: String { String(localized: "demo.command.week", defaultValue: "week") }
        static var calibrate: String { String(localized: "demo.command.calibrate", defaultValue: "calibrate") }
        static var barcode: String { String(localized: "demo.command.barcode", defaultValue: "barcode") }
        static var guided: String { String(localized: "demo.command.guided", defaultValue: "guided") }
        static var status: String { String(localized: "demo.command.status", defaultValue: "status") }
    }

    static var voyagesCommands: [BotCommand] {
        [
            tool(Command.flight, String(localized: "Live flight status"), args: String(localized: "<flight> [dd/mm]"), server: "travel", tool: "flight_status", params: ["flight", "date"]),
            tool(Command.flights, String(localized: "My upcoming booked flights"), server: "travel", tool: "booking_lookup"),
            tool(Command.favorites, String(localized: "Favorite airports and routes"), server: "travel", tool: "favorites"),
            prompt(Command.flightMode, String(localized: "Get ready for flight mode before boarding"), args: String(localized: "[flight]"),
                   template: String(localized: "I'm about to board {args}. Sum up what I need to know before going offline: gate, times, connection."), effort: "low"),
            app("reset", String(localized: "New conversation"), .newConversation),
        ]
    }

    static var coachCommands: [BotCommand] {
        [
            tool(Command.workout, String(localized: "Today's workout based on your recovery"), server: "whoop", tool: "session_today"),
            tool(Command.plan, String(localized: "This week's training plan"), server: "whoop", tool: "week_plan"),
            tool(Command.day, String(localized: "Summary of a day"), args: String(localized: "[dd/mm]"), server: "whoop", tool: "day_summary", params: ["date"]),
            tool("macros", String(localized: "Today's macros and calories"), server: "whoop", tool: "macros"),
            prompt(Command.week, String(localized: "Weekly review with tips"),
                   template: String(localized: "Review my training week (load, sleep, recovery) and give me three tips for the next one. {args}")),
            prompt(Command.calibrate, String(localized: "Recalibrate your targets"), args: String(localized: "<weight kg> [waist]"),
                   template: String(localized: "Recalibrate my calorie and macro targets with these measurements: {args}."), model: "claude-opus-5-5", effort: "high"),
            BotCommand(name: "whoop", description: String(localized: "Open WHOOP"), action: .init(type: "open", url: "https://app.whoop.com")),
            app(Command.barcode, String(localized: "Scan a food item"), .barcode),
            app(Command.guided, String(localized: "Voice-guided workout"), .voice),
            app("reset", String(localized: "New conversation"), .newConversation),
        ]
    }

    static var cobotCommands: [BotCommand] {
        [
            tool(Command.status, String(localized: "Status of the services on dev"), server: "github", tool: "services_status"),
            app("reset", String(localized: "New conversation"), .newConversation),
        ]
    }

    private static var voyagesV7: BotConfig {
        BotConfig(
            name: String(localized: "demo.bot.voyages.name", defaultValue: "Travel"), emoji: "✈️", color: "#E0EEFF",
            description: String(localized: "Flights, status, things to do"), agent: .claude,
            model: "claude-sonnet-5", effort: "medium",
            instructions: String(localized: "demo.bot.voyages.instructions", defaultValue: """
            You're Alex's travel assistant. Keep your answers short.
            Call flight_status before answering anything about a schedule.
            Always give the airport's local time.
            """),
            toolServers: ["travel", "web"], workdir: nil, permissionPolicy: .ask, voice: BotConfig.VoiceSettings(voiceId: "ara"),
            commands: voyagesCommands)
    }

    static func make() -> (bots: [Bot], versions: [String: [BotVersion]], conversations: [Conversation], messages: [String: [Message]]) {
        let now = Date()
        func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }

        let cobot = BotConfig(
            name: "Cobot", emoji: "🦊", color: "#FFE8D9", description: String(localized: "Personal assistant, full access to dev"), agent: .claude,
            model: "claude-opus-5-5", effort: "high",
            instructions: String(localized: "You're Cobot, Alex's assistant with full access to the dev machine. Keep it short and get things done."),
            toolServers: ["github", "web", "home"], workdir: "/home/alex", permissionPolicy: .auto, voice: nil,
            commands: cobotCommands)
        var coach = BotConfig(
            name: "Coach", emoji: "🏃", color: "#E3F6E8", description: String(localized: "Meals, workouts, WHOOP"), agent: .claude,
            model: "claude-opus-5-5", effort: "medium",
            instructions: String(localized: "You're Alex's sports coach. Check WHOOP before giving any advice."),
            toolServers: ["whoop", "web"], workdir: nil, permissionPolicy: .ask, voice: nil,
            commands: coachCommands)
        coach.toolRules = ["fitness/whoop_today": .allow, "nuo/gmail_send": .block]
        let voyagesV7 = Self.voyagesV7
        var voyagesDraft = voyagesV7
        voyagesDraft.instructions = String(localized: "demo.bot.voyages.draftInstructions", defaultValue: """
        You're Alex's travel assistant. Keep your answers short.
        For a flight, always show the ::flight card with the gate and seats.
        Call flight_status before answering anything about a schedule.
        Always give the airport's local time.
        """)

        var voyagesV6 = voyagesV7
        voyagesV6.model = "claude-opus-5-5"

        let voyagesVersions = [
            BotVersion(version: 7, config: voyagesV7, note: String(localized: "Airport local time"), publishedAt: ago(60 * 26)),
            BotVersion(version: 6, config: voyagesV6, note: String(localized: "Switched to Opus"), publishedAt: ago(60 * 24 * 5)),
            BotVersion(version: 5, config: voyagesV6, note: nil, publishedAt: ago(60 * 24 * 12)),
        ]

        let notes = BotConfig(
            name: String(localized: "demo.bot.notes.name", defaultValue: "Summaries"), emoji: "📝", color: "#FFF4D6",
            description: String(localized: "Writes meeting summaries, no tools"),
            agent: .claude, model: "claude-opus-5-5", effort: "medium",
            instructions: String(localized: "You write faithful summaries from transcripts. You have no tools."),
            toolServers: [], workdir: nil, permissionPolicy: .readonly, voice: nil, commands: [])
        let home = BotConfig(
            name: String(localized: "demo.bot.home.name", defaultValue: "Home"), emoji: "🏠", color: "#E4EEFB",
            description: String(localized: "Home Assistant: rooms, sensors, energy"), agent: .claude,
            model: "claude-sonnet-5", effort: "low",
            instructions: String(localized: "You're Alex's home assistant, connected to Home Assistant. Report the state of the house with cards and flag anything unusual."),
            toolServers: ["home"], workdir: nil, permissionPolicy: .ask, voice: nil,
            commands: [app("reset", String(localized: "New conversation"), .newConversation)])
        let homeBot = Bot(id: "home", published: BotVersion(version: 2, config: home, publishedAt: ago(60 * 24 * 6)), draft: nil,
                          createdAt: ago(60 * 24 * 15), updatedAt: ago(60 * 24 * 6), lastMessageAt: ago(50),
                          lastMessagePreview: String(localized: "All good at home, except the bathroom window."))
        let bots = [
            Bot(id: "6ec7defa-21f1-4f73-ab4f-1231a3a02997", slug: "comptes-rendus",
                published: BotVersion(version: 1, config: notes, publishedAt: ago(60 * 24)), draft: nil,
                createdAt: ago(60 * 24 * 2), updatedAt: ago(60 * 24), lastMessageAt: ago(60 * 9),
                lastMessagePreview: String(localized: "Summary: Client call with Julie Martin, Lyon trade show quote")),
            Bot(id: "cobot", published: BotVersion(version: 12, config: cobot, publishedAt: ago(60 * 48)), draft: nil,
                createdAt: ago(60 * 24 * 40), updatedAt: ago(60 * 48), lastMessageAt: ago(240),
                lastMessagePreview: String(localized: "I merged PR #23, the deployment is running.")),
            Bot(id: "voyages", published: voyagesVersions[0], draft: voyagesDraft,
                createdAt: ago(60 * 24 * 30), updatedAt: ago(30), lastMessageAt: ago(12),
                lastMessagePreview: String(localized: "TO8285 on Monday: on time, gate F32, boarding 13:55.")),
            Bot(id: "coach", published: BotVersion(version: 3, config: coach, publishedAt: ago(60 * 24 * 3)), draft: nil,
                createdAt: ago(60 * 24 * 20), updatedAt: ago(60 * 24 * 3), lastMessageAt: ago(95),
                lastMessagePreview: String(localized: "Today's workout: 6 × 800 m at 4:35/km")),
            homeBot,
        ]

        let conversations = [
            Conversation(id: "c-voyages-1", botId: "voyages", title: String(localized: "Monday's flight"), useDraft: false, context: ContextUsage(usedTokens: 164_000, maxTokens: 200_000, compactions: 1, updatedAt: ago(12)), createdAt: ago(14), updatedAt: ago(12)),
            Conversation(id: "c-voyages-2", botId: "voyages", title: String(localized: "Things to do in Lisbon"), useDraft: false, context: ContextUsage(usedTokens: 41_000, maxTokens: 200_000, compactions: 0, updatedAt: ago(60 * 24 * 2)), createdAt: ago(60 * 24 * 2), updatedAt: ago(60 * 24 * 2)),
            Conversation(id: "c-coach-2", botId: "coach", title: String(localized: "Dark chocolate"), useDraft: false, context: ContextUsage(usedTokens: 12_400, maxTokens: 200_000, compactions: 0, updatedAt: ago(7)), createdAt: ago(8), updatedAt: ago(7)),
            Conversation(id: "c-coach-1", botId: "coach", title: String(localized: "Today's workout"), useDraft: false, context: ContextUsage(usedTokens: 138_000, maxTokens: 200_000, compactions: 0, updatedAt: ago(95)), createdAt: ago(100), updatedAt: ago(95)),
            Conversation(id: "c-cobot-email", botId: "cobot", title: String(localized: "Julie's kitchen quote"), useDraft: false, context: ContextUsage(usedTokens: 18_200, maxTokens: 1_000_000, compactions: 0, updatedAt: ago(30)), createdAt: ago(32), updatedAt: ago(30)),
            Conversation(id: "c-cobot-1", botId: "cobot", title: String(localized: "Gateway deployment"), useDraft: false, context: ContextUsage(usedTokens: 412_000, maxTokens: 1_000_000, compactions: 2, updatedAt: ago(240)), createdAt: ago(250), updatedAt: ago(240)),
            Conversation(id: "c-cobot-mail", botId: "cobot", title: String(localized: "Unverified emails"), useDraft: false, createdAt: ago(55), updatedAt: ago(54)),
            Conversation(id: "c-home-1", botId: "home", title: String(localized: "House check"), useDraft: false, createdAt: ago(51), updatedAt: ago(50)),
            Conversation(id: "c-coach-meal", botId: "coach", title: String(localized: "Salmon poke bowl"), useDraft: false, createdAt: ago(131), updatedAt: ago(130)),
            Conversation(id: "c-coach-run", botId: "coach", title: String(localized: "Morning intervals"), useDraft: false, createdAt: ago(161), updatedAt: ago(160)),
            Conversation(id: "c-cobot-hook", botId: "cobot", title: String(localized: "Linear webhook"), useDraft: false, createdAt: ago(75), updatedAt: ago(74)),
        ]

        let barcode = DemoProducts.darkChocolate
        let productCard = #"::product {"barcode":"\#(barcode)","portion_g":20}"#

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let email = "::email " + (String(data: (try? encoder.encode(DemoDrafts.quote)) ?? Data(), encoding: .utf8) ?? "{}")

        let messages: [String: [Message]] = [
            "c-cobot-mail": DemoWakes.mail(at: ago(55), answeredAt: ago(54)),
            "c-cobot-hook": DemoWakes.hook(at: ago(75), answeredAt: ago(74)),
            "c-cobot-email": [
                Message(id: "m11", conversationId: "c-cobot-email", role: .user, text: String(localized: "Draft an email to Julie with the revised kitchen quote, and cc accounting."), createdAt: ago(32)),
                Message(
                    id: "m12", conversationId: "c-cobot-email", role: .assistant,
                    text: String(localized: "The draft is ready in Gmail, nothing has been sent. Review it, edit it if needed and send it from the card.") + "\n" + email,
                    steps: [ToolStep(toolCallId: "t8", title: "gmail_draft", kind: "other", status: .completed, durationMs: 1300)],
                    durationMs: 9000, stopReason: .endTurn, createdAt: ago(30)),
            ],
            "c-coach-run": [
                Message(id: "m15", conversationId: "c-coach-run", role: .user, text: String(localized: "How did this morning's session go?"), createdAt: ago(161)),
                Message(
                    id: "m16", conversationId: "c-coach-run", role: .assistant, text: DemoCards.session,
                    steps: [ToolStep(toolCallId: "t10", title: "whoop_workout today", kind: "fetch", status: .completed, durationMs: 900)],
                    durationMs: 4000, stopReason: .endTurn, createdAt: ago(160)),
            ],
            "c-coach-meal": [
                Message(id: "m17", conversationId: "c-coach-meal", role: .user, text: String(localized: "I had a salmon poke bowl for lunch."), createdAt: ago(131)),
                Message(
                    id: "m18", conversationId: "c-coach-meal", role: .assistant, text: DemoCards.meal,
                    steps: [
                        ToolStep(toolCallId: "t11", title: "log_food", kind: "execute", status: .completed, durationMs: 600),
                        ToolStep(toolCallId: "t12", title: "macros", kind: "fetch", status: .completed, durationMs: 300),
                    ],
                    durationMs: 4000, stopReason: .endTurn, createdAt: ago(130)),
            ],
            "c-home-1": [
                Message(id: "m13", conversationId: "c-home-1", role: .user, text: String(localized: "How's the house?"), createdAt: ago(51)),
                Message(
                    id: "m14", conversationId: "c-home-1", role: .assistant, text: DemoCards.house,
                    steps: [ToolStep(toolCallId: "t9", title: "home_assistant states --all", kind: "fetch", status: .completed, durationMs: 1100)],
                    durationMs: 5000, stopReason: .endTurn, createdAt: ago(50)),
            ],
            "c-voyages-1": [
                Message(id: "m1", conversationId: "c-voyages-1", role: .user, text: String(localized: "Is my Monday flight on time?"), createdAt: ago(13)),
                Message(
                    id: "m2", conversationId: "c-voyages-1", role: .assistant,
                    text: String(localized: "Yes, **TO8285 Rome → Paris** is on time. Boarding opens at 13:55.") + "\n" + flightCard(),
                    steps: [
                        ToolStep(toolCallId: "t1", title: "booking_lookup", kind: "fetch", status: .completed, durationMs: 2100),
                        ToolStep(toolCallId: "t2", title: "flight_status TO8285", kind: "fetch", status: .completed, durationMs: 3900),
                    ],
                    durationMs: 8000, stopReason: .endTurn, createdAt: ago(12)),
            ],
            "c-voyages-2": [
                Message(id: "m3", conversationId: "c-voyages-2", role: .user, text: String(localized: "What should I do in Lisbon on Sunday?"), createdAt: ago(60 * 24 * 2)),
                Message(id: "m4", conversationId: "c-voyages-2", role: .assistant, text: String(localized: "Three ideas: LX Factory in the morning, lunch in Belém, and sunset at the Miradouro da Senhora do Monte."), durationMs: 5000, stopReason: .endTurn, createdAt: ago(60 * 24 * 2)),
            ],
            "c-coach-1": [
                Message(id: "m5", conversationId: "c-coach-1", role: .user, text: String(localized: "What's today's workout?"), createdAt: ago(100)),
                Message(
                    id: "m6", conversationId: "c-coach-1", role: .assistant,
                    text: String(localized: "demo.seed.coachWorkout", defaultValue: """
                    Your recovery is at **71%**, so we keep the intervals:
                    - Warm-up, 15 min
                    - **6 × 800 m at 4:35/km**, 2 min recovery
                    - Cool-down, 10 min
                    ::chart {"title":"Recovery","type":"line","unit":"%","series":[{"name":"Recovery","points":[{"x":"Mon","y":54},{"x":"Tue","y":62},{"x":"Wed","y":48},{"x":"Thu","y":66},{"x":"Fri","y":71}]}]}
                    """),
                    steps: [ToolStep(toolCallId: "t3", title: "whoop_today", kind: "fetch", status: .completed, durationMs: 1400)],
                    durationMs: 6000, stopReason: .endTurn, createdAt: ago(95)),
            ],
            "c-coach-2": [
                Message(id: "m9", conversationId: "c-coach-2", role: .user, text: String(localized: "Barcode scanned: \(barcode)"), createdAt: ago(8)),
                Message(
                    id: "m10", conversationId: "c-coach-2", role: .assistant,
                    text: String(localized: "It's **Mira Extra Dark**, a dark chocolate at 70%.") + "\n" + productCard + "\n"
                        + String(localized: "The suggested serving is **20 g**, about 4 squares. How much did you have? I'll log it in today's macros."),
                    steps: [
                        ToolStep(toolCallId: "t6", title: "food_lookup \(barcode)", kind: "fetch", status: .completed, durationMs: 1200),
                        ToolStep(toolCallId: "t7", title: "macros", kind: "fetch", status: .completed, durationMs: 600),
                    ],
                    durationMs: 8000, stopReason: .endTurn, createdAt: ago(7)),
            ],
            "c-cobot-1": [
                Message(id: "m7", conversationId: "c-cobot-1", role: .user, text: String(localized: "Merge PR #23 and deploy"), createdAt: ago(250)),
                Message(
                    id: "m8", conversationId: "c-cobot-1", role: .assistant,
                    text: String(localized: "demo.seed.cobotDeploy", defaultValue: "I merged PR #23, the deployment is running.\n\n```bash\n./scripts/deploy-gateway.sh\n✓ build 41 s\n✓ restart nuo-gateway.service\n```\n::callout {\"style\":\"success\",\"title\":\"Deployed\",\"text\":\"The gateway is running v0.1.0.\"}"),
                    steps: [
                        ToolStep(toolCallId: "t4", title: "merge_pr #23", kind: "execute", status: .completed, durationMs: 2300),
                        ToolStep(toolCallId: "t5", title: "deploy-gateway.sh", kind: "execute", status: .completed, durationMs: 41000),
                    ],
                    durationMs: 47000, stopReason: .endTurn, createdAt: ago(240)),
            ],
        ]

        func published(_ id: String) -> [BotVersion] {
            bots.first { $0.id == id }?.published.map { [$0] } ?? []
        }
        return (bots, ["voyages": voyagesVersions, "cobot": published("cobot"), "coach": published("coach"), "home": published("home")], conversations, messages)
    }
}

// MARK: - Scheduled tasks

extension DemoSeed {
    struct ScheduleSeed {
        var tasks: [ScheduledTask]
        var runs: [String: [TaskRun]]
        var conversations: [Conversation]
        var messages: [String: [Message]]
    }

    static func schedules(now: Date = Date()) -> ScheduleSeed {
        let paris = TimeZone(identifier: "Europe/Paris") ?? .current
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = paris

        /// Last `count` past occurrences of a cron schedule, newest first.
        func past(_ expr: String, count: Int, before date: Date = now) -> [Date] {
            guard let spec = CronSpec(expr) else { return [] }
            var result: [Date] = []
            var day = calendar.startOfDay(for: date)
            for _ in 0..<400 where result.count < count {
                guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: day) else { break }
                var found: [Date] = []
                var cursor = day.addingTimeInterval(-60)
                while let next = spec.next(after: cursor, timeZone: paris), next < dayEnd {
                    if next < date { found.append(next) }
                    cursor = next
                }
                result.append(contentsOf: found.reversed())
                guard let previous = calendar.date(byAdding: .day, value: -1, to: day) else { break }
                day = previous
            }
            return Array(result.prefix(count))
        }

        func cron(_ expr: String) -> TaskSchedule { TaskSchedule(kind: "cron", expr: expr, timezone: "Europe/Paris", at: nil) }

        func run(_ id: String, task: String, conversation: String, at date: Date, seconds: Double, preview: String? = nil, error: String? = nil) -> TaskRun {
            TaskRun(id: id, taskId: task, conversationId: conversation, startedAt: date, endedAt: date.addingTimeInterval(seconds),
                    status: error == nil ? "ok" : "error", preview: preview, error: error)
        }

        let mealTitle = String(localized: "Log my meals")
        let mealPrompt = String(localized: "Ask me what I ate today and log the macros.")
        let rdvTitle = String(localized: "This week's appointments")
        let rdvPrompt = String(localized: "#gog my appointments this week, with the travel time to plan for.")

        let seanceTimes = past("0 7 * * 1-5", count: 5)
        let seancePreviews = [
            String(localized: "Recovery 71%: we keep the intervals, 6 × 800 m at 4:35/km, 2 min recovery."),
            String(localized: "Recovery 48%: 40 min easy run in zone 2, nothing more."),
            String(localized: "Recovery 66%: upper-body strength for 45 min, then 20 min on the bike."),
            String(localized: "Recovery 62%: 8 km tempo run at 4:55/km."),
            String(localized: "Recovery 54%: active rest, 20 min of mobility."),
        ]
        let seanceRuns = seanceTimes.enumerated().map { index, date in
            run("r-seance-\(index)", task: "t-seance", conversation: "c-coach-1", at: date, seconds: 38 + Double(index * 7), preview: seancePreviews[index % seancePreviews.count])
        }

        let rdvTimes = past("0 8 * * 1", count: 3)
        let rdvRuns = rdvTimes.enumerated().map { index, date in
            index == 2
                ? run("r-rdv-\(index)", task: "t-rdv", conversation: "c-cobot-rdv", at: date, seconds: 12, error: String(localized: "gog: Google token expired, run “gog auth” on dev."))
                : run("r-rdv-\(index)", task: "t-rdv", conversation: "c-cobot-rdv", at: date, seconds: 24,
                      preview: index == 0
                          ? String(localized: "4 appointments this week: Tuesday 10:00 dentist (25 min by metro), Thursday 14:30 Hangar check-in, Friday 19:00 family dinner.")
                          : String(localized: "3 appointments: Wednesday 9:30 bank, Thursday 18:00 squash, Saturday 11:00 car inspection."))
        }

        let mealTimes = past("0 21 * * *", count: 3, before: now.addingTimeInterval(-5 * 86400))
        let mealRuns = mealTimes.enumerated().map { index, date in
            run("r-repas-\(index)", task: "t-repas", conversation: "c-coach-repas-\(index)", at: date, seconds: 30,
                preview: String(localized: "What did you eat today? I'll log the macros as soon as you reply."))
        }

        var flightComponents = DateComponents(year: 2026, month: 10, day: 19, hour: 11, minute: 40)
        flightComponents.timeZone = paris
        let flightCheck = calendar.date(from: flightComponents) ?? now.addingTimeInterval(2 * 86400)

        func task(_ id: String, bot: String, title: String, prompt: String, schedule: TaskSchedule, enabled: Bool = true,
                  conversation: String, conversationId: String?, notify: Bool, createdBy: String = "user", runs: [TaskRun], createdDaysAgo: Double) -> ScheduledTask {
            ScheduledTask(
                id: id, botId: bot, title: title, prompt: prompt, schedule: schedule, enabled: enabled,
                conversation: conversation, conversationId: conversationId, notify: notify, createdBy: createdBy,
                nextRunAt: enabled ? ScheduleText.nextRun(schedule, after: now) : nil,
                lastRunAt: runs.first?.startedAt, lastStatus: runs.first?.status,
                createdAt: now.addingTimeInterval(-createdDaysAgo * 86400), updatedAt: now.addingTimeInterval(-createdDaysAgo * 43200))
        }

        let tasks = [
            task("t-seance", bot: "coach", title: String(localized: "Today's workout"),
                 prompt: String(localized: "Check my WHOOP recovery and give me today's workout, short and precise."),
                 schedule: cron("0 7 * * 1-5"), conversation: "dedicated", conversationId: "c-coach-1", notify: true,
                 runs: seanceRuns, createdDaysAgo: 18),
            task("t-repas", bot: "coach", title: mealTitle,
                 prompt: mealPrompt,
                 schedule: cron("0 21 * * *"), enabled: false, conversation: "new", conversationId: nil, notify: true,
                 runs: mealRuns, createdDaysAgo: 12),
            task("t-rdv", bot: "cobot", title: rdvTitle,
                 prompt: rdvPrompt,
                 schedule: cron("0 8 * * 1"), conversation: "dedicated", conversationId: "c-cobot-rdv", notify: true, createdBy: "bot",
                 runs: rdvRuns, createdDaysAgo: 22),
            task("t-to8285", bot: "voyages", title: String(localized: "TO8285 status"),
                 prompt: "/\(Command.flight) TO8285 19/10",
                 schedule: TaskSchedule(kind: "once", expr: nil, timezone: nil, at: flightCheck), conversation: "new", conversationId: nil, notify: true,
                 runs: [], createdDaysAgo: 1),
        ]

        func commandRuns(_ taskId: String, expr: String, count: Int, millis: Int, failing: Set<Int> = [], failure: (code: Int, output: String) = (1, "")) -> [TaskRun] {
            past(expr, count: count).enumerated().map { index, date in
                let failed = failing.contains(index)
                let output = failed ? failure.output : commandOutput(taskId: taskId, index: index)
                let duration = millis + (index * 137) % (millis / 2 + 1)
                return TaskRun(id: "r-\(taskId)-\(index)", taskId: taskId, conversationId: "", startedAt: date,
                               endedAt: date.addingTimeInterval(Double(duration) / 1000), status: failed ? "error" : "ok",
                               preview: output.split(separator: "\n").last.map(String.init), error: failed ? String(localized: "exit code \(failure.code)") : nil,
                               exitCode: failed ? failure.code : 0, output: output, durationMs: duration)
            }
        }

        func commandTask(_ id: String, bot: String, title: String, action: TaskAction, schedule: TaskSchedule, runs: [TaskRun], createdDaysAgo: Double) -> ScheduledTask {
            var t = task(id, bot: bot, title: title, prompt: "", schedule: schedule, conversation: "dedicated", conversationId: nil,
                         notify: action.notifyOn != "never", runs: runs, createdDaysAgo: createdDaysAgo)
            t.action = action
            return t
        }

        func command(_ command: String, cwd: String? = nil, envFile: String? = nil, env: [String: String]? = nil, timeoutSec: Int = TaskAction.defaultTimeoutSec, notifyOn: String = "failure") -> TaskAction {
            TaskAction(type: "command", command: command, cwd: cwd, envFile: envFile, env: env, timeoutSec: timeoutSec, notifyOn: notifyOn)
        }

        let raceBibRuns = commandRuns("t-race-bibs", expr: "*/10 * * * *", count: 8, millis: 2400)
        let cloudBudgetRuns = commandRuns("t-cloud-budget", expr: "*/15 * * * *", count: 8, millis: 3100)
        let apiWatchRuns = commandRuns("t-api-watch", expr: "*/15 * * * *", count: 8, millis: 1800, failing: [0, 1],
                                      failure: (2, String(localized: "demo.schedules.apiDown", defaultValue: "GET /api/health → 502 Bad Gateway (3 tries)\nalert sent: Lumen API prod is down")))
        let patrimoineRuns = commandRuns("t-patrimoine", expr: "10 8 * * *", count: 5, millis: 5200)
        let whoopRuns = commandRuns("t-whoop", expr: "0 */3 * * *", count: 6, millis: 14800)
        let commandTasks = [
            commandTask("t-race-bibs", bot: "cobot", title: String(localized: "Half marathon bibs"), action: command("~/bin/race-watch.py"),
                        schedule: cron("*/10 * * * *"), runs: raceBibRuns, createdDaysAgo: 3),
            commandTask("t-cloud-budget", bot: "cobot", title: "Cloud budget guard", action: command("~/bin/cloud-budget-guard.sh"),
                        schedule: cron("*/15 * * * *"), runs: cloudBudgetRuns, createdDaysAgo: 3),
            commandTask("t-api-watch", bot: "cobot", title: "Lumen API prod", action: command("~/bin/lumen-api-watch.py"),
                        schedule: cron("*/15 * * * *"), runs: apiWatchRuns, createdDaysAgo: 3),
            commandTask("t-patrimoine", bot: "cobot", title: String(localized: "Net worth sync"), action: command("~/bin/check-networth-sync.sh"),
                        schedule: cron("10 8 * * *"), runs: patrimoineRuns, createdDaysAgo: 3),
            commandTask("t-whoop", bot: "coach", title: String(localized: "WHOOP sync"),
                        action: command("bun run src/whoop/sync-once.ts", cwd: "~/projects/training",
                                        envFile: "~/projects/training/.env", env: ["NUO_COACH_BOT_ID": "coach"], timeoutSec: 900),
                        schedule: cron("0 */3 * * *"), runs: whoopRuns, createdDaysAgo: 3),
        ]

        var conversations = [
            Conversation(id: "c-cobot-rdv", botId: "cobot", title: rdvTitle, useDraft: false,
                         createdAt: rdvTimes.last ?? now, updatedAt: rdvTimes.first ?? now),
        ]
        var messages: [String: [Message]] = [
            "c-cobot-rdv": rdvRuns.reversed().flatMap { run in
                [
                    Message(id: "\(run.id)-u", conversationId: "c-cobot-rdv", role: .user, text: rdvPrompt, createdAt: run.startedAt),
                    Message(id: "\(run.id)-a", conversationId: "c-cobot-rdv", role: .assistant, text: run.preview ?? run.error ?? "",
                            durationMs: 24000, stopReason: .endTurn, createdAt: run.endedAt ?? run.startedAt),
                ]
            },
        ]
        for run in mealRuns {
            conversations.append(Conversation(id: run.conversationId, botId: "coach", title: mealTitle, useDraft: false, createdAt: run.startedAt, updatedAt: run.endedAt ?? run.startedAt))
            messages[run.conversationId] = [
                Message(id: "\(run.id)-u", conversationId: run.conversationId, role: .user, text: mealPrompt, createdAt: run.startedAt),
                Message(id: "\(run.id)-a", conversationId: run.conversationId, role: .assistant, text: run.preview ?? "", durationMs: 30000, stopReason: .endTurn, createdAt: run.endedAt ?? run.startedAt),
            ]
        }

        var runs = ["t-seance": seanceRuns, "t-rdv": rdvRuns, "t-repas": mealRuns]
        for (id, list) in [("t-race-bibs", raceBibRuns), ("t-cloud-budget", cloudBudgetRuns), ("t-api-watch", apiWatchRuns), ("t-patrimoine", patrimoineRuns), ("t-whoop", whoopRuns)] {
            runs[id] = list
        }
        return ScheduleSeed(tasks: tasks + commandTasks, runs: runs, conversations: conversations, messages: messages)
    }

    /// What the demo command tasks print, close to what such scripts print.
    static func commandOutput(taskId: String, index: Int = 0) -> String {
        switch taskId {
        case "t-race-bibs":
            let since = index == 0 ? String(localized: "No new bib in the last 10 min") : String(localized: "No new bib since the last check")
            return String(localized: "demo.schedules.raceWatch", defaultValue: "Riverside Half Marathon 2026: 3 waves tracked\nWave B (under 1:40): full") + "\n" + since
        case "t-cloud-budget":
            let euros = FloatingPointFormatStyle<Double>.Currency(code: "EUR")
            let spent = (3.12 + Double(index) * 0.04).formatted(euros)
            let budget = 20.0.formatted(euros)
            let share = 0.16.formatted(.percent)
            return String(localized: "Project nuo-home: \(spent) of \(budget) this month (\(share))\nNo unexpected billable API\nOK")
        case "t-api-watch":
            return String(localized: "demo.schedules.apiHealth", defaultValue: "GET /api/health → 200 in 182 ms\nworkers: 4/4 · queue: 0\nOK")
        case "t-patrimoine":
            return String(localized: "demo.schedules.networth", defaultValue: "Last sync: today 06:02\n7 accounts up to date, 0 failing\nOK")
        case "t-whoop":
            return String(localized: "demo.schedules.whoop", defaultValue: "Loading .env (4 variables)\nWHOOP: 2 cycles, 1 sleep, 1 workout imported\nCoach notified (recovery 68%)")
        default:
            return "OK"
        }
    }
}

// MARK: - Memory

extension DemoSeed {
    static func memories(now: Date = Date()) -> [String: BotMemory] {
        func lines(_ facts: [(daysAgo: Double, text: String)]) -> String {
            facts.map { "- \(MemoryDocument.day(now.addingTimeInterval(-$0.daysAgo * 86400))) \($0.text)" }.joined(separator: "\n") + "\n"
        }
        return [
            "cobot": BotMemory(content: lines([
                (41, String(localized: "Alex lives in Paris (9th), works at Helio Labs as a mobile engineer (Swift, Kotlin) and runs Lumen Studio on the side.")),
                (38, String(localized: "Prefers short, direct answers, no pleasantries.")),
                (30, String(localized: "Follows Formula 1: give a heads-up before race weekends and qualifying.")),
                (22, String(localized: "Brother Sam lives in Bordeaux; birthday on June 9.")),
                (12, String(localized: "Calls the parents on Sundays, late morning.")),
                (6, String(localized: "Dev machine: “dev” on the local network, reached over SSH.")),
                (1, String(localized: "Don't suggest meetings before 10:00 on weekdays.")),
            ]), updatedAt: now.addingTimeInterval(-2 * 3600)),
            "voyages": BotMemory(content: lines([
                (25, String(localized: "Prefers driving over the train for trips under 4 hours.")),
                (19, String(localized: "Window seat, toward the front of the plane if possible.")),
                (9, String(localized: "Frequent flyer card, Silver tier.")),
            ]), updatedAt: now.addingTimeInterval(-9 * 86400)),
            "coach": BotMemory(content: lines([
                (34, String(localized: "Usual breakfast: skyr, oats, banana, black coffee.")),
                (27, String(localized: "Training slots: 7:00 on weekdays, 10:00 on Saturdays, rest on Sundays.")),
                (20, String(localized: "Goal: a half marathon in under 1:35.")),
                (8, String(localized: "Left knee sensitive on downhills: avoid hill repeats.")),
                (0.2, String(localized: "Low WHOOP recovery (under 50%): zone 2 workouts only.")),
            ]), updatedAt: now.addingTimeInterval(-5 * 3600)),
        ]
    }
}
