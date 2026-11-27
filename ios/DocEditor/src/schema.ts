import { Extension, Mark, Node, mergeAttributes, type AnyExtension } from "@tiptap/core";
import { Details, DetailsContent, DetailsSummary } from "@tiptap/extension-details";
import Image from "@tiptap/extension-image";
import { TaskItem, TaskList } from "@tiptap/extension-list";
import { Table, TableCell, TableHeader, TableRow } from "@tiptap/extension-table";
import CodeBlock from "@tiptap/extension-code-block";
import StarterKit from "@tiptap/starter-kit";
import { t } from "./i18n";

export const COLORS = ["gray", "brown", "orange", "yellow", "green", "blue", "purple", "pink", "red"] as const;
export type ColorName = (typeof COLORS)[number];

export const CALLOUT_KINDS = ["info", "note", "tip", "important", "warning", "caution"] as const;
export const CALLOUT_COLOR: Record<string, ColorName> = {
  info: "gray",
  note: "blue",
  tip: "green",
  important: "purple",
  warning: "orange",
  caution: "red",
};

const cssColor = (value: string, kind: "text" | "bg") =>
  (COLORS as readonly string[]).includes(value) ? `var(--${kind}-${value})` : value;

export const TextColor = Mark.create({
  name: "textColor",
  priority: 900,
  addAttributes() {
    return { color: { default: "gray" } };
  },
  parseHTML() {
    return [{ tag: "span[data-color]", getAttrs: (el) => ({ color: (el as HTMLElement).dataset.color }) }];
  },
  renderHTML({ HTMLAttributes }) {
    const color = String(HTMLAttributes.color);
    return ["span", { "data-color": color, style: `color: ${cssColor(color, "text")}` }, 0];
  },
});

export const BgColor = Mark.create({
  name: "bgColor",
  priority: 950,
  addAttributes() {
    return { color: { default: "yellow" } };
  },
  parseHTML() {
    return [{ tag: "mark", getAttrs: (el) => ({ color: (el as HTMLElement).dataset.color ?? "yellow" }) }];
  },
  renderHTML({ HTMLAttributes }) {
    const color = String(HTMLAttributes.color);
    return ["mark", { "data-color": color, style: `background: ${cssColor(color, "bg")}` }, 0];
  },
});

/** Inline HTML the editor does not understand, kept verbatim. */
export const RawInline = Mark.create({
  name: "rawInline",
  excludes: "_",
  code: true,
  inclusive: false,
  renderHTML() {
    return ["code", { class: "raw-inline" }, 0];
  },
});

export const Callout = Node.create({
  name: "callout",
  group: "block",
  content: "block+",
  defining: true,
  addAttributes() {
    return { kind: { default: "info" }, emoji: { default: null } };
  },
  parseHTML() {
    return [{ tag: "div[data-callout]", getAttrs: (el) => ({ kind: (el as HTMLElement).dataset.callout, emoji: (el as HTMLElement).dataset.emoji ?? null }) }];
  },
  renderHTML({ node }) {
    return ["div", { "data-callout": node.attrs.kind, "data-emoji": node.attrs.emoji ?? "", class: `callout c-${CALLOUT_COLOR[node.attrs.kind] ?? "gray"}` }, ["div", { class: "callout-body" }, 0]];
  },
});

/** A file of the docs repo or a URL shown as a card: PDF, video, audio or any other file. */
export const FileBlock = Node.create({
  name: "fileBlock",
  group: "block",
  atom: true,
  draggable: true,
  addAttributes() {
    return { src: { default: "" }, name: { default: "" } };
  },
  parseHTML() {
    return [{ tag: "div[data-file]", getAttrs: (el) => ({ src: (el as HTMLElement).dataset.file, name: (el as HTMLElement).dataset.name }) }];
  },
  renderHTML({ node }) {
    return ["div", { "data-file": node.attrs.src, "data-name": node.attrs.name }];
  },
});

/** A link shown as a card ("Embed a link"). */
export const Bookmark = Node.create({
  name: "bookmark",
  group: "block",
  atom: true,
  draggable: true,
  addAttributes() {
    return { href: { default: "" }, title: { default: "" } };
  },
  parseHTML() {
    return [{ tag: "div[data-bookmark]", getAttrs: (el) => ({ href: (el as HTMLElement).dataset.bookmark, title: (el as HTMLElement).dataset.title }) }];
  },
  renderHTML({ node }) {
    return ["div", { "data-bookmark": node.attrs.href, "data-title": node.attrs.title }];
  },
});

/** Markdown the editor cannot show as blocks (HTML, reference definitions…), edited as source. */
export const RawBlock = Node.create({
  name: "rawBlock",
  group: "block",
  content: "text*",
  marks: "",
  code: true,
  defining: true,
  renderHTML() {
    return ["pre", { class: "raw-block" }, ["code", 0]];
  },
});

/** Placeholder while a dropped or pasted file uploads; never written to Markdown. */
export const Uploading = Node.create({
  name: "uploading",
  group: "block",
  atom: true,
  addAttributes() {
    return { id: { default: "" }, name: { default: "" } };
  },
  renderHTML({ node }) {
    return ["div", { class: "uploading", "data-id": node.attrs.id }, t("Uploading {0}…", node.attrs.name)];
  },
});

export const DocImage = Image.extend({
  draggable: true,
  addAttributes() {
    return {
      ...this.parent?.(),
      width: { default: null },
    };
  },
}).configure({ inline: false, allowBase64: false });

/** Lists remember whether they were tight, tables the alignment of their columns. */
const MarkdownAttributes = Extension.create({
  name: "markdownAttributes",
  addGlobalAttributes() {
    return [
      { types: ["bulletList", "orderedList", "taskList"], attributes: { tight: { default: true, rendered: false }, joined: { default: false, rendered: false } } },
      { types: ["details"], attributes: { sourceOpen: { default: false, rendered: false } } },
      { types: ["tableCell", "tableHeader"], attributes: { align: { default: null, renderHTML: (a) => (a.align ? { style: `text-align: ${a.align}` } : {}) } } },
    ];
  },
});

export function baseExtensions(): AnyExtension[] {
  return [
    StarterKit.configure({
      link: { openOnClick: false, autolink: true, linkOnPaste: true, HTMLAttributes: { rel: null, target: null } },
      codeBlock: false,
      trailingNode: { node: "paragraph" },
      dropcursor: { color: "var(--accent)", width: 2 },
    }),
    CodeBlock,
    TaskList,
    TaskItem.configure({ nested: true }),
    Table.configure({ resizable: false }),
    TableRow,
    TableHeader,
    TableCell,
    Details.configure({ persist: true, HTMLAttributes: { class: "toggle" } }),
    DetailsSummary,
    DetailsContent,
    DocImage,
    TextColor,
    BgColor,
    RawInline,
    Callout,
    FileBlock,
    Bookmark,
    RawBlock,
    Uploading,
    MarkdownAttributes,
  ];
}

export { mergeAttributes };
