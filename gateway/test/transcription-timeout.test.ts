import { afterEach, describe, expect, test } from "bun:test";
import { HttpError } from "../src/bots/service";
import { timeoutMs } from "../src/transcription/elevenlabs";
import { type SpeechToText, type TranscriptionRequest, TranscriptionService } from "../src/transcription/service";
import { startTestApp, type TestApp } from "./helpers";

let t: TestApp | undefined;
afterEach(async () => {
  await t?.close();
  t = undefined;
});

/** Scribe answering a long recording: too late once, or every time. */
class SlowStt implements SpeechToText {
  readonly provider = "fake-scribe";
  readonly model = "fake-model-1";
  calls = 0;
  constructor(private lateTimes: number) {}
  async transcribe(_r: TranscriptionRequest) {
    this.calls++;
    if (this.calls <= this.lateTimes) throw new HttpError(504, "ElevenLabs ne répond pas à temps");
    return { text: "Point client Julie Martin : on valide 12 000 € avant vendredi.", segments: [{ start: 754, end: 757, text: "On valide 12 000 € avant vendredi.", speaker: "1" }] };
  }
  async warm() {}
}

async function meeting(stt: SlowStt) {
  t = await startTestApp({ transcription: new TranscriptionService(stt) });
  const form = new FormData();
  form.set("audio", new Blob([new Uint8Array([0, 0, 0, 24, 102, 116, 121, 112])], { type: "audio/mp4" }), "montre.m4a");
  form.set("seconds", "18600");
  form.set("segments", "true");
  form.set("speakers", "true");
  form.set("background", "true");
  const started = await fetch(t.base + "/api/transcriptions", { method: "POST", headers: { authorization: `Bearer ${t.token}` }, body: form });
  const { id } = await started.json();
  const poll = () => fetch(`${t!.base}/api/transcriptions/${id}`, { headers: { authorization: `Bearer ${t!.token}` } });
  for (let i = 0; i < 400 && (await poll()).status === 202; i++) await Bun.sleep(5);
  return (await poll()).json();
}

describe("long recordings", () => {
  test("a background job gets half a minute plus its length within 30 minutes, or a sixth of it within an hour", () => {
    expect(timeoutMs(12, true)).toBe(42_000);
    expect(timeoutMs(120, true)).toBe(150_000);
    expect(timeoutMs(25 * 60, true)).toBe(1_530_000);
    expect(timeoutMs(3600, true)).toBe(30 * 60_000);
    expect(timeoutMs(3 * 3600, true)).toBe(30 * 60_000);
    expect(timeoutMs(3 * 3600 + 600, true)).toBe(1_900_000);
    expect(timeoutMs(5 * 3600 + 40 * 60, true)).toBe(3_400_000);
    expect(timeoutMs(8 * 3600, true)).toBe(60 * 60_000);
    expect(timeoutMs(12)).toBe(11_200);
  });

  test("a job the provider answered too late is tried again once with the same audio", async () => {
    const stt = new SlowStt(1);
    const done = await meeting(stt);
    expect(stt.calls).toBe(2);
    expect(done).toMatchObject({ status: "done", text: "Point client Julie Martin : on valide 12 000 € avant vendredi." });
  });

  test("late twice, the job fails with the provider's reason and is not tried a third time", async () => {
    const stt = new SlowStt(5);
    const failed = await meeting(stt);
    expect(stt.calls).toBe(2);
    expect(failed).toMatchObject({ status: "failed", error: { status: 504, message: "ElevenLabs ne répond pas à temps" } });
  });
});
