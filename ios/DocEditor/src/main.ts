import { Editor, Extension, InputRule } from "@tiptap/core";
import { Placeholder } from "@tiptap/extensions";
import { context, post } from "./bridge";
import { BLOCKS, currentBlockId } from "./commands";
import { LOSS_TOLERANCE, createParser, lostContent, parseChecked, serialize, splitFrontMatter } from "./markdown";
import { BlockHandle, BubbleMenu, SlashMenu, TouchHandle, applyColor, blockMenu, caretBlockPos, closePopover, docLinkPopover, linkPopover, moveBlock, openInsertMenu } from "./menus";
import { bookmarkView, calloutView, codeBlockView, fileView, imageView } from "./nodeviews";
import { baseExtensions } from "./schema";
import { EditorState, TextSelection } from "@tiptap/pm/state";
import { pickAtCaret, uploadDone, uploadFailed, uploadFiles, uploadNamed } from "./uploads";
import { t } from "./i18n";

let editor: Editor;
let frontMatter = "";
let slash: SlashMenu;
let bubble: BubbleMenu | null = null;
let handle: BlockHandle | null = null;
let touchHandle: TouchHandle | null = null;
let changeTimer: ReturnType<typeof setTimeout> | undefined;
let stateTimer: ReturnType<typeof setTimeout> | undefined;
let parse: (md: string) => import("@tiptap/pm/model").Node;

const LinkInput = Extension.create({
  name: "markdownLinkInput",
  addInputRules() {
    return [
      new InputRule({
        find: /\[([^\]]+)\]\(([^)\s]+)\)$/,
        handler: ({ state, range, match }) => {
          const link = state.schema.marks.link!.create({ href: match[2] });
          state.tr.replaceWith(range.from, range.to, state.schema.text(match[1]!, [link])).removeStoredMark(link);
        },
      }),
    ];
  },
  addKeyboardShortcuts() {
    return {
      "Mod-k": () => {
        linkPopover(this.editor);
        return true;
      },
      "Mod-e": () => this.editor.commands.toggleCode(),
      "Mod-Shift-h": () => {
        applyColor(this.editor, "bg", this.editor.isActive("bgColor") ? null : "yellow");
        return true;
      },
    };
  },
});

function extensions() {
  return [
    ...baseExtensions().map((ext) => {
      const views: Record<string, unknown> = { image: imageView, fileBlock: fileView, bookmark: bookmarkView, callout: calloutView, codeBlock: codeBlockView };
      const view = views[ext.name];
      return view ? ext.extend({ addNodeView: () => view as never }) : ext;
    }),
    Placeholder.configure({
      includeChildren: false,
      placeholder: ({ node, editor: ed }) => {
        if (node.type.name === "heading") return t("Heading {0}", node.attrs.level);
        if (node.type.name === "detailsSummary") return t("Toggle title");
        if (ed.state.doc.childCount === 1 && ed.state.doc.firstChild === node) return t("Write, or type “/” for commands");
        if (node.type.name === "paragraph") return context.platform === "ios" ? t("Write, or tap + to add a block") : t("Write, or type “/” for commands");
        return "";
      },
    }),
    LinkInput,
  ];
}

/** Only a « changed » signal crosses the bridge, at most a few times a second: the app pulls the Markdown when it saves. */
function emitChange() {
  if (changeTimer) return;
  post("changed");
  changeTimer = setTimeout(() => (changeTimer = undefined), 250);
}

function currentMarkdown(): string {
  return serialize(editor.state.doc, frontMatter);
}

function emitState() {
  if (context.platform !== "ios") return;
  clearTimeout(stateTimer);
  stateTimer = setTimeout(() => {
    const can = editor.can();
    post("state", {
      bold: editor.isActive("bold"),
      italic: editor.isActive("italic"),
      underline: editor.isActive("underline"),
      strike: editor.isActive("strike"),
      code: editor.isActive("code"),
      link: editor.isActive("link"),
      block: currentBlockId(editor),
      canUndo: can.undo(),
      canRedo: can.redo(),
      selection: !editor.state.selection.empty,
    });
  }, 80);
}

function fileDrop(files: FileList | null | undefined): File[] {
  return files ? Array.from(files) : [];
}

function create(markdown: string) {
  const split = splitFrontMatter(markdown);
  frontMatter = split.front;
  if (!editor) mount();
  parse = parse ?? createParser(editor.schema);
  let doc;
  try {
    doc = parse(markdown);
  } catch (error) {
    post("lossy", { reason: String(error) });
    return;
  }
  // A fresh state rather than setContent: no transaction over the whole document, and a new undo history.
  editor.view.updateState(EditorState.create({ doc, plugins: editor.state.plugins }));
  requestAnimationFrame(() => post("loaded"));
  setTimeout(() => {
    const lost = lostContent(markdown, currentMarkdown());
    if (lost > LOSS_TOLERANCE) post("lossy", { reason: `${lost} characters` });
  }, 0);
}

function mount() {
  editor = new Editor({
    element: document.getElementById("editor")!,
    extensions: extensions(),
    content: null,
    autofocus: false,
    editorProps: {
      attributes: { spellcheck: "true", autocorrect: "on", autocapitalize: "sentences" },
      handleKeyDown: (view, event) => {
        // Text typed right before Enter may still sit in the DOM, unread: the menu must see « /titre » first.
        if (/^(Enter|Tab|Arrow|Escape)/.test(event.key)) (view as unknown as { domObserver: { flush(): void } }).domObserver.flush();
        return slash.onKey(event);
      },
      handlePaste: (view, event) => {
        // A text copied from a page or another app may also carry files (a rendering of it): the text wins.
        if (event.clipboardData?.getData("text/plain")) return false;
        const files = fileDrop(event.clipboardData?.files).filter((f) => !f.type.startsWith("text/"));
        if (!files.length) return false;
        uploadFiles(editor, files, view.state.selection.from);
        return true;
      },
      handleDrop: (view, event, _slice, moved) => {
        const files = fileDrop((event as DragEvent).dataTransfer?.files);
        if (moved || !files.length) return false;
        const at = view.posAtCoords({ left: event.clientX, top: event.clientY });
        const $pos = view.state.doc.resolve(at?.pos ?? view.state.selection.from);
        const pos = $pos.depth > 0 ? $pos.after(1) : $pos.pos;
        uploadFiles(editor, files, pos);
        return true;
      },
      handleClickOn: (_view, _pos, node, _nodePos, event) => {
        const link = (event.target as HTMLElement).closest?.("a[href]") as HTMLAnchorElement | null;
        if (link && (event.metaKey || event.ctrlKey || context.platform === "ios" && !editor.isFocused)) {
          post("openLink", { href: link.getAttribute("href") });
          return true;
        }
        void node;
        return false;
      },
    },
    onUpdate: ({ transaction }) => {
      if (transaction.getMeta("external")) return;
      emitChange();
    },
    onTransaction: () => {
      slash.sync();
      bubble?.sync();
      handle?.syncWithCaret();
      touchHandle?.sync();
      emitState();
    },
    onFocus: () => post("focus"),
    onBlur: () => {
      bubble?.hide();
      touchHandle?.sync();
      post("blur");
    },
  });
  slash = new SlashMenu(editor);
  bubble = new BubbleMenu(editor);
  document.querySelectorAll(".block-handle, .touch-handle").forEach((n) => n.remove());
  if (context.platform === "mac") handle = new BlockHandle(editor);
  else touchHandle = new TouchHandle(editor);
}

document.addEventListener("nuo-link", () => linkPopover(editor));
document.addEventListener("nuo-doclink", () => docLinkPopover(editor));

const api = {
  /** First load: `{markdown, basePath, platform, theme, sizes, docs, focus}`. */
  load(options: { markdown: string; basePath?: string; platform?: "mac" | "ios"; theme?: string; sizes?: Record<string, number>; docs?: string[]; focus?: boolean }) {
    context.basePath = options.basePath ?? "";
    context.platform = options.platform ?? "mac";
    context.sizes = options.sizes ?? {};
    context.docs = options.docs ?? [];
    document.documentElement.dataset.platform = context.platform;
    if (options.theme) api.setTheme(options.theme);
    create(options.markdown);
    if (options.focus) api.focus();
  },
  /** The file changed elsewhere and nothing is being edited here: replace the content, keep the caret if possible. */
  setMarkdown(markdown: string) {
    if (!editor) return api.load({ markdown, basePath: context.basePath, platform: context.platform });
    // The current content stays when the new one cannot be shown whole: the app switches to the Markdown source.
    const checked = parseChecked(parse, markdown);
    if ("lossy" in checked) {
      post("lossy", { reason: checked.lossy });
      return;
    }
    const doc = checked.doc;
    frontMatter = splitFrontMatter(markdown).front;
    const { from } = editor.state.selection;
    let state = EditorState.create({ doc, plugins: editor.state.plugins });
    try {
      state = state.apply(state.tr.setSelection(TextSelection.near(doc.resolve(Math.min(from, doc.content.size)))));
    } catch {}
    editor.view.updateState(state);
  },
  markdown(): string {
    return editor ? currentMarkdown() : "";
  },
  setTheme(theme: string) {
    document.documentElement.dataset.theme = theme;
  },
  setFiles(sizes: Record<string, number>, docs: string[]) {
    context.sizes = sizes;
    context.docs = docs;
  },
  focus() {
    editor?.commands.focus();
  },
  blur() {
    (editor?.view.dom as HTMLElement | undefined)?.blur();
  },
  uploadDone: (id: string, file: { src: string; name: string; size?: number }) => {
    if (file.size !== undefined) context.sizes[file.src] = file.size;
    uploadDone(editor, id, file);
  },
  uploadFailed: (id: string, message: string) => uploadFailed(editor, id, message),
  uploadNamed: (id: string, name: string) => uploadNamed(editor, id, name),
  /** Actions of the iPhone toolbar. */
  command(name: string, arg?: string) {
    const c = editor.chain().focus();
    switch (name) {
      case "bold": return c.toggleBold().run();
      case "italic": return c.toggleItalic().run();
      case "underline": return c.toggleUnderline().run();
      case "strike": return c.toggleStrike().run();
      case "code": return c.toggleCode().run();
      case "undo": return c.undo().run();
      case "redo": return c.redo().run();
      case "indent": return c.sinkListItem(editor.isActive("taskItem") ? "taskItem" : "listItem").run();
      case "outdent": return c.liftListItem(editor.isActive("taskItem") ? "taskItem" : "listItem").run();
      case "insert": return openInsertMenu(editor);
      case "link": return linkPopover(editor);
      case "doclink": return docLinkPopover(editor);
      case "pick": return pickAtCaret(editor, arg || "file");
      case "color": return applyColor(editor, "text", arg || null);
      case "background": return applyColor(editor, "bg", arg || null);
      case "turn":
        return BLOCKS.find((b) => b.id === arg)?.run(editor);
      case "moveUp":
      case "moveDown": {
        const pos = caretBlockPos(editor);
        if (pos !== null) moveBlock(editor, pos, name === "moveUp" ? -1 : 1);
        return;
      }
      case "blockMenu": {
        const pos = caretBlockPos(editor);
        if (pos === null) return;
        const coords = editor.view.coordsAtPos(editor.state.selection.from);
        return blockMenu(editor, pos, coords);
      }
      case "dismiss":
        closePopover();
        slash.dismiss();
        return;
    }
  },
};

(window as unknown as { nuo: typeof api }).nuo = api;
post("ready");
