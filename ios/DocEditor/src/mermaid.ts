/** Pele, loaded by doc-editor.html from the app's bundled pele.js (shared with the reader, not bundled twice). */
interface Pele {
  render(source: string, options?: { maxWidth?: number; fontFamily?: string }): { svg: string; width: number; height: number };
}

export type Drawing = { svg: string } | { error: string };

/** A ```mermaid block drawn as the reader draws it; a diagram too wide for `maxWidth` is laid out top to bottom. */
export function drawMermaid(source: string, maxWidth?: number): Drawing | null {
  const pele = (globalThis as { pele?: Pele }).pele;
  if (!pele || !source.trim()) return null;
  try {
    const { svg } = pele.render(source, { fontFamily: "-apple-system, sans-serif", ...(maxWidth && maxWidth > 0 ? { maxWidth } : {}) });
    return { svg };
  } catch (e) {
    // Pele's syntax errors list the grammar's expectations after the first line, which says where.
    const message = (e as Error)?.message ?? String(e);
    return { error: message.split("\n")[0]!.replace(/[:\s]+$/, "") };
  }
}
