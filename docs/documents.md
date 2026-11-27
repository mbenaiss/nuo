# Documents: visual editor and Markdown conventions

Documents stay plain Markdown files in the docs git repository (`docs/data.md`): agents read and write them with
their usual tools. The apps edit them visually, like Notion pages, and write back Markdown that any renderer shows
sensibly. This file lists what the editor writes for everything CommonMark has no syntax for; the native reader
(`ios/Nuo/Features/Files/MarkdownView.swift`) shows the same constructs.

## Editor

- `ios/DocEditor/`: a ProseMirror editor (Tiptap 3) with its own Markdown parser and serializer
  (`src/markdown.ts`, markdown-it + prosemirror-markdown). `bun run build` bundles it into
  `ios/Nuo/Resources/DocEditor/` (committed, loaded offline through the `nuo-editor://` scheme, no CDN);
  `bun test` checks the round trip on `test/fixtures/` (`make editor-check` does both).
- The app (`RichDocEditor.swift`) loads Markdown into the page and pulls it back when it saves; edits only send a
  « changed » signal over the bridge. Files of the repo (images, PDF previews) are fetched by the app with the gateway
  token, never by the page.
- Saving is automatic one second after the last change, with the sha the document was opened at. When an agent
  changed the file meanwhile, the app merges line by line (`DocMerge`) if both sides touched different lines, and asks
  otherwise (keep mine / take theirs / keep editing).
- A document the editor cannot show without losing text opens in the raw Markdown editor (« Avancé › Markdown brut »
  on the Mac, the « … » menu on the iPhone).

## Conventions

| What | Markdown written |
|---|---|
| Text color | `<span style="color: red">texte</span>` |
| Background color | `<mark>texte</mark>` (yellow), `<mark style="background: blue">texte</mark>` |
| Underline | `<u>texte</u>` |
| Block color | the same span or mark around the whole content of the block (`## <span style="color: purple">Titre</span>`) |
| Callout | GitHub alert: `> [!NOTE]` then `> 💡 Texte…` (an emoji opening the body is the callout's icon) |
| Toggle | `<details>` / `<summary>Titre</summary>` / blank line / content / blank line / `</details>` |
| Task | `- [ ] à faire`, `- [x] fait` |
| Equation | a ```` ```math ```` code block (rendered by GitHub, shown as code in the apps) |
| Image | `![légende](_fichiers/photo.png)`; once resized: `<img src="_fichiers/photo.png" alt="légende" width="480">` |
| File, PDF, video, audio | `[📎 rapport.pdf](_fichiers/rapport.pdf)` alone on its line: a file card, PDFs shown inline |
| Embedded link | `[🔗 Titre](https://exemple.fr)` alone on its line: a link card |
| Link to a document | a relative link, `[Plan 2026](../lumen-studio/plan-2026.md)` |

Colors are Notion's palette, written by name: `gray`, `brown`, `orange`, `yellow`, `green`, `blue`, `purple`, `pink`,
`red` (readable by any HTML renderer; the apps use Notion's light and dark shades). Other CSS colors are kept.

Callout kinds and colors: `INFO` gray (Notion's default), `NOTE` blue, `TIP` green, `IMPORTANT` purple, `WARNING`
orange, `CAUTION` red.

Files added from the apps go to `<folder of the document>/_fichiers/` (`POST /api/docs/upload`, 50 MB max, never
overwrites: `photo-2.png`) and are linked relatively, so moving the folder keeps the links. They are committed like
the documents: large videos make the repository grow.

## What changes when the editor saves a file written elsewhere

The first save rewrites the file in a canonical form; later saves change only what was edited. Normalisations:
`*`/`+` bullets become `-`, `1)` becomes `1.` with sequential numbers, `__strong__`/`_em_` become `**`/`*`,
setext titles become `#`, indented code becomes fenced, reference links become inline links (the definitions are
kept), `<details open>` stays open, HTML entities are decoded, tables lose their column padding. Unknown HTML blocks,
comments and reference definitions are kept verbatim; unknown inline HTML is kept verbatim too.
