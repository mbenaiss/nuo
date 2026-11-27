import { chmodSync, mkdirSync, readdirSync, readFileSync, rmSync } from "node:fs";
import { chmod, readFile, rename, rm, stat, writeFile } from "node:fs/promises";
import { join } from "node:path";
import type { TranscriptionRequest, TranscriptReply } from "./service";

/** What a background transcription was asked, without its audio (kept beside it). */
export type JobRequest = Omit<TranscriptionRequest, "audio"> & { audioType: string };

export interface JobRecord {
  id: string;
  deviceId: string;
  createdAt: number;
  status: "running" | "done" | "failed";
  /** Calls to the provider so far: a job is started again once after a restart, never more. */
  attempts: number;
  finishedAt?: number;
  result?: TranscriptReply;
  error?: { status: number; message: string };
  request: JobRequest;
}

export const JOB_ID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const STATUSES = new Set(["running", "done", "failed"]);

/** A record as written by this gateway; anything else (a crash mid-write, a hand edit) is dropped at startup. */
function valid(value: unknown, id: string): value is JobRecord {
  const r = value as Partial<JobRecord> | null;
  const q = r?.request as Partial<JobRequest> | undefined;
  return (
    !!r &&
    typeof r === "object" &&
    r.id === id &&
    typeof r.deviceId === "string" &&
    typeof r.createdAt === "number" &&
    typeof r.status === "string" &&
    STATUSES.has(r.status) &&
    !!q &&
    typeof q === "object" &&
    typeof q.filename === "string" &&
    typeof q.seconds === "number" &&
    Array.isArray(q.keyterms) &&
    Array.isArray(q.otherLanguages)
  );
}

/**
 * Background transcriptions of one profile on disk (`<data>/transcriptions`, 0700, files 0600): `<id>.json` holds the
 * request, the state and the result, `<id>.audio` the recording until a result or an error comes back. A gateway that
 * restarts finds its jobs again; a file it cannot read never stops it from starting.
 */
export class JobStore {
  private records = new Map<string, JobRecord>();

  /** The disk work of each job, one operation after the other: a removal can never be undone by a write in flight. */
  private queues = new Map<string, Promise<void>>();

  constructor(readonly dir: string) {
    mkdirSync(dir, { recursive: true, mode: 0o700 });
    chmodSync(dir, 0o700);
    // Only files of this store are touched, one at a time: an odd entry (a folder, a file it cannot read) is left or
    // dropped, never a reason for the gateway not to start.
    const files = () => {
      try {
        return readdirSync(dir, { withFileTypes: true }).filter((e) => e.isFile()).map((e) => e.name);
      } catch (e) {
        console.error(`[transcription] ${dir} not readable: ${(e as Error)?.message ?? e}`);
        return [];
      }
    };
    const drop = (name: string) => {
      try {
        rmSync(join(dir, name), { force: true });
      } catch (e) {
        console.error(`[transcription] ${name} not removed: ${(e as Error)?.message ?? e}`);
      }
    };
    for (const name of files()) {
      if (name.endsWith(".tmp")) {
        drop(name);
        continue;
      }
      if (!name.endsWith(".json")) continue;
      const id = name.slice(0, -".json".length);
      if (!JOB_ID.test(id)) continue;
      let record: unknown;
      try {
        record = JSON.parse(readFileSync(join(dir, name), "utf8"));
      } catch {}
      if (valid(record, id)) {
        this.records.set(id, { ...record, attempts: typeof record.attempts === "number" ? record.attempts : 1 });
      } else {
        console.warn(`[transcription] dropping unreadable job ${id}`);
        drop(name);
      }
    }
    // Audio no running job needs: left by a crash between two writes, by a dropped record, or beside a finished job.
    for (const name of files()) {
      if (name.endsWith(".audio") && this.records.get(name.slice(0, -".audio".length))?.status !== "running") drop(name);
    }
  }

  private enqueue(id: string, operation: () => Promise<void>): Promise<void> {
    const next = (this.queues.get(id) ?? Promise.resolve()).catch(() => {}).then(operation);
    this.queues.set(id, next);
    const settled = () => {
      if (this.queues.get(id) === next) this.queues.delete(id);
    };
    next.then(settled, settled);
    return next;
  }

  all(): JobRecord[] {
    return [...this.records.values()];
  }

  get(id: string): JobRecord | undefined {
    return this.records.get(id);
  }

  /** Writes the audio, then the record: a record on disk always has its audio while it runs. */
  async create(record: JobRecord, audio: Blob): Promise<void> {
    const bytes = new Uint8Array(await audio.arrayBuffer());
    await this.enqueue(record.id, () => this.write(this.audioPath(record.id), bytes));
    await this.save(record);
  }

  async hasAudio(id: string): Promise<boolean> {
    return stat(this.audioPath(id)).then(
      () => true,
      () => false,
    );
  }

  async audio(id: string): Promise<Blob> {
    const record = this.records.get(id);
    return new Blob([await readFile(this.audioPath(id))], { type: record?.request.audioType || "audio/mp4" });
  }

  /**
   * The job's new state, in memory at once and on disk atomically; its audio goes as soon as it is finished. A state
   * that is no longer the job's when its turn comes (removed, or saved again since) is not written.
   */
  save(record: JobRecord): Promise<void> {
    this.records.set(record.id, record);
    return this.enqueue(record.id, async () => {
      if (this.records.get(record.id) !== record) return;
      const path = join(this.dir, `${record.id}.json`);
      await this.write(`${path}.tmp`, JSON.stringify(record));
      await rename(`${path}.tmp`, path);
      if (record.status !== "running") await rm(this.audioPath(record.id), { force: true });
    });
  }

  remove(id: string): Promise<void> {
    this.records.delete(id);
    return this.enqueue(id, async () => {
      await rm(join(this.dir, `${id}.json`), { force: true });
      await rm(join(this.dir, `${id}.json.tmp`), { force: true });
      await rm(this.audioPath(id), { force: true });
    });
  }

  private audioPath(id: string): string {
    return join(this.dir, `${id}.audio`);
  }

  private async write(path: string, data: string | Uint8Array): Promise<void> {
    await writeFile(path, data, { mode: 0o600 });
    await chmod(path, 0o600);
  }
}
