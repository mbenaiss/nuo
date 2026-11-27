export const MASKED = "[secret masqué]";

const REFRESH_MS = 30_000;

/**
 * Values worth hiding: long enough and random-looking. Short words, paths, URLs and sentences are left alone,
 * or every answer naming the public address or a folder would be masked.
 */
export function maskable(value: string): boolean {
  const v = value.trim();
  if (v.length < 10 || /\s/.test(v) || v.includes("://") || v.startsWith("/") || v.startsWith("~")) return false;
  return /\d/.test(v) || v.length >= 20;
}

/**
 * Replaces every known secret value in what the bots write before it reaches a screen, a push or the database:
 * the rule in their instructions is the first line, this one holds even when a bot is talked into it.
 */
export class SecretMask {
  private values: string[] = [];
  private loadedAt = -Infinity;

  constructor(
    private readonly source: () => string[],
    private readonly now: () => number = Date.now,
  ) {}

  private current(): string[] {
    if (this.now() - this.loadedAt > REFRESH_MS) {
      this.loadedAt = this.now();
      try {
        // Longest first, so a value that contains another one is masked whole.
        this.values = [...new Set(this.source().map((v) => v.trim()).filter(maskable))].sort((a, b) => b.length - a.length);
      } catch {
        // keep the last known values
      }
    }
    return this.values;
  }

  get longest(): number {
    return this.current()[0]?.length ?? 0;
  }

  mask(text: string): string {
    let out = text;
    for (const v of this.current()) if (out.includes(v)) out = out.split(v).join(MASKED);
    return out;
  }

  /** For streamed text: a value split across two chunks is held back until it can be seen whole. */
  stream(): { push(chunk: string): string; flush(): string } {
    let pending = "";
    return {
      push: (chunk) => {
        const masked = this.mask(pending + chunk);
        const hold = Math.max(0, this.longest - 1);
        if (masked.length <= hold) {
          pending = masked;
          return "";
        }
        pending = masked.slice(masked.length - hold);
        return masked.slice(0, masked.length - hold);
      },
      flush: () => {
        const out = this.mask(pending);
        pending = "";
        return out;
      },
    };
  }
}
