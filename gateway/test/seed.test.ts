import { afterEach, describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { startTestApp, type TestApp } from "./helpers";

let t: TestApp | undefined;
afterEach(async () => {
  await t?.close();
  t = undefined;
});

describe("bots seed", () => {
  test("a new installation gets the bot that writes the notes: read only, without any tool", async () => {
    const seed = JSON.parse(readFileSync(join(import.meta.dir, "..", "config", "bots.seed.json"), "utf8"));
    t = await startTestApp({ seed });
    const bots = (await t.api("GET", "/api/bots")).data as { slug: string; published: { config: Record<string, unknown> } }[];
    const notes = bots.find((b) => b.slug === "comptes-rendus");
    expect(notes?.published.config).toMatchObject({ name: "Comptes rendus", emoji: "📝", permissionPolicy: "readonly", toolServers: [], noTools: true });
    expect(notes?.published.config.overview).toBeUndefined();
    expect(String(notes?.published.config.instructions)).toContain("compte rendu");
  });
});
