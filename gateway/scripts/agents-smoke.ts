// Real end-to-end check of the agent runtimes: one tiny prompt per authenticated agent.
// Usage: bun scripts/agents-smoke.ts [agent...] [--model <id>] [--effort <e>] [--policy auto|ask|readonly] [--prompt <text>] [--cancel-after <ms>] [--resume] [--models]
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { AcpSession } from "../src/agents/acp";
import { allRuntimes } from "../src/agents/registry";
import type { AgentRuntime, RunEvent } from "../src/agents/types";
import type { PermissionPolicy } from "../src/protocol";

const argv = process.argv.slice(2);
const flag = (name: string) => {
  const i = argv.indexOf(name);
  if (i < 0) return undefined;
  const v = argv[i + 1];
  argv.splice(i, 2);
  return v;
};
const model = flag("--model");
const effort = flag("--effort");
const policy = (flag("--policy") ?? "auto") as PermissionPolicy;
const cancelAfter = Number(flag("--cancel-after")) || 0;
const promptText = flag("--prompt") ?? "Réponds uniquement OK";
const resume = argv.includes("--resume");
const listModels = argv.includes("--models");
const only = argv.filter((a) => !a.startsWith("--"));

function treeRssMb(pid: number | undefined): number | undefined {
  if (!pid || process.platform !== "linux") return undefined;
  const r = Bun.spawnSync(["ps", "-o", "rss=", "-g", String(pid)]);
  const kb = r.stdout
    .toString()
    .split("\n")
    .map((l) => Number(l.trim()) || 0)
    .reduce((a, b) => a + b, 0);
  return Math.round(kb / 1024);
}

async function turn(session: AcpSession, text: string, t0: number) {
  let out = "";
  const log = (e: RunEvent) => {
    const at = `${String(Date.now() - t0).padStart(6)}ms`;
    if (e.type === "text") out += e.text;
    else if (e.type === "thought") process.stdout.write(`  ${at} thought ${JSON.stringify(e.text.slice(0, 80))}\n`);
    else console.log(`  ${at} ${e.type} ${JSON.stringify(e)}`);
  };
  let rss: number | undefined;
  const sampler = setInterval(() => (rss = Math.max(rss ?? 0, treeRssMb(session.pid) ?? 0)), 500);
  const canceller = cancelAfter
    ? setTimeout(() => {
        console.log(`  ${Date.now() - t0}ms cancel`);
        void session.cancel();
      }, cancelAfter)
    : undefined;
  const r = await session.prompt(text, [], log, async (ask) => {
    console.log(`  permission asked: ${ask.title} ${JSON.stringify(ask.options)}`);
    return ask.options.find((o) => o.kind === "allow_once")?.id ?? ask.options[0]!.id;
  });
  clearInterval(sampler);
  clearTimeout(canceller);
  console.log(`  ${Date.now() - t0}ms stop=${r.stopReason}${r.error ? ` error=${r.error}` : ""}`);
  console.log(`  text=${JSON.stringify(out)}`);
  if (rss) console.log(`  peak RSS of the agent process tree during the turn: ${rss} MB`);
}

async function smoke(rt: AgentRuntime) {
  console.log(`\n=== ${rt.id}`);
  const st = await rt.status();
  console.log(`  status ${JSON.stringify(st)}`);
  if (listModels) console.log(`  models ${JSON.stringify(await rt.models())}`);
  if (!st.available || !st.authenticated) return;
  const dir = mkdtempSync(join(tmpdir(), `nuo-smoke-${rt.id}-`));
  const t0 = Date.now();
  let session: AcpSession | undefined;
  try {
    session = (await rt.start({ workdir: dir, model: model ?? "", effort, mcpServers: [], permissionPolicy: policy })) as AcpSession;
    console.log(`  ${Date.now() - t0}ms started session ${session.agentSessionId} ${JSON.stringify(session.currentSelection)} (idle RSS ${treeRssMb(session.pid) ?? "?"} MB)`);
    await turn(session, promptText, t0);
    if (resume) {
      const id = session.agentSessionId;
      await session.close();
      const t1 = Date.now();
      session = (await rt.start({
        workdir: dir,
        model: model ?? "",
        effort,
        mcpServers: [],
        permissionPolicy: policy,
        resumeId: id,
      })) as AcpSession;
      console.log(`  ${Date.now() - t1}ms resumed ${id} -> ${session.agentSessionId} (${session.agentSessionId === id ? "same" : "NEW"} session)`);
      await turn(session, "Répète exactement mon message précédent, sans rien d'autre", t1);
    }
  } catch (e) {
    console.log(`  FAILED after ${Date.now() - t0}ms: ${e instanceof Error ? e.message : e}`);
  } finally {
    await session?.close();
    rmSync(dir, { recursive: true, force: true });
  }
}

for (const rt of allRuntimes()) {
  if (only.length && !only.includes(rt.id)) continue;
  await smoke(rt);
}
process.exit(0);
