import { getSchema } from "@tiptap/core";
import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { contentWeight, createParser, serialize, splitFrontMatter } from "../src/markdown";
import { baseExtensions } from "../src/schema";

const schema = getSchema(baseExtensions());
const parse = createParser(schema);
const roundTrip = (md: string) => serialize(parse(md), splitFrontMatter(md).front);
const fixture = (name: string) => readFileSync(join(import.meta.dir, "fixtures", name), "utf8");

test("canonical Markdown survives the editor unchanged", () => {
  const md = fixture("canonical.md");
  expect(roundTrip(md)).toBe(md);
});

test("other spellings are normalised once, then stable", () => {
  const md = fixture("variants.md");
  const once = roundTrip(md);
  expect(roundTrip(once)).toBe(once);
  expect(contentWeight(once)).toBeGreaterThanOrEqual(contentWeight(md));
});

test("every construct maps to its block", () => {
  const doc = parse(fixture("canonical.md"));
  const types = new Set<string>();
  doc.descendants((n) => {
    types.add(n.type.name);
    n.marks.forEach((m) => types.add(`mark:${m.type.name}`));
  });
  for (const t of ["heading", "bulletList", "orderedList", "taskList", "taskItem", "blockquote", "callout", "codeBlock", "horizontalRule", "table", "tableHeader", "details", "detailsSummary", "image", "fileBlock", "bookmark", "rawBlock", "hardBreak", "mark:bold", "mark:italic", "mark:underline", "mark:strike", "mark:code", "mark:link", "mark:textColor", "mark:bgColor", "mark:rawInline"]) {
    expect(types.has(t)).toBe(true);
  }
});
