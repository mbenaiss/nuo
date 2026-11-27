import type { Database } from "bun:sqlite";
import { copyFileSync, existsSync, mkdirSync, readdirSync } from "node:fs";
import { dirname, join } from "node:path";
import type { Layout } from "../paths";
import type { Pusher } from "../push/apns";
import type { Device } from "../store/store";
import { Dashboards } from "./dashboards";
import { changeVersion, openDataDb, SCHEMA_DIR, type SchemaDirs } from "./db";
import { Docs, initDocsRepo } from "./docs";
import type { DropPublisher } from "./drop";
import { Projects } from "./projects"; import { Places, ReminderNotifier, Reminders } from "./reminders";
import { DataStore } from "./store";

export const REPO_DASHBOARDS_DIR = new URL("../../config/dashboards", import.meta.url).pathname;

type DataLayout = Pick<Layout, "dataDb" | "dataFiles" | "docs" | "dashboards">;

/** Creates the data folders; docs becomes a git repo; starter dashboards are copied on the very first run only. */
export function prepareDataLayout(layout: DataLayout, defaultDashboards = REPO_DASHBOARDS_DIR): void {
  mkdirSync(layout.dataFiles, { recursive: true });
  initDocsRepo(layout.docs);
  if (!existsSync(layout.dashboards)) {
    mkdirSync(layout.dashboards, { recursive: true });
    if (existsSync(defaultDashboards)) {
      for (const f of readdirSync(defaultDashboards).filter((f) => f.endsWith(".json"))) copyFileSync(join(defaultDashboards, f), join(layout.dashboards, f));
    }
  }
}

export interface DataServices {
  db: Database;
  store: DataStore;
  reminders: Reminders;
  places: Places; projects: Projects;
  notifier: ReminderNotifier;
  dashboards: Dashboards;
  docs: Docs;
  /** Public links to documents (NUO_DROP_URL, NUO_DROP_API_KEY); without it the apps share files only. */
  drop?: DropPublisher;
  filesDir: string;
  start(): void;
  stop(): void;
}

export interface DataOptions {
  clock?: () => number;
  reminderIntervalMs?: number;
  dashboardTimeoutMs?: number;
  /** Set to false in tests that drive the notifier by hand. */
  autoStart?: boolean;
  /** The starter dashboards query the owner's collections; other profiles start without them. */
  starterDashboards?: boolean;
  /** False for another profile: its database gets the shared tables, not the owner's collections. */
  ownerCollections?: boolean;
  /** Where the migrations are read from; tests add their example owner collections. */
  schemaDirs?: SchemaDirs;
  drop?: DropPublisher;
}

export function createDataServices(layout: DataLayout, pusher: Pusher, devices: () => Device[], o: DataOptions = {}): DataServices {
  prepareDataLayout(layout, o.starterDashboards === false ? "" : REPO_DASHBOARDS_DIR);
  const db = openDataDb(layout.dataDb, o.schemaDirs ?? SCHEMA_DIR, o.ownerCollections !== false);
  const reminders = new Reminders(db, o.clock);
  const notifier = new ReminderNotifier(reminders, pusher, devices, o.reminderIntervalMs);
  const dashboards = new Dashboards(layout.dashboards, layout.dataDb, o.dashboardTimeoutMs, () => changeVersion(db));
  return {
    db,
    store: new DataStore(db),
    reminders,
    places: new Places(db, o.clock),
    projects: new Projects(db, o.clock),
    notifier,
    dashboards,
    docs: new Docs(layout.docs, join(dirname(layout.dataDb), "docs-pins.json")),
    drop: o.drop,
    filesDir: layout.dataFiles,
    start() {
      if (o.autoStart !== false) notifier.start();
    },
    stop() {
      notifier.stop();
      dashboards.close();
      db.close();
    },
  };
}
