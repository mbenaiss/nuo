import { afterEach, describe, expect, test } from "bun:test";
import { ElevenLabsSpeechToText, keyterms, segmentsFromWords, timeoutMs } from "../src/transcription/elevenlabs";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { HttpError } from "../src/bots/service";
import { type ProfileTranscriptions, type SpeechToText, STALE_MS, type TranscriptionRequest, TranscriptionService, transcriptionFromEnv } from "../src/transcription/service";
import { type JobRecord, JobStore } from "../src/transcription/jobs";
import { startTestApp, type TestApp } from "./helpers";

const json = (data: unknown, status = 200) => new Response(JSON.stringify(data), { status, headers: { "content-type": "application/json" } });

/** Waits for work the gateway does in the background (disk, provider) without a fixed delay. */
const until = async (condition: () => boolean) => {
  for (let i = 0; i < 400 && !condition(); i++) await Bun.sleep(5);
};

/** A profile's transcription jobs folder, as `<data>/transcriptions`. */
const jobsDir = () => join(mkdtempSync(join(tmpdir(), "nuo-transcriptions-")), "transcriptions");

/** A few bytes standing for the AAC file the app uploads. */
const m4a = () => new Blob([new Uint8Array([0, 0, 0, 24, 102, 116, 121, 112, 77, 52, 65, 32])], { type: "audio/mp4" });

const request = (over: Partial<TranscriptionRequest> = {}): TranscriptionRequest => ({
  audio: m4a(),
  filename: "dictation.m4a",
  language: "fr",
  otherLanguages: ["en"],
  keyterms: [],
  segments: false,
  speakers: false,
  seconds: 7,
  background: false,
  ...over,
});

/** Scribe answering with `body`, keeping each request and its parsed form. */
function scribe(body: unknown, status = 200) {
  const seen: { url: string; key: string | null; form: FormData }[] = [];
  const fetcher = async (input: RequestInfo | URL, init?: RequestInit) => {
    const req = new Request(String(input), init);
    seen.push({ url: req.url, key: req.headers.get("xi-api-key"), form: req.method === "POST" ? await req.formData() : new FormData() });
    return json(body, status);
  };
  return { seen, fetcher };
}

const dictationReply = {
  language_code: "fra",
  language_probability: 0.98,
  text: "Rappelle-moi d'appeler Julie Martin demain à 9 h pour la facture EDF.",
  words: [],
};

describe("ElevenLabs Scribe behind the gateway", () => {
  test("one request with the key, the best settings and no fillers", async () => {
    const { seen, fetcher } = scribe(dictationReply);
    const stt = new ElevenLabsSpeechToText("el-key-3f9a1c", { fetcher });
    const result = await stt.transcribe(request({ keyterms: ["Julie Martin", "Coach", "coach", "EDF"] }));
    expect(result).toEqual({ text: "Rappelle-moi d'appeler Julie Martin demain à 9 h pour la facture EDF.", language: "fr" });
    expect(seen).toHaveLength(1);
    const { url, key, form } = seen[0]!;
    expect(url).toBe("https://api.elevenlabs.io/v1/speech-to-text");
    expect(key).toBe("el-key-3f9a1c");
    expect(form.get("model_id")).toBe("scribe_v3");
    expect(form.get("language_code")).toBe("fr");
    expect(form.getAll("secondary_language_codes")).toEqual(["en"]);
    expect(form.get("no_verbatim")).toBe("true");
    expect(form.get("tag_audio_events")).toBe("false");
    expect(form.get("temperature")).toBe("0");
    expect(form.get("numbers_format")).toBe("digits");
    expect(form.getAll("keyterms")).toEqual(["Julie Martin", "Coach", "EDF"]);
    expect(form.get("diarize")).toBeNull();
    expect(form.get("timestamps_granularity")).toBeNull();
    const file = form.get("file") as File;
    expect(file.name).toBe("dictation.m4a");
    expect(file.size).toBe(12);
  });

  test("a meeting stream asks for speakers and gets timed segments", async () => {
    const words = [
      { text: "On", type: "word", start: 0.4, end: 0.6, speaker_id: "speaker_3" },
      { text: " ", type: "spacing", start: 0.6, end: 0.62, speaker_id: "speaker_3" },
      { text: "commence ?", type: "word", start: 0.62, end: 1.1, speaker_id: "speaker_3" },
      { text: " ", type: "spacing", start: 1.1, end: 1.4, speaker_id: "speaker_3" },
      { text: "(rires)", type: "audio_event", start: 1.4, end: 2, speaker_id: "speaker_3" },
      { text: "Oui,", type: "word", start: 2.1, end: 2.4, speaker_id: "speaker_0" },
      { text: " ", type: "spacing", start: 2.4, end: 2.45, speaker_id: "speaker_0" },
      { text: "vas-y.", type: "word", start: 2.45, end: 2.9, speaker_id: "speaker_0" },
      { text: "Bon,", type: "word", start: 5.2, end: 5.5, speaker_id: "speaker_3" },
    ];
    const { seen, fetcher } = scribe({ language_code: "fra", text: "On commence ? Oui, vas-y. Bon,", words });
    const result = await new ElevenLabsSpeechToText("el-key-3f9a1c", { fetcher }).transcribe(request({ speakers: true, segments: true, maxSpeakers: 3, seconds: 1800 }));
    expect(seen[0]!.form.get("diarize")).toBe("true");
    expect(seen[0]!.form.get("num_speakers")).toBe("3");
    expect(seen[0]!.form.get("timestamps_granularity")).toBe("word");
    expect(result.segments).toEqual([
      { start: 0.4, end: 1.1, text: "On commence ?", speaker: "1" },
      { start: 2.1, end: 2.9, text: "Oui, vas-y.", speaker: "2" },
      { start: 5.2, end: 5.5, text: "Bon,", speaker: "1" },
    ]);
  });

  test("a refused key, a rate limit and a dead network become gateway errors", async () => {
    const refused = new ElevenLabsSpeechToText("revoked", { fetcher: scribe({ detail: { status: "invalid_api_key" } }, 401).fetcher });
    expect(refused.transcribe(request())).rejects.toMatchObject({ status: 502, message: "ElevenLabs key (NUO_ELEVENLABS_API_KEY) refused" });
    const limited = new ElevenLabsSpeechToText("el-key-3f9a1c", { fetcher: scribe({ detail: "too_many_concurrent_requests" }, 429).fetcher });
    expect(limited.transcribe(request())).rejects.toMatchObject({ status: 429 });
    const invalid = new ElevenLabsSpeechToText("el-key-3f9a1c", { fetcher: scribe({ detail: [{ msg: "file too short" }] }, 422).fetcher });
    expect(invalid.transcribe(request())).rejects.toMatchObject({ status: 502, message: 'ElevenLabs answered 422: [{"msg":"file too short"}]' });
    const slow = new ElevenLabsSpeechToText("el-key-3f9a1c", {
      fetcher: async () => {
        throw Object.assign(new Error("The operation timed out."), { name: "TimeoutError" });
      },
    });
    expect(slow.transcribe(request())).rejects.toMatchObject({ status: 504 });
  });

  test("Scribe v2 gets neither secondary languages nor number formatting, which it does not know", async () => {
    const { seen, fetcher } = scribe(dictationReply);
    await new ElevenLabsSpeechToText("el-key-3f9a1c", { fetcher, model: "scribe_v2" }).transcribe(request());
    expect(seen[0]!.form.get("model_id")).toBe("scribe_v2");
    expect(seen[0]!.form.get("secondary_language_codes")).toBeNull();
    expect(seen[0]!.form.get("numbers_format")).toBeNull();
    expect(seen[0]!.form.get("no_verbatim")).toBe("true");
  });

  test("keyterms follow Scribe's limits", () => {
    expect(keyterms(["Julie Martin", " julie  martin ", "facture [EDF]", "un nom bien trop long pour être un seul terme", "Point hebdo Nuo", ""])).toEqual([
      "Julie Martin",
      "facture EDF",
      "Point hebdo Nuo",
    ]);
    expect(keyterms(Array.from({ length: 300 }, (_, i) => `Projet ${i}`))).toHaveLength(100);
  });

  test("a dictation gives up before the app does; a meeting job gets the time it needs, within half an hour", () => {
    // The app waits 15 s + upload + 0.15 s per second of audio.
    expect(timeoutMs(12)).toBe(11_200);
    expect(timeoutMs(300)).toBe(40_000);
    expect(timeoutMs(12, true)).toBe(42_000);
    expect(timeoutMs(3600, true)).toBe(1_800_000);
  });

  test("a second refusal from Scribe is the provider's error, not a crash", async () => {
    let calls = 0;
    const stt = new ElevenLabsSpeechToText("el-key-3f9a1c", { fetcher: async () => (calls++, json({ detail: "invalid language_code" }, 422)) });
    const failure = await stt.transcribe(request({ keyterms: ["Julie Martin"] })).catch((e) => e);
    expect(calls).toBe(2);
    expect(failure).toBeInstanceOf(HttpError);
    expect(failure).toMatchObject({ status: 502, message: "ElevenLabs answered 422: invalid language_code" });
  });

  test("a request Scribe refuses is tried once more without keyterms", async () => {
    const seen: FormData[] = [];
    const fetcher = async (input: RequestInfo | URL, init?: RequestInit) => {
      const form = await new Request(String(input), init).formData();
      seen.push(form);
      return form.getAll("keyterms").length > 0 ? json({ detail: [{ msg: "invalid keyterm" }] }, 422) : json(dictationReply);
    };
    const result = await new ElevenLabsSpeechToText("el-key-3f9a1c", { fetcher }).transcribe(request({ keyterms: ["Julie Martin", "EDF"] }));
    expect(result.text).toContain("Julie Martin");
    expect(seen.map((f) => f.getAll("keyterms"))).toEqual([["Julie Martin", "EDF"], []]);
    const without = new ElevenLabsSpeechToText("el-key-3f9a1c", { fetcher: scribe({ detail: [{ msg: "file too short" }] }, 422).fetcher });
    expect(without.transcribe(request())).rejects.toMatchObject({ status: 502 });
  });

  test("an app that goes away stops the call to Scribe", async () => {
    let providerSignal: AbortSignal | undefined;
    const fetcher = (_: RequestInfo | URL, init?: RequestInit) =>
      new Promise<Response>((_resolve, reject) => {
        providerSignal = init?.signal ?? undefined;
        init?.signal?.addEventListener("abort", () => reject(Object.assign(new Error("aborted"), { name: "AbortError" })));
      });
    const app = new AbortController();
    const pending = new ElevenLabsSpeechToText("el-key-3f9a1c", { fetcher }).transcribe(request(), app.signal);
    await Bun.sleep(5);
    app.abort();
    expect(pending).rejects.toMatchObject({ status: 499 });
    expect(providerSignal?.aborted).toBe(true);
  });

  test("a cut between two words' middles separates them, whatever their edges say", () => {
    const word = (text: string, start: number, end: number) => ({ text, type: "word" as const, start, end });
    // The first word's end runs past the cut.
    expect(segmentsFromWords([word("Bonjour", 9.0, 10.2), word("merci", 10.3, 10.6)], false, [10.0])).toEqual([
      { start: 9, end: 10.2, text: "Bonjour" },
      { start: 10.3, end: 10.6, text: "merci" },
    ]);
    // The next word is dated just before the cut, but mostly after it.
    expect(segmentsFromWords([word("Bonjour", 9.0, 9.5), word("merci", 9.95, 10.4), word("beaucoup", 10.5, 10.9)], false, [10.0])).toEqual([
      { start: 9, end: 9.5, text: "Bonjour" },
      { start: 9.95, end: 10.9, text: "merci beaucoup" },
    ]);
    expect(segmentsFromWords([word("Bonjour", 1, 1.5), word("merci", 2.3, 2.6)], false, [1e300, Number.NaN, 2.0, 0.5])).toHaveLength(2);
  });

  test("a short reply never merges with what was said minutes later across a cut", () => {
    const word = (text: string, start: number, end: number) => ({ text, type: "word" as const, start, end });
    // « Oui. » at 00:10, then a sentence at 05:10: the app cut the silence, they are 0.9 s apart in the sent audio.
    const words = [word("Oui.", 0.3, 0.6), word("On", 1.5, 1.7), word("valide", 1.75, 2.1), word("le", 2.15, 2.2), word("devis.", 2.25, 2.7)];
    expect(segmentsFromWords(words, false)).toEqual([{ start: 0.3, end: 2.7, text: "Oui. On valide le devis." }]);
    expect(segmentsFromWords(words, false, [1.2])).toEqual([
      { start: 0.3, end: 0.6, text: "Oui." },
      { start: 1.5, end: 2.7, text: "On valide le devis." },
    ]);
  });

  test("segments break on pauses, and at a full stop once long enough", () => {
    const word = (text: string, start: number, end: number) => ({ text, type: "word" as const, start, end });
    const segments = segmentsFromWords(
      [word("Première", 0, 4), word("phrase.", 4.2, 9), word("Deuxième", 9.1, 9.6), word("phrase", 9.7, 10), word("après", 12, 12.4), word("pause.", 12.5, 13)],
      false,
    );
    expect(segments).toEqual([
      { start: 0, end: 9, text: "Première phrase." },
      { start: 9.1, end: 10, text: "Deuxième phrase" },
      { start: 12, end: 13, text: "après pause." },
    ]);
  });
});

/** Stands for any provider: the app never knows which one answers. */
class FakeStt implements SpeechToText {
  readonly provider = "fake-scribe";
  readonly model = "fake-model-1";
  seen: TranscriptionRequest[] = [];
  warmed = 0;
  async transcribe(r: TranscriptionRequest) {
    this.seen.push(r);
    return { text: "Peux-tu décaler le rendez-vous chez le kiné à vendredi ?", language: "fr" };
  }
  async warm() {
    this.warmed++;
  }
}

describe("POST /api/transcriptions", () => {
  let t: TestApp | undefined;
  afterEach(async () => {
    await t?.close();
    t = undefined;
  });

  const upload = (form: FormData, token = t!.token, path = "/api/transcriptions") =>
    fetch(t!.base + path, { method: "POST", headers: { authorization: `Bearer ${token}` }, body: form });

  const dictation = () => {
    const form = new FormData();
    form.set("audio", m4a(), "dictation.m4a");
    form.set("language", "fr");
    form.set("otherLanguages", "en,fr,english");
    form.set("keyterms", JSON.stringify(["Julie Martin", 42, "Coach"]));
    form.set("seconds", "6.4");
    return form;
  };

  test("the paired app sends audio and gets text, whoever the provider is", async () => {
    const stt = new FakeStt();
    t = await startTestApp({ transcription: new TranscriptionService(stt) });
    const res = await upload(dictation());
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body).toMatchObject({ text: "Peux-tu décaler le rendez-vous chez le kiné à vendredi ?", language: "fr", provider: "fake-scribe", model: "fake-model-1" });
    expect(typeof body.ms).toBe("number");
    expect(stt.seen).toHaveLength(1);
    expect(stt.seen[0]).toMatchObject({ filename: "dictation.m4a", language: "fr", otherLanguages: ["en"], keyterms: ["Julie Martin", "Coach"], segments: false, speakers: false, seconds: 6.4 });
    expect(stt.seen[0]!.maxSpeakers).toBeUndefined();

    const meeting = dictation();
    meeting.set("speakers", "true");
    meeting.set("maxSpeakers", "4");
    await upload(meeting);
    expect(stt.seen[1]).toMatchObject({ segments: true, speakers: true, maxSpeakers: 4 });
  });

  test("the old single-use token route is gone: dictation goes through the gateway only", async () => {
    t = await startTestApp({ transcription: new TranscriptionService(new FakeStt()) });
    const old = await t.api("POST", "/api/dictation/tokens", {});
    expect([old.status, old.data]).toEqual([404, { error: "not found" }]);
  });

  test("a long meeting runs in the background and is fetched by the device that sent it", async () => {
    let finish: (() => void) | undefined;
    const stt = new FakeStt();
    stt.transcribe = async (r) => {
      stt.seen.push(r);
      await new Promise<void>((resolve) => (finish = resolve));
      return { text: "On vise le vendredi 24 pour la bêta.", segments: [{ start: 44, end: 47.5, text: "On vise le vendredi 24 pour la bêta.", speaker: "1" }] };
    };
    t = await startTestApp({ transcription: new TranscriptionService(stt) });
    const meeting = dictation();
    meeting.set("speakers", "true");
    meeting.set("background", "true");
    meeting.set("seconds", "5400");
    const started = await upload(meeting);
    expect(started.status).toBe(202);
    const { id } = await started.json();
    expect(id).toMatch(/^[0-9a-f-]{36}$/);
    const poll = () => fetch(`${t!.base}/api/transcriptions/${id}`, { headers: { authorization: `Bearer ${t!.token}` } });
    expect((await poll()).status).toBe(202);
    finish!();
    for (let i = 0; i < 400 && (await poll()).status === 202; i++) await Bun.sleep(5);
    const done = await poll();
    expect(done.status).toBe(200);
    expect(await done.json()).toMatchObject({ text: "On vise le vendredi 24 pour la bêta.", segments: [{ speaker: "1", start: 44 }], provider: "fake-scribe" });
    const unknown = await fetch(`${t.base}/api/transcriptions/00000000-0000-4000-8000-000000000000`, { headers: { authorization: `Bearer ${t.token}` } });
    expect(unknown.status).toBe(404);
    const stop = await fetch(`${t.base}/api/transcriptions/${id}`, { method: "DELETE", headers: { authorization: `Bearer ${t.token}` } });
    expect(stop.status).toBe(204);
    expect((await poll()).status).toBe(404);
  });

  test("a failed job answers 200 with its error, so no proxy can pass for it", async () => {
    const stt = new FakeStt();
    stt.transcribe = async () => {
      throw new HttpError(429, "ElevenLabs is limiting transcriptions for now, try again in a moment");
    };
    t = await startTestApp({ transcription: new TranscriptionService(stt) });
    const meeting = dictation();
    meeting.set("background", "true");
    const { id } = await (await upload(meeting)).json();
    for (let i = 0; i < 400 && (await fetch(`${t.base}/api/transcriptions/${id}`, { headers: { authorization: `Bearer ${t.token}` } })).status === 202; i++) await Bun.sleep(5);
    const res = await fetch(`${t.base}/api/transcriptions/${id}`, { headers: { authorization: `Bearer ${t.token}` } });
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ status: "failed", error: { status: 429, message: "ElevenLabs is limiting transcriptions for now, try again in a moment" } });
  });

  test("warming opens the provider's connection at most every 20 s", async () => {
    const stt = new FakeStt();
    t = await startTestApp({ transcription: new TranscriptionService(stt) });
    const first = await upload(new FormData(), t.token, "/api/transcriptions/warm");
    expect(first.status).toBe(200);
    expect(await first.json()).toEqual({ provider: "fake-scribe", model: "fake-model-1" });
    await upload(new FormData(), t.token, "/api/transcriptions/warm");
    expect(stt.warmed).toBe(1);
  });

  test("no audio, a bad language, an extension or no provider are refused", async () => {
    t = await startTestApp({ transcription: new TranscriptionService(new FakeStt()) });
    const empty = new FormData();
    empty.set("language", "fr");
    expect((await upload(empty)).status).toBe(400);
    const odd = dictation();
    odd.set("language", "fr-FR; drop");
    expect((await upload(odd)).status).toBe(400);
    expect((await upload(dictation(), t.device.extensionTokens.share!.token)).status).toBe(403);
    await t.close();
    t = await startTestApp();
    expect((await upload(dictation())).status).toBe(404);
    expect((await upload(new FormData(), t.token, "/api/transcriptions/warm")).status).toBe(404);
  });

  const post = (profile: ProfileTranscriptions, device: string, background = false, signal?: AbortSignal) => {
    const form = dictation();
    if (background) form.set("background", "true");
    return profile.handle(new Request("http://gateway/api/transcriptions", { method: "POST", body: form, signal }), device);
  };

  test("a failed background job reports the provider's error", async () => {
    const stt = new FakeStt();
    stt.transcribe = async () => {
      throw new HttpError(502, "ElevenLabs key (NUO_ELEVENLABS_API_KEY) refused");
    };
    const profile = new TranscriptionService(stt).at(jobsDir())!;
    const { id } = (await post(profile, "mac", true)) as { id: string };
    await until(() => profile.job(id, "mac").status !== "running");
    expect(profile.job(id, "mac")).toEqual({ status: "failed", error: { status: 502, message: "ElevenLabs key (NUO_ELEVENLABS_API_KEY) refused" } });
    expect(() => profile.job(id, "iphone")).toThrow("unknown or expired transcription");
  });

  test("a device may have three transcriptions under way, not more", async () => {
    const stt = new FakeStt();
    const waiting: (() => void)[] = [];
    stt.transcribe = async (r) => {
      stt.seen.push(r);
      await new Promise<void>((resolve) => waiting.push(resolve));
      return { text: "Point hebdo : bêta le vendredi 24." };
    };
    const profile = new TranscriptionService(stt).at(jobsDir())!;
    const settle = (device: string) =>
      post(profile, device).then(
        () => "transcrit",
        (e) => `refusé ${e.status}`,
      );
    const answers = Promise.all([settle("mac"), settle("mac"), settle("mac"), settle("mac"), settle("iphone")]);
    for (let i = 0; i < 200 && waiting.length < 4; i++) await Bun.sleep(5);
    for (const resolve of waiting) resolve();
    expect(await answers).toEqual(["transcrit", "transcrit", "transcrit", "refusé 429", "transcrit"]);
    stt.transcribe = async () => ({ text: "Point hebdo : bêta le vendredi 24." });
    expect(await settle("mac")).toBe("transcrit");
  });

  test("a dictation whose app hangs up stops the provider", async () => {
    const stt = new FakeStt();
    let aborted = false;
    stt.transcribe = (_r, signal) =>
      new Promise((_resolve, reject) => signal?.addEventListener("abort", () => ((aborted = true), reject(new Error("aborted")))));
    const app = new AbortController();
    const pending = post(new TranscriptionService(stt).at(jobsDir()), "iphone", false, app.signal);
    await Bun.sleep(5);
    app.abort();
    expect(pending).rejects.toThrow("aborted");
    expect(aborted).toBe(true);
  });

  test("a meeting job is kept on disk, private, and its audio goes once transcribed", async () => {
    let finish: (() => void) | undefined;
    const stt = new FakeStt();
    stt.transcribe = async () => {
      await new Promise<void>((resolve) => (finish = resolve));
      return { text: "On vise le vendredi 24 pour la bêta." };
    };
    const dir = jobsDir();
    const profile = new TranscriptionService(stt).at(dir)!;
    const { id } = (await post(profile, "mac", true)) as { id: string };
    expect((statSync(dir).mode & 0o777).toString(8)).toBe("700");
    expect((statSync(join(dir, `${id}.audio`)).mode & 0o777).toString(8)).toBe("600");
    expect((statSync(join(dir, `${id}.json`)).mode & 0o777).toString(8)).toBe("600");
    expect(JSON.parse(readFileSync(join(dir, `${id}.json`), "utf8"))).toMatchObject({ id, deviceId: "mac", status: "running" });
    finish!();
    await until(() => !existsSync(join(dir, `${id}.audio`)));
    expect(existsSync(join(dir, `${id}.audio`))).toBe(false);
    expect(JSON.parse(readFileSync(join(dir, `${id}.json`), "utf8"))).toMatchObject({ status: "done", result: { text: "On vise le vendredi 24 pour la bêta." } });
  });

  test("a job the gateway was running when it restarted starts again from its audio", async () => {
    const dir = jobsDir();
    const before = new FakeStt();
    before.transcribe = () => new Promise(() => {});
    const { id } = (await post(new TranscriptionService(before).at(dir), "mac", true)) as { id: string };

    const after = new FakeStt();
    after.transcribe = async (r) => {
      after.seen.push(r);
      return { text: "Dernier point : on ouvre la bêta à plus de monde ?" };
    };
    const restarted = new TranscriptionService(after).at(dir)!;
    await until(() => restarted.job(id, "mac").status === "done");
    expect(restarted.job(id, "mac")?.text).toBe("Dernier point : on ouvre la bêta à plus de monde ?");
    expect(after.seen[0]).toMatchObject({ language: "fr", keyterms: ["Julie Martin", "Coach"], background: true });
    expect(after.seen[0]!.audio.size).toBe(12);
  });

  test("a running job whose audio is gone after a restart fails with a reason, never a silent 404", async () => {
    const dir = jobsDir();
    const before = new FakeStt();
    before.transcribe = () => new Promise(() => {});
    const { id } = (await post(new TranscriptionService(before).at(dir), "mac", true)) as { id: string };
    rmSync(join(dir, `${id}.audio`));
    const restarted = new TranscriptionService(new FakeStt()).at(dir)!;
    await until(() => restarted.job(id, "mac").status === "failed");
    const view = restarted.job(id, "mac");
    expect(view.status).toBe("failed");
    expect(view.status === "failed" && view.error.message).toContain("the gateway restarted during the transcription");
  });

  test("a result can be read again until it expires after 24 hours, with its files", async () => {
    let now = Date.parse("2026-11-14T09:00:00Z");
    const dir = jobsDir();
    const profile = new TranscriptionService(new FakeStt(), () => now).at(dir)!;
    const { id } = (await post(profile, "mac", true)) as { id: string };
    await until(() => profile.job(id, "mac").status === "done");
    expect(profile.job(id, "mac")?.text).toContain("kiné");
    expect(existsSync(join(dir, `${id}.audio`))).toBe(false);
    now += 23 * 3600_000;
    // The first answer was lost on the way, or the Mac slept overnight: asking again still works.
    expect(profile.job(id, "mac")?.text).toContain("kiné");
    now += 2 * 3600_000;
    profile.prune();
    expect(() => profile.job(id, "mac")).toThrow("unknown or expired transcription");
    await until(() => !existsSync(join(dir, `${id}.json`)));
    expect(existsSync(join(dir, `${id}.json`))).toBe(false);
  });

  test("a meeting sent again after a lost answer finds its job instead of paying twice", async () => {
    const stt = new FakeStt();
    const profile = new TranscriptionService(stt).at(jobsDir())!;
    const named = () => {
      const form = dictation();
      form.set("background", "true");
      form.set("id", "6f1c2b9e-4a7d-4c55-9e1f-2b8a7c3d1e40");
      return new Request("http://gateway/api/transcriptions", { method: "POST", body: form });
    };
    expect(await profile.handle(named(), "mac")).toEqual({ id: "6f1c2b9e-4a7d-4c55-9e1f-2b8a7c3d1e40" });
    expect(await profile.handle(named(), "mac")).toEqual({ id: "6f1c2b9e-4a7d-4c55-9e1f-2b8a7c3d1e40" });
    await Bun.sleep(5);
    expect(stt.seen).toHaveLength(1);
    expect(profile.handle(named(), "iphone")).rejects.toMatchObject({ status: 409 });
    const odd = dictation();
    odd.set("background", "true");
    odd.set("id", "../../etc/passwd");
    expect(profile.handle(new Request("http://gateway/api/transcriptions", { method: "POST", body: odd }), "mac")).rejects.toMatchObject({ status: 400 });
  });

  test("the same job sent twice at once is transcribed once", async () => {
    const stt = new FakeStt();
    stt.transcribe = async (r) => {
      stt.seen.push(r);
      await Bun.sleep(30);
      return { text: "Bonjour" };
    };
    const profile = new TranscriptionService(stt).at(jobsDir())!;
    const id = "0b9d1c52-7a3e-4f1d-9c7e-5a2f8e4b6d10";
    const named = () => {
      const form = dictation();
      form.set("background", "true");
      form.set("id", id);
      return new Request("http://gateway/api/transcriptions", { method: "POST", body: form });
    };
    expect(await Promise.all([profile.handle(named(), "mac"), profile.handle(named(), "mac")])).toEqual([{ id }, { id }]);
    await Bun.sleep(60);
    expect(stt.seen).toHaveLength(1);
  });

  test("a job sent again by its id header is found even while the device is at its limit", async () => {
    const stt = new FakeStt();
    stt.transcribe = () => new Promise(() => {});
    const profile = new TranscriptionService(stt).at(jobsDir())!;
    const ids = ["0b9d1c52-7a3e-4f1d-9c7e-5a2f8e4b6d11", "0b9d1c52-7a3e-4f1d-9c7e-5a2f8e4b6d12", "0b9d1c52-7a3e-4f1d-9c7e-5a2f8e4b6d13"];
    const send = (id: string) => {
      const form = dictation();
      form.set("background", "true");
      return profile.handle(new Request("http://gateway/api/transcriptions", { method: "POST", body: form, headers: { "x-nuo-transcription-id": id } }), "mac");
    };
    for (const id of ids) await send(id);
    expect(await send(ids[0]!)).toEqual({ id: ids[0]! });
    expect(send("0b9d1c52-7a3e-4f1d-9c7e-5a2f8e4b6d14")).rejects.toMatchObject({ status: 429 });
    expect(send("not-a-uuid")).rejects.toMatchObject({ status: 400 });
  });

  test("unreadable files never stop the gateway, and are cleared", async () => {
    const dir = jobsDir();
    mkdirSync(dir, { recursive: true });
    const shapeless = "0b9d1c52-7a3e-4f1d-9c7e-5a2f8e4b6d20";
    writeFileSync(join(dir, `${shapeless}.json`), JSON.stringify({ id: shapeless }));
    writeFileSync(join(dir, `${shapeless}.audio`), "x");
    writeFileSync(join(dir, "0b9d1c52-7a3e-4f1d-9c7e-5a2f8e4b6d21.json.tmp"), '{"id":');
    writeFileSync(join(dir, "0b9d1c52-7a3e-4f1d-9c7e-5a2f8e4b6d22.json"), '{"id":');
    writeFileSync(join(dir, "0b9d1c52-7a3e-4f1d-9c7e-5a2f8e4b6d24.json"), "null");
    const half = "0b9d1c52-7a3e-4f1d-9c7e-5a2f8e4b6d23";
    writeFileSync(join(dir, `${half}.json`), JSON.stringify({ id: half, deviceId: "mac", createdAt: Date.now(), status: "running" }));
    const stt = new FakeStt();
    const profile = new TranscriptionService(stt).at(dir)!;
    await Bun.sleep(5);
    expect(readdirSync(dir)).toEqual([]);
    expect(stt.seen).toHaveLength(0);
    expect(() => profile.job(shapeless, "mac")).toThrow("unknown or expired transcription");
  });

  const leftRunning = (dir: string, over: Record<string, unknown> = {}) => {
    mkdirSync(dir, { recursive: true });
    const id = "0b9d1c52-7a3e-4f1d-9c7e-5a2f8e4b6d30";
    writeFileSync(join(dir, `${id}.json`), JSON.stringify({
      id, deviceId: "mac", createdAt: Date.now() - 5 * 60_000, status: "running", attempts: 1,
      request: { filename: "meeting-them.m4a", otherLanguages: [], keyterms: [], segments: true, speakers: true, seconds: 3200, background: true, audioType: "audio/mp4" },
      ...over,
    }));
    writeFileSync(join(dir, `${id}.audio`), "x");
    return id;
  };

  test("a job left running by a gateway down for two days is failed, not paid for again", async () => {
    const dir = jobsDir();
    const id = leftRunning(dir, { createdAt: Date.now() - 48 * 3600_000 });
    const stt = new FakeStt();
    const profile = new TranscriptionService(stt).at(dir)!;
    await until(() => !existsSync(join(dir, `${id}.audio`)));
    expect(stt.seen).toHaveLength(0);
    expect(profile.job(id, "mac").status).toBe("failed");
    expect(existsSync(join(dir, `${id}.audio`))).toBe(false);
  });

  test("a long recording still within its two hours is started again after a restart", async () => {
    const dir = jobsDir();
    const id = leftRunning(dir, {
      createdAt: Date.now() - 110 * 60_000,
      request: { filename: "seminaire-edf.m4a", otherLanguages: [], keyterms: [], segments: true, speakers: true, seconds: 5 * 3600, background: true, audioType: "audio/mp4" },
    });
    const stt = new FakeStt();
    const profile = new TranscriptionService(stt).at(dir)!;
    await until(() => profile.job(id, "mac").status === "done");
    expect(STALE_MS).toBe(2 * 3600_000);
    expect(stt.seen).toHaveLength(1);
  });

  test("a job sent longer ago than any job can last is failed as a gateway down too long", async () => {
    const dir = jobsDir();
    const id = leftRunning(dir, { createdAt: Date.now() - 125 * 60_000 });
    const stt = new FakeStt();
    const profile = new TranscriptionService(stt).at(dir)!;
    await until(() => profile.job(id, "mac").status === "failed");
    const view = profile.job(id, "mac");
    expect(view.status === "failed" && view.error.message).toContain("the gateway was stopped too long");
    expect(stt.seen).toHaveLength(0);
  });

  test("a job is started again once after a restart, never twice", async () => {
    const dir = jobsDir();
    const id = leftRunning(dir);
    const hang = new FakeStt();
    hang.transcribe = async (r) => {
      hang.seen.push(r);
      return new Promise(() => {});
    };
    new TranscriptionService(hang).at(dir)!;
    await until(() => hang.seen.length === 1);
    expect(hang.seen).toHaveLength(1);
    expect(JSON.parse(readFileSync(join(dir, `${id}.json`), "utf8")).attempts).toBe(2);
    // The gateway crashes again during that attempt.
    const again = new FakeStt();
    const profile = new TranscriptionService(again).at(dir)!;
    await until(() => profile.job(id, "mac").status === "failed");
    expect(again.seen).toHaveLength(0);
    expect(profile.job(id, "mac").status).toBe("failed");
  });

  test("a disk that refuses the result does not bring the gateway down", async () => {
    const dir = jobsDir();
    const stt = new FakeStt();
    stt.transcribe = async () => {
      await Bun.sleep(20);
      return { text: "On vise le vendredi 24 pour la bêta." };
    };
    const profile = new TranscriptionService(stt).at(dir)!;
    const { id } = (await post(profile, "mac", true)) as { id: string };
    chmodSync(dir, 0o500);
    try {
      await Bun.sleep(60);
      expect(profile.job(id, "mac")).toMatchObject({ status: "done", text: "On vise le vendredi 24 pour la bêta." });
    } finally {
      chmodSync(dir, 0o700);
    }
  });

  test("only the device that started a job may stop it; stopping aborts the provider and deletes its files", async () => {
    const dir = jobsDir();
    let aborted = false;
    const stt = new FakeStt();
    stt.transcribe = (_r, signal) => new Promise((_resolve, reject) => signal?.addEventListener("abort", () => ((aborted = true), reject(new Error("aborted")))));
    const profile = new TranscriptionService(stt).at(dir)!;
    const { id } = (await post(profile, "mac", true)) as { id: string };
    expect(profile.delete(id, "iphone")).rejects.toMatchObject({ status: 404 });
    expect(aborted).toBe(false);
    await profile.delete(id, "mac");
    await until(() => aborted && readdirSync(dir).length === 0);
    expect(aborted).toBe(true);
    expect(readdirSync(dir)).toEqual([]);
    expect(() => profile.job(id, "mac")).toThrow("unknown or expired transcription");
  });

  test("a result written while the job is stopped never comes back on disk", async () => {
    for (let i = 0; i < 60; i++) {
      const dir = jobsDir();
      const store = new JobStore(dir);
      const id = crypto.randomUUID();
      const record: JobRecord = {
        id, deviceId: "mac", createdAt: Date.now(), status: "running", attempts: 1,
        request: { filename: "meeting-them.m4a", otherLanguages: ["en"], keyterms: ["Julie Martin"], segments: true, speakers: true, seconds: 1800, background: true, audioType: "audio/mp4" },
      };
      await store.create(record, new Blob([new Uint8Array(200_000)]));
      // The provider answers and the app's DELETE lands in the same tick, or just after.
      const saved = store.save({ ...record, status: "done", finishedAt: Date.now(), result: { text: "Bonjour Julie, on valide le devis de 4 200 euros.", provider: "elevenlabs", model: "scribe_v3", ms: 900 } });
      if (i % 3 === 1) await Promise.resolve();
      if (i % 3 === 2) await new Promise((resolve) => setImmediate(resolve));
      await Promise.all([saved, store.remove(id)]);
      expect(readdirSync(dir)).toEqual([]);
      expect(store.get(id)).toBeUndefined();
    }
  });

  test("a job stopped while its upload is being written never starts", async () => {
    const stt = new FakeStt();
    const profile = new TranscriptionService(stt).at(jobsDir())!;
    const id = "0b9d1c52-7a3e-4f1d-9c7e-5a2f8e4b6d40";
    const form = dictation();
    form.set("background", "true");
    form.set("id", id);
    // The disk is slow: the upload is still being written when the app stops the job.
    const create = JobStore.prototype.create;
    let release = () => {};
    const written = new Promise<void>((resolve) => (release = resolve));
    JobStore.prototype.create = async function (this: JobStore, ...args: Parameters<JobStore["create"]>) {
      await written;
      return create.apply(this, args);
    };
    try {
      const sending = profile.handle(new Request("http://gateway/api/transcriptions", { method: "POST", body: form }), "mac");
      const reserved = (profile as unknown as { reserved: Map<string, string> }).reserved;
      await until(() => reserved.has(id));
      await profile.delete(id, "mac");
      release();
      expect(await sending).toEqual({ id });
    } finally {
      JobStore.prototype.create = create;
    }
    await Bun.sleep(20);
    expect(stt.seen).toHaveLength(0);
    expect(() => profile.job(id, "mac")).toThrow("unknown or expired transcription");
  });

  test("a folder named like a job file does not stop the gateway from starting", () => {
    const dir = jobsDir();
    mkdirSync(join(dir, "3d6f0a52-8f0e-4c43-9a55-2f1c0f4f6f10.json"), { recursive: true });
    mkdirSync(join(dir, "3d6f0a52-8f0e-4c43-9a55-2f1c0f4f6f10.json.tmp"), { recursive: true });
    mkdirSync(join(dir, "3d6f0a52-8f0e-4c43-9a55-2f1c0f4f6f11.audio"), { recursive: true });
    expect(() => new TranscriptionService(new FakeStt()).at(dir)).not.toThrow();
  });

  test("the app's cuts reach the provider with the job", async () => {
    const stt = new FakeStt();
    const profile = new TranscriptionService(stt).at(jobsDir())!;
    const form = dictation();
    form.set("background", "true");
    form.set("speakers", "true");
    form.set("breaks", JSON.stringify([12.4, 31.05, "x", -1]));
    await profile.handle(new Request("http://gateway/api/transcriptions", { method: "POST", body: form }), "mac");
    await until(() => stt.seen.length === 1);
    expect(stt.seen[0]!.breaks).toEqual([12.4, 31.05]);
  });

  test("a DELETE while the job's record is being written stops it before the provider is called", async () => {
    const stt = new FakeStt();
    const profile = new TranscriptionService(stt).at(jobsDir())!;
    const id = "7c1e5d7a-52b4-4c0e-9d41-1c1f0a6b9e01";
    const save = JobStore.prototype.save;
    let deleted: Promise<void> | undefined;
    JobStore.prototype.save = function (this: JobStore, record: JobRecord) {
      const pending = save.call(this, record);
      if (!deleted) deleted = profile.delete(id, "mac");
      return pending;
    };
    try {
      const form = dictation();
      form.set("background", "true");
      expect(await profile.handle(new Request("http://gateway/api/transcriptions", { method: "POST", body: form, headers: { "x-nuo-transcription-id": id } }), "mac")).toEqual({ id });
      await deleted;
    } finally {
      JobStore.prototype.save = save;
    }
    await Bun.sleep(40);
    expect(stt.seen).toHaveLength(0);
    expect(() => profile.job(id, "mac")).toThrow("unknown or expired transcription");
  });

  test("an upload arriving after its own DELETE does not start, for a few minutes", async () => {
    let now = Date.parse("2026-11-14T09:00:00Z");
    const stt = new FakeStt();
    const profile = new TranscriptionService(stt, () => now).at(jobsDir())!;
    const id = "7c1e5d7a-52b4-4c0e-9d41-1c1f0a6b9e02";
    const send = () => {
      const form = dictation();
      form.set("background", "true");
      return profile.handle(new Request("http://gateway/api/transcriptions", { method: "POST", body: form, headers: { "x-nuo-transcription-id": id } }), "mac");
    };
    // Stopped while its upload is still being written.
    const create = JobStore.prototype.create;
    let release = () => {};
    const written = new Promise<void>((resolve) => (release = resolve));
    JobStore.prototype.create = async function (this: JobStore, ...args: Parameters<JobStore["create"]>) {
      await written;
      return create.apply(this, args);
    };
    try {
      const first = send();
      await Bun.sleep(5);
      await profile.delete(id, "mac");
      release();
      expect(await first).toEqual({ id });
    } finally {
      JobStore.prototype.create = create;
    }
    // The app sends it again a moment later: still stopped.
    expect(await send()).toEqual({ id });
    await Bun.sleep(20);
    expect(stt.seen).toHaveLength(0);
    now += 6 * 60_000;
    await send();
    await until(() => stt.seen.length === 1);
    expect(stt.seen).toHaveLength(1);
  });

  test("a DELETE heard before its upload keeps that upload from starting, a hundred ids per device at most", async () => {
    const stt = new FakeStt();
    const profile = new TranscriptionService(stt).at(jobsDir())!;
    const id = "7c1e5d7a-52b4-4c0e-9d41-1c1f0a6b9e05";
    // The stop overtook the upload on the way: the gateway does not know the job yet.
    await profile.delete(id, "mac").catch(() => {});
    const form = dictation();
    form.set("background", "true");
    expect(await profile.handle(new Request("http://gateway/api/transcriptions", { method: "POST", body: form, headers: { "x-nuo-transcription-id": id } }), "mac")).toEqual({ id });
    await Bun.sleep(30);
    expect(stt.seen).toHaveLength(0);
    const stopped = (profile as unknown as { stopped: Map<string, Map<string, number>> }).stopped;
    for (let i = 0; i < 150; i++) await profile.delete(crypto.randomUUID(), "mac").catch(() => {});
    expect(stopped.get("mac")?.size).toBe(100);
  });

  test("a retry sent while the first upload is still being read waits for it, and sends its own audio when it dies", async () => {
    const stt = new FakeStt();
    const profile = new TranscriptionService(stt).at(jobsDir())!;
    const id = "6f1c2b9e-4a7d-4c55-9e1f-2b8a7c3d1e40";
    const form = dictation();
    form.set("background", "true");
    const whole = new Response(form);
    const type = whole.headers.get("content-type")!;
    let die = () => {};
    const body = new ReadableStream<Uint8Array>({
      async start(controller) {
        const bytes = new Uint8Array(await whole.arrayBuffer());
        controller.enqueue(bytes.slice(0, 100));
        await new Promise<void>((resolve) => (die = resolve));
        controller.error(new Error("connection lost"));
      },
    });
    const first = profile
      .handle(new Request("http://gateway/api/transcriptions", { method: "POST", headers: { "content-type": type, "x-nuo-transcription-id": id }, body, duplex: "half" } as RequestInit), "mac")
      .then((r) => r, (e) => ({ failed: e.status }));
    await Bun.sleep(20);
    // The app's replay on the other route, complete this time.
    const again = dictation();
    again.set("background", "true");
    const second = profile.handle(new Request("http://gateway/api/transcriptions", { method: "POST", body: again, headers: { "x-nuo-transcription-id": id } }), "mac");
    await Bun.sleep(20);
    die();
    expect(await first).toEqual({ failed: 400 });
    expect(await second).toEqual({ id });
    await until(() => profile.job(id, "mac").status === "done");
    expect(profile.job(id, "mac").status).toBe("done");
    expect(stt.seen).toHaveLength(1);
  });

  test("a job named by its form field, then sent again by its header, is waited for without spinning", async () => {
    const stt = new FakeStt();
    const profile = new TranscriptionService(stt).at(jobsDir())!;
    const id = "6f1c2b9e-4a7d-4c55-9e1f-2b8a7c3d1e41";
    // A slow disk keeps the first upload, named only in its form, reserved for a while.
    const create = JobStore.prototype.create;
    let release = () => {};
    const written = new Promise<void>((resolve) => (release = resolve));
    JobStore.prototype.create = async function (this: JobStore, ...args: Parameters<JobStore["create"]>) {
      await written;
      return create.apply(this, args);
    };
    try {
      const form = dictation();
      form.set("background", "true");
      form.set("id", id);
      const first = profile.handle(new Request("http://gateway/api/transcriptions", { method: "POST", body: form }), "mac");
      const reserved = (profile as unknown as { reserved: Map<string, string> }).reserved;
      await until(() => reserved.has(id));
      const again = dictation();
      again.set("background", "true");
      const second = profile.handle(new Request("http://gateway/api/transcriptions", { method: "POST", body: again, headers: { "x-nuo-transcription-id": id } }), "mac");
      await Bun.sleep(20);
      release();
      expect(await first).toEqual({ id });
      expect(await second).toEqual({ id });
    } finally {
      JobStore.prototype.create = create;
    }
    await until(() => stt.seen.length === 1);
    await Bun.sleep(20);
    expect(stt.seen).toHaveLength(1);
  });

  test("a resend waits for the first upload a while, then is told the gateway is busy without its body being read", async () => {
    const stt = new FakeStt();
    const profile = new TranscriptionService(stt, Date.now, { uploadWaitMs: 60 }).at(jobsDir())!;
    const id = "6f1c2b9e-4a7d-4c55-9e1f-2b8a7c3d1e42";
    const form = dictation();
    form.set("background", "true");
    const whole = new Response(form);
    const type = whole.headers.get("content-type")!;
    let die = () => {};
    const stuck = new ReadableStream<Uint8Array>({
      async start(controller) {
        const bytes = new Uint8Array(await whole.arrayBuffer());
        controller.enqueue(bytes.slice(0, 100));
        await new Promise<void>((resolve) => (die = resolve));
        controller.error(new Error("connection lost"));
      },
    });
    const first = profile
      .handle(new Request("http://gateway/api/transcriptions", { method: "POST", headers: { "content-type": type, "x-nuo-transcription-id": id }, body: stuck, duplex: "half" } as RequestInit), "mac")
      .catch(() => undefined);
    await Bun.sleep(20);
    const again = dictation();
    again.set("background", "true");
    const resend = new Request("http://gateway/api/transcriptions", { method: "POST", body: again, headers: { "x-nuo-transcription-id": id } });
    const clock = performance.now();
    expect(profile.handle(resend, "mac")).rejects.toMatchObject({ status: 429 });
    await Bun.sleep(150);
    expect(performance.now() - clock).toBeLessThan(1_000);
    // Answered without its upload ever being read: nothing of it stays in memory past the answer.
    expect(resend.bodyUsed).toBe(false);
    die();
    await first;
  });

  test("a resume whose audio cannot be read, or whose attempt cannot be counted, fails instead of hanging", async () => {
    const unreadable = jobsDir();
    const a = leftRunning(unreadable);
    chmodSync(join(unreadable, `${a}.audio`), 0o000);
    const first = new TranscriptionService(new FakeStt()).at(unreadable)!;
    await until(() => first.job(a, "mac").status === "failed");
    expect(first.job(a, "mac").status).toBe("failed");

    const locked = jobsDir();
    const b = leftRunning(locked);
    const stt = new FakeStt();
    stt.transcribe = () => new Promise(() => {});
    const second = new TranscriptionService(stt).at(locked)!;
    chmodSync(locked, 0o500);
    try {
      await until(() => second.job(b, "mac").status === "failed", );
      expect(second.job(b, "mac").status).toBe("failed");
    } finally {
      chmodSync(locked, 0o700);
    }
  });

  test("a retry sending the same jobs while they are still being read takes no second place", async () => {
    const stt = new FakeStt();
    const profile = new TranscriptionService(stt).at(jobsDir())!;
    const ids = ["11111111-1111-4111-8111-111111111111", "22222222-2222-4222-8222-222222222222"];
    const slow = (id: string) => {
      const form = dictation();
      form.set("background", "true");
      const whole = new Response(form);
      const type = whole.headers.get("content-type")!;
      let release = () => {};
      const gate = new Promise<void>((resolve) => (release = resolve));
      const body = new ReadableStream<Uint8Array>({
        async start(controller) {
          const bytes = new Uint8Array(await whole.arrayBuffer());
          controller.enqueue(bytes.slice(0, 100));
          await gate;
          controller.enqueue(bytes.slice(100));
          controller.close();
        },
      });
      const req = new Request("http://gateway/api/transcriptions", { method: "POST", headers: { "content-type": type, "x-nuo-transcription-id": id }, body, duplex: "half" } as RequestInit);
      return { answer: profile.handle(req, "mac").then((r) => r, (e) => ({ status: e.status })), release };
    };
    // The follower's two streams, then the retry's same two, before any upload is complete.
    const sends = [slow(ids[0]!), slow(ids[1]!), slow(ids[0]!), slow(ids[1]!)];
    await Bun.sleep(20);
    sends.forEach((s) => s.release());
    expect(await Promise.all(sends.map((s) => s.answer))).toEqual([{ id: ids[0] }, { id: ids[1] }, { id: ids[0] }, { id: ids[1] }]);
    await until(() => stt.seen.length === 2);
    await Bun.sleep(20);
    expect(stt.seen).toHaveLength(2);
  });

  test("a job deleted while the gateway resumes it does not come back as failed", async () => {
    const dir = jobsDir();
    const id = leftRunning(dir);
    const stt = new FakeStt();
    const profile = new TranscriptionService(stt).at(dir)!;
    await profile.delete(id, "mac");
    await Bun.sleep(50);
    expect(stt.seen).toHaveLength(0);
    expect(readdirSync(dir)).toEqual([]);
    expect(() => profile.job(id, "mac")).toThrow("unknown or expired transcription");
  });

  test("a provider error without words still tells the app something", async () => {
    const stt = new FakeStt();
    stt.transcribe = async () => {
      throw new HttpError(502, "  ");
    };
    const profile = new TranscriptionService(stt).at(jobsDir())!;
    const { id } = (await post(profile, "mac", true)) as { id: string };
    await until(() => profile.job(id, "mac").status === "failed");
    expect(profile.job(id, "mac")).toEqual({ status: "failed", error: { status: 502, message: "the transcription failed at the provider" } });
  });

  test("audio left beside a finished job by a crash goes at startup", async () => {
    const dir = jobsDir();
    mkdirSync(dir, { recursive: true });
    const id = "5b0c9a3e-1d2f-4a6b-8c7d-9e0f1a2b3c4d";
    writeFileSync(join(dir, `${id}.json`), JSON.stringify({
      id, deviceId: "mac", createdAt: Date.now() - 60_000, finishedAt: Date.now() - 30_000, status: "done", attempts: 1,
      result: { text: "Julie Martin valide le devis de 4 200 euros.", provider: "elevenlabs", model: "scribe_v3", ms: 900 },
      request: { filename: "meeting-them.m4a", otherLanguages: [], keyterms: [], segments: true, speakers: true, seconds: 1800, background: true, audioType: "audio/mp4" },
    }));
    writeFileSync(join(dir, `${id}.audio`), new Uint8Array(4096));
    new TranscriptionService(new FakeStt()).at(dir)!;
    expect(readdirSync(dir)).toEqual([`${id}.json`]);
  });

  test("a file where the jobs folder should be leaves the profile without transcription, not closed", () => {
    const parent = mkdtempSync(join(tmpdir(), "nuo-transcriptions-"));
    writeFileSync(join(parent, "transcriptions"), "pas un dossier");
    expect(new TranscriptionService(new FakeStt()).at(join(parent, "transcriptions"))).toBeUndefined();
  });

  test("a device is held back after 120 transcriptions in 10 minutes", async () => {
    let now = Date.parse("2026-11-14T09:00:00Z");
    const profile = new TranscriptionService(new FakeStt(), () => now).at(jobsDir())!;
    for (let i = 0; i < 120; i++) await post(profile, "iphone");
    expect(post(profile, "iphone")).rejects.toMatchObject({ status: 429 });
    now += 11 * 60_000;
    expect(((await post(profile, "iphone")) as { text: string }).text).toContain("kiné");
  });
});

describe("provider configuration", () => {
  test("ElevenLabs Scribe v3 by default, the model and provider from the environment", () => {
    const service = transcriptionFromEnv({ NUO_ELEVENLABS_API_KEY: " el-key-3f9a1c " });
    expect(service?.info()).toEqual({ provider: "elevenlabs", model: "scribe_v3" });
    expect(transcriptionFromEnv({ NUO_ELEVENLABS_API_KEY: "el-key-3f9a1c", NUO_ELEVENLABS_STT_MODEL: "scribe_v2" })?.info().model).toBe("scribe_v2");
    expect(transcriptionFromEnv({ NUO_TRANSCRIPTION_PROVIDER: "ElevenLabs", NUO_ELEVENLABS_API_KEY: "el-key-3f9a1c" })?.info().provider).toBe("elevenlabs");
    expect(transcriptionFromEnv({})).toBeUndefined();
    expect(transcriptionFromEnv({ NUO_TRANSCRIPTION_PROVIDER: "carrier-pigeon", NUO_ELEVENLABS_API_KEY: "el-key-3f9a1c" })).toBeUndefined();
  });
});
