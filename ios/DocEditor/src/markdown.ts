import MarkdownIt from "markdown-it";
import type StateBlock from "markdown-it/lib/rules_block/state_block.mjs";
import type StateCore from "markdown-it/lib/rules_core/state_core.mjs";
import type Token from "markdown-it/lib/token.mjs";
import type { Mark, Node as PMNode, Schema } from "@tiptap/pm/model";
import { MarkdownParser, MarkdownSerializerState } from "prosemirror-markdown";
import { CALLOUT_KINDS } from "./schema";

// Conventions are documented in docs/documents.md; the native reader (MarkdownView.swift) follows the same ones.

const FRONT_MATTER = /^---[ \t]*\n[\s\S]*?\n---[ \t]*(?:\n+|$)/;
const EMOJI = /^(\p{Extended_Pictographic}(?:️|‍\p{Extended_Pictographic}|\p{Emoji_Modifier})*)(?:\s+|$)/u;
const FILE_PREFIX = "📎 ";
const BOOKMARK_PREFIX = "🔗 ";

export function splitFrontMatter(source: string): { front: string; body: string } {
  const m = FRONT_MATTER.exec(source);
  return m ? { front: m[0], body: source.slice(m[0].length) } : { front: "", body: source };
}

// MARK: Tokenizer

function tokenizer(): MarkdownIt {
  const md = new MarkdownIt("commonmark", { html: true });
  md.enable(["table", "strikethrough"]);
  // Paths stay as written (accents, spaces in <…>): agents read the same links.
  md.normalizeLink = (url) => url;
  md.normalizeLinkText = (url) => url;
  md.block.ruler.before("html_block", "details", detailsRule, { alt: ["paragraph", "reference", "blockquote", "list"] });
  keepReferenceDefinitions(md);
  md.core.ruler.push("nuo", (state) => {
    inlineHtml(state);
    tableParagraphs(state);
    callouts(state);
    taskLists(state);
    listSpacing(state);
    liftBlocks(state);
  });
  return md;
}

function detailsRule(state: StateBlock, startLine: number, endLine: number, silent: boolean): boolean {
  const lineText = (n: number) => state.src.slice(state.bMarks[n]! + state.tShift[n]!, state.eMarks[n]);
  if (state.sCount[startLine]! - state.blkIndent >= 4) return false;
  const first = lineText(startLine);
  const open = /^<details(\s+open)?\s*>(.*)$/i.exec(first);
  if (!open) return false;
  let summary = "";
  let rest = open[2]!.trim();
  let line = startLine + 1;
  const summaryRe = /^<summary>(.*?)<\/summary>\s*$/i;
  if (rest) {
    const s = summaryRe.exec(rest);
    if (!s) return false;
    summary = s[1]!;
  } else {
    while (line < endLine && !lineText(line).trim()) line++;
    const s = line < endLine ? summaryRe.exec(lineText(line).trim()) : null;
    if (!s) return false;
    summary = s[1]!;
    line++;
  }
  let depth = 1;
  let close = -1;
  let fence: string | null = null;
  for (let n = line; n < endLine; n++) {
    if (state.sCount[n]! < state.blkIndent) break;
    const text = lineText(n).trim();
    const f = /^(`{3,}|~{3,})/.exec(text);
    if (f) {
      if (!fence) fence = f[1]!;
      else if (text.startsWith(fence)) fence = null;
      continue;
    }
    if (fence) continue;
    if (/^<details(\s+open)?\s*>/i.test(text)) depth++;
    if (/^<\/details>\s*$/i.test(text) && --depth === 0) {
      close = n;
      break;
    }
  }
  if (close < 0) return false;
  if (silent) return true;

  const t = state.push("details_open", "details", 1);
  t.attrSet("open", open[1] ? "true" : "");
  t.map = [startLine, close + 1];
  state.push("details_summary_open", "summary", 1);
  const inline = state.push("inline", "", 0);
  inline.content = summary.trim();
  inline.map = [startLine, line];
  inline.children = [];
  state.push("details_summary_close", "summary", -1);
  state.push("details_content_open", "div", 1);
  const oldParent = state.parentType;
  const oldMax = state.lineMax;
  state.parentType = "container" as typeof state.parentType;
  state.lineMax = close;
  state.md.block.tokenize(state, line, close);
  state.parentType = oldParent;
  state.lineMax = oldMax;
  state.push("details_content_close", "div", -1);
  state.push("details_close", "details", -1);
  state.line = close + 1;
  return true;
}

/** markdown-it drops `[label]: url` lines once it resolved them; keep them as raw blocks. */
function keepReferenceDefinitions(md: MarkdownIt) {
  const rules = (md.block.ruler as unknown as { __rules__: { name: string; fn: Function }[] }).__rules__;
  const ref = rules.find((r) => r.name === "reference")!;
  const original = ref.fn as (s: StateBlock, a: number, b: number, c: boolean) => boolean;
  ref.fn = (state: StateBlock, start: number, end: number, silent: boolean) => {
    const ok = original(state, start, end, silent);
    if (ok && !silent) {
      const t = state.push("raw_block", "", 0);
      t.content = state.src.slice(state.bMarks[start]!, state.bMarks[state.line] ?? state.src.length).replace(/\n+$/, "");
      t.map = [start, state.line];
    }
    return ok;
  };
}

const SPAN_STYLE = /^<span\s+style\s*=\s*["']([^"']*)["']\s*>$/i;
const MARK_OPEN = /^<mark(?:\s+style\s*=\s*["']([^"']*)["'])?\s*>$/i;
const STYLE_COLOR = /(?:^|;)\s*color\s*:\s*([^;]+)/i;
const STYLE_BG = /(?:^|;)\s*background(?:-color)?\s*:\s*([^;]+)/i;

/** `<span style="color: …">`, `<mark>`, `<u>`, `<br>` become marks and breaks; any other inline HTML stays verbatim. */
function inlineHtml(state: StateCore) {
  for (const block of state.tokens) {
    if (block.type !== "inline" || !block.children) continue;
    const kids = block.children;
    type Open = { index: number; tag: string; type: string; attr?: string };
    const opens: Open[] = [];
    const pairs = new Map<number, Open & { close: number }>();
    kids.forEach((tok, index) => {
      if (tok.type !== "html_inline") return;
      const html = tok.content.trim();
      let m: RegExpExecArray | null;
      if ((m = SPAN_STYLE.exec(html))) {
        const color = STYLE_COLOR.exec(m[1]!)?.[1]?.trim();
        const bg = STYLE_BG.exec(m[1]!)?.[1]?.trim();
        if (color && !bg) opens.push({ index, tag: "span", type: "text_color", attr: color });
        else if (bg && !color) opens.push({ index, tag: "span", type: "bg_color", attr: bg });
        else opens.push({ index, tag: "span", type: "" });
      } else if ((m = MARK_OPEN.exec(html))) {
        const bg = m[1] ? STYLE_BG.exec(m[1])?.[1]?.trim() : "yellow";
        opens.push({ index, tag: "mark", type: bg ? "bg_color" : "", attr: bg });
      } else if (/^<u>$/i.test(html)) {
        opens.push({ index, tag: "u", type: "underline" });
      } else if (/^<span\b[^>]*>$/i.test(html)) {
        opens.push({ index, tag: "span", type: "" });
      } else {
        const close = /^<\/(span|mark|u)\s*>$/i.exec(html);
        if (!close) return;
        const tag = close[1]!.toLowerCase();
        for (let j = opens.length - 1; j >= 0; j--) {
          if (opens[j]!.tag !== tag) continue;
          const [open] = opens.splice(j, 1);
          if (open!.type) pairs.set(open!.index, { ...open!, close: index });
          break;
        }
      }
    });
    const closes = new Map<number, string>();
    for (const p of pairs.values()) closes.set(p.close, p.type);
    kids.forEach((tok, index) => {
      if (tok.type !== "html_inline") return;
      const open = pairs.get(index);
      if (open) {
        tok.type = `${open.type}_open`;
        tok.nesting = 1;
        if (open.attr) tok.attrSet("color", open.attr);
      } else if (closes.has(index)) {
        tok.type = `${closes.get(index)}_close`;
        tok.nesting = -1;
      } else if (/^<br\s*\/?>$/i.test(tok.content.trim())) {
        tok.type = "hardbreak";
      } else {
        tok.type = "raw_inline";
      }
    });
  }
}

function tableParagraphs(state: StateCore) {
  const out: Token[] = [];
  const Tok = state.Token;
  for (const tok of state.tokens) {
    if (tok.type === "inline" && /^(th|td)_open$/.test(out[out.length - 1]?.type ?? "")) {
      out.push(new Tok("paragraph_open", "p", 1), tok, new Tok("paragraph_close", "p", -1));
    } else {
      out.push(tok);
    }
  }
  state.tokens = out;
}

/** `> [!KIND]` blockquotes; an emoji opening the body is the callout's icon. */
function callouts(state: StateCore) {
  const tokens = state.tokens;
  for (let i = 0; i < tokens.length; i++) {
    if (tokens[i]!.type !== "blockquote_open" || tokens[i + 1]?.type !== "paragraph_open") continue;
    const inline = tokens[i + 2]!;
    const kids = inline.children ?? [];
    const m = /^\[!(\w+)\][ \t]*$/.exec(kids[0]?.type === "text" ? kids[0].content : "");
    if (!m || !(kids.length === 1 || kids[1]!.type === "softbreak")) continue;
    const kind = m[1]!.toLowerCase();
    const open = tokens[i]!;
    open.type = "callout_open";
    open.attrSet("kind", (CALLOUT_KINDS as readonly string[]).includes(kind) ? kind : kind || "note");
    let depth = 0;
    for (let j = i; j < tokens.length; j++) {
      depth += tokens[j]!.nesting;
      if (depth === 0) {
        tokens[j]!.type = "callout_close";
        break;
      }
    }
    kids.splice(0, kids.length === 1 ? 1 : 2);
    const first = kids[0];
    if (first?.type === "text") {
      const e = EMOJI.exec(first.content);
      if (e && (first.content.length > e[0].length || kids.length === 1)) {
        open.attrSet("emoji", e[1]!);
        first.content = first.content.slice(e[0].length);
        if (!first.content) kids.shift();
        if (kids[0]?.type === "softbreak") kids.shift();
      }
    }
    inline.content = kids.map((k) => k.content).join("");
    if (!kids.length) tokens.splice(i + 1, 3);
  }
}

function taskLists(state: StateCore) {
  type Ctx = { open: Token; kind: "bullet" | "task" | null; level: number };
  const out: Token[] = [];
  const stack: Ctx[] = [];
  const tokens = state.tokens;
  const Tok = state.Token;
  for (let i = 0; i < tokens.length; i++) {
    const tok = tokens[i]!;
    if (tok.type === "bullet_list_open") {
      stack.push({ open: tok, kind: null, level: tok.level });
      out.push(tok);
      continue;
    }
    if (tok.type === "ordered_list_open") {
      stack.push({ open: tok, kind: null, level: -1 });
      out.push(tok);
      continue;
    }
    if (tok.type === "ordered_list_close") {
      stack.pop();
      out.push(tok);
      continue;
    }
    if (tok.type === "bullet_list_close") {
      const ctx = stack.pop()!;
      if (ctx.kind === "task") tok.type = "task_list_close";
      out.push(tok);
      continue;
    }
    const ctx = stack[stack.length - 1];
    if (tok.type === "list_item_open" && ctx && ctx.level === tok.level - 1) {
      const inline = tokens[i + 2];
      const checkbox = tokens[i + 1]?.type === "paragraph_open" && inline?.type === "inline" ? /^\[([ xX])\](?:[ \t]+|$)/.exec(inline.content) : null;
      const kind = checkbox ? "task" : "bullet";
      if (ctx.kind === null) {
        ctx.kind = kind;
        if (kind === "task") ctx.open.type = "task_list_open";
      } else if (ctx.kind !== kind) {
        out.push(new Tok(ctx.kind === "task" ? "task_list_close" : "bullet_list_close", "ul", -1));
        const reopen = new Tok(kind === "task" ? "task_list_open" : "bullet_list_open", "ul", 1);
        reopen.level = ctx.open.level;
        reopen.markup = ctx.open.markup;
        out.push(reopen);
        ctx.kind = kind;
      }
      if (checkbox) {
        tok.type = "task_item_open";
        tok.attrSet("checked", checkbox[1] === " " ? "" : "true");
        inline!.content = inline!.content.slice(checkbox[0].length);
        const first = inline!.children?.[0];
        if (first?.type === "text") {
          first.content = first.content.slice(Math.min(checkbox[0].length, first.content.length));
          if (!first.content) inline!.children!.shift();
        }
        let depth = 0;
        for (let j = i; j < tokens.length; j++) {
          depth += tokens[j]!.nesting;
          if (depth === 0) {
            tokens[j]!.type = "task_item_close";
            break;
          }
        }
      }
    }
    out.push(tok);
  }
  state.tokens = out;
}

/**
 * CommonMark makes a whole list loose as soon as one blank line separates two items, which happens when a bullet
 * list and a task list follow each other. Tightness is decided per run instead, from the source lines, and a run
 * written right after the previous one without a blank line is marked `joined`.
 */
function listSpacing(state: StateCore) {
  const lines = state.src.split("\n");
  const blankBefore = (line: number) => line > 0 && !(lines[line - 1] ?? "").trim();
  const tokens = state.tokens;
  let previousRunEnd: { level: number; index: number; blankAfter: boolean } | null = null;
  for (let i = 0; i < tokens.length; i++) {
    const open = tokens[i]!;
    if (!/^(bullet|ordered|task)_list_open$/.test(open.type)) continue;
    const items: Token[] = [];
    const indices: number[] = [];
    let close = i;
    for (let j = i + 1, depth = 1; j < tokens.length; j++) {
      depth += tokens[j]!.nesting;
      if (tokens[j]!.nesting === 1 && tokens[j]!.level === open.level + 1 && /_item_open$/.test(tokens[j]!.type)) {
        items.push(tokens[j]!);
        indices.push(j);
      }
      if (depth === 0) {
        close = j;
        break;
      }
    }
    let tight = true;
    items.forEach((item, n) => {
      if (n < items.length - 1 && item.map && blankBefore(item.map[1])) tight = false;
      let lastEnd = -1;
      for (let j = indices[n]! + 1, depth = 1; j < tokens.length && depth > 0; j++) {
        const t = tokens[j]!;
        if (t.nesting === 1 && t.level === item.level + 1 && t.map) {
          if (lastEnd >= 0 && t.map[0] > lastEnd) tight = false;
          lastEnd = t.map[1];
        }
        depth += t.nesting;
      }
    });
    open.attrSet("tight", tight ? "true" : "false");
    const first = items[0];
    if (previousRunEnd && previousRunEnd.level === open.level && previousRunEnd.index === i - 1 && first?.map) {
      open.attrSet("joined", previousRunEnd.blankAfter ? "false" : "true");
    }
    const last = items[items.length - 1];
    previousRunEnd = { level: open.level, index: close, blankAfter: !!last?.map && blankBefore(last.map[1]) };
  }
}

const IMG_TAG = /^<img\s+([^>]*?)\/?>$/i;

function imgAttrs(html: string): Record<string, string> | null {
  const m = IMG_TAG.exec(html.trim());
  if (!m) return null;
  const attrs: Record<string, string> = {};
  for (const a of m[1]!.matchAll(/([a-zA-Z-]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+))/g)) attrs[a[1]!.toLowerCase()] = a[2] ?? a[3] ?? a[4] ?? "";
  return attrs.src ? attrs : null;
}

/**
 * A paragraph holding only an image, a `📎` file link or a `🔗` link becomes a block. Inline images among text
 * stay verbatim: the editor's images are blocks.
 */
function liftBlocks(state: StateCore) {
  const tokens = state.tokens;
  const Tok = state.Token;
  const parents: string[] = [];
  const out: Token[] = [];
  for (let i = 0; i < tokens.length; i++) {
    const tok = tokens[i]!;
    if (tok.type === "html_block") {
      const img = imgAttrs(tok.content);
      if (img) {
        out.push(imageToken(Tok, img.src!, img.alt ?? "", img.title ?? "", img.width ?? ""));
        continue;
      }
    }
    if (tok.type === "paragraph_open" && !tok.hidden && !["list_item", "task_item", "th", "td"].includes(parents[parents.length - 1] ?? "")) {
      const inline = tokens[i + 1]!;
      const kids = (inline.children ?? []).filter((k) => !(k.type === "softbreak" || (k.type === "text" && !k.content.trim())));
      const block = soloBlock(Tok, kids);
      if (block) {
        out.push(block);
        i += 2;
        continue;
      }
    }
    if (tok.type === "inline" && tok.children) {
      tok.children = tok.children.map((k) => {
        if (k.type !== "image") return k;
        const raw = new Tok("raw_inline", "", 0);
        raw.content = `![${k.content}](${destination(k.attrGet("src") ?? "")}${k.attrGet("title") ? ` "${k.attrGet("title")}"` : ""})`;
        return raw;
      });
    }
    if (tok.nesting === 1) parents.push(tok.type.replace(/_open$/, ""));
    if (tok.nesting === -1) parents.pop();
    out.push(tok);
  }
  state.tokens = out;
}

function soloBlock(Tok: typeof Token, kids: Token[]): Token | null {
  if (kids.length === 1 && kids[0]!.type === "image") {
    const k = kids[0]!;
    return imageToken(Tok, k.attrGet("src") ?? "", k.content, k.attrGet("title") ?? "", "");
  }
  if (kids.length === 1 && kids[0]!.type === "raw_inline") {
    const img = imgAttrs(kids[0]!.content);
    if (img) return imageToken(Tok, img.src!, img.alt ?? "", img.title ?? "", img.width ?? "");
  }
  if (kids.length === 3 && kids[0]!.type === "link_open" && kids[1]!.type === "text" && kids[2]!.type === "link_close" && !kids[0]!.attrGet("title")) {
    const href = kids[0]!.attrGet("href") ?? "";
    const text = kids[1]!.content;
    if (text.startsWith(FILE_PREFIX) || text.startsWith(BOOKMARK_PREFIX)) {
      const file = text.startsWith(FILE_PREFIX);
      const t = new Tok(file ? "file_block" : "bookmark", "", 0);
      t.attrSet(file ? "src" : "href", href);
      t.attrSet(file ? "name" : "title", text.slice((file ? FILE_PREFIX : BOOKMARK_PREFIX).length).trim());
      return t;
    }
  }
  return null;
}

function imageToken(Tok: typeof Token, src: string, alt: string, title: string, width: string): Token {
  const t = new Tok("image_block", "img", 0);
  t.attrSet("src", src);
  t.attrSet("alt", alt);
  t.attrSet("title", title);
  t.attrSet("width", width);
  return t;
}

// MARK: Parser

export function createParser(schema: Schema): (markdown: string) => PMNode {
  const md = tokenizer();
  const tight = (tok: Token) => ({ tight: tok.attrGet("tight") !== "false", joined: tok.attrGet("joined") === "true" });
  const align = (tok: Token) => ({ align: /text-align:\s*(\w+)/.exec(tok.attrGet("style") ?? "")?.[1] ?? null });
  const parser = new MarkdownParser(schema, md, {
    paragraph: { block: "paragraph" },
    heading: { block: "heading", getAttrs: (tok) => ({ level: Number(tok.tag.slice(1)) }) },
    blockquote: { block: "blockquote" },
    callout: { block: "callout", getAttrs: (tok) => ({ kind: tok.attrGet("kind") ?? "note", emoji: tok.attrGet("emoji") || null }) },
    bullet_list: { block: "bulletList", getAttrs: tight },
    ordered_list: { block: "orderedList", getAttrs: (tok) => ({ start: Number(tok.attrGet("start") ?? 1), ...tight(tok) }) },
    list_item: { block: "listItem" },
    task_list: { block: "taskList", getAttrs: tight },
    task_item: { block: "taskItem", getAttrs: (tok) => ({ checked: tok.attrGet("checked") === "true" }) },
    code_block: { block: "codeBlock", noCloseToken: true },
    fence: { block: "codeBlock", getAttrs: (tok) => ({ language: tok.info.trim() || null }), noCloseToken: true },
    hr: { node: "horizontalRule" },
    image_block: {
      node: "image",
      getAttrs: (tok) => ({ src: tok.attrGet("src"), alt: tok.attrGet("alt") || null, title: tok.attrGet("title") || null, width: tok.attrGet("width") || null }),
    },
    file_block: { node: "fileBlock", getAttrs: (tok) => ({ src: tok.attrGet("src"), name: tok.attrGet("name") }) },
    bookmark: { node: "bookmark", getAttrs: (tok) => ({ href: tok.attrGet("href"), title: tok.attrGet("title") }) },
    html_block: { block: "rawBlock", noCloseToken: true },
    raw_block: { block: "rawBlock", noCloseToken: true },
    table: { block: "table" },
    thead: { ignore: true },
    tbody: { ignore: true },
    tr: { block: "tableRow" },
    th: { block: "tableHeader", getAttrs: align },
    td: { block: "tableCell", getAttrs: align },
    details: { block: "details", getAttrs: (tok) => ({ sourceOpen: tok.attrGet("open") === "true", open: tok.attrGet("open") === "true" }) },
    details_summary: { block: "detailsSummary" },
    details_content: { block: "detailsContent" },
    hardbreak: { node: "hardBreak" },
    em: { mark: "italic" },
    strong: { mark: "bold" },
    s: { mark: "strike" },
    underline: { mark: "underline" },
    text_color: { mark: "textColor", getAttrs: (tok) => ({ color: tok.attrGet("color") }) },
    bg_color: { mark: "bgColor", getAttrs: (tok) => ({ color: tok.attrGet("color") }) },
    link: { mark: "link", getAttrs: (tok) => ({ href: tok.attrGet("href"), title: tok.attrGet("title") || null }) },
    code_inline: { mark: "code", noCloseToken: true },
    raw_inline: { mark: "rawInline", noCloseToken: true },
  });
  ((parser as unknown as { tokenHandlers: unknown }).tokenHandlers as Record<string, (state: { addText(t: string): void }) => void>).softbreak = (state) => state.addText("\n");
  return (markdown) => parser.parse(splitFrontMatter(markdown).body);
}

// MARK: Serializer

const PUNCT = /[!-/:-@[-`{-~]/;
const WORD = /[\p{L}\p{N}]/u;
const SPACE = /\s/;

/** Members of prosemirror-markdown's state that its typings mark internal. */
interface Internals {
  out: string;
  delim: string;
  atBlockStart: boolean;
  closed: PMNode | null;
  inTightList: boolean;
  inAutolink: boolean | undefined;
  nodes: unknown;
  marks: unknown;
  options: Record<string, unknown>;
  flushClose(size?: number): void;
}
const SerializerState = MarkdownSerializerState as unknown as new (nodes: unknown, marks: unknown, options: unknown) => MarkdownSerializerState & Internals;

class State extends SerializerState {
  inTable = false;

  /** Whether the output flushed by `serialize` so far ends a line. */
  flushedBlank = true;

  // The original tests a regex against the whole output on each write, quadratic on long documents; `serialize`
  // also flushes the output after each top-level block, so reading its last character stays cheap.
  atBlank(): boolean {
    return this.out.length === 0 ? this.flushedBlank : this.out.charCodeAt(this.out.length - 1) === 10;
  }

  override text(text: string, escape = true) {
    const lines = text.split("\n");
    for (let i = 0; i < lines.length; i++) {
      this.write();
      const line = i < lines.length - 1 ? lines[i]!.replace(/[ \t]+$/, "") : lines[i]!;
      this.out += escape ? this.esc(line, i === 0 ? this.atBlockStart : true) : line;
      if (i !== lines.length - 1) this.out += this.inTable ? " " : "\n";
    }
  }

  /** Escapes only what would change meaning, so text written by agents keeps its look (snake_case, 5 * 3, [^1]). */
  override esc(str: string, startOfLine = false): string {
    let out = "";
    const count = (ch: string) => str.split(ch).length - 1;
    for (let i = 0; i < str.length; i++) {
      const c = str[i]!;
      const prev = str[i - 1] ?? "";
      const next = str[i + 1] ?? "";
      const edge = i === 0 || i === str.length - 1;
      switch (c) {
        case "\\":
          out += PUNCT.test(next) || i === str.length - 1 ? "\\\\" : "\\";
          break;
        case "`":
          out += "\\`";
          break;
        case "*":
        case "_": {
          const blankAround = (!prev || SPACE.test(prev)) && (!next || SPACE.test(next));
          const intraword = c === "_" && WORD.test(prev) && WORD.test(next);
          out += !blankAround && !intraword && (edge || count(c) > 1) ? `\\${c}` : c;
          break;
        }
        case "~":
          out += next === "~" || prev === "~" ? "\\~" : "~";
          break;
        case "[":
          out +=
            /^[^\]]*\][([]/.test(str.slice(i + 1)) || (startOfLine && i === 0 && (/^\[[ xX]\]/.test(str) || /^\[[^\]]+\]:[ \t]*\S+[ \t]*$/.test(str)))
              ? "\\["
              : "[";
          break;
        case "<":
          out += /[A-Za-z/!?]/.test(next) ? "\\<" : "<";
          break;
        case "&":
          out += /^&(#\d+|#x[0-9a-f]+|[a-z][a-z0-9]*);/i.test(str.slice(i)) ? "\\&" : "&";
          break;
        case "|":
          out += this.inTable ? "\\|" : "|";
          break;
        default:
          out += c;
      }
    }
    if (startOfLine) {
      out = out
        .replace(/^(\s*)(#{1,6})(?=\s|$)/, "$1\\$2")
        .replace(/^(\s*)([-+*])(?=\s|$)/, "$1\\$2")
        .replace(/^(\s*)(\d{1,9})([.)])(?=\s|$)/, "$1$2\\$3")
        .replace(/^(\s*)>/, "$1\\>")
        .replace(/^(\s*)([=-])(?=[=-]*\s*$)/, "$1\\$2");
    }
    return out;
  }
}

type NodeFn = (state: State, node: PMNode, parent: PMNode, index: number) => void;

function destination(href: string): string {
  return /[\s<>]/.test(href) || href === "" ? `<${href.replace(/[<>]/g, (c) => encodeURIComponent(c))}>` : href.replace(/[()]/g, "\\$&");
}

const title = (t: string | null | undefined) => (t ? ` "${t.replace(/"/g, '\\"')}"` : "");

function htmlAttr(value: string): string {
  return value.replace(/&/g, "&amp;").replace(/"/g, "&quot;");
}

const LISTS = new Set(["bulletList", "taskList", "orderedList"]);

function renderList(state: State, node: PMNode, marker: (i: number, child: PMNode) => string) {
  const closed = state.closed as PMNode | null;
  const tight = node.attrs.tight !== false;
  if (closed && LISTS.has(closed.type.name) && closed.type !== node.type && node.type.name !== "orderedList" && closed.type.name !== "orderedList") {
    // A list mixing tasks and bullets is split in two by the parser; written back as one.
    state.flushClose(node.attrs.joined ? 1 : 2);
  } else if (closed && closed.type === node.type) {
    state.flushClose(2);
  } else if (state.inTightList) {
    state.flushClose(1);
  }
  const prevTight = state.inTightList;
  state.inTightList = tight;
  node.forEach((child, _, i) => {
    if (i && tight) state.flushClose(1);
    const first = marker(i, child);
    const indent = node.type.name === "orderedList" ? first.length : 2;
    state.wrapBlock(" ".repeat(indent), first, node, () => state.render(child, node, i));
  });
  state.inTightList = prevTight;
}

function cellMarkdown(parent: State, cell: PMNode): string {
  const state = new State(parent.nodes, parent.marks, parent.options);
  state.inTable = true;
  const parts: string[] = [];
  cell.forEach((block) => {
    state.out = "";
    if (block.isTextblock) state.renderInline(block);
    else state.text(block.textContent);
    parts.push(state.out.trim());
  });
  return parts.filter(Boolean).join("<br>");
}

const nodes: Record<string, NodeFn> = {
  paragraph(state, node) {
    state.renderInline(node);
    state.closeBlock(node);
  },
  heading(state, node) {
    state.write("#".repeat(node.attrs.level) + " ");
    state.renderInline(node, false);
    state.closeBlock(node);
  },
  blockquote(state, node) {
    state.wrapBlock("> ", null, node, () => state.renderContent(node));
  },
  callout(state, node) {
    state.wrapBlock("> ", null, node, () => {
      state.write(`[!${String(node.attrs.kind).toUpperCase()}]`);
      state.ensureNewLine();
      const emoji = node.attrs.emoji as string | null;
      const first = node.firstChild;
      if (emoji) {
        if (first?.type.name === "paragraph" && first.content.size > 0) {
          state.write(`${emoji} `);
        } else {
          state.write(emoji);
          state.ensureNewLine();
        }
      }
      node.forEach((child, _, i) => {
        if (i === 0 && emoji && child.type.name === "paragraph" && child.content.size === 0) return;
        state.render(child, node, i);
      });
    });
  },
  codeBlock(state, node) {
    const runs = node.textContent.match(/`{3,}/gm);
    const fence = runs ? runs.sort((a, b) => a.length - b.length).slice(-1)[0] + "`" : "```";
    state.write(fence + (node.attrs.language ?? "") + "\n");
    if (node.textContent) {
      state.text(node.textContent, false);
      state.ensureNewLine();
    }
    state.write(fence);
    state.closeBlock(node);
  },
  horizontalRule(state, node) {
    state.write("---");
    state.closeBlock(node);
  },
  bulletList(state, node) {
    renderList(state, node, () => "- ");
  },
  taskList(state, node) {
    renderList(state, node, (_, child) => (child.attrs.checked ? "- [x] " : "- [ ] "));
  },
  orderedList(state, node) {
    const start = Number(node.attrs.start ?? 1);
    renderList(state, node, (i) => `${start + i}. `);
  },
  listItem(state, node) {
    state.renderContent(node);
  },
  taskItem(state, node) {
    state.renderContent(node);
  },
  image(state, node) {
    const { src, alt, title: t, width } = node.attrs;
    if (!src) return;
    if (width) {
      state.write(`<img src="${htmlAttr(src ?? "")}" alt="${htmlAttr(alt ?? "")}" width="${htmlAttr(String(width))}">`);
    } else {
      state.write(`![${state.esc(alt ?? "")}](${destination(src ?? "")}${title(t)})`);
    }
    state.closeBlock(node);
  },
  fileBlock(state, node) {
    if (!node.attrs.src) return;
    state.write(`[${FILE_PREFIX}${state.esc(node.attrs.name || "fichier")}](${destination(node.attrs.src ?? "")})`);
    state.closeBlock(node);
  },
  bookmark(state, node) {
    if (!node.attrs.href) return;
    state.write(`[${BOOKMARK_PREFIX}${state.esc(node.attrs.title || node.attrs.href)}](${destination(node.attrs.href ?? "")})`);
    state.closeBlock(node);
  },
  rawBlock(state, node) {
    state.text(node.textContent, false);
    state.closeBlock(node);
  },
  uploading() {},
  hardBreak(state, node, parent, index) {
    for (let i = index + 1; i < parent.childCount; i++) {
      if (parent.child(i).type !== node.type) {
        state.write(state.inTable ? "<br>" : "\\\n");
        return;
      }
    }
  },
  text(state, node) {
    state.text(node.text ?? "", !state.inAutolink);
  },
  table(state, node) {
    const rows: string[][] = [];
    const aligns: (string | null)[] = [];
    node.forEach((row, _, r) => {
      const cells: string[] = [];
      row.forEach((cell, __, c) => {
        cells.push(cellMarkdown(state, cell));
        if (r === 0) aligns[c] = cell.attrs.align ?? null;
      });
      rows.push(cells);
    });
    const width = Math.max(...rows.map((r) => r.length));
    const line = (cells: string[]) => `| ${Array.from({ length: width }, (_, i) => cells[i] ?? "").join(" | ")} |`;
    const sep = Array.from({ length: width }, (_, i) =>
      aligns[i] === "left" ? ":---" : aligns[i] === "center" ? ":---:" : aligns[i] === "right" ? "---:" : "---",
    );
    const lines = [line(rows[0] ?? []), `|${sep.join("|")}|`, ...rows.slice(1).map(line)];
    lines.forEach((l, i) => {
      state.write(l);
      if (i < lines.length - 1) state.ensureNewLine();
    });
    state.closeBlock(node);
  },
  details(state, node) {
    state.write(node.attrs.sourceOpen ? "<details open>" : "<details>");
    state.ensureNewLine();
    const summary = node.child(0);
    state.write("<summary>");
    state.renderInline(summary, false);
    state.write("</summary>");
    state.closeBlock(summary);
    const content = node.childCount > 1 ? node.child(1) : null;
    if (content) state.renderContent(content);
    state.write("</details>");
    state.closeBlock(node);
  },
};

const marks = {
  italic: { open: "*", close: "*", mixable: true, expelEnclosingWhitespace: true },
  bold: { open: "**", close: "**", mixable: true, expelEnclosingWhitespace: true },
  strike: { open: "~~", close: "~~", mixable: true, expelEnclosingWhitespace: true },
  underline: { open: "<u>", close: "</u>", mixable: true, expelEnclosingWhitespace: true },
  textColor: { open: (_: State, mark: Mark) => `<span style="color: ${mark.attrs.color}">`, close: "</span>", expelEnclosingWhitespace: true },
  bgColor: {
    open: (_: State, mark: Mark) => (mark.attrs.color === "yellow" ? "<mark>" : `<mark style="background: ${mark.attrs.color}">`),
    close: "</mark>",
    expelEnclosingWhitespace: true,
  },
  rawInline: { open: "", close: "", escape: false },
  link: {
    open(state: State, mark: Mark, parent: PMNode, index: number) {
      state.inAutolink = isPlainURL(mark, parent, index);
      return state.inAutolink ? "<" : "[";
    },
    close(state: State, mark: Mark) {
      const auto = state.inAutolink;
      state.inAutolink = undefined;
      return auto ? ">" : `](${destination(mark.attrs.href ?? "")}${title(mark.attrs.title)})`;
    },
    mixable: true,
  },
  code: {
    open: (_: State, __: Mark, parent: PMNode, index: number) => backticks(parent.child(index), -1),
    close: (_: State, __: Mark, parent: PMNode, index: number) => backticks(parent.child(index - 1), 1),
    escape: false,
  },
};

function backticks(node: PMNode, side: number): string {
  let len = 0;
  if (node.isText) for (const m of node.text!.matchAll(/`+/g)) len = Math.max(len, m[0].length);
  let result = len > 0 && side > 0 ? " `" : "`";
  result += "`".repeat(len);
  if (len > 0 && side < 0) result += " ";
  return result;
}

function isPlainURL(link: Mark, parent: PMNode, index: number): boolean {
  if (link.attrs.title || !/^\w+:/.test(link.attrs.href)) return false;
  const content = parent.child(index);
  if (!content.isText || content.text !== link.attrs.href || content.marks[content.marks.length - 1] !== link) return false;
  return index === parent.childCount - 1 || !link.isInSet(parent.child(index + 1).marks);
}

export function serialize(doc: PMNode, frontMatter = ""): string {
  const state = new State(nodes as never, marks as never, { tightLists: true, hardBreakNodeName: "hardBreak", strict: false });
  const chunks: string[] = [];
  doc.forEach((child, _, i) => {
    state.render(child, doc, i);
    if (state.out) {
      chunks.push(state.out);
      state.flushedBlank = state.out.charCodeAt(state.out.length - 1) === 10;
      state.out = "";
    }
  });
  const body = chunks.join("").replace(/\s+$/, "");
  return frontMatter + (body ? body + "\n" : "");
}

/** Letters and digits of a Markdown text, to tell whether a round trip through the editor lost content. */
export function contentWeight(markdown: string): number {
  return (markdown.match(/[\p{L}\p{N}]/gu) ?? []).length;
}

/** Letters and digits lost between `before` (Markdown) and `after`: how much the editor would drop. */
export const LOSS_TOLERANCE = 2;

export function lostContent(before: string, after: string): number {
  const weight = (md: string) => contentWeight(splitFrontMatter(md).body.replace(/&#?\w+;/g, ""));
  return weight(before) - weight(after);
}

/** The document the editor would show for `markdown`, or why showing it would drop content. */
export function parseChecked(parse: (markdown: string) => PMNode, markdown: string): { doc: PMNode } | { lossy: string } {
  let doc: PMNode;
  try {
    doc = parse(markdown);
  } catch (error) {
    return { lossy: String(error) };
  }
  const lost = lostContent(markdown, serialize(doc));
  return lost > LOSS_TOLERANCE ? { lossy: `${lost} characters` } : { doc };
}
