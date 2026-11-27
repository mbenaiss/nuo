import { HttpError } from "../bots/service";

export const bad = (msg: string) => new HttpError(400, msg);

export function obj(v: unknown, field: string): Record<string, unknown> {
  if (!v || typeof v !== "object" || Array.isArray(v)) throw bad(`${field} must be an object`);
  return v as Record<string, unknown>;
}

export function str(v: unknown, field: string, max: number, required: true): string;
export function str(v: unknown, field: string, max: number, required?: boolean): string | undefined;
export function str(v: unknown, field: string, max: number, required = false): string | undefined {
  if (v === undefined || v === null || v === "") {
    if (required) throw bad(`${field} is required`);
    return undefined;
  }
  if (typeof v !== "string") throw bad(`${field} must be a string`);
  const s = v.trim();
  if (!s && required) throw bad(`${field} is required`);
  if (s.length > max) throw bad(`${field} is too long (max ${max})`);
  return s || undefined;
}

export function bool(v: unknown, field: string, fallback?: boolean): boolean {
  if (v === undefined || v === null) {
    if (fallback === undefined) throw bad(`${field} is required`);
    return fallback;
  }
  if (typeof v !== "boolean") throw bad(`${field} must be a boolean`);
  return v;
}

export function int(v: unknown, field: string, min: number, max: number, fallback?: number): number {
  if (v === undefined || v === null) {
    if (fallback === undefined) throw bad(`${field} is required`);
    return fallback;
  }
  if (typeof v !== "number" || !Number.isInteger(v) || v < min || v > max) throw bad(`${field} must be an integer between ${min} and ${max}`);
  return v;
}

/** Instant as a normalized ISO string (the form stored in data.db). */
export function iso(v: unknown, field: string): string {
  if (typeof v !== "string" || !v || Number.isNaN(Date.parse(v))) throw bad(`${field} must be an ISO date-time`);
  return new Date(v).toISOString();
}

const EMAIL = /^[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$/;

export function email(v: unknown, field: string): string {
  const s = str(v, field, 254, true);
  if (!EMAIL.test(s)) throw bad(`${field} is not a valid email address`);
  return s;
}

export const isEmail = (s: string) => s.length <= 254 && EMAIL.test(s);
