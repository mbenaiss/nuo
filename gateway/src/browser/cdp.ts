/** Minimal Chrome DevTools Protocol client over the browser-level WebSocket, with flattened target sessions. */
export type CdpListener = (method: string, params: any, sessionId?: string) => void;

const CALL_TIMEOUT_MS = 15_000;

export class Cdp {
  private nextId = 1;
  private pending = new Map<number, { resolve: (v: any) => void; reject: (e: Error) => void; timer: ReturnType<typeof setTimeout> }>();
  private listeners = new Set<CdpListener>();
  private closeListeners = new Set<() => void>();
  closed = false;

  private constructor(private ws: WebSocket) {
    ws.onmessage = (m) => this.receive(String(m.data));
    ws.onclose = () => this.shutdown();
    ws.onerror = () => this.shutdown();
  }

  static connect(url: string, timeoutMs = 10_000): Promise<Cdp> {
    return new Promise((resolve, reject) => {
      const ws = new WebSocket(url);
      const timer = setTimeout(() => {
        ws.close();
        reject(new Error("DevTools connection timed out"));
      }, timeoutMs);
      ws.onopen = () => {
        clearTimeout(timer);
        resolve(new Cdp(ws));
      };
      ws.onerror = () => {
        clearTimeout(timer);
        reject(new Error("DevTools connection failed"));
      };
    });
  }

  send<T = any>(method: string, params: Record<string, unknown> = {}, sessionId?: string): Promise<T> {
    if (this.closed) return Promise.reject(new Error("DevTools connection closed"));
    const id = this.nextId++;
    return new Promise<T>((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`${method} timed out`));
      }, CALL_TIMEOUT_MS);
      this.pending.set(id, { resolve, reject, timer });
      this.ws.send(JSON.stringify({ id, method, params, ...(sessionId ? { sessionId } : {}) }));
    });
  }

  on(listener: CdpListener): () => void {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  onClose(listener: () => void) {
    if (this.closed) listener();
    else this.closeListeners.add(listener);
  }

  close() {
    if (this.closed) return;
    this.ws.close();
    this.shutdown();
  }

  private receive(raw: string) {
    let msg: { id?: number; result?: unknown; error?: { message?: string }; method?: string; params?: unknown; sessionId?: string };
    try {
      msg = JSON.parse(raw);
    } catch {
      return;
    }
    if (msg.id !== undefined) {
      const p = this.pending.get(msg.id);
      if (!p) return;
      this.pending.delete(msg.id);
      clearTimeout(p.timer);
      if (msg.error) p.reject(new Error(msg.error.message ?? "DevTools error"));
      else p.resolve(msg.result);
      return;
    }
    if (msg.method) for (const l of this.listeners) l(msg.method, msg.params ?? {}, msg.sessionId);
  }

  private shutdown() {
    if (this.closed) return;
    this.closed = true;
    for (const p of this.pending.values()) {
      clearTimeout(p.timer);
      p.reject(new Error("DevTools connection closed"));
    }
    this.pending.clear();
    for (const l of this.closeListeners) l();
    this.closeListeners.clear();
  }
}
