import { afterEach, describe, expect, test } from "bun:test";
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { DropPublisher, dropFromEnv } from "../src/data/drop";
import { startTestApp, type TestApp } from "./helpers";

const json = (data: unknown, status = 200) => new Response(JSON.stringify(data), { status, headers: { "content-type": "application/json" } });
const certificate = new Uint8Array([0x25, 0x50, 0x44, 0x46, 0x2d, 0x31, 0x2e, 0x37, 0x0a]);

/** drop answering every upload like its own API does, keeping what it received. */
function drop(seen: { req: Request; form: FormData }[] = [], status = 200) {
  return async (input: RequestInfo | URL, init?: RequestInit) => {
    const req = new Request(String(input), init);
    seen.push({ req, form: await req.clone().formData() });
    if (status !== 200) return json({ error: "authentication required" }, status);
    const ttl = Number(seen.at(-1)!.form.get("ttl"));
    return json({ id: "drop-4be1c07f93a2", url: "https://drop.example.com/s/drop-4be1c07f93a2/", expiresAt: ttl ? Date.parse("2026-11-14T21:40:00Z") : null, permanent: !ttl });
  };
}

describe("public links on drop", () => {
  let t: TestApp | undefined;
  afterEach(async () => {
    await t?.close();
    t = undefined;
  });

  test("the file goes to drop under its name with the chosen lifetime, the key staying on the gateway", async () => {
    const seen: { req: Request; form: FormData }[] = [];
    const publisher = new DropPublisher("https://drop.example.com/", "drop_k_8f31c2", drop(seen));
    const link = await publisher.publish("PPS Athlé — P4DB26F777D.pdf", new Blob([certificate], { type: "application/pdf" }), 1440);
    expect(link).toEqual({ url: "https://drop.example.com/s/drop-4be1c07f93a2/", expiresAt: "2026-11-14T21:40:00.000Z" });
    const { req, form } = seen[0]!;
    expect([req.method, req.url, req.headers.get("authorization")]).toEqual(["POST", "https://drop.example.com/api/sites", "Bearer drop_k_8f31c2"]);
    expect([form.get("access"), form.get("ttl")]).toEqual(["public", "1440"]);
    const file = form.get("file") as File;
    expect(file.name).toBe("PPS Athlé — P4DB26F777D.pdf");
    expect(new Uint8Array(await file.arrayBuffer())).toEqual(certificate);

    expect(await publisher.publish("plan-2026.md", new Blob(["# Plan 2026"]), 0)).toEqual({ url: "https://drop.example.com/s/drop-4be1c07f93a2/", expiresAt: null });
  });

  test("a lifetime drop does not offer, a file over 25 MB and a refused key are errors", async () => {
    const publisher = new DropPublisher("https://drop.example.com", "drop_k_8f31c2", drop());
    expect(publisher.publish("plan-2026.md", new Blob(["# Plan"]), 45)).rejects.toMatchObject({ status: 400 });
    expect(publisher.publish("plan-2026.md", new Blob(["# Plan"]), "1440")).rejects.toMatchObject({ status: 400 });
    expect(publisher.publish("visite-chantier.mov", new Blob([new Uint8Array(25 * 1024 * 1024 + 1)]), 60)).rejects.toMatchObject({ status: 413 });
    const revoked = new DropPublisher("https://drop.example.com", "revoked", drop([], 401));
    expect(revoked.publish("plan-2026.md", new Blob(["# Plan"]), 60)).rejects.toMatchObject({ status: 502, message: "drop key (NUO_DROP_API_KEY) refused" });
  });

  test("configured only with both the URL and the key", () => {
    expect(dropFromEnv({ NUO_DROP_URL: "https://drop.example.com", NUO_DROP_API_KEY: "drop_k_8f31c2" })).toBeInstanceOf(DropPublisher);
    expect(dropFromEnv({ NUO_DROP_URL: "https://drop.example.com" })).toBeUndefined();
    expect(dropFromEnv({ NUO_DROP_API_KEY: "drop_k_8f31c2" })).toBeUndefined();
  });

  test("the app publishes a document of the repo by its path", async () => {
    const seen: { req: Request; form: FormData }[] = [];
    t = await startTestApp({ data: { autoStart: false, drop: new DropPublisher("https://drop.example.com", "drop_k_8f31c2", drop(seen)) } });
    const folder = join(t.profileHome, "docs", "Perso", "Santé", "Sport");
    mkdirSync(folder, { recursive: true });
    writeFileSync(join(folder, "PPS Athlé — P4DB26F777D.pdf"), certificate);

    const res = await t.api("POST", "/api/docs/drop", { path: "Perso/Santé/Sport/PPS Athlé — P4DB26F777D.pdf", ttl: 60 });
    expect(res.status).toBe(200);
    expect(res.data.url).toBe("https://drop.example.com/s/drop-4be1c07f93a2/");
    expect((seen[0]!.form.get("file") as File).name).toBe("PPS Athlé — P4DB26F777D.pdf");

    expect((await t.api("POST", "/api/docs/drop", { path: "Perso/Santé/absent.pdf", ttl: 60 })).status).toBe(404);
    expect((await t.api("POST", "/api/docs/drop", { path: "../nuo.db", ttl: 60 })).status).toBe(400);
  });

  test("without drop configured the route says so", async () => {
    t = await startTestApp({ data: { autoStart: false } });
    expect((await t.api("POST", "/api/docs/drop", { path: "plan.md", ttl: 60 })).status).toBe(404);
  });
});
