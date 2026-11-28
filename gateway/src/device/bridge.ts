import { randomUUID } from "node:crypto";
import { HttpError } from "../bots/service";
import type { Pusher } from "../push/apns";
import type { Hub, SocketData } from "../runner/hub";
import type { Device, Store } from "../store/store";
import { DEVICE_TOOL_NAMES, type DevicePlatform } from "./tools";

export interface DeviceCapabilities {
  platform: DevicePlatform;
  tools: string[];
  updatedAt: string;
}

export interface DeviceAnswer {
  ok: boolean;
  result?: unknown;
  error?: string;
}

export interface BridgeOptions {
  /** How long a bot waits for any device. */
  timeoutMs: number;
  /** How long the iPhones have to claim a request before the Macs are asked too. */
  fallbackMs: number;
}

export const DEFAULT_BRIDGE_OPTIONS: BridgeOptions = { timeoutMs: 30_000, fallbackMs: 8_000 };

interface Pending {
  tool: string;
  args: Record<string, unknown>;
  targets: Set<string>;
  claimedBy?: string;
  resolve: (a: DeviceAnswer) => void;
}

const metaKey = (deviceId: string) => `device.capabilities.${deviceId}`;

/**
 * Hands a bot's tool call to the user's iPhone, or to a Mac when no iPhone takes it: the device runs it with EventKit,
 * CoreLocation, WeatherKit or MapKit and posts the answer back. A device whose app is on screen (or a Mac, which keeps
 * its socket) gets the request on its socket; the others are woken by a silent push and claim it over HTTP.
 */
export class DeviceBridge {
  private pending = new Map<string, Pending>();

  constructor(
    private store: Store,
    private hub: Hub,
    private pusher: Pusher,
    private o: BridgeOptions = DEFAULT_BRIDGE_OPTIONS,
  ) {}

  setCapabilities(deviceId: string, input: { platform?: unknown; tools?: unknown }): DeviceCapabilities {
    if (input.platform !== "ios" && input.platform !== "mac") throw new HttpError(400, 'platform must be "ios" or "mac"');
    if (!Array.isArray(input.tools) || input.tools.some((t) => typeof t !== "string")) throw new HttpError(400, "tools must be an array of tool names");
    const caps: DeviceCapabilities = {
      platform: input.platform,
      tools: [...new Set(input.tools as string[])].filter((t) => DEVICE_TOOL_NAMES.has(t)).sort(),
      updatedAt: new Date().toISOString(),
    };
    this.store.setMeta(metaKey(deviceId), JSON.stringify(caps));
    return caps;
  }

  capabilities(deviceId: string): DeviceCapabilities | undefined {
    const raw = this.store.getMeta(metaKey(deviceId));
    if (!raw) return undefined;
    try {
      return JSON.parse(raw) as DeviceCapabilities;
    } catch {
      return undefined;
    }
  }

  /** Paired devices that can run `tool`. */
  candidates(tool: string): { device: Device; platform: DevicePlatform }[] {
    return this.store
      .devices()
      .map((device) => ({ device, caps: this.capabilities(device.id) }))
      .filter((c): c is { device: Device; caps: DeviceCapabilities } => !!c.caps?.tools.includes(tool))
      .map((c) => ({ device: c.device, platform: c.caps.platform }));
  }

  async call(tool: string, args: Record<string, unknown>): Promise<unknown> {
    if (!DEVICE_TOOL_NAMES.has(tool)) throw new HttpError(404, `unknown device tool ${tool}`);
    const candidates = this.candidates(tool);
    if (!candidates.length) {
      throw new HttpError(
        503,
        "No iPhone or Mac has turned this access on: ask the user to open Nuo, then Settings › Bot access, and to allow the access needed.",
      );
    }
    const id = randomUUID();
    const answer = new Promise<DeviceAnswer>((resolve) => this.pending.set(id, { tool, args, targets: new Set(candidates.map((c) => c.device.id)), resolve }));
    // A suspended iPhone keeps its socket open for a while without reading it: only a visible app counts as live.
    const live = (platform: DevicePlatform) => (data: SocketData) => platform === "mac" || data.active === true;
    const reach = (c: { device: Device; platform: DevicePlatform }) => {
      if (this.hub.sendTo(c.device.id, { type: "device.request", requestId: id, tool, args }, live(c.platform))) return true;
      if (!c.device.apnsToken) return false;
      void this.pusher.sendBackground(c.device, { deviceRequest: id }).catch(() => {});
      return true;
    };
    // The iPhone is always with the user; the Mac, maybe closed, only steps in when no iPhone took the request.
    const tiers = (["ios", "mac"] as const).map((p) => candidates.filter((c) => c.platform === p)).filter((t) => t.length);
    let next = 0;
    const dispatch = (): boolean => {
      while (next < tiers.length) if (tiers[next++]!.map(reach).some(Boolean)) return true;
      return false;
    };
    if (!dispatch()) {
      this.pending.delete(id);
      throw new HttpError(503, "Nuo is open on no device and notifications are turned off: ask the user to open Nuo on their iPhone or Mac, then try again.");
    }
    const timers: ReturnType<typeof setTimeout>[] = [];
    const fallback = () => {
      if (!this.pending.has(id) || this.pending.get(id)!.claimedBy || next >= tiers.length) return;
      if (dispatch()) timers.push(setTimeout(fallback, this.o.fallbackMs));
    };
    timers.push(setTimeout(fallback, this.o.fallbackMs));
    timers.push(setTimeout(() => this.settle(id, { ok: false, error: "timeout" }), this.o.timeoutMs));
    try {
      const a = await answer;
      if (a.ok) return a.result ?? null;
      if (a.error === "timeout") {
        throw new HttpError(504, "The iPhone and the Mac did not answer in time: Nuo may be closed, or the device offline. Suggest that the user opens Nuo and tries again.");
      }
      throw new HttpError(422, a.error || "the device refused the request");
    } finally {
      for (const t of timers) clearTimeout(t);
      this.pending.delete(id);
    }
  }

  /**
   * A device takes the request before running it, so a write never runs twice when the iPhone answers late and the
   * Mac was asked meanwhile. The claimant may claim again (socket and push both arrived).
   */
  claim(id: string, deviceId: string): { id: string; tool: string; args: Record<string, unknown> } | "missing" | "taken" {
    const p = this.pending.get(id);
    if (!p || !p.targets.has(deviceId)) return "missing";
    if (p.claimedBy && p.claimedBy !== deviceId) return "taken";
    p.claimedBy = deviceId;
    return { id, tool: p.tool, args: p.args };
  }

  /** Only the device that claimed the request answers it. */
  answer(id: string, deviceId: string, a: DeviceAnswer): boolean {
    const p = this.pending.get(id);
    if (!p || p.claimedBy !== deviceId) return false;
    return this.settle(id, a);
  }

  private settle(id: string, a: DeviceAnswer): boolean {
    const p = this.pending.get(id);
    if (!p) return false;
    this.pending.delete(id);
    p.resolve(a);
    return true;
  }

  close() {
    for (const id of [...this.pending.keys()]) this.settle(id, { ok: false, error: "the gateway is restarting" });
  }
}
