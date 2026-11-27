import { describe, expect, test } from "bun:test";
import { createBridge, endpoint, eventData, tokenFromEnvironment } from "../scripts/mcp-http";

const URL = "https://printer.nuo.example.com/mcp";

function recorder(reply: (body: string) => Response) {
  const calls: { body: string; headers: Record<string, string> }[] = [];
  const fetch = (async (_url: string | URL | Request, init?: RequestInit) => {
    const headers = Object.fromEntries(Object.entries((init?.headers ?? {}) as Record<string, string>));
    const body = String(init?.body ?? "");
    calls.push({ body, headers });
    return reply(body);
  }) as unknown as typeof globalThis.fetch;
  return { calls, fetch };
}

const ok = (payload: unknown) =>
  new Response(JSON.stringify(payload), { status: 200, headers: { "content-type": "application/json" } });

describe("mcp-http bridge", () => {
  test("passes a request on and gives the server's answer back", async () => {
    const tools = { jsonrpc: "2.0", id: 1, result: { tools: [{ name: "create_design" }] } };
    const { calls, fetch } = recorder(() => ok(tools));
    const bridge = createBridge({ url: URL, token: "jeton-agent", fetch });

    const answer = await bridge.handle('{"jsonrpc":"2.0","id":1,"method":"tools/list"}');

    expect(JSON.parse(answer!)).toEqual(tools);
    expect(calls[0]!.headers.authorization).toBe("Bearer jeton-agent");
    expect(calls[0]!.headers.accept).toContain("text/event-stream");
  });

  test("reads the answer out of a server-sent-events body", async () => {
    const stream = 'event: message\ndata: {"jsonrpc":"2.0","id":7,"result":{"ok":true}}\n\n';
    const { fetch } = recorder(
      () => new Response(stream, { status: 200, headers: { "content-type": "text/event-stream" } }));
    const bridge = createBridge({ url: URL, fetch });

    const answer = await bridge.handle('{"jsonrpc":"2.0","id":7,"method":"ping"}');

    expect(JSON.parse(answer!).result).toEqual({ ok: true });
  });

  /// A notification owes no answer: inventing one would leave a reply the client never asked for.
  test("stays silent on a notification", async () => {
    const { fetch } = recorder(() => new Response("", { status: 202 }));
    const bridge = createBridge({ url: URL, fetch });

    expect(await bridge.handle('{"jsonrpc":"2.0","method":"notifications/initialized"}')).toBeNull();
  });

  test("turns a refused request into a JSON-RPC error rather than leaving the bot waiting", async () => {
    const { fetch } = recorder(() => new Response('{"error":"unauthorized"}', { status: 401 }));
    const bridge = createBridge({ url: URL, fetch });

    const answer = JSON.parse((await bridge.handle('{"jsonrpc":"2.0","id":4,"method":"tools/list"}'))!);

    expect(answer.id).toBe(4);
    expect(answer.error.message).toContain("401");
  });

  test("reports a server that cannot be reached", async () => {
    const fetch = (async () => {
      throw new Error("connect ECONNREFUSED");
    }) as unknown as typeof globalThis.fetch;
    const bridge = createBridge({ url: URL, fetch });

    const answer = JSON.parse((await bridge.handle('{"jsonrpc":"2.0","id":5,"method":"tools/list"}'))!);

    expect(answer.error.message).toContain("ECONNREFUSED");
  });

  test("keeps the session the server hands out", async () => {
    const { calls, fetch } = recorder(
      () =>
        new Response(JSON.stringify({ jsonrpc: "2.0", id: 1, result: {} }), {
          status: 200,
          headers: { "content-type": "application/json", "mcp-session-id": "s-42" },
        }));
    const bridge = createBridge({ url: URL, fetch });

    await bridge.handle('{"jsonrpc":"2.0","id":1,"method":"initialize"}');
    await bridge.handle('{"jsonrpc":"2.0","id":2,"method":"tools/list"}');

    expect(calls[0]!.headers["mcp-session-id"]).toBeUndefined();
    expect(calls[1]!.headers["mcp-session-id"]).toBe("s-42");
  });

  test("answers a malformed line instead of dying", async () => {
    const { fetch } = recorder(() => ok({}));
    const bridge = createBridge({ url: URL, fetch });

    const answer = JSON.parse((await bridge.handle("pas du json"))!);

    expect(answer.error.code).toBe(-32700);
  });

  test("takes the token from the variable the tool server names", () => {
    expect(tokenFromEnvironment({ MCP_TOKEN_VAR: "FORMA_AGENT_TOKEN", FORMA_AGENT_TOKEN: "abc" })).toBe("abc");
    expect(tokenFromEnvironment({ MCP_TOKEN: "direct" })).toBe("direct");
    expect(tokenFromEnvironment({})).toBeUndefined();
  });

  /// `dev` asks the router, which does not know the home names; the certificate is still the server's own.
  test("can be told where to connect while keeping the name for TLS", async () => {
    const seen: { url: string; init: RequestInit | undefined }[] = [];
    const fetch = (async (url: string | URL | Request, init?: RequestInit) => {
      seen.push({ url: String(url), init });
      return ok({ jsonrpc: "2.0", id: 1, result: {} });
    }) as unknown as typeof globalThis.fetch;
    const bridge = createBridge({ url: "https://printer.nuo.example.com/mcp", address: "192.0.2.54", fetch });

    await bridge.handle('{"jsonrpc":"2.0","id":1,"method":"tools/list"}');

    expect(seen[0]!.url).toBe("https://192.0.2.54/mcp");
    const headers = seen[0]!.init!.headers as Record<string, string>;
    expect(headers.host).toBe("printer.nuo.example.com");
    expect((seen[0]!.init as { tls?: { serverName?: string } }).tls?.serverName).toBe("printer.nuo.example.com");
  });

  test("goes straight to the name when no address is given", () => {
    expect(endpoint("https://printer.nuo.example.com/mcp").url).toBe("https://printer.nuo.example.com/mcp");
    expect(endpoint("https://printer.nuo.example.com/mcp").extra.headers).toEqual({});
    expect(endpoint("https://printer.nuo.example.com:8788/mcp", "192.0.2.54").url)
      .toBe("https://192.0.2.54:8788/mcp");
  });

  test("takes the last data line of an event stream", () => {
    expect(eventData("data: {\"a\":1}\n\ndata: {\"b\":2}\n")).toBe('{"b":2}');
    expect(eventData("event: ping\n\n")).toBe("");
  });
});
