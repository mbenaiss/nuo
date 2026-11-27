import type { Editor, Range } from "@tiptap/core";
import { NodeSelection, TextSelection } from "@tiptap/pm/state";
import type { Node as PMNode } from "@tiptap/pm/model";
import { context, h } from "./bridge";
import { BLOCKS, currentBlockId, docTitle, fold, relativePath, searchBlocks, type BlockItem } from "./commands";
import { CALLOUT_COLOR, CALLOUT_KINDS, COLORS } from "./schema";
import { t } from "./i18n";

const COLOR_LABEL: Record<string, string> = {
  gray: t("Gray"),
  brown: t("Brown"),
  orange: t("Orange"),
  yellow: t("Yellow"),
  green: t("Green"),
  blue: t("Blue"),
  purple: t("Purple"),
  pink: t("Pink"),
  red: t("Red"),
};
const CALLOUT_LABEL: Record<string, string> = { info: t("Gray"), note: t("Blue"), tip: t("Green"), important: t("Purple"), warning: t("Orange"), caution: t("Red") };

function place(el: HTMLElement, rect: { left: number; top: number; bottom: number }, below = true) {
  document.body.append(el);
  const margin = 8;
  const w = el.offsetWidth;
  const hgt = el.offsetHeight;
  let left = Math.min(Math.max(margin, rect.left), window.innerWidth - w - margin);
  let top = below ? rect.bottom + 6 : rect.top - hgt - 8;
  if (below && top + hgt > window.innerHeight - margin && rect.top - hgt - 6 > margin) top = rect.top - hgt - 6;
  if (!below && top < margin) top = rect.bottom + 8;
  el.style.left = `${left + window.scrollX}px`;
  el.style.top = `${top + window.scrollY}px`;
}

let openPopover: { el: HTMLElement; close: () => void } | null = null;

export function closePopover() {
  openPopover?.close();
}

/** One floating panel at a time; closes on outside click and Escape. */
function popover(el: HTMLElement, onClose?: () => void): () => void {
  closePopover();
  const outside = (e: Event) => {
    if (!el.contains(e.target as Node)) close();
  };
  const key = (e: KeyboardEvent) => {
    if (e.key === "Escape") {
      e.preventDefault();
      close();
    }
  };
  const close = () => {
    el.remove();
    document.removeEventListener("mousedown", outside, true);
    document.removeEventListener("keydown", key, true);
    if (openPopover?.el === el) openPopover = null;
    onClose?.();
  };
  setTimeout(() => {
    document.addEventListener("mousedown", outside, true);
    document.addEventListener("keydown", key, true);
  }, 0);
  openPopover = { el, close };
  return close;
}

// MARK: Slash menu

export class SlashMenu {
  private el = h("div", { class: "menu slash-menu", role: "listbox" });
  private items: BlockItem[] = [];
  private index = 0;
  private range: Range | null = null;
  private dismissedAt = -1;
  active = false;

  constructor(private editor: Editor) {
    this.el.addEventListener("mousedown", (e) => e.preventDefault());
  }

  /** Called on every editor update: a `/` at line start or after a space opens the menu, the text after it filters. */
  sync() {
    const { state } = this.editor;
    const { selection } = state;
    if (!selection.empty || !selection.$from.parent.isTextblock || selection.$from.parent.type.spec.code) return this.hide();
    const $from = selection.$from;
    const before = $from.parent.textBetween(0, $from.parentOffset, undefined, "￼");
    // The query may hold a space (« /titre 2 ») but cannot start with one (« 12 / 05 »).
    const m = /(?:^|\s)\/((?:[^\s/][^/\n]{0,23})?)$/.exec(before);
    if (!m) return this.hide();
    const from = $from.pos - m[1]!.length - 1;
    if (from === this.dismissedAt) return this.hide();
    this.range = { from, to: $from.pos };
    const items = searchBlocks(m[1]!);
    if (!items.length && (m[1]!.length > 3 || m[1]!.endsWith(" "))) return this.hide();
    this.show(items);
  }

  private show(items: BlockItem[]) {
    const changed = items.length !== this.items.length || items.some((x, i) => x !== this.items[i]);
    this.items = items;
    if (changed) this.index = 0;
    this.render();
    const coords = this.editor.view.coordsAtPos(this.range!.from);
    place(this.el, coords);
    this.active = true;
  }

  hide() {
    if (!this.active) return;
    this.el.remove();
    this.active = false;
  }

  dismiss() {
    if (this.range) this.dismissedAt = this.range.from;
    this.hide();
  }

  private render() {
    this.el.replaceChildren();
    if (!this.items.length) {
      this.el.append(h("div", { class: "menu-empty" }, t("No results")));
      return;
    }
    let group = "";
    const grouped = this.items.length === BLOCKS.length;
    this.items.forEach((item, i) => {
      if (grouped && item.group !== group) {
        group = item.group;
        this.el.append(h("div", { class: "menu-group" }, t(group)));
      }
      const row = h(
        "div",
        { class: `menu-item${i === this.index ? " selected" : ""}`, role: "option" },
        h("span", { class: "menu-icon" }, item.icon),
        h("span", { class: "menu-text" }, h("span", { class: "menu-label" }, item.label), h("span", { class: "menu-hint" }, item.hint)),
      );
      row.addEventListener("mouseenter", () => {
        this.index = i;
        this.el.querySelectorAll(".menu-item").forEach((n, j) => n.classList.toggle("selected", j === i));
      });
      row.addEventListener("click", () => this.choose(i));
      this.el.append(row);
    });
    this.el.querySelector(".selected")?.scrollIntoView({ block: "nearest" });
  }

  private choose(i: number) {
    const item = this.items[i];
    const range = this.range;
    this.hide();
    if (item && range) item.run(this.editor, range);
  }

  onKey(e: KeyboardEvent): boolean {
    if (!this.active) return false;
    if (e.key === "ArrowDown" || e.key === "ArrowUp") {
      const n = this.items.length;
      if (!n) return true;
      this.index = (this.index + (e.key === "ArrowDown" ? 1 : n - 1)) % n;
      this.render();
      return true;
    }
    if (e.key === "Enter" || e.key === "Tab") {
      if (!this.items.length) return false;
      this.choose(this.index);
      return true;
    }
    if (e.key === "Escape") {
      this.dismiss();
      return true;
    }
    return false;
  }
}

/** Starts a new line with « / » so the block menu opens and typing filters it (the « + » buttons). */
export function openInsertMenu(editor: Editor, afterPos?: number) {
  const { state } = editor;
  if (afterPos !== undefined) {
    const node = state.doc.nodeAt(afterPos);
    if (node?.type.name === "paragraph" && node.content.size === 0) {
      editor.chain().focus().setTextSelection(afterPos + 1).insertContent("/").run();
      return;
    }
    const at = afterPos + (node?.nodeSize ?? 0);
    editor.chain().focus().insertContentAt(at, { type: "paragraph", content: [{ type: "text", text: "/" }] }).setTextSelection(at + 2).run();
    return;
  }
  const $from = state.selection.$from;
  if ($from.parent.isTextblock && $from.parent.content.size === 0) {
    editor.chain().focus().insertContent("/").run();
  } else if ($from.parent.isTextblock) {
    const at = $from.after($from.depth);
    editor.chain().focus().insertContentAt(at, { type: "paragraph", content: [{ type: "text", text: "/" }] }).setTextSelection(at + 2).run();
  } else {
    editor.chain().focus().insertContent({ type: "paragraph", content: [{ type: "text", text: "/" }] }).run();
  }
}

// MARK: Colors

export function colorPanel(editor: Editor, apply: (kind: "text" | "bg", color: string | null) => void, calloutKind?: (kind: string) => void): HTMLElement {
  const panel = h("div", { class: "color-panel" });
  if (calloutKind) {
    panel.append(h("div", { class: "menu-group" }, t("Callout color")));
    const row = h("div", { class: "swatches" });
    for (const kind of CALLOUT_KINDS) {
      const b = h("button", { type: "button", class: `swatch bg c-${CALLOUT_COLOR[kind]}`, title: CALLOUT_LABEL[kind]! }, "A");
      b.addEventListener("click", () => calloutKind(kind));
      row.append(b);
    }
    panel.append(row);
  }
  for (const kind of ["text", "bg"] as const) {
    panel.append(h("div", { class: "menu-group" }, kind === "text" ? t("Text color") : t("Background color")));
    const row = h("div", { class: "swatches" });
    const none = h("button", { type: "button", class: "swatch none", title: t("Default") }, "A");
    none.addEventListener("click", () => apply(kind, null));
    row.append(none);
    for (const color of COLORS) {
      const b = h("button", { type: "button", class: `swatch ${kind} c-${color}`, title: COLOR_LABEL[color]! }, "A");
      b.addEventListener("click", () => apply(kind, color));
      row.append(b);
    }
    panel.append(row);
  }
  panel.addEventListener("mousedown", (e) => e.preventDefault());
  void editor;
  return panel;
}

export function applyColor(editor: Editor, kind: "text" | "bg", color: string | null, range?: { from: number; to: number }) {
  const mark = kind === "text" ? "textColor" : "bgColor";
  const c = editor.chain().focus();
  if (range) c.setTextSelection(range);
  if (color) c.setMark(mark, { color });
  else c.unsetMark(mark);
  c.run();
}

// MARK: Link and document pickers

export function linkPopover(editor: Editor) {
  const { from, to, empty } = editor.state.selection;
  const current = editor.getAttributes("link").href as string | undefined;
  const input = h("input", { type: "text", placeholder: t("Paste or type a link"), value: current ?? "" });
  const textInput = h("input", { type: "text", placeholder: t("Link text") });
  const remove = h("button", { type: "button", class: "text-button" }, t("Remove link"));
  const panel = h("div", { class: "popover link-popover" }, input);
  if (empty && !current) panel.append(textInput);
  if (current) panel.append(remove);
  const close = popover(panel, () => editor.commands.focus());
  const apply = () => {
    const href = input.value.trim();
    close();
    if (!href) return;
    const chain = editor.chain().focus();
    if (empty && !current) {
      const text = textInput.value.trim() || href;
      chain.insertContent({ type: "text", text, marks: [{ type: "link", attrs: { href } }] }).run();
    } else {
      chain.setTextSelection({ from, to }).extendMarkRange("link").setLink({ href }).run();
    }
  };
  for (const field of [input, textInput]) {
    field.addEventListener("keydown", (e) => {
      if (e.key === "Enter") {
        e.preventDefault();
        apply();
      }
    });
  }
  remove.addEventListener("click", () => {
    close();
    editor.chain().focus().setTextSelection({ from, to }).extendMarkRange("link").unsetLink().run();
  });
  place(panel, editor.view.coordsAtPos(from));
  input.focus();
}

export function docLinkPopover(editor: Editor) {
  const pos = editor.state.selection.from;
  const input = h("input", { type: "text", placeholder: t("Search for a document") });
  const list = h("div", { class: "doc-list" });
  const panel = h("div", { class: "popover doc-popover" }, input, list);
  const close = popover(panel, () => editor.commands.focus());
  let results: string[] = [];
  let index = 0;
  const choose = (path: string) => {
    close();
    editor.chain().focus().setTextSelection(pos).insertContent([{ type: "text", text: docTitle(path), marks: [{ type: "link", attrs: { href: relativePath(path) } }] }, { type: "text", text: " " }]).run();
  };
  const render = () => {
    const q = fold(input.value);
    results = context.docs.filter((d) => !q || fold(d).includes(q)).slice(0, 30);
    index = Math.min(index, Math.max(0, results.length - 1));
    list.replaceChildren(
      ...(results.length
        ? results.map((path, i) => {
            const row = h("div", { class: `menu-item${i === index ? " selected" : ""}` }, h("span", { class: "menu-icon" }, "📝"), h("span", { class: "menu-text" }, h("span", { class: "menu-label" }, docTitle(path)), h("span", { class: "menu-hint" }, path)));
            row.addEventListener("mousedown", (e) => e.preventDefault());
            row.addEventListener("click", () => choose(path));
            return row;
          })
        : [h("div", { class: "menu-empty" }, t("No documents"))]),
    );
  };
  input.addEventListener("input", () => {
    index = 0;
    render();
  });
  input.addEventListener("keydown", (e) => {
    if (e.key === "ArrowDown" || e.key === "ArrowUp") {
      e.preventDefault();
      index = (index + (e.key === "ArrowDown" ? 1 : results.length - 1)) % Math.max(1, results.length);
      render();
    } else if (e.key === "Enter" && results[index]) {
      e.preventDefault();
      choose(results[index]!);
    }
  });
  render();
  place(panel, editor.view.coordsAtPos(pos));
  input.focus();
}

// MARK: Formatting toolbar on selection

export class BubbleMenu {
  private el = h("div", { class: "bubble" });
  private mouseDown = false;
  private buttons: Record<string, HTMLButtonElement> = {};
  private turnInto = h("button", { type: "button", class: "bubble-turn" });

  constructor(private editor: Editor) {
    const add = (id: string, label: string, title: string, run: () => void) => {
      const b = h("button", { type: "button", class: `bubble-${id}`, title }, label);
      b.addEventListener("mousedown", (e) => e.preventDefault());
      b.addEventListener("click", run);
      this.buttons[id] = b;
      return b;
    };
    this.turnInto.addEventListener("mousedown", (e) => e.preventDefault());
    this.turnInto.addEventListener("click", () => this.openTurnInto());
    this.el.append(
      this.turnInto,
      h("span", { class: "sep" }),
      add("bold", "B", t("Bold (⌘B)"), () => editor.chain().focus().toggleBold().run()),
      add("italic", "I", t("Italic (⌘I)"), () => editor.chain().focus().toggleItalic().run()),
      add("underline", "U", t("Underline (⌘U)"), () => editor.chain().focus().toggleUnderline().run()),
      add("strike", "S", t("Strikethrough (⌘⇧S)"), () => editor.chain().focus().toggleStrike().run()),
      add("code", "</>", "Code (⌘E)", () => editor.chain().focus().toggleCode().run()),
      h("span", { class: "sep" }),
      add("link", t("Link"), t("Link (⌘K)"), () => linkPopover(editor)),
      add("color", "A", t("Color"), () => this.openColors()),
    );
    this.el.addEventListener("mousedown", (e) => e.preventDefault());
    document.addEventListener("mousedown", (e) => {
      if (context.platform === "mac" && !this.el.contains(e.target as Node)) this.mouseDown = true;
    });
    document.addEventListener("mouseup", () => {
      if (!this.mouseDown) return;
      this.mouseDown = false;
      setTimeout(() => this.sync(), 0);
    });
  }

  sync() {
    const { state, view } = this.editor;
    const { selection } = state;
    const show = !this.mouseDown && view.hasFocus() && !selection.empty && selection instanceof TextSelection && !state.doc.textBetween(selection.from, selection.to).match(/^\s*$/) && !selection.$from.parent.type.spec.code;
    if (!show) {
      this.el.remove();
      return;
    }
    for (const id of ["bold", "italic", "underline", "strike", "code", "link"]) this.buttons[id]!.classList.toggle("active", this.editor.isActive(id));
    const current = BLOCKS.find((b) => b.id === currentBlockId(this.editor));
    this.turnInto.textContent = `${current?.label ?? t("Text")} ▾`;
    const start = view.coordsAtPos(selection.from);
    const end = view.coordsAtPos(selection.to);
    const left = Math.min(start.left, end.left);
    document.body.append(this.el);
    // On iPhone the system menu sits above the selection: the bar goes below, clear of the selection handles.
    const below = context.platform === "ios";
    place(this.el, { left: left - 8, top: Math.min(start.top, end.top), bottom: Math.max(start.bottom, end.bottom) + (below ? 18 : 0) }, below);
  }

  hide() {
    this.el.remove();
  }

  private openColors() {
    const { from, to } = this.editor.state.selection;
    const panel = colorPanel(this.editor, (kind, color) => {
      close();
      applyColor(this.editor, kind, color, { from, to });
    });
    panel.classList.add("popover");
    const close = popover(panel);
    place(panel, this.buttons.color!.getBoundingClientRect());
  }

  private openTurnInto() {
    const panel = h("div", { class: "popover menu" });
    for (const item of BLOCKS.filter((b) => b.transform)) {
      const row = h("div", { class: "menu-item compact" }, h("span", { class: "menu-icon" }, item.icon), h("span", { class: "menu-label" }, item.label));
      row.addEventListener("mousedown", (e) => e.preventDefault());
      row.addEventListener("click", () => {
        close();
        item.run(this.editor);
      });
      panel.append(row);
    }
    const close = popover(panel);
    place(panel, this.turnInto.getBoundingClientRect());
  }
}

// MARK: Block handle (+ and ⋮⋮) and block menu

const HANDLE_TARGETS = "li, .ProseMirror > *";

export class BlockHandle {
  private el = h("div", { class: "block-handle", contenteditable: "false" });
  private plus = h("button", { type: "button", title: t("Add a block below") }, "+");
  private grip = h("button", { type: "button", title: t("Drag to move\nClick to open the menu"), draggable: "true" }, "⋮⋮");
  private pos: number | null = null;
  private target: HTMLElement | null = null;

  constructor(private editor: Editor) {
    this.el.append(this.plus, this.grip);
    document.body.append(this.el);
    const dom = editor.view.dom as HTMLElement;
    const root = dom.parentElement!;
    root.addEventListener("mousemove", (e) => this.hover(e));
    root.addEventListener("mouseleave", (e) => {
      if (!this.el.contains(e.relatedTarget as Node)) this.hideSoon();
    });
    this.el.addEventListener("mouseleave", (e) => {
      if (!root.contains(e.relatedTarget as Node)) this.hideSoon();
    });
    this.el.addEventListener("mouseenter", () => clearTimeout(this.timer));
    this.plus.addEventListener("mousedown", (e) => e.preventDefault());
    this.plus.addEventListener("click", () => {
      if (this.pos !== null) openInsertMenu(editor, this.pos);
    });
    this.grip.addEventListener("mousedown", (e) => e.stopPropagation());
    this.grip.addEventListener("click", () => {
      if (this.pos !== null) blockMenu(editor, this.pos, this.grip.getBoundingClientRect());
    });
    this.grip.addEventListener("dragstart", (e) => this.dragStart(e));
    this.grip.addEventListener("dragend", () => this.el.classList.remove("dragging"));
  }

  private timer: ReturnType<typeof setTimeout> | undefined;

  private hideSoon() {
    clearTimeout(this.timer);
    this.timer = setTimeout(() => this.el.classList.remove("visible"), 250);
  }

  private hover(e: MouseEvent) {
    const view = this.editor.view;
    const content = (view.dom as HTMLElement).getBoundingClientRect();
    let el = (e.target as HTMLElement).closest?.(HANDLE_TARGETS) as HTMLElement | null;
    if (!el || !view.dom.contains(el)) {
      const probe = document.elementFromPoint(Math.max(content.left + 24, e.clientX), e.clientY) as HTMLElement | null;
      el = probe?.closest?.(HANDLE_TARGETS) as HTMLElement | null;
    }
    if (!el || !view.dom.contains(el) || el === view.dom) return;
    this.show(el);
  }

  /** The handle follows the caret on an empty line too, so « + » is discoverable without a mouse. */
  syncWithCaret() {
    const { selection } = this.editor.state;
    const $from = selection.$from;
    if (!selection.empty || $from.depth < 1 || $from.parent.content.size !== 0 || $from.parent.type.name !== "paragraph") return;
    const dom = this.editor.view.nodeDOM($from.before($from.depth)) as HTMLElement | null;
    if (dom) this.show(dom.closest(HANDLE_TARGETS) as HTMLElement ?? dom);
  }

  private show(el: HTMLElement) {
    const pos = nodePos(this.editor, el);
    if (pos === null) return;
    clearTimeout(this.timer);
    this.pos = pos;
    this.target = el;
    const rect = el.getBoundingClientRect();
    const style = getComputedStyle(el);
    const line = parseFloat(style.lineHeight) || 24;
    const padTop = parseFloat(style.paddingTop) || 0;
    const top = el.tagName === "LI" || /^(P|H[1-6])$/.test(el.tagName) ? rect.top + padTop + line / 2 - 12 : rect.top + 2;
    this.el.style.left = `${rect.left + window.scrollX - (el.tagName === "LI" ? 76 : 54)}px`;
    this.el.style.top = `${top + window.scrollY}px`;
    this.el.classList.add("visible");
  }

  private dragStart(e: DragEvent) {
    if (this.pos === null || !this.target) return;
    const view = this.editor.view;
    const sel = NodeSelection.create(view.state.doc, this.pos);
    view.dispatch(view.state.tr.setSelection(sel));
    (view as unknown as { dragging: unknown }).dragging = { slice: sel.content(), move: true, node: sel };
    e.dataTransfer?.setData("text/plain", sel.node.textContent);
    e.dataTransfer?.setDragImage(this.target, 0, 0);
    if (e.dataTransfer) e.dataTransfer.effectAllowed = "move";
    this.el.classList.add("dragging");
  }
}

function nodePos(editor: Editor, el: HTMLElement): number | null {
  const view = editor.view;
  let inside: number;
  try {
    inside = view.posAtDOM(el, 0);
  } catch {
    return null;
  }
  if (inside > 0 && view.nodeDOM(inside - 1) === el) return inside - 1;
  if (view.nodeDOM(inside) === el) return inside;
  const $pos = view.state.doc.resolve(inside);
  for (let d = $pos.depth; d > 0; d--) {
    if (view.nodeDOM($pos.before(d)) === el) return $pos.before(d);
  }
  return null;
}

function textRange(node: PMNode, pos: number): { from: number; to: number } {
  return { from: pos + 1, to: pos + node.nodeSize - 1 };
}

export function blockMenu(editor: Editor, pos: number, anchor: { left: number; top: number; bottom: number }) {
  const node = editor.state.doc.nodeAt(pos);
  if (!node) return;
  const panel = h("div", { class: "popover menu block-menu" });
  const close = popover(panel);
  const focusInside = () => {
    const inner = Math.min(pos + 1, editor.state.doc.content.size);
    editor.chain().focus().setTextSelection(node.isTextblock || node.type.name.endsWith("Item") ? inner + (node.isTextblock ? 0 : 1) : inner).run();
  };
  const row = (icon: string, label: string, run: () => void, cls = "") => {
    const r = h("div", { class: `menu-item compact ${cls}` }, h("span", { class: "menu-icon" }, icon), h("span", { class: "menu-label" }, label));
    r.addEventListener("mousedown", (e) => e.preventDefault());
    r.addEventListener("click", () => {
      close();
      run();
    });
    panel.append(r);
  };
  const transformable = node.isTextblock || ["listItem", "taskItem", "blockquote", "callout", "bulletList", "orderedList", "taskList"].includes(node.type.name);
  if (transformable) {
    panel.append(h("div", { class: "menu-group" }, t("Turn into")));
    for (const item of BLOCKS.filter((b) => b.transform)) {
      row(item.icon, item.label, () => {
        focusInside();
        item.run(editor);
      });
    }
  }
  if (!node.isAtom) {
    const colors = colorPanel(
      editor,
      (kind, color) => {
        close();
        const range = textRange(node, pos);
        applyColor(editor, kind, color, range);
      },
      node.type.name === "callout"
        ? (kind) => {
            close();
            editor.view.dispatch(editor.state.tr.setNodeMarkup(pos, undefined, { ...node.attrs, kind }));
          }
        : undefined,
    );
    panel.append(colors);
  }
  panel.append(h("div", { class: "menu-sep" }));
  row("⧉", t("Duplicate"), () => {
    editor.view.dispatch(editor.state.tr.insert(pos + node.nodeSize, node.copy(node.content)));
  });
  row("↑", t("Move up"), () => moveBlock(editor, pos, -1));
  row("↓", t("Move down"), () => moveBlock(editor, pos, 1));
  row("🗑", t("Delete"), () => editor.view.dispatch(editor.state.tr.delete(pos, pos + node.nodeSize)), "danger");
  place(panel, anchor);
}

export function moveBlock(editor: Editor, pos: number, dir: -1 | 1) {
  const { state } = editor;
  const $pos = state.doc.resolve(pos);
  const node = state.doc.nodeAt(pos);
  if (!node) return;
  const index = $pos.index();
  const parent = $pos.parent;
  if (dir === -1 && index === 0) return;
  if (dir === 1 && index >= parent.childCount - 1) return;
  const tr = state.tr;
  if (dir === -1) {
    const prev = parent.child(index - 1);
    const target = pos - prev.nodeSize;
    tr.delete(pos, pos + node.nodeSize).insert(target, node);
    tr.setSelection(NodeSelection.create(tr.doc, target));
  } else {
    const next = parent.child(index + 1);
    tr.delete(pos, pos + node.nodeSize).insert(pos + next.nodeSize, node);
    tr.setSelection(NodeSelection.create(tr.doc, pos + next.nodeSize));
  }
  editor.view.dispatch(tr.scrollIntoView());
}

/** Position of the block holding the caret (list item, or top-level block). */
export function caretBlockPos(editor: Editor): number | null {
  const { selection } = editor.state;
  if (selection instanceof NodeSelection) return selection.from;
  const $from = selection.$from;
  for (let d = $from.depth; d > 0; d--) {
    const name = $from.node(d).type.name;
    if (name === "listItem" || name === "taskItem" || d === 1) return $from.before(d);
  }
  return null;
}

/**
 * Touch: a « ⋮⋮ » button in the margin of the block holding the caret opens the block menu (move, turn into, color,
 * duplicate, delete); a long press in the margin, or on an image or a file, does the same.
 */
export class TouchHandle {
  private el = h("button", { class: "touch-handle", type: "button", "aria-label": t("Block options") }, "⋮⋮");
  private pos: number | null = null;
  private press: ReturnType<typeof setTimeout> | undefined;

  constructor(private editor: Editor) {
    document.body.append(this.el);
    this.el.addEventListener("mousedown", (e) => e.preventDefault());
    this.el.addEventListener("click", () => this.open(this.pos));
    // The web view's text interaction would take the tap (and show its edit menu) before the click arrives.
    this.el.addEventListener("touchend", (e) => {
      e.preventDefault();
      this.open(this.pos);
    }, { passive: false });
    const dom = editor.view.dom as HTMLElement;
    document.addEventListener("touchstart", (e) => {
      const touch = e.touches[0];
      if (!touch || e.touches.length > 1) return;
      const target = e.target as HTMLElement;
      const content = dom.getBoundingClientRect();
      const atom = target.closest?.(".image-block, .file-block, .bookmark") as HTMLElement | null;
      const inMargin = touch.clientX < content.left && touch.clientY > content.top && touch.clientY < content.bottom;
      if (!atom && !inMargin) return;
      clearTimeout(this.press);
      this.press = setTimeout(() => {
        const probe = atom ?? (document.elementFromPoint(content.left + 12, touch.clientY) as HTMLElement | null);
        const block = (probe?.closest?.(HANDLE_TARGETS) as HTMLElement | null) ?? atom;
        if (block && dom.contains(block)) this.open(nodePos(editor, block));
      }, 500);
    }, { passive: true });
    for (const type of ["touchend", "touchmove", "touchcancel"]) document.addEventListener(type, () => clearTimeout(this.press), { passive: true });
  }

  sync() {
    const pos = caretBlockPos(this.editor);
    const dom = pos === null ? null : (this.editor.view.nodeDOM(pos) as HTMLElement | null);
    if (pos === null || !dom || !this.editor.view.hasFocus()) {
      this.el.classList.remove("visible");
      return;
    }
    this.pos = pos;
    const rect = dom.getBoundingClientRect();
    const content = (this.editor.view.dom as HTMLElement).getBoundingClientRect();
    const style = getComputedStyle(dom);
    const line = parseFloat(style.lineHeight) || 26;
    this.el.style.left = `${content.left + window.scrollX - 34}px`;
    this.el.style.top = `${rect.top + window.scrollY + (parseFloat(style.paddingTop) || 0) + line / 2 - 16}px`;
    this.el.classList.add("visible");
  }

  private open(pos: number | null) {
    if (pos === null) return;
    const dom = this.editor.view.nodeDOM(pos) as HTMLElement | null;
    const rect = dom?.getBoundingClientRect() ?? this.el.getBoundingClientRect();
    navigator.vibrate?.(10);
    blockMenu(this.editor, pos, { left: rect.left, top: rect.top, bottom: Math.min(rect.bottom, rect.top + 40) });
  }
}
