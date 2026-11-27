import { getSchema } from "@tiptap/core";
import { readFileSync } from "node:fs";
import { createParser, serialize, splitFrontMatter } from "../src/markdown";
import { baseExtensions } from "../src/schema";

// Prints a Markdown file as the editor would save it: `bun run scripts/roundtrip.ts <file.md>`.
const md = readFileSync(process.argv[2]!, "utf8");
const parse = createParser(getSchema(baseExtensions()));
process.stdout.write(serialize(parse(md), splitFrontMatter(md).front));
