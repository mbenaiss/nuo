import { Cdp } from "./cdp";
import { addressToUrl, safeUrl, type BrowserManager } from "./manager";

/** The app socket a viewer streams to. */
export interface ViewerSink {
  send(text: string): void;
  sendBinary(data: Uint8Array): void;
  close(code: number, reason: string): void;
}

interface Tab {
  id: string;
  title: string;
  url: string;
}

interface FrameMeta {
  deviceWidth: number;
  deviceHeight: number;
}

interface Frame {
  data: string;
  meta: FrameMeta;
  ackId: number;
}

const JPEG_QUALITY = 60;
const MAX_FRAME_SIDE = 1600;
const MAX_TEXT = 10_000;
/** Frames travel as one binary message: this header, then the JPEG bytes. */
const FRAME_HEADER_BYTES = 8;
const FRAME_KIND = 1;
/** Restarting the screencast costs a few dropped frames: only worth it when the app's surface really changed. */
const SURFACE_CHANGE_RATIO = 0.15;
const MAX_PAGE_SCALE = 5;
/** Two frames in flight let the wire and the app's decoding overlap, without letting the stream fall behind. */
const MAX_FRAMES_IN_FLIGHT = 2;

/** What kind of field has the keyboard in the page, so the app can offer the right input. Never its value. */
export type FocusKind = "text" | "password" | null;

/** windowsVirtualKeyCode and DOM `code` of the non-printable keys the app sends; Enter also types "\r" so forms submit. */
const KEYS: Record<string, { code: string; vk: number; text?: string }> = {
  Enter: { code: "Enter", vk: 13, text: "\r" },
  Backspace: { code: "Backspace", vk: 8 },
  Tab: { code: "Tab", vk: 9 },
  Escape: { code: "Escape", vk: 27 },
  Delete: { code: "Delete", vk: 46 },
  ArrowLeft: { code: "ArrowLeft", vk: 37 },
  ArrowUp: { code: "ArrowUp", vk: 38 },
  ArrowRight: { code: "ArrowRight", vk: 39 },
  ArrowDown: { code: "ArrowDown", vk: 40 },
  Home: { code: "Home", vk: 36 },
  End: { code: "End", vk: 35 },
  PageUp: { code: "PageUp", vk: 33 },
  PageDown: { code: "PageDown", vk: 34 },
};

const MOUSE_BUTTONS = new Set(["left", "middle", "right"]);
const BUTTON_MASK: Record<string, number> = { left: 1, right: 2, middle: 4 };

const isPage = (t: { type?: string; url?: string }) => t.type === "page" && !/^(devtools|chrome-extension):/.test(t.url ?? "");
const num = (v: unknown, min: number, max: number): number | undefined => (typeof v === "number" && Number.isFinite(v) ? Math.min(max, Math.max(min, v)) : undefined);

/**
 * Bridges one app socket to the shared browser over CDP: JPEG screencast of the active tab (one frame in flight,
 * paced by the app's acks), input events, tabs and navigation. Nothing the user types is logged.
 */
export class BrowserViewer {
  private cdp?: Cdp;
  private targetId?: string;
  private sessionId?: string;
  private mainFrameId?: string;
  private tabs = new Map<string, Tab>();
  private meta?: FrameMeta;
  private inFlight = 0;
  private queued?: Frame;
  private pressed = 0;
  private viewport?: { width: number; height: number };
  /** Size of the browser's own viewport (frames without override): an emulated one must fit inside it. */
  private native?: FrameMeta;
  private history = { url: "", title: "", canGoBack: false, canGoForward: false };
  private loading = false;
  private closed = false;
  private stateTimer?: ReturnType<typeof setTimeout>;
  private unsubscribe?: () => void;
  private attaching?: Promise<void>;
  private reattaching = false;
  /** Pixel size of the area the app paints the frame into: Chrome need not paint more than that. */
  private surface?: { width: number; height: number };
  private pageScale = 1;
  private focus: FocusKind = null;
  private focusTimer?: ReturnType<typeof setTimeout>;
  private surfaceTimer?: ReturnType<typeof setTimeout>;

  constructor(
    private manager: BrowserManager,
    private sink: ViewerSink,
  ) {}

  async open() {
    this.manager.viewerOpened();
    this.unsubscribe = this.manager.onLoginsChanged(() => this.scheduleState());
    this.emit({ type: "status", phase: "starting" });
    try {
      const url = await this.manager.ensure();
      if (this.closed) return;
      const cdp = await Cdp.connect(url);
      if (this.closed) return cdp.close();
      this.cdp = cdp;
      cdp.on((method, params, sessionId) => this.onEvent(method, params, sessionId));
      cdp.onClose(() => this.lost());
      const { targetInfos } = await cdp.send<{ targetInfos: { targetId: string; type: string; title: string; url: string }[] }>("Target.getTargets");
      for (const t of targetInfos) if (isPage(t)) this.tabs.set(t.targetId, { id: t.targetId, title: t.title, url: t.url });
      await cdp.send("Target.setDiscoverTargets", { discover: true });
      await this.attach(await this.initialTab());
      this.emit({ type: "status", phase: "ready" });
    } catch (e) {
      if (this.closed) return;
      this.emit({ type: "error", message: (e as Error)?.message ?? "browser unavailable" });
      this.sink.close(4503, "browser unavailable");
    }
  }

  /** Opens on the page an agent asked the user to log in to, when there is one. */
  private async initialTab(): Promise<string> {
    for (const login of this.manager.pendingLogins().reverse()) {
      if (!login.url) continue;
      const host = new URL(login.url).hostname.replace(/^www\./, "");
      const tab = [...this.tabs.values()].find((t) => {
        try {
          return new URL(t.url).hostname.replace(/^www\./, "").endsWith(host);
        } catch {
          return false;
        }
      });
      return tab?.id ?? (await this.createTab(login.url));
    }
    return this.tabs.keys().next().value ?? (await this.createTab("about:blank"));
  }

  close() {
    if (this.closed) return;
    this.closed = true;
    clearTimeout(this.stateTimer);
    clearTimeout(this.focusTimer);
    clearTimeout(this.surfaceTimer);
    this.unsubscribe?.();
    this.manager.viewerClosed();
    const { cdp, sessionId } = this;
    if (!cdp) return;
    // Detaching drops the viewport override, so agents get the normal window back.
    const done = sessionId ? cdp.send("Target.detachFromTarget", { sessionId }).catch(() => {}) : Promise.resolve();
    void done.finally(() => cdp.close());
  }

  /** One message from the app. Errors go back to the app only: their text may contain what was typed. */
  async handle(raw: string) {
    let m: Record<string, unknown>;
    try {
      m = JSON.parse(raw);
    } catch {
      return this.emit({ type: "error", message: "invalid JSON" });
    }
    if (m.type === "ping") return this.emit({ type: "pong" });
    if (m.type === "ack") return this.clientAck();
    if (!this.cdp || !this.sessionId) return;
    this.manager.touch();
    try {
      await this.dispatch(m);
    } catch (e) {
      this.emit({ type: "error", message: (e as Error)?.message ?? "browser error" });
    }
  }

  private async dispatch(m: Record<string, unknown>) {
    const cdp = this.cdp!;
    const sid = this.sessionId!;
    switch (m.type) {
      case "mouse":
        return this.mouse(m);
      case "key":
        return this.key(m);
      case "text": {
        const text = typeof m.text === "string" ? m.text.slice(0, MAX_TEXT) : "";
        if (text) await cdp.send("Input.insertText", { text }, sid);
        return;
      }
      case "navigate": {
        const url = addressToUrl(String(m.url ?? ""));
        if (!url) throw new Error("Adresse invalide");
        await cdp.send("Page.navigate", { url }, sid);
        return;
      }
      case "back":
      case "forward": {
        const h = await cdp.send<{ currentIndex: number; entries: { id: number }[] }>("Page.getNavigationHistory", {}, sid);
        const entry = h.entries[h.currentIndex + (m.type === "back" ? -1 : 1)];
        if (entry) await cdp.send("Page.navigateToHistoryEntry", { entryId: entry.id }, sid);
        return;
      }
      case "reload":
        await cdp.send("Page.reload", {}, sid);
        return;
      case "tab.select":
        if (typeof m.id === "string" && this.tabs.has(m.id) && m.id !== this.targetId) await this.attach(m.id);
        return;
      case "tab.new": {
        const url = typeof m.url === "string" && m.url ? addressToUrl(m.url) : "about:blank";
        await this.attach(await this.createTab(url ?? "about:blank"));
        return;
      }
      case "tab.close": {
        if (typeof m.id !== "string" || !this.tabs.has(m.id)) return;
        // Closing the last tab would quit the browser.
        if (this.tabs.size <= 1) await cdp.send("Page.navigate", { url: "about:blank" }, sid);
        else await cdp.send("Target.closeTarget", { targetId: m.id });
        return;
      }
      case "viewport": {
        // A headful browser's screencast paints the emulated viewport inside its window, at 1x: a larger
        // viewport or a higher scale factor only shrinks the frame.
        const maxW = this.native?.deviceWidth ?? 1280;
        const maxH = this.native?.deviceHeight ?? 700;
        const width = num(m.width, 0, maxW);
        const height = num(m.height, 0, maxH);
        this.viewport = width && height && width >= 200 && height >= 200 ? { width: Math.floor(width), height: Math.floor(height) } : undefined;
        await this.applyViewport();
        this.scheduleState();
        return;
      }
      case "surface": {
        const width = num(m.width, 0, 4 * MAX_FRAME_SIDE);
        const height = num(m.height, 0, 4 * MAX_FRAME_SIDE);
        const next = width && height && width >= 200 && height >= 200 ? { width: Math.round(width), height: Math.round(height) } : undefined;
        if (!surfaceChanged(this.surface, next)) return;
        this.surface = next;
        // Dragging a window's edge walks through many sizes: restart once it settles, or the view would blink.
        clearTimeout(this.surfaceTimer);
        this.surfaceTimer = setTimeout(() => void this.restartScreencast().catch(() => {}), 250);
        return;
      }
      case "zoom": {
        // A real page zoom, so text stays sharp instead of being an upscaled JPEG. A browser that refuses it keeps
        // its scale, and the app is not told: a failed pinch must not raise an alert.
        const factor = num(m.factor, 1, MAX_PAGE_SCALE) ?? 1;
        const applied = await cdp
          .send("Emulation.setPageScaleFactor", { pageScaleFactor: factor }, sid)
          .then(() => true)
          .catch(() => false);
        if (!applied) return;
        this.pageScale = factor;
        this.scheduleState(0);
        return;
      }
      case "done": {
        const completed = this.manager.completeLogins();
        this.emit({ type: "done", completed });
        return;
      }
      default:
        throw new Error(`unknown event type ${String(m.type)}`);
    }
  }

  private async mouse(m: Record<string, unknown>) {
    if (!this.meta) return;
    const x = (num(m.x, 0, 1) ?? 0) * this.meta.deviceWidth;
    const y = (num(m.y, 0, 1) ?? 0) * this.meta.deviceHeight;
    const button = typeof m.button === "string" && MOUSE_BUTTONS.has(m.button) ? m.button : "left";
    const modifiers = num(m.modifiers, 0, 15) ?? 0;
    const send = (params: Record<string, unknown>) => this.cdp!.send("Input.dispatchMouseEvent", { x, y, modifiers, ...params }, this.sessionId);
    switch (m.action) {
      case "click": {
        const clickCount = num(m.clickCount, 1, 3) ?? 1;
        await send({ type: "mouseMoved", button: "none" });
        await send({ type: "mousePressed", button, buttons: BUTTON_MASK[button], clickCount });
        await send({ type: "mouseReleased", button, buttons: 0, clickCount });
        this.scheduleFocus();
        return;
      }
      case "down":
        this.pressed |= BUTTON_MASK[button]!;
        await send({ type: "mousePressed", button, buttons: this.pressed, clickCount: num(m.clickCount, 1, 3) ?? 1 });
        return;
      case "up":
        this.pressed &= ~BUTTON_MASK[button]!;
        await send({ type: "mouseReleased", button, buttons: this.pressed, clickCount: num(m.clickCount, 1, 3) ?? 1 });
        this.scheduleFocus();
        return;
      case "move":
        await send({ type: "mouseMoved", button: this.pressed ? "left" : "none", buttons: this.pressed });
        return;
      case "wheel": {
        // Deltas come as fractions of the frame, like the coordinates.
        const deltaX = (num(m.deltaX, -20, 20) ?? 0) * this.meta.deviceWidth;
        const deltaY = (num(m.deltaY, -20, 20) ?? 0) * this.meta.deviceHeight;
        await send({ type: "mouseWheel", deltaX, deltaY });
        return;
      }
    }
  }

  private async key(m: Record<string, unknown>) {
    const key = typeof m.key === "string" ? m.key : "";
    const modifiers = num(m.modifiers, 0, 15) ?? 0;
    const special = KEYS[key];
    let params: Record<string, unknown>;
    if (special) {
      params = { key, code: special.code, windowsVirtualKeyCode: special.vk, nativeVirtualKeyCode: special.vk, ...(special.text && !modifiers ? { text: special.text } : {}) };
    } else if ([...key].length === 1) {
      // Shortcuts such as Ctrl+A or Ctrl+V: the character itself is typed through `text` events.
      const upper = key.toUpperCase();
      const letter = /^[A-Z]$/.test(upper);
      const vk = letter || /^[0-9]$/.test(upper) ? upper.charCodeAt(0) : 0;
      params = { key, code: letter ? `Key${upper}` : /^[0-9]$/.test(key) ? `Digit${key}` : "", windowsVirtualKeyCode: vk, nativeVirtualKeyCode: vk, ...(modifiers & ~8 ? {} : { text: key }) };
    } else {
      throw new Error("unknown key");
    }
    const sid = this.sessionId;
    await this.cdp!.send("Input.dispatchKeyEvent", { type: params.text ? "keyDown" : "rawKeyDown", modifiers, ...params }, sid);
    await this.cdp!.send("Input.dispatchKeyEvent", { type: "keyUp", modifiers, ...params, text: undefined }, sid);
    if (key === "Tab" || key === "Enter" || key === "Escape") this.scheduleFocus();
  }

  private async createTab(url: string): Promise<string> {
    const { targetId } = await this.cdp!.send<{ targetId: string }>("Target.createTarget", { url: url === "about:blank" ? url : (safeUrl(url) ?? "about:blank") });
    if (!this.tabs.has(targetId)) this.tabs.set(targetId, { id: targetId, title: "", url });
    return targetId;
  }

  private attach(targetId: string): Promise<void> {
    const run = async () => {
      const cdp = this.cdp!;
      const previous = this.sessionId;
      this.sessionId = undefined;
      this.queued = undefined;
      this.meta = undefined;
      this.pressed = 0;
      this.inFlight = 0;
      if (previous) await cdp.send("Target.detachFromTarget", { sessionId: previous }).catch(() => {});
      const { sessionId } = await cdp.send<{ sessionId: string }>("Target.attachToTarget", { targetId, flatten: true });
      this.targetId = targetId;
      this.sessionId = sessionId;
      // A background tab of a headful browser paints nothing: bring the viewed one to the front.
      await cdp.send("Target.activateTarget", { targetId }).catch(() => {});
      await cdp.send("Page.enable", {}, sessionId);
      const tree = await cdp.send<{ frameTree: { frame: { id: string } } }>("Page.getFrameTree", {}, sessionId).catch(() => undefined);
      this.mainFrameId = tree?.frameTree.frame.id;
      await this.applyViewport();
      // A fresh target starts unzoomed, and whatever had the keyboard is gone with the old page.
      this.pageScale = 1;
      this.focus = null;
      await cdp.send("Page.startScreencast", { format: "jpeg", quality: JPEG_QUALITY, ...this.screencastBounds(), everyNthFrame: 1 }, sessionId);
      await this.refreshHistory();
      this.scheduleState(0);
    };
    const next = (this.attaching ?? Promise.resolve()).catch(() => {}).then(run);
    this.attaching = next;
    return next;
  }

  /** Chrome scales each frame to fit these: sending more pixels than the app shows only costs time. */
  private screencastBounds(): { maxWidth: number; maxHeight: number } {
    const s = this.surface;
    return {
      maxWidth: Math.min(MAX_FRAME_SIDE, s?.width ?? MAX_FRAME_SIDE),
      maxHeight: Math.min(MAX_FRAME_SIDE, s?.height ?? MAX_FRAME_SIDE),
    };
  }

  private async restartScreencast() {
    const { cdp, sessionId } = this;
    if (!cdp || !sessionId) return;
    await cdp.send("Page.stopScreencast", {}, sessionId).catch(() => {});
    this.inFlight = 0;
    this.queued = undefined;
    await cdp.send("Page.startScreencast", { format: "jpeg", quality: JPEG_QUALITY, ...this.screencastBounds(), everyNthFrame: 1 }, sessionId);
  }

  /**
   * Reads what kind of field the page gave the keyboard to, a short moment after the input that may have moved it
   * (the page's own handlers run first). Only the kind, never the value: what the user types stays in the page.
   */
  private scheduleFocus(delay = 80) {
    if (this.closed) return;
    clearTimeout(this.focusTimer);
    this.focusTimer = setTimeout(() => void this.readFocus(), delay);
  }

  private async readFocus() {
    const { cdp, sessionId } = this;
    if (!cdp || !sessionId) return;
    const expression = `(() => {
      const e = document.activeElement;
      if (!e) return "";
      const tag = e.tagName;
      if (tag === "TEXTAREA") return "text";
      if (tag !== "INPUT") return e.isContentEditable ? "text" : "";
      const type = (e.getAttribute("type") || "text").toLowerCase();
      if (type === "password") return "password";
      return ["text", "email", "search", "tel", "url", "number", ""].includes(type) ? "text" : "";
    })()`;
    const r = await cdp.send<{ result?: { value?: unknown } }>("Runtime.evaluate", { expression, returnByValue: true }, sessionId).catch(() => undefined);
    const value = r?.result?.value;
    const focus: FocusKind = value === "password" || value === "text" ? value : null;
    if (this.closed || focus === this.focus) return;
    this.focus = focus;
    this.scheduleState(0);
  }

  private async applyViewport() {
    const { cdp, sessionId, viewport } = this;
    if (!cdp || !sessionId) return;
    if (viewport) {
      await cdp.send("Emulation.setDeviceMetricsOverride", { width: viewport.width, height: viewport.height, deviceScaleFactor: 1, mobile: false }, sessionId);
    } else {
      await cdp.send("Emulation.clearDeviceMetricsOverride", {}, sessionId);
    }
  }

  private async refreshHistory() {
    if (!this.cdp || !this.sessionId) return;
    const h = await this.cdp
      .send<{ currentIndex: number; entries: { url: string; title: string }[] }>("Page.getNavigationHistory", {}, this.sessionId)
      .catch(() => undefined);
    if (!h) return;
    const current = h.entries[h.currentIndex];
    this.history = { url: current?.url ?? "", title: current?.title ?? "", canGoBack: h.currentIndex > 0, canGoForward: h.currentIndex < h.entries.length - 1 };
  }

  private onEvent(method: string, p: any, sessionId?: string) {
    if (this.closed) return;
    if (sessionId) {
      if (sessionId !== this.sessionId) return;
      switch (method) {
        case "Page.screencastFrame":
          return this.frame({ data: p.data, meta: { deviceWidth: p.metadata.deviceWidth, deviceHeight: p.metadata.deviceHeight }, ackId: p.sessionId });
        case "Page.frameNavigated":
          if (p.frame?.parentId) return;
          return void this.refreshHistory().then(() => this.scheduleState());
        case "Page.navigatedWithinDocument":
          return void this.refreshHistory().then(() => this.scheduleState());
        case "Page.frameStartedLoading":
        case "Page.frameStoppedLoading":
          if (p.frameId !== this.mainFrameId) return;
          this.loading = method === "Page.frameStartedLoading";
          return void this.refreshHistory().then(() => this.scheduleState());
        case "Page.loadEventFired":
          return void this.refreshHistory().then(() => this.scheduleState());
      }
      return;
    }
    switch (method) {
      case "Target.targetCreated":
      case "Target.targetInfoChanged": {
        const t = p.targetInfo;
        if (!isPage(t)) {
          if (this.tabs.delete(t.targetId)) this.scheduleState();
          return;
        }
        this.tabs.set(t.targetId, { id: t.targetId, title: t.title, url: t.url });
        if (t.targetId === this.targetId) return void this.refreshHistory().then(() => this.scheduleState());
        return this.scheduleState();
      }
      case "Target.targetDestroyed":
        this.tabs.delete(p.targetId);
        if (p.targetId === this.targetId) void this.reattach();
        return this.scheduleState();
      case "Target.detachedFromTarget":
        if (p.sessionId === this.sessionId) void this.reattach();
        return;
    }
  }

  /** The viewed tab was closed (by the user, an agent or a crash): show another one. */
  private async reattach() {
    if (this.closed || !this.cdp || this.reattaching) return;
    this.reattaching = true;
    this.sessionId = undefined;
    try {
      const next = [...this.tabs.keys()].pop() ?? (await this.createTab("about:blank"));
      await this.attach(next);
    } catch {
    } finally {
      this.reattaching = false;
    }
  }

  private frame(f: Frame) {
    if (this.inFlight >= MAX_FRAMES_IN_FLIGHT) {
      // The app has not caught up: Chrome stops painting until it does, and the newest frame wins.
      this.queued = f;
      return;
    }
    this.sendFrame(f);
  }

  private sendFrame(f: Frame) {
    this.meta = f.meta;
    if (!this.viewport) this.native = f.meta;
    this.inFlight++;
    if (!this.closed) this.sink.sendBinary(encodeFrame(f));
    void this.cdp?.send("Page.screencastFrameAck", { sessionId: f.ackId }, this.sessionId).catch(() => {});
  }

  private clientAck() {
    this.inFlight = Math.max(0, this.inFlight - 1);
    const q = this.queued;
    this.queued = undefined;
    if (q) this.sendFrame(q);
  }

  private scheduleState(delay = 60) {
    if (this.closed) return;
    clearTimeout(this.stateTimer);
    this.stateTimer = setTimeout(() => this.emitState(), delay);
  }

  private emitState() {
    const active = this.targetId ? this.tabs.get(this.targetId) : undefined;
    this.emit({
      type: "state",
      tabs: [...this.tabs.values()],
      activeTabId: this.targetId ?? null,
      url: active?.url || this.history.url,
      // Chrome does not always report a title change on the target; the history entry has the loaded one.
      title: (this.history.url === active?.url && this.history.title) || active?.title || this.history.title,
      canGoBack: this.history.canGoBack,
      canGoForward: this.history.canGoForward,
      loading: this.loading,
      viewport: this.viewport ?? null,
      pageScale: this.pageScale,
      focus: this.focus,
      logins: this.manager.pendingLogins(),
    });
  }

  private lost() {
    if (this.closed) return;
    this.emit({ type: "status", phase: "stopped" });
    this.sink.close(4503, "browser closed");
  }

  private emit(e: Record<string, unknown>) {
    if (!this.closed) this.sink.send(JSON.stringify(e));
  }
}

/** `[kind, reserved, width u16le, height u16le, reserved u16]` then the JPEG: no base64, no JSON around the bytes. */
export function encodeFrame(f: { data: string; meta: FrameMeta }): Uint8Array {
  const jpeg = Buffer.from(f.data, "base64");
  const out = Buffer.allocUnsafe(FRAME_HEADER_BYTES + jpeg.byteLength);
  out.writeUInt8(FRAME_KIND, 0);
  out.writeUInt8(0, 1);
  out.writeUInt16LE(Math.min(65535, Math.max(0, Math.round(f.meta.deviceWidth))), 2);
  out.writeUInt16LE(Math.min(65535, Math.max(0, Math.round(f.meta.deviceHeight))), 4);
  out.writeUInt16LE(0, 6);
  jpeg.copy(out, FRAME_HEADER_BYTES);
  return out;
}

type Surface = { width: number; height: number } | undefined;

function surfaceChanged(a: Surface, b: Surface): boolean {
  if (!a || !b) return a !== b;
  const apart = (x: number, y: number) => Math.abs(x - y) / Math.max(x, y) > SURFACE_CHANGE_RATIO;
  return apart(a.width, b.width) || apart(a.height, b.height);
}
