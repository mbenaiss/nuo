import type { Editor } from "@tiptap/core";
import { fileKind, post, toast } from "./bridge";
import { t } from "./i18n";

const MAX_BYTES = 50 * 1024 * 1024;
let counter = 0;
const newId = () => `u${Date.now().toString(36)}${(counter++).toString(36)}`;

function findUploading(editor: Editor, id: string): { pos: number; size: number } | null {
  let found: { pos: number; size: number } | null = null;
  editor.state.doc.descendants((node, pos) => {
    if (found) return false;
    if (node.type.name === "uploading" && node.attrs.id === id) found = { pos, size: node.nodeSize };
    return true;
  });
  return found;
}

function readBase64(file: File): Promise<string> {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => resolve(String(reader.result).replace(/^data:[^,]*,/, ""));
    reader.onerror = () => reject(reader.error);
    reader.readAsDataURL(file);
  });
}

/** Dropped or pasted files: a placeholder per file at `pos`, then the app uploads next to the document. */
export async function uploadFiles(editor: Editor, files: File[], pos: number) {
  const accepted = files.filter((f) => {
    if (f.size > MAX_BYTES) toast(t("“{0}” is over 50 MB.", f.name));
    return f.size <= MAX_BYTES;
  });
  if (!accepted.length) return;
  const items = accepted.map((file) => ({ file, id: newId() }));
  const nodes = items.map(({ file, id }) => ({ type: "uploading", attrs: { id, name: file.name || t("file") } }));
  editor.chain().insertContentAt(pos, nodes).run();
  for (const { file, id } of items) {
    try {
      const data = await readBase64(file);
      post("upload", { id, name: file.name || t("file"), mime: file.type, size: file.size, data });
    } catch {
      uploadFailed(editor, id, t("Couldn't read “{0}”.", file.name));
    }
  }
}

/** "Upload from this device": the empty block becomes a placeholder while the app shows its file picker. */
export function beginPick(editor: Editor, pos: number, size: number, accept: string) {
  const id = newId();
  editor.view.dispatch(editor.state.tr.replaceWith(pos, pos + size, editor.schema.nodes.uploading!.create({ id, name: "…" })));
  post("pick", { id, accept });
}

export function uploadDone(editor: Editor, id: string, file: { src: string; name: string; size?: number }) {
  const found = findUploading(editor, id);
  if (!found) return;
  const { schema } = editor;
  const node = fileKind(file.name) === "image" ? schema.nodes.image!.create({ src: file.src, alt: null }) : schema.nodes.fileBlock!.create({ src: file.src, name: file.name });
  editor.view.dispatch(editor.state.tr.replaceWith(found.pos, found.pos + found.size, node));
}

export function uploadFailed(editor: Editor, id: string, message: string) {
  const found = findUploading(editor, id);
  if (found) editor.view.dispatch(editor.state.tr.delete(found.pos, found.pos + found.size).setMeta("addToHistory", false));
  if (message) toast(message);
}

export function uploadNamed(editor: Editor, id: string, name: string) {
  const found = findUploading(editor, id);
  if (found) editor.view.dispatch(editor.state.tr.setNodeMarkup(found.pos, undefined, { id, name }).setMeta("addToHistory", false));
}

/** The iPhone toolbar's photo and file buttons: a placeholder after the caret's block while the app shows its picker. */
export function pickAtCaret(editor: Editor, accept: string) {
  const { $from } = editor.state.selection;
  const empty = $from.parent.isTextblock && $from.parent.content.size === 0 && $from.depth > 0;
  const id = newId();
  const node = editor.schema.nodes.uploading!.create({ id, name: "…" });
  const tr = editor.state.tr;
  if (empty) tr.replaceWith($from.before($from.depth), $from.after($from.depth), node);
  else tr.insert($from.depth > 0 ? $from.after(1) : $from.pos, node);
  editor.view.dispatch(tr.setMeta("addToHistory", false));
  post("pick", { id, accept });
}
