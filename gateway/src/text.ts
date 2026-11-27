// JS strings are UTF-16: a cut between the two halves of an emoji leaves a lone surrogate, which JSON.stringify
// writes as a \uD8xx escape that the apps' JSONDecoder rejects, dropping the whole event or response.

const isHigh = (code: number) => code >= 0xd800 && code <= 0xdbff;
const isLow = (code: number) => code >= 0xdc00 && code <= 0xdfff;

/** `index`, moved back by one when it falls between the two halves of a surrogate pair. */
export function safeCut(text: string, index: number): number {
  return index > 0 && index < text.length && isHigh(text.charCodeAt(index - 1)) && isLow(text.charCodeAt(index)) ? index - 1 : index;
}

/** The first `max` code units at most, never ending on half of a pair. */
export function head(text: string, max: number): string {
  return text.length > max ? text.slice(0, safeCut(text, Math.max(0, max))) : text;
}

/** The last `max` code units at most, never starting on half of a pair. */
export function tail(text: string, max: number): string {
  if (text.length <= max) return text;
  const start = text.length - Math.max(0, max);
  return text.slice(start > 0 && isLow(text.charCodeAt(start)) && isHigh(text.charCodeAt(start - 1)) ? start + 1 : start);
}
