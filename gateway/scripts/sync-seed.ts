// Adds the seed bots' slash commands to an existing deployment: one new published version per bot whose
// commands differ, everything else unchanged. Idempotent. Usage: bun run sync-seed
import { join } from "node:path";
import { ToolCatalog } from "../src/bots/catalog";
import { syncSeedCommands } from "../src/bots/sync-seed";
import { defaultLayout, REPO_CONFIG_DIR, seedConfig } from "../src/paths";
import { openDb } from "../src/store/db";
import { Store } from "../src/store/store";

const layout = defaultLayout();
seedConfig(layout.config, REPO_CONFIG_DIR);
const configDir = layout.config;
const store = new Store(openDb(layout.data));
try {
  const results = syncSeedCommands(store, new ToolCatalog(join(configDir, "tools.json")), join(configDir, "bots.seed.json"));
  for (const r of results) {
    const version = r.version ? ` v${r.version}` : "";
    console.log(`${r.name}: ${r.status}${version}${r.detail ? ` (${r.detail})` : ""}`);
  }
  if (results.some((r) => r.status === "invalid")) process.exitCode = 1;
} finally {
  store.db.close();
}
