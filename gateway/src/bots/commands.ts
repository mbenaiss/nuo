import type { BotCommand, BotCommandAction, BotConfig } from "../protocol";
import type { ToolCatalog } from "./catalog";
import { SCAN_TOOL_NAMES } from "../scan/tools";

export const COMMAND_NAME_RE = /^[a-z0-9_]{1,24}$/;
const APP_ACTIONS = ["new_conversation", "barcode", "voice"] as const;
/** The gateway's own tools a `tool` command may call on every bot, without enabling a tool server. */
export const BUILTIN_TOOL_SERVER = "nuo";
export const BUILTIN_COMMAND_TOOLS: ReadonlySet<string> = SCAN_TOOL_NAMES;

const isObject = (v: unknown): v is Record<string, unknown> => !!v && typeof v === "object" && !Array.isArray(v);
const optString = (v: unknown) => v === undefined || typeof v === "string";

/** Returns the normalized commands, or pushes readable messages into `errors`. */
export function validateCommands(raw: unknown, toolServers: string[], catalog: ToolCatalog, errors: string[]): BotCommand[] | undefined {
  if (raw === undefined || raw === null) return undefined;
  if (!Array.isArray(raw)) {
    errors.push("commands must be an array");
    return undefined;
  }
  const out: BotCommand[] = [];
  const seen = new Set<string>();
  raw.forEach((c: unknown, i) => {
    const where = isObject(c) && typeof c.name === "string" ? `command /${c.name}` : `command #${i + 1}`;
    if (!isObject(c)) return void errors.push(`${where}: must be an object`);
    const name = typeof c.name === "string" ? c.name : "";
    if (!COMMAND_NAME_RE.test(name)) errors.push(`${where}: name must match [a-z0-9_] (1 to 24 characters, no slash)`);
    else if (seen.has(name)) errors.push(`${where}: duplicate command name`);
    seen.add(name);
    if (typeof c.description !== "string" || !c.description.trim()) errors.push(`${where}: description is required`);
    if (!optString(c.args)) errors.push(`${where}: args must be a string`);
    const action = validateAction(c.action, toolServers, catalog, where, errors);
    if (!action) return;
    out.push({
      name,
      description: typeof c.description === "string" ? c.description.trim() : "",
      ...(typeof c.args === "string" && c.args.trim() ? { args: c.args.trim() } : {}),
      action,
    });
  });
  return out;
}

function validateAction(a: unknown, toolServers: string[], catalog: ToolCatalog, where: string, errors: string[]): BotCommandAction | undefined {
  if (!isObject(a)) return void errors.push(`${where}: action is required`);
  const before = errors.length;
  switch (a.type) {
    case "tool": {
      const server = typeof a.server === "string" ? a.server : "";
      const tool = typeof a.tool === "string" ? a.tool : "";
      if (server === BUILTIN_TOOL_SERVER) {
        if (!BUILTIN_COMMAND_TOOLS.has(tool)) errors.push(`${where}: tool "${tool}" is not one of the gateway's tools (${[...BUILTIN_COMMAND_TOOLS].join(", ")})`);
      } else if (!toolServers.includes(server)) errors.push(`${where}: tool server "${server}" is not enabled on this bot`);
      else if (!catalog.list().find((s) => s.id === server)?.tools.includes(tool)) errors.push(`${where}: tool "${tool}" is not listed for server "${server}"`);
      if (a.params !== undefined && (!Array.isArray(a.params) || a.params.some((p) => typeof p !== "string" || !p))) {
        errors.push(`${where}: params must be an array of parameter names`);
      }
      if (a.fixedArgs !== undefined && !isObject(a.fixedArgs)) errors.push(`${where}: fixedArgs must be an object`);
      if (errors.length > before) return undefined;
      return {
        type: "tool",
        server,
        tool,
        ...(Array.isArray(a.params) && a.params.length ? { params: a.params as string[] } : {}),
        ...(isObject(a.fixedArgs) && Object.keys(a.fixedArgs).length ? { fixedArgs: a.fixedArgs } : {}),
      };
    }
    case "prompt":
      if (typeof a.template !== "string" || !a.template.trim()) errors.push(`${where}: template is required`);
      if (!optString(a.model) || !optString(a.effort)) errors.push(`${where}: model and effort must be strings`);
      if (errors.length > before) return undefined;
      return {
        type: "prompt",
        template: a.template as string,
        ...(typeof a.model === "string" && a.model.trim() ? { model: a.model.trim() } : {}),
        ...(typeof a.effort === "string" && a.effort.trim() ? { effort: a.effort.trim() } : {}),
      };
    case "open":
      if (typeof a.url !== "string" || !/^https?:\/\/\S+$/.test(a.url)) return void errors.push(`${where}: url must be an http(s) URL`);
      return { type: "open", url: a.url };
    case "app":
      if (!APP_ACTIONS.includes(a.action as (typeof APP_ACTIONS)[number])) return void errors.push(`${where}: app action must be one of ${APP_ACTIONS.join(", ")}`);
      return { type: "app", action: a.action as (typeof APP_ACTIONS)[number] };
    default:
      return void errors.push(`${where}: action type must be tool, prompt, open or app`);
  }
}

export interface ParsedCommand {
  command: BotCommand;
  args: string;
}

/** Matches "/name args…" against the bot's commands; anything else goes to the agent unchanged. */
export function parseCommand(text: string, config: BotConfig | undefined): ParsedCommand | undefined {
  const m = /^\s*\/([a-z0-9_]+)(?:\s+([\s\S]*))?$/.exec(text);
  if (!m || !config?.commands?.length) return undefined;
  const command = config.commands.find((c) => c.name === m[1]);
  return command ? { command, args: (m[2] ?? "").trim() } : undefined;
}

/** Positional words fill `params` in order, the last one takes the remainder; `fixedArgs` always win. */
export function toolArguments(params: string[] | undefined, fixedArgs: Record<string, unknown> | undefined, args: string): Record<string, unknown> {
  const out: Record<string, unknown> = {};
  const words = args.split(/\s+/).filter(Boolean);
  const names = params ?? [];
  names.forEach((name, i) => {
    const value = i === names.length - 1 ? words.slice(i).join(" ") : words[i];
    if (value) out[name] = value;
  });
  return { ...out, ...(fixedArgs ?? {}) };
}

export function expandTemplate(template: string, args: string): string {
  return template.replaceAll("{args}", args);
}
