import { getSchema } from "@tiptap/core";
import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { createParser, lostContent, parseChecked, serialize } from "../src/markdown";
import { baseExtensions } from "../src/schema";

const schema = getSchema(baseExtensions());
const parse = createParser(schema);
const canonical = readFileSync(join(import.meta.dir, "fixtures", "canonical.md"), "utf8");

const minutes = `---
tags: [copropriete]
---
# Assemblée générale du 14 mars

- Ravalement de la façade : devis Bâti-Est à 48 200 €
- Vote du budget 2026 : adopté à 812 tantièmes sur 1 000
`;

test("a document the editor shows whole is accepted", () => {
  const checked = parseChecked(parse, canonical);
  expect("doc" in checked).toBe(true);
  if ("doc" in checked) expect(serialize(checked.doc)).toContain("#");
});

test("front matter is not counted as lost", () => {
  const checked = parseChecked(parse, minutes);
  expect("doc" in checked).toBe(true);
  expect(lostContent(minutes, serialize(parse(minutes)))).toBeLessThanOrEqual(0);
});

test("a parser failure is reported instead of replacing the content", () => {
  const failing = () => {
    throw new Error("unclosed table in Charges.md");
  };
  expect(parseChecked(failing, minutes)).toEqual({ lossy: "Error: unclosed table in Charges.md" });
});

test("a reload that would drop text is reported", () => {
  const truncated = () => schema.node("doc", null, [schema.node("heading", { level: 1 }, [schema.text("Assemblée générale du 14 mars")])]);
  const checked = parseChecked(truncated, minutes);
  expect("lossy" in checked).toBe(true);
  expect(lostContent(minutes, "# Assemblée générale du 14 mars\n")).toBeGreaterThan(40);
});
