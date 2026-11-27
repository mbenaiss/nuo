import type { Editor, NodeViewRendererProps } from "@tiptap/core";
import type { Node as PMNode } from "@tiptap/pm/model";
import type { NodeView } from "@tiptap/pm/view";
import { context, displayURL, fileKind, formatSize, h, post, repoPath } from "./bridge";
import { drawMermaid } from "./mermaid";
import { CALLOUT_COLOR } from "./schema";
import { beginPick } from "./uploads";
import { t } from "./i18n";

type Props = NodeViewRendererProps;

function update(props: Props, attrs: Record<string, unknown>) {
  const pos = typeof props.getPos === "function" ? props.getPos() : undefined;
  if (pos === undefined) return;
  const { view } = props.editor;
  view.dispatch(view.state.tr.setNodeMarkup(pos, undefined, { ...props.node.attrs, ...attrs }));
}

/** A link pasted in an empty media block fills it; typing goes on below it. */
function fill(props: Props, attrs: Record<string, unknown>) {
  update(props, attrs);
  const pos = typeof props.getPos === "function" ? props.getPos() : undefined;
  if (pos === undefined) return;
  const after = pos + props.editor.state.doc.nodeAt(pos)!.nodeSize;
  props.editor.chain().focus().setTextSelection(Math.min(after + 1, props.editor.state.doc.content.size)).run();
}

function removeNode(props: Props) {
  const pos = typeof props.getPos === "function" ? props.getPos() : undefined;
  if (pos === undefined) return;
  const { view } = props.editor;
  view.dispatch(view.state.tr.delete(pos, pos + props.node.nodeSize));
}

/** Notion's empty media block: upload a file or paste a link. */
function picker(props: Props, label: string, accept: string, onLink: (url: string) => void): HTMLElement {
  const input = h("input", { type: "url", placeholder: t("Paste a link…"), class: "picker-input" });
  const upload = h("button", { class: "picker-upload", type: "button" }, t("Upload from this device"));
  upload.addEventListener("click", (e) => {
    e.preventDefault();
    const pos = typeof props.getPos === "function" ? props.getPos() : undefined;
    if (pos !== undefined) beginPick(props.editor, pos, props.node.nodeSize, accept);
  });
  input.addEventListener("keydown", (e) => {
    if (e.key === "Enter" && input.value.trim()) {
      e.preventDefault();
      onLink(input.value.trim());
    }
    if (e.key === "Escape") props.editor.commands.focus();
  });
  const remove = h("button", { class: "picker-remove", type: "button", title: t("Delete") }, "×");
  remove.addEventListener("click", () => removeNode(props));
  return h("div", { class: "picker", contenteditable: "false" }, h("div", { class: "picker-title" }, label), upload, h("div", { class: "picker-or" }, t("or")), input, remove);
}

export function imageView(props: Props): NodeView {
  let node = props.node;
  const dom = h("figure", { class: "image-block" });
  const render = () => {
    dom.replaceChildren();
    if (!node.attrs.src) {
      dom.append(picker(props, t("Image"), "image", (url) => fill(props, { src: url })));
      return;
    }
    const frame = h("div", { class: "image-frame" });
    const img = h("img", { src: displayURL(node.attrs.src), alt: node.attrs.alt ?? "", draggable: "false" });
    if (node.attrs.width) frame.style.width = `${node.attrs.width}px`;
    img.addEventListener("error", () => frame.classList.add("broken"));
    const handle = h("div", { class: "resize-handle", title: t("Resize") });
    handle.addEventListener("pointerdown", (e) => {
      e.preventDefault();
      const startX = e.clientX;
      const startW = frame.getBoundingClientRect().width;
      const max = dom.getBoundingClientRect().width;
      const move = (ev: PointerEvent) => {
        frame.style.width = `${Math.max(80, Math.min(max, startW + ev.clientX - startX))}px`;
      };
      const up = () => {
        window.removeEventListener("pointermove", move);
        window.removeEventListener("pointerup", up);
        const width = Math.round(frame.getBoundingClientRect().width);
        update(props, { width: width >= max - 2 ? null : String(width) });
      };
      window.addEventListener("pointermove", move);
      window.addEventListener("pointerup", up);
    });
    frame.append(img, handle);
    const caption = h("input", { class: "caption", placeholder: t("Add a caption"), value: node.attrs.alt ?? "" });
    caption.addEventListener("change", () => update(props, { alt: caption.value || null }));
    caption.addEventListener("keydown", (e) => {
      if (e.key === "Enter") {
        e.preventDefault();
        caption.blur();
        props.editor.commands.focus();
      }
    });
    dom.append(frame, caption);
  };
  render();
  return {
    dom,
    update(next) {
      if (next.type !== node.type) return false;
      const changed = next.attrs.src !== node.attrs.src || next.attrs.width !== node.attrs.width || next.attrs.alt !== node.attrs.alt;
      node = next;
      if (changed) render();
      return true;
    },
    stopEvent: (e) => (e.target as HTMLElement).tagName === "INPUT" || (e.target as HTMLElement).closest?.(".resize-handle, .picker") != null,
    ignoreMutation: () => true,
  };
}

const KIND_LABEL = { pdf: t("PDF"), video: t("Video"), audio: t("Audio"), image: t("Image"), file: t("File") } as const;
const KIND_ICON = { pdf: "📄", video: "🎬", audio: "🎧", image: "🖼️", file: "📎" } as const;

export function fileView(props: Props): NodeView {
  let node = props.node;
  const dom = h("div", { class: "file-block", contenteditable: "false" });
  const render = () => {
    dom.replaceChildren();
    const src = node.attrs.src as string;
    if (!src) {
      const accept = (node.attrs.name as string) || "file";
      const label = { pdf: t("PDF"), video: t("Video"), audio: t("Audio") }[accept] ?? t("File");
      dom.append(picker(props, label, accept, (url) => fill(props, { src: url, name: decodeURIComponent(url.split("/").pop() || url) })));
      return;
    }
    const name = (node.attrs.name as string) || src.split("/").pop() || src;
    const kind = fileKind(name.includes(".") ? name : src);
    const path = repoPath(src);
    const meta = [KIND_LABEL[kind], formatSize(path ? context.sizes[path] : undefined)].filter(Boolean).join(" · ");
    const open = () => post("openFile", { src, name });
    if (kind === "pdf" && path) {
      const preview = h("img", { class: "pdf-preview", src: displayURL(src, "thumb"), alt: "", draggable: "false" });
      preview.addEventListener("error", () => preview.remove());
      preview.addEventListener("click", open);
      dom.append(preview);
    }
    const card = h(
      "div",
      { class: "file-card" },
      h("span", { class: "file-icon" }, KIND_ICON[kind]),
      h("span", { class: "file-text" }, h("span", { class: "file-name" }, name), h("span", { class: "file-meta" }, meta)),
      h("button", { class: "file-open", type: "button" }, kind === "video" || kind === "audio" ? t("Play") : t("Open")),
    );
    card.addEventListener("click", open);
    dom.append(card);
  };
  render();
  return {
    dom,
    update(next) {
      if (next.type !== node.type) return false;
      node = next;
      render();
      return true;
    },
    stopEvent: (e) => (e.target as HTMLElement).closest?.(".picker, .file-open") != null,
    ignoreMutation: () => true,
  };
}

export function refreshFileSizes(editor: Editor) {
  editor.view.dispatch(editor.state.tr.setMeta("refreshFiles", true));
}

export function bookmarkView(props: Props): NodeView {
  let node = props.node;
  const dom = h("div", { class: "bookmark", contenteditable: "false" });
  const render = () => {
    dom.replaceChildren();
    const href = node.attrs.href as string;
    if (!href) {
      const input = h("input", { type: "url", placeholder: t("Paste a link (site, video, document…)"), class: "picker-input" });
      input.addEventListener("keydown", (e) => {
        if (e.key === "Enter" && input.value.trim()) {
          e.preventDefault();
          const url = input.value.trim();
          let title = url;
          try {
            title = new URL(url).hostname.replace(/^www\./, "");
          } catch {}
          fill(props, { href: url, title });
        }
      });
      const remove = h("button", { class: "picker-remove", type: "button", title: t("Delete") }, "×");
      remove.addEventListener("click", () => removeNode(props));
      dom.append(h("div", { class: "picker" }, h("div", { class: "picker-title" }, t("Embed a link")), input, remove));
      setTimeout(() => input.focus(), 0);
      return;
    }
    let host = href;
    try {
      host = new URL(href).hostname.replace(/^www\./, "");
    } catch {}
    const card = h("div", { class: "bookmark-card" }, h("span", { class: "bookmark-title" }, node.attrs.title || host), h("span", { class: "bookmark-url" }, `🔗 ${host}`));
    card.addEventListener("click", () => post("openLink", { href }));
    dom.append(card);
  };
  render();
  return {
    dom,
    update(next) {
      if (next.type !== node.type) return false;
      node = next;
      render();
      return true;
    },
    stopEvent: (e) => (e.target as HTMLElement).tagName === "INPUT",
    ignoreMutation: () => true,
  };
}

/** Shown when the Markdown names no icon; not written back. */
const KIND_EMOJI: Record<string, string> = { info: "💡", note: "ℹ️", tip: "✅", important: "❗", warning: "⚠️", caution: "🛑" };

const EMOJIS = ["💡", "📌", "⚠️", "❗", "✅", "❌", "ℹ️", "🔥", "⭐", "📝", "🎯", "🚀", "💬", "📅", "💰", "🔒"];

export function calloutView(props: Props): NodeView {
  let node: PMNode = props.node;
  const icon = h("button", { class: "callout-icon", contenteditable: "false", type: "button", title: t("Change the icon") });
  const content = h("div", { class: "callout-body" });
  const dom = h("div", { class: "callout" }, icon, content);
  const paint = () => {
    dom.className = `callout c-${CALLOUT_COLOR[node.attrs.kind] ?? "gray"}`;
    icon.textContent = node.attrs.emoji || KIND_EMOJI[node.attrs.kind] || "💡";
  };
  icon.addEventListener("mousedown", (e) => e.preventDefault());
  icon.addEventListener("click", () => {
    const panel = h("div", { class: "popover emoji-panel" });
    for (const emoji of EMOJIS) {
      const b = h("button", { type: "button" }, emoji);
      b.addEventListener("click", () => {
        update({ ...props, node }, { emoji });
        panel.remove();
      });
      panel.append(b);
    }
    const none = h("button", { type: "button", class: "wide" }, t("No icon"));
    none.addEventListener("click", () => {
      update({ ...props, node }, { emoji: null });
      panel.remove();
    });
    panel.append(none);
    const r = icon.getBoundingClientRect();
    panel.style.left = `${r.left + window.scrollX}px`;
    panel.style.top = `${r.bottom + window.scrollY + 4}px`;
    document.body.append(panel);
    const close = (e: Event) => {
      if (!panel.contains(e.target as Node)) {
        panel.remove();
        document.removeEventListener("mousedown", close, true);
      }
    };
    setTimeout(() => document.addEventListener("mousedown", close, true), 0);
  });
  paint();
  return {
    dom,
    contentDOM: content,
    update(next) {
      if (next.type !== node.type) return false;
      node = next;
      paint();
      return true;
    },
    stopEvent: (e) => icon.contains(e.target as Node),
    ignoreMutation: (m) => icon.contains(m.target as Node) || m.target === dom,
  };
}

export function codeBlockView(props: Props): NodeView {
  let node = props.node;
  const code = h("code", { spellcheck: "false" });
  const pre = h("pre", {}, code);
  const lang = h("input", { class: "code-lang", placeholder: "langage", value: node.attrs.language ?? "", spellcheck: "false" });
  lang.addEventListener("change", () => update({ ...props, node }, { language: lang.value.trim() || null }));
  lang.addEventListener("keydown", (e) => {
    if (e.key === "Enter") {
      e.preventDefault();
      lang.blur();
      props.editor.commands.focus();
    }
  });
  // A ```mermaid block shows its diagram under the code, redrawn once typing pauses.
  const preview = h("div", { class: "mermaid-preview", contenteditable: "false" });
  let drawn: string | null = null;
  let timer: ReturnType<typeof setTimeout> | undefined;
  const draw = () => {
    const isDiagram = node.attrs.language === "mermaid";
    dom.classList.toggle("mermaid", isDiagram);
    if (!isDiagram) {
      drawn = null;
      return preview.replaceChildren();
    }
    const source = node.textContent;
    if (source === drawn) return;
    drawn = source;
    const drawing = drawMermaid(source, preview.clientWidth || dom.clientWidth || undefined);
    if (!drawing) return preview.replaceChildren();
    if ("svg" in drawing) preview.innerHTML = drawing.svg;
    else preview.replaceChildren(h("div", { class: "mermaid-error" }, t("Unreadable diagram: {0}", drawing.error)));
  };
  const dom = h("div", { class: `code-block${node.attrs.language === "math" ? " math" : ""}` }, h("div", { class: "code-head", contenteditable: "false" }, lang), pre, preview);
  requestAnimationFrame(draw);
  return {
    dom,
    contentDOM: code,
    update(next) {
      if (next.type !== node.type) return false;
      node = next;
      if (document.activeElement !== lang) lang.value = node.attrs.language ?? "";
      dom.classList.toggle("math", node.attrs.language === "math");
      clearTimeout(timer);
      timer = setTimeout(draw, 300);
      return true;
    },
    destroy: () => clearTimeout(timer),
    stopEvent: (e) => e.target === lang,
    ignoreMutation: (m) => !code.contains(m.target as Node),
  };
}
