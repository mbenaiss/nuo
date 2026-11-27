import { copyFileSync, mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";

// Bundles the editor into the app's resources (served offline by the app, never from a CDN).
const out = join(import.meta.dir, "..", "..", "Nuo", "Resources", "DocEditor");
mkdirSync(out, { recursive: true });
const result = await Bun.build({ entrypoints: [join(import.meta.dir, "..", "src", "main.ts")], target: "browser", format: "iife", minify: true });
if (!result.success) {
  for (const log of result.logs) console.error(log);
  process.exit(1);
}
writeFileSync(join(out, "doc-editor.js"), await result.outputs[0]!.text());
copyFileSync(join(import.meta.dir, "..", "src", "editor.css"), join(out, "doc-editor.css"));
writeFileSync(
  join(out, "doc-editor.html"),
  `<!doctype html>
<html lang="fr">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, viewport-fit=cover">
<link rel="stylesheet" href="doc-editor.css">
</head>
<body>
<div id="editor"></div>
<script src="pele.js"></script>
<script src="doc-editor.js"></script>
</body>
</html>
`,
);
// Pele draws the docs' and answers' ```mermaid blocks natively (MermaidRenderer.swift), pinned like the editor.
const pele = join(import.meta.dir, "..", "..", "Nuo", "Resources", "Pele");
mkdirSync(pele, { recursive: true });
copyFileSync(join(import.meta.dir, "..", "node_modules", "pele", "dist", "pele.global.js"), join(pele, "pele.js"));
console.log(`doc-editor.js ${(Bun.file(join(out, "doc-editor.js")).size / 1024).toFixed(0)} KB`);
