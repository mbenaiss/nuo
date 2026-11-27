import { getSchema } from "@tiptap/core";
import { afterEach, beforeEach, expect, test } from "bun:test";
import * as pele from "pele";
import { createParser, serialize } from "../src/markdown";
import { drawMermaid } from "../src/mermaid";
import { baseExtensions } from "../src/schema";

const CHARGES = `flowchart LR
  A[Relevé des charges reçu] --> B{Justificatifs fournis ?}
  B -->|oui| C[Comparer avec 2024]
  B -->|non| D[Demander au syndic]
  C --> E[Validation en AG]`;

beforeEach(() => {
  (globalThis as { pele?: unknown }).pele = pele;
});
afterEach(() => {
  delete (globalThis as { pele?: unknown }).pele;
});

test("a mermaid block is drawn as the reader draws it", () => {
  const drawing = drawMermaid(CHARGES);
  expect(drawing && "svg" in drawing && drawing.svg.startsWith("<svg")).toBe(true);
  expect(drawing && "svg" in drawing && drawing.svg.includes("Demander au syndic")).toBe(true);
});

test("a diagram too wide for the editor is laid out top to bottom", () => {
  const wide = pele.render(CHARGES);
  const narrow = drawMermaid(CHARGES, 340);
  const [width, height] = (/viewBox="0 0 ([\d.]+) ([\d.]+)"/.exec(narrow && "svg" in narrow ? narrow.svg : "") ?? []).slice(1).map(Number);
  expect(width!).toBeLessThan(wide.width / 2);
  expect(height!).toBeGreaterThan(width!);
});

test("a broken diagram says where, on one line", () => {
  const drawing = drawMermaid("flowchart LR\n  A[Relevé] -->");
  expect(drawing && "error" in drawing ? drawing.error : "").toContain("line");
  expect(drawing && "error" in drawing ? drawing.error : "\n").not.toContain("\n");
});

test("nothing is drawn without Pele or without code", () => {
  delete (globalThis as { pele?: unknown }).pele;
  expect(drawMermaid(CHARGES)).toBeNull();
  (globalThis as { pele?: unknown }).pele = pele;
  expect(drawMermaid("  ")).toBeNull();
});

test("a mermaid block survives the editor unchanged", () => {
  const schema = getSchema(baseExtensions());
  const md = "# Contrôle des charges\n\n```mermaid\n" + CHARGES + "\n```\n";
  expect(serialize(createParser(schema)(md))).toBe(md);
});
