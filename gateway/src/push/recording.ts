import type { Hub } from "../runner/hub";
import type { Device, Store } from "../store/store";
import type { Pusher, PushPayload } from "./apns";

const DEDUP_WINDOW_MS = 10_000;

/**
 * Keeps every alert pushed to the devices in the profile's alert history, then pushes it. `send` runs once per
 * device with the same payload, so one alert is recorded once.
 */
export function recordingPusher(inner: Pusher, store: Store, hub: Hub, o: { windowMs?: number; now?: () => number } = {}): Pusher {
  const windowMs = o.windowMs ?? DEDUP_WINDOW_MS;
  const clock = o.now ?? Date.now;
  const recent = new Map<string, number>();

  const record = (p: PushPayload) => {
    // A chat answer already sits in its conversation.
    if (p.messageId && p.destination.kind === "conversation") return;
    const at = clock();
    for (const [key, seen] of recent) if (at - seen >= windowMs) recent.delete(key);
    const key = JSON.stringify([p.title, p.body, p.destination, p.category ?? null, p.messageId ?? null]);
    if (recent.has(key)) return;
    recent.set(key, at);
    try {
      const alert = store.addAlert({ title: p.title, body: p.body, botId: p.botId, destination: p.destination });
      hub.broadcast({ type: "alert", alert });
    } catch (e) {
      console.warn(`[push] alert history: ${(e as Error)?.message ?? e}`);
    }
  };

  return {
    send(device: Device, payload: PushPayload) {
      record(payload);
      return inner.send(device, payload);
    },
    sendLiveActivity: (target, payload) => inner.sendLiveActivity(target, payload),
    sendBackground: (device, data) => inner.sendBackground(device, data),
    close: () => inner.close(),
  };
}
