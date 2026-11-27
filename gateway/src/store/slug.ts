const MAX_SLUG = 40;

export function slugify(name: string): string {
  const s = name
    .normalize("NFKD")
    .replace(/[̀-ͯ]/g, "")
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, MAX_SLUG)
    .replace(/-+$/, "");
  return s || "bot";
}

export function uniqueSlug(name: string, taken: (slug: string) => boolean): string {
  const base = slugify(name);
  if (!taken(base)) return base;
  for (let n = 2; ; n++) {
    const s = `${base}-${n}`;
    if (!taken(s)) return s;
  }
}
