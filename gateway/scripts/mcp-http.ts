/**
 * Bridges a stdio MCP client to an MCP server that speaks Streamable HTTP.
 *
 * Bots launch their tool servers as processes (see src/bots/catalog.ts), so a server that only listens on HTTP —
 * Forma's, on another machine — needs this in between. One line of JSON-RPC in, one line out.
 *
 * Environment: MCP_URL, and the bearer token either in MCP_TOKEN or in the variable MCP_TOKEN_VAR names (so a
 * tool server can take it straight from ~/.secrets/nuo.env under its own name). MCP_ADDRESS is the host or IP
 * to connect to when the name in MCP_URL cannot be resolved here.
 */

export interface BridgeOptions {
  url: string;
  token?: string;
  /**
   * Where to connect, when it is not what MCP_URL names: `dev` asks the router for its names and the router does
   * not know the home ones. The certificate is still checked against the name, which travels as Host and as the
   * TLS server name, so this is a route around the resolver and not around TLS.
   */
  address?: string;
  /** Injected in tests. */
  fetch?: typeof globalThis.fetch;
}

const PARSE_ERROR = -32700;
const INTERNAL_ERROR = -32603;

export function createBridge(opts: BridgeOptions) {
  const call = opts.fetch ?? globalThis.fetch;
  const { url, extra } = endpoint(opts.url, opts.address);
  // The server may hand out a session to carry on the same conversation; stateless servers never do.
  let session: string | undefined;

  const failure = (id: unknown, code: number, message: string) =>
    JSON.stringify({ jsonrpc: "2.0", id: id ?? null, error: { code, message } });

  /** Answers one client message, or null when none is owed (a notification). */
  async function handle(line: string): Promise<string | null> {
    let id: unknown;
    try {
      const message = JSON.parse(line);
      id = Array.isArray(message) ? undefined : message?.id;
      // A notification expects no answer, so a failure to deliver it must not invent one.
      const notification = id === undefined || id === null;
      const headers: Record<string, string> = {
        "content-type": "application/json",
        accept: "application/json, text/event-stream",
      };
      if (opts.token) headers.authorization = `Bearer ${opts.token}`;
      if (session) headers["mcp-session-id"] = session;
      Object.assign(headers, extra.headers);

      const res = await call(url, { method: "POST", headers, body: line, ...extra.init });
      const given = res.headers.get("mcp-session-id");
      if (given) session = given;
      const body = await res.text();
      if (!res.ok) {
        if (notification) return null;
        return failure(id, INTERNAL_ERROR, `${opts.url} answered ${res.status}: ${body.slice(0, 200)}`);
      }
      const payload = (res.headers.get("content-type") ?? "").includes("text/event-stream") ? eventData(body) : body.trim();
      if (!payload) return null;
      return payload;
    } catch (error) {
      const message = error instanceof SyntaxError ? "the client sent invalid JSON" : String((error as Error)?.message ?? error);
      return failure(id, error instanceof SyntaxError ? PARSE_ERROR : INTERNAL_ERROR, message);
    }
  }

  return { handle };
}

/** Where the request really goes, and what has to travel with it for the server to recognise itself. */
export function endpoint(target: string, address?: string) {
  if (!address) return { url: target, extra: { headers: {} as Record<string, string>, init: {} } };
  const asked = new URL(target);
  const name = asked.hostname;
  asked.hostname = address;
  return {
    url: asked.toString(),
    extra: { headers: { host: name }, init: { tls: { serverName: name } } },
  };
}

/** The last `data:` payload of a server-sent-events answer, which is where the JSON-RPC response is. */
export function eventData(body: string): string {
  const lines = body.split(/\r?\n/).filter((line) => line.startsWith("data:"));
  return lines.length ? lines[lines.length - 1]!.slice(5).trim() : "";
}

export function tokenFromEnvironment(env: Record<string, string | undefined>): string | undefined {
  if (env.MCP_TOKEN) return env.MCP_TOKEN;
  const named = env.MCP_TOKEN_VAR;
  return named ? env[named] : undefined;
}

async function main() {
  const url = process.env.MCP_URL;
  if (!url) {
    console.error("mcp-http: MCP_URL is not set");
    process.exit(2);
  }
  const bridge = createBridge({
    url, token: tokenFromEnvironment(process.env), address: process.env.MCP_ADDRESS || undefined,
  });
  const decoder = new TextDecoder();
  let pending = "";
  for await (const chunk of Bun.stdin.stream()) {
    pending += decoder.decode(chunk, { stream: true });
    let cut = pending.indexOf("\n");
    while (cut >= 0) {
      const line = pending.slice(0, cut).trim();
      pending = pending.slice(cut + 1);
      cut = pending.indexOf("\n");
      if (!line) continue;
      // Answers go out in the order the client asked, which is what a stdio client expects.
      const answer = await bridge.handle(line);
      if (answer) await Bun.write(Bun.stdout, answer + "\n");
    }
  }
}

if (import.meta.main) await main();
