import { writeFileSync } from "node:fs";

// Writes a long document mixing every block type: `bun run scripts/perf-fixture.ts <lines> <out.md>`.
const target = Number(process.argv[2] ?? 2000);
const section = (i: number) => `## Section ${i}

Un paragraphe avec du **gras**, de l'*italique*, un [lien](notes/plan-${i}.md), du <span style="color: red">rouge</span> et <mark>surligné</mark>.
Une deuxième ligne du même paragraphe, snake_case et 5 * 3.

- Puce ${i}.1
- Puce ${i}.2
  - Sous-puce

- [ ] Tâche ${i}
- [x] Tâche faite ${i}

> [!TIP]
> 💡 Un encadré numéro ${i}.

| Quoi | Combien | Quand |
|---|---|---|
| Item ${i} | ${i * 3} € | lundi |
| Autre | 12 € | mardi |

<details>
<summary>Détails ${i}</summary>

Contenu caché ${i}.

</details>

![Image ${i}](_fichiers/image-${i % 7}.png)

\`\`\`js
const value${i} = ${i};
\`\`\`

`;
let out = "# Document de test\n\n";
let i = 0;
while (out.split("\n").length < target) out += section(++i);
writeFileSync(process.argv[3]!, out);
console.log(`${out.split("\n").length} lines, ${i} sections, ${(out.length / 1024).toFixed(0)} KB`);
