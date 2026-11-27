// Stand-in for `agy --print … --output-format stream-json`, driven by the prompt text.
import { appendFileSync } from "node:fs";

const args = process.argv.slice(2);
const prompt = args[args.indexOf("--print") + 1] ?? "";
const resumed = args.includes("--conversation") ? args[args.indexOf("--conversation") + 1] : undefined;
if (process.env.FAKE_AGY_ARGS) appendFileSync(process.env.FAKE_AGY_ARGS, JSON.stringify(args) + "\n");

const conv = resumed ?? "conv-1";
const out = (o: unknown) => process.stdout.write(JSON.stringify(o) + "\n");
const step = (s: Record<string, unknown>) => out({ event: "step_update", step_update: { conversation_id: conv, ...s } });

out({ event: "init", conversation_id: conv, init: { cwd: process.cwd(), tools: ["run_command"], permission_mode: "request-review" } });
step({ step_index: 0, state: "DONE", step_type: "user_input" });

if (prompt === "auth") {
  process.stderr.write("Error: authentication required. Run 'agy' to log in.\n");
  process.exit(1);
}
if (prompt === "hang") {
  await new Promise(() => {});
}
if (prompt === "long-command") {
  // 76 characters, then a runner emoji whose two halves sit on either side of the 77-character cut.
  const command = `${"grep -rn 'Sortie Z2' ~/Documents/entrainements/2026/novembre/ | sort ".padEnd(76, "-")}🏃 | head -20`;
  step({ step_index: 1, state: "ACTIVE", step_type: "tool", tool_name: "run_command", tool_info: { name: "run_command", parameters: { CommandLine: command } } });
  step({ step_index: 1, state: "DONE", step_type: "tool", tool_name: "run_command", tool_info: { name: "run_command", output: "" } });
}
if (prompt === "tool") {
  step({ step_index: 1, state: "ACTIVE", step_type: "tool", tool_name: "run_command", tool_info: { name: "run_command", parameters: { CommandLine: "ls" } } });
  step({ step_index: 1, state: "DONE", step_type: "tool", tool_name: "run_command", tool_info: { name: "run_command", output: "a\n" } });
  step({ step_index: 2, state: "ERROR", step_type: "tool", tool_name: "view_file", tool_info: { name: "view_file", parameters: { AbsolutePath: "/x" }, error: { type: "x", message: "nope" } } });
}
if (prompt === "fail") {
  out({ event: "result", result: { conversation_id: conv, status: "ERROR", error: "quota exceeded" } });
  process.exit(3);
}
if (prompt === "silent") {
  out({ event: "result", result: { conversation_id: conv, status: "SUCCESS", response: "Only in result" } });
  process.exit(0);
}
step({ step_index: 3, state: "ACTIVE", step_type: "agent_response", text_delta: "Hel" });
step({ step_index: 3, state: "ACTIVE", step_type: "agent_response", text_delta: "lo" });
step({ step_index: 3, state: "DONE", step_type: "agent_response", usage: { input_tokens: 1000, output_tokens: 20, cache_read_tokens: 800, total_tokens: 1020 } });
out({ event: "result", result: { conversation_id: conv, status: "SUCCESS", response: "Hello", usage: { input_tokens: 5000, output_tokens: 90, total_tokens: 5090 } } });
