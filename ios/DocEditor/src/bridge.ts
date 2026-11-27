import { locale, t } from "./i18n";
/** Messages to the app (WKScriptMessageHandler "nuo"); logged when the page runs in a plain browser. */
export function post(type: string, payload: Record<string, unknown> = {}) {
  const handler = (window as unknown as { webkit?: { messageHandlers?: { nuo?: { postMessage(m: unknown): void } } } }).webkit?.messageHandlers?.nuo;
  if (handler) handler.postMessage({ type, ...payload });
  else console.log("[nuo]", type, payload);
}

export interface Context {
  /** Folder of the document in the docs repo, to resolve relative paths. */
  basePath: string;
  platform: "mac" | "ios";
  /** Sizes of the repo's files, for file cards. */
  sizes: Record<string, number>;
  /** Markdown documents of the repo, for "Link to a document". */
  docs: string[];
}

export const context: Context = { basePath: "", platform: "mac", sizes: {}, docs: [] };

export function repoPath(src: string): string | null {
  if (!src || /^[a-z][a-z0-9+.-]*:/i.test(src) || src.startsWith("/api/")) return null;
  let path = src;
  try {
    path = decodeURIComponent(src);
  } catch {}
  const parts = (path.startsWith("/") ? path.slice(1) : context.basePath ? `${context.basePath}/${path}` : path).split("/");
  const out: string[] = [];
  for (const p of parts) {
    if (!p || p === ".") continue;
    if (p === "..") out.pop();
    else out.push(p);
  }
  return out.join("/");
}

/** URL the web view can load: repo files go through the app's scheme handler (it adds the gateway token). */
export function displayURL(src: string, kind: "asset" | "thumb" = "asset"): string {
  const path = repoPath(src);
  if (path === null) return src;
  return `nuo-editor://app/${kind}?path=${encodeURIComponent(path)}`;
}

export function fileKind(name: string): "pdf" | "video" | "audio" | "image" | "file" {
  const ext = name.toLowerCase().split(/[?#]/)[0]!.split(".").pop() ?? "";
  if (ext === "pdf") return "pdf";
  if (["mp4", "mov", "m4v", "webm"].includes(ext)) return "video";
  if (["mp3", "m4a", "wav", "aac", "ogg", "flac"].includes(ext)) return "audio";
  if (["png", "jpg", "jpeg", "gif", "webp", "heic", "svg"].includes(ext)) return "image";
  return "file";
}

export function formatSize(bytes: number | undefined): string {
  if (bytes === undefined) return "";
  if (bytes < 1024) return t("{0} B", bytes);
  if (bytes < 1024 * 1024) return t("{0} KB", Math.round(bytes / 1024));
  const megabytes = new Intl.NumberFormat(locale(), { minimumFractionDigits: 1, maximumFractionDigits: 1 }).format(bytes / 1024 / 1024);
  return t("{0} MB", megabytes);
}

let toastTimer: ReturnType<typeof setTimeout> | undefined;

export function toast(message: string) {
  let el = document.getElementById("toast");
  if (!el) {
    el = document.createElement("div");
    el.id = "toast";
    document.body.appendChild(el);
  }
  el.textContent = message;
  el.classList.add("visible");
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => el!.classList.remove("visible"), 5000);
}

export function h<K extends keyof HTMLElementTagNameMap>(tag: K, attrs: Record<string, string> = {}, ...children: (Node | string)[]): HTMLElementTagNameMap[K] {
  const el = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs)) {
    if (k === "class") el.className = v;
    else el.setAttribute(k, v);
  }
  for (const c of children) el.append(c);
  return el;
}
