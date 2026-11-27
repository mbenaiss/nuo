import type { Editor, Range } from "@tiptap/core";
import { context } from "./bridge";
import { locale, t } from "./i18n";

export interface BlockItem {
  id: string;
  label: string;
  hint: string;
  icon: string;
  keywords: string;
  group: "Basic blocks" | "Media" | "Other";
  /** Can turn an existing text block into this type ("Turn into"). */
  transform?: boolean;
  run(editor: Editor, range?: Range): void;
}

const chain = (editor: Editor, range?: Range) => {
  const c = editor.chain().focus();
  return range ? c.deleteRange(range) : c;
};

function insertBlock(editor: Editor, range: Range | undefined, content: Record<string, unknown>) {
  chain(editor, range).insertContent(content).run();
}

export const BLOCKS: BlockItem[] = [
  { id: "text", label: t("Text"), hint: t("Write plain text"), icon: "T", keywords: "paragraphe text plain normal", group: "Basic blocks", transform: true, run: (e, r) => chain(e, r).clearNodes().setParagraph().run() },
  { id: "h1", label: t("Heading 1"), hint: t("Big section heading"), icon: "H1", keywords: "heading titre h1 grand", group: "Basic blocks", transform: true, run: (e, r) => chain(e, r).clearNodes().setHeading({ level: 1 }).run() },
  { id: "h2", label: t("Heading 2"), hint: t("Medium heading"), icon: "H2", keywords: "heading titre h2 sous-titre", group: "Basic blocks", transform: true, run: (e, r) => chain(e, r).clearNodes().setHeading({ level: 2 }).run() },
  { id: "h3", label: t("Heading 3"), hint: t("Small heading"), icon: "H3", keywords: "heading titre h3", group: "Basic blocks", transform: true, run: (e, r) => chain(e, r).clearNodes().setHeading({ level: 3 }).run() },
  { id: "bullet", label: t("Bulleted list"), hint: t("A simple list"), icon: "•", keywords: "bullet liste puces ul", group: "Basic blocks", transform: true, run: (e, r) => chain(e, r).clearNodes().toggleBulletList().run() },
  { id: "numbered", label: t("Numbered list"), hint: t("A list with numbers"), icon: "1.", keywords: "numbered ordered liste numerotee ol", group: "Basic blocks", transform: true, run: (e, r) => chain(e, r).clearNodes().toggleOrderedList().run() },
  { id: "todo", label: t("To-do list"), hint: t("Checkboxes"), icon: "☑", keywords: "todo task checkbox taches cases cocher", group: "Basic blocks", transform: true, run: (e, r) => chain(e, r).clearNodes().toggleTaskList().run() },
  { id: "toggle", label: t("Toggle"), hint: t("Collapsible content"), icon: "▸", keywords: "toggle details replier deplier bascule", group: "Basic blocks", transform: true, run: (e, r) => chain(e, r).clearNodes().setDetails().updateAttributes("details", { open: true }).run() },
  { id: "quote", label: t("Quote"), hint: t("Highlight a quote"), icon: "❝", keywords: "quote citation blockquote", group: "Basic blocks", transform: true, run: (e, r) => chain(e, r).clearNodes().toggleBlockquote().run() },
  { id: "callout", label: t("Callout"), hint: t("A colored block with an icon"), icon: "💡", keywords: "callout encadre note info alerte attention", group: "Basic blocks", transform: true, run: (e, r) => chain(e, r).clearNodes().wrapIn("callout", { kind: "info", emoji: "💡" }).run() },
  { id: "code", label: t("Code block"), hint: t("Code or plain text"), icon: "</>", keywords: "code bloc programme", group: "Basic blocks", transform: true, run: (e, r) => chain(e, r).clearNodes().setCodeBlock().run() },
  { id: "divider", label: t("Divider"), hint: t("A separating line"), icon: "—", keywords: "divider separateur ligne hr trait", group: "Basic blocks", run: (e, r) => chain(e, r).setHorizontalRule().run() },
  { id: "table", label: t("Table"), hint: t("A 3 × 3 table"), icon: "⊞", keywords: "table tableau grille", group: "Basic blocks", run: (e, r) => chain(e, r).insertTable({ rows: 3, cols: 3, withHeaderRow: true }).run() },
  { id: "image", label: t("Image"), hint: t("Upload or paste a link"), icon: "🖼️", keywords: "image photo picture", group: "Media", run: (e, r) => insertBlock(e, r, { type: "image", attrs: { src: "" } }) },
  { id: "file", label: t("File"), hint: t("Attach any file"), icon: "📎", keywords: "file fichier piece jointe upload", group: "Media", run: (e, r) => insertBlock(e, r, { type: "fileBlock", attrs: { src: "", name: "file" } }) },
  { id: "pdf", label: t("PDF"), hint: t("Show a PDF"), icon: "📄", keywords: "pdf document", group: "Media", run: (e, r) => insertBlock(e, r, { type: "fileBlock", attrs: { src: "", name: "pdf" } }) },
  { id: "video", label: t("Video"), hint: t("Attach a video"), icon: "🎬", keywords: "video film", group: "Media", run: (e, r) => insertBlock(e, r, { type: "fileBlock", attrs: { src: "", name: "video" } }) },
  { id: "audio", label: t("Audio"), hint: t("Attach a sound"), icon: "🎧", keywords: "audio son musique enregistrement", group: "Media", run: (e, r) => insertBlock(e, r, { type: "fileBlock", attrs: { src: "", name: "audio" } }) },
  { id: "embed", label: t("Embed a link"), hint: t("A card pointing to a site"), icon: "🔗", keywords: "embed bookmark integrer lien carte site", group: "Media", run: (e, r) => insertBlock(e, r, { type: "bookmark", attrs: { href: "", title: "" } }) },
  { id: "link", label: t("Link"), hint: t("A link in the text"), icon: "↗", keywords: "link lien url", group: "Other", run: (e, r) => {
    chain(e, r).run();
    document.dispatchEvent(new CustomEvent("nuo-link"));
  } },
  { id: "doclink", label: t("Link to a document"), hint: t("Mention another document"), icon: "📝", keywords: "page document mention lien note", group: "Other", run: (e, r) => {
    chain(e, r).run();
    document.dispatchEvent(new CustomEvent("nuo-doclink"));
  } },
  { id: "date", label: t("Today's date"), hint: t("Insert today's date"), icon: "📅", keywords: "date jour aujourd'hui today", group: "Other", run: (e, r) => {
    const today = new Date().toLocaleDateString(locale(), { day: "numeric", month: "long", year: "numeric" });
    chain(e, r).insertContent(today + " ").run();
  } },
  { id: "diagram", label: t("Diagram"), hint: t("A Mermaid diagram: steps, schedule, org chart"), icon: "◇", keywords: "schema diagramme mermaid organigramme flowchart gantt planning processus", group: "Other", run: (e, r) => chain(e, r).clearNodes().setCodeBlock({ language: "mermaid" }).run() },
  { id: "math", label: t("Equation"), hint: t("A math formula (LaTeX)"), icon: "∑", keywords: "equation math formule latex katex", group: "Other", run: (e, r) => chain(e, r).clearNodes().setCodeBlock({ language: "math" }).run() },
];

export const fold = (s: string) => s.normalize("NFD").replace(/[̀-ͯ]/g, "").toLowerCase();

export function searchBlocks(query: string, items = BLOCKS): BlockItem[] {
  const q = fold(query.trim());
  if (!q) return items;
  return items
    .map((item) => {
      const label = fold(item.label);
      const score = label.startsWith(q) ? 0 : label.includes(q) ? 1 : fold(item.keywords).includes(q) ? 2 : -1;
      return { item, score };
    })
    .filter((x) => x.score >= 0)
    .sort((a, b) => a.score - b.score)
    .map((x) => x.item);
}

/** Path of `target` relative to the document's folder, as Markdown links write it. */
export function relativePath(target: string): string {
  const from = context.basePath ? context.basePath.split("/") : [];
  const to = target.split("/");
  let i = 0;
  while (i < from.length && i < to.length - 1 && from[i] === to[i]) i++;
  return [...Array(from.length - i).fill(".."), ...to.slice(i)].join("/");
}

export function docTitle(path: string): string {
  const name = path.split("/").pop() ?? path;
  const base = name.replace(/\.md$/i, "").replace(/[-_]+/g, " ").trim();
  return base.charAt(0).toUpperCase() + base.slice(1);
}

/** Current block type, for the "Turn into" button label. */
export function currentBlockId(editor: Editor): string {
  if (editor.isActive("heading", { level: 1 })) return "h1";
  if (editor.isActive("heading", { level: 2 })) return "h2";
  if (editor.isActive("heading", { level: 3 })) return "h3";
  if (editor.isActive("taskList")) return "todo";
  if (editor.isActive("orderedList")) return "numbered";
  if (editor.isActive("bulletList")) return "bullet";
  if (editor.isActive("codeBlock")) return "code";
  if (editor.isActive("callout")) return "callout";
  if (editor.isActive("blockquote")) return "quote";
  if (editor.isActive("details")) return "toggle";
  return "text";
}
