import { readFileSync } from "node:fs";
import { join } from "node:path";

/** The chrono's exercise catalog (`webapp/chrono/exercises.js` of the fitness repo): one source for both screens. */
export interface ExerciseCatalog {
  /** Picture of a free-text exercise name, relative to the chrono's `img/` folder (`mx/leg-press.jpg`), or null. */
  photo(name: string): string | null;
}

type Entry = { k: string };

/** exercises.js is a classic browser script (globals, no DOM, no exports): evaluated as is, like its own tests do. */
export function loadCatalog(chronoDir: string): ExerciseCatalog {
  const src = readFileSync(join(chronoDir, "exercises.js"), "utf8");
  const { findEx, exThumb } = new Function(`${src}\nreturn { findEx, exThumb };`)() as {
    findEx: (name: string) => Entry | null;
    exThumb: (e: Entry | null) => string;
  };
  return {
    photo: (name) => {
      const thumb = exThumb(findEx(name));
      return thumb.startsWith("img/") ? thumb.slice(4) : null;
    },
  };
}
