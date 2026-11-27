import { HttpError } from "../bots/service";
import { ElevenLabsSpeechToText, timeoutMs } from "./elevenlabs";
import { JOB_ID, type JobRecord, JobStore } from "./jobs";

/** One stretch of speech; `speaker` is "1", "2"… in order of first appearance, only when speakers were asked for. */
export interface TranscriptSegment {
  start: number;
  end: number;
  text: string;
  speaker?: string;
}

export interface Transcript {
  text: string;
  /** ISO 639-1 when the provider says which language it heard. */
  language?: string;
  segments?: TranscriptSegment[];
}

export interface TranscriptionRequest {
  audio: Blob;
  filename: string;
  /** ISO 639-1; absent lets the provider detect it. */
  language?: string;
  /** Other languages that may come up, such as English technical terms in French speech. */
  otherLanguages: string[];
  /** Names and words to spell right (bots, people, projects). */
  keyterms: string[];
  /** Timed segments, for meetings. */
  segments: boolean;
  /** Who speaks when (diarization); implies segments. */
  speakers: boolean;
  /** Most speakers to tell apart, when the app knows who attends. */
  maxSpeakers?: number;
  /** Seconds into the audio where the app joined pieces of it (silences cut out): no segment runs across them. */
  breaks?: number[];
  /** Length of the audio as the app measured it, to give a long recording the time it needs. */
  seconds: number;
  /** A job the app polls: no client waits on the connection, the provider may take its time. */
  background: boolean;
}

/** A speech-to-text service. The app only knows `POST /api/transcriptions`; which provider answers is gateway config. */
export interface SpeechToText {
  readonly provider: string;
  readonly model: string;
  /** `signal` aborts when the app that waits for the text goes away. */
  transcribe(request: TranscriptionRequest, signal?: AbortSignal): Promise<Transcript>;
  /** Opens the connection to the provider ahead of an upload; never throws. */
  warm(): Promise<void>;
}

const RATE_WINDOW_MS = 10 * 60_000;
/** Dictations and meeting streams together: a busy hour, not a stolen session running up a bill. */
const RATE_MAX = 120;
const WARM_EVERY_MS = 20_000;
const MAX_SECONDS = 6 * 3600;
const MAX_KEYTERMS = 200;
const LANGUAGE = /^[a-z]{2,3}$/;
/** A cut every couple of seconds over six hours. */
const MAX_BREAKS = 20_000;
/** A finished job's text waits this long for the app to fetch it, as many times as it asks; its audio is long gone. */
const JOB_KEEP_MS = 24 * 3600_000;
/** Two meeting streams and a dictation at once; more is a runaway client. */
const MAX_IN_FLIGHT = 3;

export type TranscriptReply = Transcript & { provider: string; model: string; ms: number };

/** The provider, the limits and the warm connection, shared by every profile; jobs are kept per profile (`at`). */
export class TranscriptionService {
  private recent = new Map<string, number[]>();
  private warmedAt = 0;
  private inFlight = new Map<string, number>();
  private profiles = new Map<string, ProfileTranscriptions>();

  constructor(
    readonly stt: SpeechToText,
    readonly now: () => number = Date.now,
    /** How long a resent job waits for its first upload before the gateway says it is busy (429). */
    readonly o: { uploadWaitMs?: number } = {},
  ) {
    setInterval(() => {
      for (const p of this.profiles.values()) p.prune();
    }, 60_000).unref?.();
  }

  /**
   * The transcriptions of the profile whose data lives in `dir`; jobs a restart interrupted start again. Undefined,
   * and said in the log, when that folder cannot be made (a file in its place): the profile opens without transcription.
   */
  at(dir: string): ProfileTranscriptions | undefined {
    let p = this.profiles.get(dir);
    if (!p) {
      let store: JobStore;
      try {
        store = new JobStore(dir);
      } catch (e) {
        console.error(`[transcription] ${dir} unusable, transcription off for this profile: ${(e as Error)?.message ?? e}`);
        return undefined;
      }
      p = new ProfileTranscriptions(this, store);
      this.profiles.set(dir, p);
    }
    return p;
  }

  info() {
    return { provider: this.stt.provider, model: this.stt.model };
  }

  /** Called when the user starts speaking, so the upload at the end skips the TLS handshakes. */
  warm(): void {
    const t = this.now();
    if (t - this.warmedAt < WARM_EVERY_MS) return;
    this.warmedAt = t;
    void this.stt.warm();
  }

  /** Takes a place among the device's transcriptions under way; the returned function gives it back. */
  admit(deviceId: string): () => void {
    if ((this.inFlight.get(deviceId) ?? 0) >= MAX_IN_FLIGHT) throw new HttpError(429, "trop de transcriptions en cours, attends la fin de la précédente");
    const t = this.now();
    const times = (this.recent.get(deviceId) ?? []).filter((x) => t - x < RATE_WINDOW_MS);
    if (times.length >= RATE_MAX) throw new HttpError(429, "trop de transcriptions en peu de temps, réessaie dans quelques minutes");
    times.push(t);
    this.recent.set(deviceId, times);
    this.inFlight.set(deviceId, (this.inFlight.get(deviceId) ?? 0) + 1);
    let released = false;
    return () => {
      if (released) return;
      released = true;
      this.inFlight.set(deviceId, Math.max(0, (this.inFlight.get(deviceId) ?? 1) - 1));
    };
  }

  async run(request: TranscriptionRequest, signal?: AbortSignal): Promise<TranscriptReply> {
    const started = performance.now();
    const transcript = await this.stt.transcribe(request, signal);
    return { ...transcript, ...this.info(), ms: Math.round(performance.now() - started) };
  }
}

/** What `GET /api/transcriptions/:id` says about a job. */
export type JobView =
  | ({ status: "done" } & TranscriptReply)
  | { status: "running" }
  | { status: "failed"; error: { status: number; message: string } };

/** How long an id the app stopped keeps an upload with that id from starting. */
const STOPPED_MS = 5 * 60_000;
/** A resend waits this long for the first upload of the same job, then is told to come back (429). */
const UPLOAD_WAIT_MS = 25_000;
const STOPPED_PER_DEVICE = 100;
/**
 * A job still `running` this long after it was sent belongs to a gateway that was down: it is not started again. The
 * longest a job can run: the provider's budget for the longest audio, twice (one retry when it answers too late).
 */
export const STALE_MS = 2 * timeoutMs(MAX_SECONDS, true);
/** Lets the app name its job before sending the audio, so a job it already sent is found without reading the upload. */
export const JOB_ID_HEADER = "x-nuo-transcription-id";

/** One profile's transcriptions: dictations answered at once, meetings as jobs kept on disk until fetched or expired. */
export class ProfileTranscriptions {
  /** Ids taken by an upload still being read or written, so a second POST with the same id finds it. */
  private reserved = new Map<string, string>();
  /** Settles when the upload holding a named id is done, one way or the other. */
  private uploads = new Map<string, Promise<void>>();
  /**
   * Jobs each device stopped, remembered a while (`device:id`), so that an upload of theirs still on its way (or one the
   * stop overtook) never starts. A hundred per device at most.
   */
  private stopped = new Map<string, Map<string, number>>();
  private running = new Map<string, AbortController>();

  constructor(
    private service: TranscriptionService,
    private store: JobStore,
  ) {
    this.prune();
    for (const record of store.all()) if (record.status === "running") void this.resume(record);
  }

  info() {
    return this.service.info();
  }

  warm(): void {
    this.service.warm();
  }

  /** The transcript, or with `background=true` a job id to poll at `GET /api/transcriptions/:id`. */
  async handle(req: Request, deviceId: string): Promise<TranscriptReply | { id: string }> {
    const named = namedJob(req);
    if (named) {
      // The same job sent again while its first upload is still being read (a retry on the other route) waits for that
      // upload: if it becomes the job, this one is answered with it; if it dies, this one carries on with its own audio.
      // At most `uploadWaitMs`: a first upload stuck on a dead connection must not hold this request (and the app) for
      // ever. Its body is not read meanwhile, and goes with the answer.
      const until = this.service.now() + (this.service.o.uploadWaitMs ?? UPLOAD_WAIT_MS);
      for (let upload = this.uploads.get(named); upload && this.reserved.get(named) === deviceId; upload = this.uploads.get(named)) {
        const left = until - this.service.now();
        const settled = left > 0 && (await Promise.race([upload.then(() => true), Bun.sleep(left).then(() => false)]));
        if (!settled) throw new HttpError(429, "l'envoi précédent de cette transcription est encore en cours, réessaie dans un moment");
      }
      // A job sent again after a lost answer: found before any limit, and before its upload is read.
      const sent = this.known(named, deviceId);
      if (sent) return sent;
      if (this.wasStopped(named, deviceId)) return { id: named };
    }
    // Taken before the upload is read, so a burst of uploads cannot slip past the limit. The relay's jobs are kept
    // apart (`<device>:relay`) but spend the device's own budget.
    const done = this.service.admit(deviceId.replace(/:relay$/, ""));
    let launched = false;
    let reserved: string | undefined;
    let settle = () => {};
    const reserve = (id: string) => {
      this.reserved.set(id, deviceId);
      reserved = id;
      this.uploads.set(id, new Promise<void>((resolve) => (settle = resolve)));
    };
    // Reserved before its upload is read: the same job sent again meanwhile takes no second place, and waits.
    if (named) reserve(named);
    try {
      const { request, jobId } = await parse(req);
      if (request.background && deviceId.endsWith(":relay")) throw new HttpError(403, "the relay cannot start a background transcription");
      if (!request.background) return await this.service.run(request, req.signal);
      this.prune();
      const id = named ?? jobId ?? crypto.randomUUID();
      if (!named) {
        const known = this.known(id, deviceId);
        if (known) return known;
      }
      if (this.wasStopped(id, deviceId)) return { id };
      if (reserved !== id) reserve(id);
      const { audio, ...rest } = request;
      const record: JobRecord = {
        id,
        deviceId,
        createdAt: this.service.now(),
        status: "running",
        attempts: 1,
        request: { ...rest, audioType: audio.type },
      };
      try {
        await this.store.create(record, audio);
      } catch (e) {
        console.error(`[transcription] job ${id} not written: ${(e as Error)?.message ?? e}`);
        await this.store.remove(id).catch(() => {});
        throw new HttpError(507, "la passerelle n'a pas pu garder l'enregistrement");
      }
      // Stopped while its upload was being written, or right after: removed, never started.
      if (this.wasStopped(id, deviceId) || this.store.get(id) !== record) {
        await this.store.remove(id).catch(() => {});
        return { id };
      }
      this.launch(record, request, done);
      launched = true;
      return { id };
    } finally {
      if (!launched) done();
      if (reserved) {
        this.reserved.delete(reserved);
        this.uploads.delete(reserved);
      }
      settle();
    }
  }

  /** Only the device that started a job may see it; to any other it does not exist. */
  job(id: string, deviceId: string): JobView {
    this.prune();
    const record = this.owned(id, deviceId);
    if (!record) return { status: "running" };
    switch (record.status) {
      case "running":
        return { status: "running" };
      case "failed":
        return { status: "failed", error: record.error ?? { status: 502, message: "la transcription a échoué" } };
      case "done":
        return { status: "done", ...(record.result as TranscriptReply) };
    }
  }

  /** Stops the provider and deletes the job's files: the meeting was discarded, or the app gave up waiting. */
  async delete(id: string, deviceId: string): Promise<void> {
    // Remembered even when unknown (still 404): a stop can overtake its own upload on the way, which then never starts.
    this.remember(id, deviceId);
    const record = this.owned(id, deviceId);
    this.running.get(id)?.abort();
    this.running.delete(id);
    if (record) await this.store.remove(id);
  }

  private remember(id: string, deviceId: string) {
    let ids = this.stopped.get(deviceId);
    if (!ids) {
      ids = new Map();
      this.stopped.set(deviceId, ids);
    }
    ids.delete(id);
    ids.set(id, this.service.now());
    while (ids.size > STOPPED_PER_DEVICE) ids.delete(ids.keys().next().value!);
  }

  private wasStopped(id: string, deviceId: string): boolean {
    const at = this.stopped.get(deviceId)?.get(id);
    return at !== undefined && this.service.now() - at < STOPPED_MS;
  }

  /** Finished jobs go after a day, with their files; stopped ids are forgotten after a few minutes. */
  prune() {
    const t = this.service.now();
    for (const [deviceId, ids] of this.stopped) {
      for (const [id, at] of ids) if (t - at >= STOPPED_MS) ids.delete(id);
      if (ids.size === 0) this.stopped.delete(deviceId);
    }
    for (const record of this.store.all()) {
      if (record.status !== "running" && t - (record.finishedAt ?? record.createdAt) > JOB_KEEP_MS) {
        this.store.remove(record.id).catch((e) => console.error(`[transcription] job ${record.id} not removed: ${(e as Error)?.message ?? e}`));
      }
    }
  }

  /** `{id}` when this device already sent that job; 409 when another one did. */
  private known(id: string, deviceId: string): { id: string } | undefined {
    const owner = this.store.get(id)?.deviceId ?? this.reserved.get(id);
    if (owner === undefined) return undefined;
    if (owner !== deviceId) throw new HttpError(409, "identifiant de transcription déjà pris");
    return { id };
  }

  /** The record, or a reserved upload (undefined), for its device; 404 otherwise. */
  private owned(id: string, deviceId: string): JobRecord | undefined {
    const record = this.store.get(id);
    if (record?.deviceId === deviceId) return record;
    if (!record && this.reserved.get(id) === deviceId) return undefined;
    throw new HttpError(404, "transcription inconnue ou expirée");
  }

  private launch(record: JobRecord, request: TranscriptionRequest, done: () => void = () => {}) {
    const controller = new AbortController();
    this.running.set(record.id, controller);
    void (async () => {
      let next: JobRecord;
      try {
        let result;
        try {
          result = await this.service.run(request, controller.signal);
        } catch (e) {
          // Too late once: the same audio, once more, without the app sending it again.
          if (!(e instanceof HttpError) || e.status !== 504 || controller.signal.aborted) throw e;
          result = await this.service.run(request, controller.signal);
        }
        next = { ...record, status: "done", result, finishedAt: this.service.now() };
      } catch (e) {
        const error = e instanceof HttpError ? e : new HttpError(502, String((e as Error)?.message ?? e));
        // The app shows this message: never an empty one.
        const message = error.message.trim() || "la transcription a échoué chez le fournisseur";
        next = { ...record, status: "failed", error: { status: error.status, message }, finishedAt: this.service.now() };
      } finally {
        done();
        if (this.running.get(record.id) === controller) this.running.delete(record.id);
      }
      // Deleted while the provider worked: nothing to keep.
      if (controller.signal.aborted || !this.store.get(record.id)) return;
      await this.persist(next);
    })();
  }

  /** A full disk or a removed folder is logged; the job keeps its state in memory until the next restart. */
  private async persist(record: JobRecord) {
    try {
      await this.store.save(record);
    } catch (e) {
      console.error(`[transcription] job ${record.id} not saved: ${(e as Error)?.message ?? e}`);
    }
  }

  /**
   * A job the gateway was running when it stopped: started again from its audio, once. It fails, with its reason,
   * when it was already started again, when the gateway was down for longer than a job can last, or when its audio is gone.
   */
  private async resume(record: JobRecord) {
    // The state this resume last saw: the record, then its counted attempt. A job the app deleted meanwhile stays
    // deleted: no « failed » record comes back for it.
    let current = record;
    const fail = async (message: string) => {
      if (this.store.get(record.id) !== current) return;
      await this.persist({ ...current, status: "failed", error: { status: 502, message }, finishedAt: this.service.now() });
    };
    try {
      if (this.service.now() - record.createdAt > STALE_MS) return await fail("la passerelle était arrêtée trop longtemps pendant la transcription : elle se refait sur l'appareil");
      if (record.attempts >= 2) return await fail("la transcription a déjà été relancée après un redémarrage de la passerelle : elle se refait sur l'appareil");
      if (!(await this.store.hasAudio(record.id))) return await fail("la passerelle a redémarré pendant la transcription et l'audio n'a pas été gardé : elle se refait sur l'appareil");
      const next = { ...record, attempts: record.attempts + 1 };
      if (this.store.get(record.id) !== record) return;
      // Counted before the provider is called again: a crash during this attempt cannot start a third one. In memory
      // at once, even if the disk then refuses it.
      current = next;
      await this.store.save(next);
      // Stopped by the app while the attempt was being counted, or while its audio was read.
      if (this.store.get(next.id) !== next) return;
      const audio = await this.store.audio(next.id);
      if (this.store.get(next.id) !== next) return;
      this.launch(next, { ...next.request, audio });
    } catch (e) {
      console.error(`[transcription] job ${record.id} not resumed: ${(e as Error)?.message ?? e}`);
      await fail("la transcription n'a pas pu reprendre après un redémarrage de la passerelle : elle se refait sur l'appareil");
    }
  }
}

/** A form flag, read the same way wherever it is checked: « true », « TRUE », « 1 », padded or not. */
export function isTrue(v: unknown): boolean {
  return typeof v === "string" && ["true", "1", "yes", "on"].includes(v.trim().toLowerCase());
}

/** The id the app gave its job in a header or the query string, read without touching the upload. */
function namedJob(req: Request): string | undefined {
  const raw = req.headers.get(JOB_ID_HEADER) ?? new URL(req.url).searchParams.get("id");
  if (!raw) return undefined;
  const id = raw.trim().toLowerCase();
  if (!JOB_ID.test(id)) throw new HttpError(400, "identifiant de transcription invalide");
  return id;
}

async function parse(req: Request): Promise<{ request: TranscriptionRequest; jobId?: string }> {
  let form: FormData;
  try {
    form = await req.formData();
  } catch {
    throw new HttpError(400, "multipart/form-data attendu");
  }
  const audio = form.get("audio");
  if (!(audio instanceof Blob) || audio.size === 0) throw new HttpError(400, "champ audio manquant");
  const field = (name: string) => {
    const value = form.get(name);
    return typeof value === "string" ? value.trim() : undefined;
  };
  const language = field("language");
  if (language && !LANGUAGE.test(language)) throw new HttpError(400, "langue invalide");
  const otherLanguages = (field("otherLanguages") ?? "").split(",").map((l) => l.trim()).filter((l) => LANGUAGE.test(l) && l !== language).slice(0, 4);
  let keyterms: string[] = [];
  const raw = field("keyterms");
  if (raw) {
    try {
      const parsed = JSON.parse(raw);
      if (Array.isArray(parsed)) keyterms = parsed.filter((k): k is string => typeof k === "string").slice(0, MAX_KEYTERMS);
    } catch {
      throw new HttpError(400, "keyterms : tableau JSON attendu");
    }
  }
  const seconds = Number(field("seconds"));
  const speakers = field("speakers") === "true";
  const maxSpeakers = Number(field("maxSpeakers"));
  let breaks: number[] | undefined;
  const rawBreaks = field("breaks");
  if (rawBreaks) {
    try {
      const parsed = JSON.parse(rawBreaks);
      if (Array.isArray(parsed)) breaks = parsed.filter((b): b is number => typeof b === "number" && Number.isFinite(b) && b > 0).slice(0, MAX_BREAKS);
    } catch {
      throw new HttpError(400, "breaks : tableau JSON attendu");
    }
  }
  const request: TranscriptionRequest = {
    audio,
    filename: (audio as File).name || "audio.m4a",
    language: language || undefined,
    otherLanguages,
    keyterms,
    segments: speakers || field("segments") === "true",
    speakers,
    maxSpeakers: speakers && Number.isInteger(maxSpeakers) && maxSpeakers >= 1 ? Math.min(maxSpeakers, 32) : undefined,
    seconds: Number.isFinite(seconds) && seconds > 0 ? Math.min(seconds, MAX_SECONDS) : 60,
    background: isTrue(field("background")),
    ...(breaks?.length ? { breaks } : {}),
  };
  const jobId = field("id")?.toLowerCase();
  if (jobId && !JOB_ID.test(jobId)) throw new HttpError(400, "identifiant de transcription invalide");
  return { request, jobId: jobId || undefined };
}

/** `NUO_TRANSCRIPTION_PROVIDER` picks the service (default `elevenlabs`); undefined when it lacks its key. */
export function transcriptionFromEnv(env: Record<string, string | undefined> = process.env): TranscriptionService | undefined {
  const provider = (env.NUO_TRANSCRIPTION_PROVIDER?.trim() || "elevenlabs").toLowerCase();
  switch (provider) {
    case "elevenlabs": {
      const key = env.NUO_ELEVENLABS_API_KEY?.trim();
      if (!key) return undefined;
      return new TranscriptionService(new ElevenLabsSpeechToText(key, { model: env.NUO_ELEVENLABS_STT_MODEL?.trim() || undefined }));
    }
    default:
      console.warn(`[transcription] unknown NUO_TRANSCRIPTION_PROVIDER "${provider}": the apps transcribe on the device only`);
      return undefined;
  }
}
