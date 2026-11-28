import type { ServerWebSocket } from "bun";
import type { ServerEvent } from "../protocol";

export interface SocketData {
  /** Profile of the device; set once the socket is authenticated. */
  profileId?: string;
  deviceId: string;
  /** Token scope the socket was opened with (src/auth/policy.ts); absent means the full app scope. */
  scope?: string;
  /** Access token expiry (ms): the socket is closed then so the client reconnects with a fresh token. */
  expiresAt?: number;
  /** Opened without a token; must send `{type:"auth", accessToken}` first. */
  pending?: boolean;
  zone?: "local" | "lan" | "internet";
  ip?: string;
  /** Set on sockets that are not the event stream (the browser live view): no broadcasts, but revoked like the rest. */
  channel?: "browser";
  /** Last `presence` the app sent; unknown for older apps, which never silence the other devices. */
  active?: boolean;
  /** The Accept-Language of the upgrade request: what the gateway answers this socket in (src/i18n/language.ts). */
  languages?: string[];
}

export class Hub {
  private sockets = new Set<ServerWebSocket<SocketData>>();
  private observers = new Set<(e: ServerEvent) => void>();

  add(ws: ServerWebSocket<SocketData>) {
    this.sockets.add(ws);
  }

  remove(ws: ServerWebSocket<SocketData>) {
    this.sockets.delete(ws);
  }

  connected(deviceId: string): boolean {
    for (const ws of this.sockets) if (ws.data.deviceId === deviceId && !ws.data.channel) return true;
    return false;
  }

  /** Someone is looking at the app on one of the devices. */
  anyActive(): boolean {
    for (const ws of this.sockets) if (ws.data.active === true && !ws.data.channel) return true;
    return false;
  }

  /** Sends to the device's event sockets that pass `accept`; false when there was none. */
  sendTo(deviceId: string, e: ServerEvent, accept: (data: SocketData) => boolean = () => true): boolean {
    const msg = JSON.stringify(e);
    let sent = false;
    for (const ws of this.sockets) {
      if (ws.data.deviceId !== deviceId || ws.data.channel || (ws.data.scope ?? "app") !== "app" || !accept(ws.data)) continue;
      ws.send(msg);
      sent = true;
    }
    return sent;
  }

  broadcast(e: ServerEvent) {
    for (const fn of this.observers) {
      try {
        fn(e);
      } catch (err) {
        console.warn(`[hub] observer: ${(err as Error)?.message ?? err}`);
      }
    }
    const msg = JSON.stringify(e);
    for (const ws of this.sockets) if (!ws.data.channel) ws.send(msg);
  }

  /** Sees every broadcast event, connected devices or not; a throwing observer never stops the broadcast. Returns the unsubscribe. */
  observe(fn: (e: ServerEvent) => void): () => void {
    this.observers.add(fn);
    return () => this.observers.delete(fn);
  }

  closeDevice(deviceId: string) {
    for (const ws of this.sockets) {
      if (ws.data.deviceId !== deviceId) continue;
      ws.close(4401, "device revoked");
      this.sockets.delete(ws);
    }
  }

  closeAll() {
    for (const ws of this.sockets) ws.close(1001, "server shutting down");
    this.sockets.clear();
  }
}
