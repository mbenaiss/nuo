import { existsSync, mkdirSync, readFileSync, renameSync, rmSync } from "node:fs";
import { join } from "node:path";
import type { Layout } from "../paths";
import type { Bot, BotConfig, BotMemory, PermissionPolicy, ToolRule } from "../protocol";
import type { AgentDirectory } from "../runner/runtimes";
import type { Store } from "../store/store";
import type { ToolCatalog } from "./catalog";
import { validateCommands } from "./commands";
import { prepareWorkspace, type BrowserAccess, type Workspace } from "./instructions";
import { MemoryStore } from "./memory";
import { languageName, t } from "../i18n/language";
import { isToolRuleKey, TOOL_RULES_MAX, toolRuleError, validateToolRules } from "./tool-rules";

export class HttpError extends Error {
  constructor(
    readonly status: number,
    message: string,
  ) {
    super(message);
  }
}

const POLICIES: PermissionPolicy[] = ["ask", "auto", "readonly"];

export class BotService {
  readonly memory: MemoryStore;
  /** Told after every change of a bot's published config, so the scheduler keeps its proposals task in step. */
  onPublished?: (botId: string) => void;

  constructor(
    private store: Store,
    private catalog: ToolCatalog,
    private agents: AgentDirectory,
    private layout: Pick<Layout, "bots" | "instructions" | "memory"> & Partial<Pick<Layout, "home" | "nuo" | "dataDb" | "docs" | "dashboards">>,
    /** Profiles other than the owner: agents run as another Linux user, without the owner's data paths or folders. */
    private restricted = false,
    private browser?: BrowserAccess,
  ) {
    this.memory = new MemoryStore(layout.memory);
  }

  private slug(botId: string): string {
    const slug = this.store.botSlug(botId);
    if (!slug) throw new HttpError(404, "bot not found");
    return slug;
  }

  workspace(botId: string): Workspace {
    const slug = this.slug(botId);
    const { home, nuo, dataDb, docs, dashboards } = this.layout;
    const app = nuo ?? home;
    const data = !this.restricted && app && dataDb && docs && dashboards ? { home: app, db: dataDb, docs, dashboards } : undefined;
    return {
      slug,
      botDir: join(this.layout.bots, slug),
      instructionsPath: join(this.layout.instructions, `${slug}.md`),
      ...(data ? { data } : {}),
      ...(this.browser ? { browser: this.browser } : {}),
      ...(this.restricted ? { shared: true } : {}),
    };
  }

  /**
   * Where the gateway writes files for the bot's agent. A restricted profile's agent can write in its bot folder,
   * so the gateway writes outside it (it would otherwise follow links the agent planted).
   */
  attachmentsRoot(botId: string): string {
    const slug = this.slug(botId);
    return this.restricted && this.layout.home ? join(this.layout.home, "inbox", slug) : join(this.layout.bots, slug);
  }

  botDir(botId: string) {
    return this.workspace(botId).botDir;
  }

  /**
   * A relay session's working folder, empty: never under the bot's folder, whose CLAUDE.md holds the memory (Claude
   * Code reads every parent's), and in the gateway's instructions tree, where no agent of a profile can plant settings.
   */
  relayDir(botId: string): string {
    const dir = join(this.layout.instructions, "relay", this.slug(botId));
    mkdirSync(dir, { recursive: true });
    return dir;
  }

  readMemory(botId: string): BotMemory {
    return this.memory.read(this.slug(botId));
  }

  writeMemory(botId: string, content: unknown): BotMemory {
    return this.memory.write(this.slug(botId), content);
  }

  addMemory(botId: string, fact: unknown): BotMemory {
    return this.memory.add(this.slug(botId), fact);
  }

  /** Folders named after the bot id (layout before slugs) become slug folders; nothing is overwritten. */
  migrateFolders(onMoved?: (from: string, to: string) => void) {
    for (const { id, slug } of this.store.botSlugs()) {
      const from = join(this.layout.bots, id);
      const to = join(this.layout.bots, slug);
      if (id === slug || !existsSync(from)) continue;
      if (existsSync(to)) {
        console.warn(`[bots] both ${from} and ${to} exist; leaving ${from} in place`);
        continue;
      }
      renameSync(from, to);
      console.log(`[bots] moved bots/${id} to bots/${slug}`);
      try {
        onMoved?.(from, to);
      } catch (e) {
        console.warn(`[bots] ${slug}: ${(e as Error)?.message ?? e}`);
      }
    }
  }

  /** Every bot gets the gateway's current rules as soon as it starts, not only at the bot's next session. */
  async refreshInstructions(): Promise<void> {
    for (const bot of this.store.bots()) {
      const config = bot.published?.config;
      if (!config) continue;
      try {
        await prepareWorkspace(this.workspace(bot.id), config, this.readMemory(bot.id).content, languageName(this.store.userLanguages()[0]));
      } catch (e) {
        console.warn(`[bots] instructions of ${bot.id}: ${(e as Error)?.message ?? e}`);
      }
    }
  }

  get(id: string): Bot {
    const bot = this.store.bot(id);
    if (!bot) throw new HttpError(404, "bot not found");
    return bot;
  }

  validate(config: unknown): BotConfig {
    if (!config || typeof config !== "object") throw new HttpError(400, "invalid bot configuration");
    const c = config as Partial<BotConfig>;
    const errors: string[] = [];
    const name = typeof c.name === "string" ? c.name.trim() : "";
    if (name.length < 1 || name.length > 40) errors.push("name must be 1 to 40 characters");
    if (!c.agent || !this.agents.runtimes.get(c.agent)) errors.push(`unknown agent "${c.agent ?? ""}"`);
    if (typeof c.model !== "string" || !c.model.trim()) errors.push("model is required");
    if (typeof c.instructions !== "string") errors.push("instructions must be a string");
    const tools = Array.isArray(c.toolServers) ? c.toolServers : [];
    if (c.toolServers !== undefined && !Array.isArray(c.toolServers)) errors.push("toolServers must be an array");
    const missing = tools.filter((t) => !this.catalog.has(t));
    if (missing.length) errors.push(`unknown tool servers: ${missing.join(", ")}`);
    if (c.permissionPolicy && !POLICIES.includes(c.permissionPolicy)) errors.push(`permissionPolicy must be one of ${POLICIES.join(", ")}`);
    if (c.workdir && !c.workdir.startsWith("/")) errors.push("workdir must be an absolute path");
    if (c.workdir && this.restricted) errors.push("workdir is not available for this profile");
    if (c.proactive !== undefined && typeof c.proactive !== "boolean") errors.push("proactive must be a boolean");
    if (c.overview !== undefined && typeof c.overview !== "boolean") errors.push("overview must be a boolean");
    if (c.noTools !== undefined && typeof c.noTools !== "boolean") errors.push("noTools must be a boolean");
    const language = typeof c.language === "string" ? c.language.trim() : "";
    if (c.language !== undefined && (typeof c.language !== "string" || language.length > 40)) errors.push("language must be a language name of at most 40 characters");
    const commands = validateCommands(c.commands, tools, this.catalog, errors);
    const toolRules = validateToolRules(c.toolRules, errors);
    if (c.noTools === true) {
      if (tools.length) errors.push("a bot without tools cannot have toolServers");
      if (c.overview) errors.push("a bot without tools cannot see every bot (overview)");
      if (commands?.some((cmd) => cmd.action.type === "tool")) errors.push("a bot without tools cannot have tool commands");
      const runtime = c.agent ? this.agents.runtimes.get(c.agent) : undefined;
      if (runtime && !runtime.toolless) errors.push(`${runtime.name} cannot run without tools`);
    }
    if (errors.length) throw new HttpError(400, errors.join("; "));
    return {
      name,
      emoji: c.emoji || "🤖",
      color: c.color || "#E0EEFF",
      description: c.description ?? "",
      agent: c.agent!,
      model: c.model!.trim(),
      ...(c.effort ? { effort: c.effort } : {}),
      instructions: c.instructions!,
      toolServers: tools,
      ...(c.workdir ? { workdir: c.workdir } : {}),
      permissionPolicy: c.permissionPolicy ?? "ask",
      ...(c.voice ? { voice: c.voice } : {}),
      ...(commands?.length ? { commands } : {}),
      ...(c.proactive ? { proactive: true } : {}),
      ...(c.overview ? { overview: true } : {}),
      ...(c.noTools ? { noTools: true } : {}),
      ...(language ? { language } : {}),
      ...(toolRules ? { toolRules } : {}),
    };
  }

  async create(name: unknown, fromBotId?: string): Promise<Bot> {
    const trimmed = typeof name === "string" ? name.trim() : "";
    if (trimmed.length < 1 || trimmed.length > 40) throw new HttpError(400, "name must be 1 to 40 characters");
    let draft: BotConfig;
    if (fromBotId) {
      const src = this.get(fromBotId);
      const base = src.draft ?? src.published?.config;
      if (!base) throw new HttpError(400, "source bot has no configuration");
      draft = { ...structuredClone(base), name: trimmed };
    } else {
      const agent = this.agents.runtimes.all()[0]?.id ?? "claude";
      draft = {
        name: trimmed,
        emoji: "🤖",
        color: "#E0EEFF",
        description: "",
        agent,
        model: await this.agents.defaultModel(agent),
        instructions: "",
        toolServers: [],
        // Another profile's agents run as its own sandboxed Linux user, so they act without asking at every step.
        permissionPolicy: this.restricted ? "auto" : "ask",
      };
    }
    return this.get(this.store.createBot(draft, trimmed));
  }

  /**
   * An app that does not know `noTools` sends a draft without it: only `setNoTools` changes it. Tool rules too: an
   * editor opened before a rule was added or removed must not undo it.
   */
  saveDraft(id: string, config: unknown): Bot {
    const bot = this.get(id);
    const kept = config && typeof config === "object" ? { ...config, noTools: hasNoTools(bot), toolRules: currentToolRules(bot) } : config;
    this.store.setDraft(id, this.validate(kept));
    return this.get(id);
  }

  discardDraft(id: string): Bot {
    const bot = this.get(id);
    if (!bot.published) throw new HttpError(400, "cannot discard the draft of a bot that was never published");
    this.store.setDraft(id, undefined);
    return this.get(id);
  }

  publish(id: string, note?: string): Bot {
    const bot = this.get(id);
    if (!bot.draft) throw new HttpError(400, "nothing to publish: the bot has no draft");
    this.store.publish(id, this.validate(bot.draft), note, true);
    this.onPublished?.(id);
    return this.get(id);
  }

  /** Switching permissions from a chat must not publish an unrelated pending draft, so both are updated in place. */
  setPermissions(id: string, policy: unknown): Bot {
    const bot = this.get(id);
    if (!POLICIES.includes(policy as PermissionPolicy)) throw new HttpError(400, `permissionPolicy must be one of ${POLICIES.join(", ")}`);
    const p = policy as PermissionPolicy;
    if (bot.published && bot.published.config.permissionPolicy !== p) {
      this.store.publish(id, { ...bot.published.config, permissionPolicy: p }, `Permissions : ${p}`, false);
      this.onPublished?.(id);
    }
    if (bot.draft) this.store.setDraft(id, { ...bot.draft, permissionPolicy: p });
    return this.get(id);
  }

  /** Like the permissions, both the published version and the draft change in place, without publishing the draft. */
  setNoTools(id: string, value: unknown): Bot {
    const bot = this.get(id);
    if (typeof value !== "boolean") throw new HttpError(400, "noTools must be a boolean");
    const published = bot.published && !!bot.published.config.noTools !== value ? this.validate({ ...bot.published.config, noTools: value }) : undefined;
    const draft = bot.draft ? this.validate({ ...bot.draft, noTools: value }) : undefined;
    if (published) {
      this.store.publish(id, published, `Sans outil : ${value ? "oui" : "non"}`, false);
      this.onPublished?.(id);
    }
    if (draft) this.store.setDraft(id, draft);
    return this.get(id);
  }

  toolRules(id: string): { toolRules: Record<string, ToolRule> } {
    return { toolRules: currentToolRules(this.get(id)) ?? {} };
  }

  /** Keeps (or, with no rule, forgets) what the user decided for a tool; like the permissions, in place on both configs. */
  setToolRule(id: string, key: string, rule: ToolRule | undefined): Bot {
    const bot = this.get(id);
    const error = rule === undefined ? (isToolRuleKey(key) ? undefined : `invalid tool rule key "${key.slice(0, 80)}"`) : toolRuleError(key, rule);
    if (error) throw new HttpError(400, error);
    const apply = (config: BotConfig): BotConfig | undefined => {
      if (config.toolRules?.[key] === rule) return undefined;
      const { toolRules: rules, ...rest } = config;
      const next = { ...rules };
      if (rule) next[key] = rule;
      else delete next[key];
      if (Object.keys(next).length > TOOL_RULES_MAX) throw new HttpError(400, `toolRules holds at most ${TOOL_RULES_MAX} tools`);
      return Object.keys(next).length ? { ...rest, toolRules: next } : rest;
    };
    const published = bot.published ? apply(bot.published.config) : undefined;
    const draft = bot.draft ? apply(bot.draft) : undefined;
    if (published) {
      this.store.publish(id, published, t(rule === "allow" ? "bots.toolRuleAllowed" : rule === "block" ? "bots.toolRuleBlocked" : "bots.toolRuleRemoved", { tool: key }, this.store.uiLanguage()), false);
      this.onPublished?.(id);
    }
    if (draft) this.store.setDraft(id, draft);
    return this.get(id);
  }

  rollback(id: string, version: unknown): Bot {
    const bot = this.get(id);
    const v = typeof version === "number" ? this.store.version(id, version) : undefined;
    if (!v) throw new HttpError(404, `version ${version} not found`);
    const { noTools: _old, toolRules: _oldRules, ...config } = v.config;
    const toolRules = currentToolRules(bot);
    this.store.publish(id, { ...config, ...(hasNoTools(bot) ? { noTools: true } : {}), ...(toolRules ? { toolRules } : {}) }, `Rollback to v${v.version}`, false);
    this.onPublished?.(id);
    return this.get(id);
  }

  /** Memory goes with the bot: a new bot reusing the slug must not inherit it. */
  delete(id: string) {
    const ws = this.workspace(id);
    if (!this.store.deleteBot(id)) throw new HttpError(404, "bot not found");
    rmSync(ws.botDir, { recursive: true, force: true });
    if (this.restricted && this.layout.home) rmSync(join(this.layout.home, "inbox", ws.slug), { recursive: true, force: true });
    rmSync(ws.instructionsPath, { force: true });
    rmSync(join(this.layout.memory, ws.slug), { recursive: true, force: true });
  }

  /** Seeds bots once, on the very first start; a user deleting every bot must not resurrect them. */
  seed(path: string) {
    if (this.store.getMeta("seeded") || this.store.botCount() > 0 || !existsSync(path)) return;
    const entries = JSON.parse(readFileSync(path, "utf8")) as { config: BotConfig }[];
    for (const { config } of entries) {
      try {
        this.validate(config);
      } catch (e) {
        console.warn(`[seed] ${config.name}: ${(e as Error).message}`);
      }
      const id = this.store.createBot(undefined, config.name);
      this.store.publish(id, { ...config, toolServers: config.toolServers ?? [], permissionPolicy: config.permissionPolicy ?? "ask" }, "Seed", true);
    }
    this.store.setMeta("seeded", new Date().toISOString());
    console.log(`[seed] created ${entries.length} bots`);
  }
}

/** The bot as it runs now, or as its draft says when it was never published. */
function hasNoTools(bot: Bot): boolean {
  return !!(bot.published?.config ?? bot.draft)?.noTools;
}

function currentToolRules(bot: Bot): Record<string, ToolRule> | undefined {
  return (bot.published?.config ?? bot.draft)?.toolRules;
}
