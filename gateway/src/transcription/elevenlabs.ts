import { HttpError } from "../bots/service";
import { t as i18n } from "../i18n/language";
import type { Fetch } from "../scan/products";
import type { SpeechToText, Transcript, TranscriptionRequest, TranscriptSegment } from "./service";

const API = "https://api.elevenlabs.io/v1";
const DEFAULT_MODEL = "scribe_v3";
const PROVIDER = "ElevenLabs";
/** Past 100 keyterms, every request is billed at least 20 s. */
const MAX_KEYTERMS = 100;
/** A new segment after this much silence, even within one speaker's turn. */
const PAUSE_S = 1.5;
/** A segment this long ends at its next full stop… */
const SENTENCE_S = 8;
/** …and is cut here when nobody stops. */
const MAX_SEGMENT_S = 30;

interface Word {
  text: string;
  type?: "word" | "spacing" | "audio_event";
  start?: number | null;
  end?: number | null;
  speaker_id?: string | null;
}

/**
 * ElevenLabs Scribe over a whole recording, from the gateway: the key never reaches the apps. `no_verbatim` leaves out
 * fillers ("um", "uh"), false starts and non-speech sounds.
 */
export class ElevenLabsSpeechToText implements SpeechToText {
  readonly provider = "elevenlabs";
  readonly model: string;
  private fetcher: Fetch;

  constructor(
    private key: string,
    o: { model?: string; fetcher?: Fetch } = {},
  ) {
    this.model = o.model ?? DEFAULT_MODEL;
    this.fetcher = o.fetcher ?? fetch;
  }

  async transcribe(r: TranscriptionRequest, signal?: AbortSignal): Promise<Transcript> {
    // One budget for the call and its retry: the app waits for both together.
    const budget = AbortSignal.timeout(timeoutMs(r.seconds, r.background));
    try {
      return await this.send(r, keyterms(r.keyterms), budget, signal);
    } catch (e) {
      if (!(e instanceof RejectedRequest)) throw e;
      // A term Scribe refuses must not cost the user the whole transcription: once more without them.
      if (r.keyterms.length === 0) throw e.error;
      try {
        return await this.send(r, [], budget, signal);
      } catch (again) {
        throw again instanceof RejectedRequest ? again.error : again;
      }
    }
  }

  private async send(r: TranscriptionRequest, terms: string[], budget: AbortSignal, signal?: AbortSignal): Promise<Transcript> {
    const form = new FormData();
    form.set("model_id", this.model);
    form.set("file", r.audio, r.filename);
    if (r.language) form.set("language_code", r.language);
    form.set("no_verbatim", "true");
    form.set("tag_audio_events", "false");
    form.set("temperature", "0");
    for (const term of terms) form.append("keyterms", term);
    if (this.model.startsWith("scribe_v3")) {
      // Both only exist from Scribe v3 on.
      for (const code of r.otherLanguages) form.append("secondary_language_codes", code);
      form.set("numbers_format", "digits");
    }
    if (r.segments) form.set("timestamps_granularity", "word");
    if (r.speakers) {
      form.set("diarize", "true");
      if (r.maxSpeakers) form.set("num_speakers", String(r.maxSpeakers));
    }
    let res: Response;
    try {
      res = await this.fetcher(`${API}/speech-to-text`, {
        method: "POST",
        headers: { "xi-api-key": this.key },
        body: form,
        signal: AbortSignal.any([budget, ...(signal ? [signal] : [])]),
      });
    } catch (e) {
      if (signal?.aborted) throw new HttpError(499, i18n("transcription.cancelled"));
      const timedOut = (e as Error)?.name === "TimeoutError";
      throw new HttpError(timedOut ? 504 : 502, timedOut ? i18n("transcription.providerTimeout", { provider: PROVIDER }) : i18n("transcription.providerUnreachable", { provider: PROVIDER, detail: String((e as Error)?.message ?? e) }));
    }
    const body = (await res.json().catch(() => undefined)) as { text?: string; language_code?: string; words?: Word[]; detail?: unknown } | undefined;
    if (res.status === 401 || res.status === 403) throw new HttpError(502, i18n("transcription.providerKeyRefused", { provider: PROVIDER, variable: "NUO_ELEVENLABS_API_KEY" }));
    if (res.status === 429) throw new HttpError(429, i18n("transcription.providerRateLimited", { provider: PROVIDER }));
    const text = detail(body?.detail);
    const failure = new HttpError(502, text ? i18n("transcription.providerFailedDetail", { provider: PROVIDER, status: res.status, detail: text }) : i18n("transcription.providerFailed", { provider: PROVIDER, status: res.status }));
    if (res.status === 422) throw new RejectedRequest(failure);
    if (!res.ok || typeof body?.text !== "string") throw failure;
    const transcript: Transcript = { text: body.text.trim(), language: iso1(body.language_code) };
    if (r.segments) transcript.segments = segmentsFromWords(body.words ?? [], r.speakers, r.breaks);
    return transcript;
  }

  async warm(): Promise<void> {
    try {
      await this.fetcher(`${API}/models`, { method: "GET", headers: { "xi-api-key": this.key }, signal: AbortSignal.timeout(5_000) });
    } catch {}
  }
}

/**
 * A dictation's app waits 15 s plus its upload plus 0.15 s per second of audio: the gateway gives up first, so the app
 * hears why and moves on to the device instead of sending the audio again. A background job (a meeting, a recording
 * of several hours) has half a minute plus the audio's length, within half an hour, or a sixth of that length when
 * longer, within an hour: a silent provider does not hold a short recording, nor its place, for half an hour.
 */
export function timeoutMs(seconds: number, background = false): number {
  const job = Math.min(60 * 60, Math.max(Math.min(30 * 60, 30 + seconds), seconds / 6));
  return Math.round((background ? job : 10 + seconds * 0.1) * 1000);
}

/** Scribe refused the request itself (422): worth one more try without what the app added. */
class RejectedRequest extends Error {
  constructor(readonly error: HttpError) {
    super(error.message);
  }
}

/** Scribe's limits: 50 characters, 5 words, none of `<>{}[]\`; kept to 100 terms for the billing floor above it. */
export function keyterms(terms: string[]): string[] {
  const seen = new Set<string>();
  const kept: string[] = [];
  for (const raw of terms) {
    const term = raw.replace(/[<>{}[\]\\]/g, " ").replace(/\s+/g, " ").trim();
    if (!term || term.length > 50 || term.split(" ").length > 5) continue;
    const folded = term.toLowerCase();
    if (seen.has(folded)) continue;
    seen.add(folded);
    kept.push(term);
    if (kept.length === MAX_KEYTERMS) break;
  }
  return kept;
}

/** Scribe gives three-letter codes ("fra"); the apps speak ISO 639-1. */
function iso1(code: string | undefined): string | undefined {
  if (!code) return undefined;
  const map: Record<string, string> = { fra: "fr", eng: "en", deu: "de", spa: "es", ita: "it", por: "pt", nld: "nl", ara: "ar" };
  return code.length === 2 ? code : (map[code] ?? code);
}

function detail(value: unknown): string {
  if (!value) return "";
  return (typeof value === "string" ? value : JSON.stringify(value)).slice(0, 200);
}

/**
 * Timed words into segments: a new one when the speaker changes, after a pause, at one of the app's `breaks` (where it
 * cut silences out of the audio: what follows may have been said minutes later), at the first full stop once a
 * segment is long enough, or at `MAX_SEGMENT_S`. Speakers become "1", "2"… in order of first appearance.
 */
export function segmentsFromWords(words: Word[], speakers: boolean, breaks: number[] = []): TranscriptSegment[] {
  const cuts = breaks.filter(Number.isFinite).sort((a, b) => a - b);
  let nextCut = 0;
  /** Middle of the previous word: a cut between two words' middles falls between them, whatever their edges say. */
  let previousMiddle = -Infinity;
  const labels = new Map<string, string>();
  const label = (id: string | null | undefined) => {
    if (!speakers || !id) return undefined;
    if (!labels.has(id)) labels.set(id, String(labels.size + 1));
    return labels.get(id);
  };
  const segments: TranscriptSegment[] = [];
  let current: (TranscriptSegment & { raw: string }) | undefined;
  let gap = "";
  const close = () => {
    if (!current) return;
    const text = current.raw.replace(/\s+/g, " ").trim();
    if (text) segments.push({ start: current.start, end: current.end, text, ...(current.speaker ? { speaker: current.speaker } : {}) });
    current = undefined;
  };
  for (const w of words) {
    if (w.type === "audio_event") continue;
    if (w.type === "spacing") {
      gap += w.text;
      continue;
    }
    const start = w.start ?? current?.end ?? 0;
    const end = Math.max(w.end ?? start, start);
    const speaker = label(w.speaker_id);
    // A cut between the previous word and this one: they were not said together.
    const middle = (start + end) / 2;
    let crossesCut = false;
    while (nextCut < cuts.length && cuts[nextCut]! <= middle) {
      if (cuts[nextCut]! > previousMiddle) crossesCut = true;
      nextCut++;
    }
    previousMiddle = middle;
    if (current) {
      const length = current.end - current.start;
      const sentenceDone = /[.!?…]["»)]?$/.test(current.raw.trim()) && length >= SENTENCE_S;
      if (speaker !== current.speaker || crossesCut || start - current.end >= PAUSE_S || sentenceDone || length >= MAX_SEGMENT_S) close();
    }
    if (!current) {
      current = { start, end, text: "", raw: w.text, ...(speaker ? { speaker } : {}) };
    } else {
      current.raw += (gap || " ") + w.text;
      current.end = end;
    }
    gap = "";
  }
  close();
  return segments;
}
