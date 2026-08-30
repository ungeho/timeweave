/**
 * Central place for all date/time conversions.
 *
 * Rules for the whole codebase:
 * - Instants are passed around as UTC ISO 8601 strings (JS `Date#toISOString()`).
 * - Never build or slice those strings by hand. Use these helpers.
 * - The UI displays in the user's local timezone via `Intl`. If we later need
 *   arbitrary-timezone arithmetic, only this file changes (e.g. swap in
 *   date-fns-tz) — no dependency is exposed to callers.
 */

/** Local-time components used by date/time input controls. */
export interface LocalDateTimeParts {
  year: number;
  /** 1-12 */
  month: number;
  /** 1-31 */
  day: number;
  hour: number;
  minute: number;
}

/** Parse a UTC ISO string into a Date. Throws on invalid input. */
export function fromIso(iso: string): Date {
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) {
    throw new Error(`Invalid ISO datetime: ${iso}`);
  }
  return d;
}

/** A Date -> UTC ISO 8601 string. */
export function toIso(date: Date): string {
  return date.toISOString();
}

/** Current instant as UTC ISO. */
export function nowIso(): string {
  return new Date().toISOString();
}

/** Build a UTC ISO string from local wall-clock parts (as the user typed them). */
export function isoFromLocalParts(p: LocalDateTimeParts): string {
  return new Date(p.year, p.month - 1, p.day, p.hour, p.minute, 0, 0).toISOString();
}

/** Decompose a UTC ISO string into local wall-clock parts for form inputs. */
export function localPartsFromIso(iso: string): LocalDateTimeParts {
  const d = fromIso(iso);
  return {
    year: d.getFullYear(),
    month: d.getMonth() + 1,
    day: d.getDate(),
    hour: d.getHours(),
    minute: d.getMinutes(),
  };
}

/**
 * Convert a UTC ISO string to the value format used by
 * `<input type="datetime-local">` ("YYYY-MM-DDTHH:mm"), in local time.
 */
export function toDatetimeLocalValue(iso: string): string {
  const p = localPartsFromIso(iso);
  return (
    `${pad(p.year, 4)}-${pad(p.month, 2)}-${pad(p.day, 2)}` +
    `T${pad(p.hour, 2)}:${pad(p.minute, 2)}`
  );
}

/** Parse a `<input type="datetime-local">` value (local time) into UTC ISO. */
export function isoFromDatetimeLocalValue(value: string): string {
  // Interpreting the naive value with the Date ctor treats it as local time.
  const d = new Date(value);
  if (Number.isNaN(d.getTime())) {
    throw new Error(`Invalid datetime-local value: ${value}`);
  }
  return d.toISOString();
}

/** Convert a UTC ISO string to a "YYYY-MM-DD" value for `<input type="date">`. */
export function toDateInputValue(iso: string): string {
  const p = localPartsFromIso(iso);
  return `${pad(p.year, 4)}-${pad(p.month, 2)}-${pad(p.day, 2)}`;
}

/** Local calendar day key ("YYYY-MM-DD") for grouping occurrences by day. */
export function localDayKey(iso: string): string {
  return toDateInputValue(iso);
}

/** Local midnight of a "YYYY-MM-DD" calendar date, as a UTC ISO instant. */
export function isoFromDateString(dateStr: string): string {
  const [y, m, d] = dateStr.split('-').map(Number);
  if (!y || !m || !d) {
    throw new Error(`Invalid date string: ${dateStr}`);
  }
  return new Date(y, m - 1, d, 0, 0, 0, 0).toISOString();
}

/** Shift a "YYYY-MM-DD" date by whole days, returning "YYYY-MM-DD" (local). */
export function addDaysToDateString(dateStr: string, days: number): string {
  const [y, m, d] = dateStr.split('-').map(Number);
  if (!y || !m || !d) {
    throw new Error(`Invalid date string: ${dateStr}`);
  }
  const shifted = new Date(y, m - 1, d + days, 0, 0, 0, 0);
  return `${pad(shifted.getFullYear(), 4)}-${pad(shifted.getMonth() + 1, 2)}-${pad(shifted.getDate(), 2)}`;
}

/** Start of the local day containing `iso`, as UTC ISO. */
export function startOfLocalDay(iso: string): string {
  const d = fromIso(iso);
  return new Date(d.getFullYear(), d.getMonth(), d.getDate(), 0, 0, 0, 0).toISOString();
}

/** End of the local day (exclusive: start of next day) containing `iso`, as UTC ISO. */
export function endOfLocalDay(iso: string): string {
  const d = fromIso(iso);
  return new Date(d.getFullYear(), d.getMonth(), d.getDate() + 1, 0, 0, 0, 0).toISOString();
}

/** Format an instant for display in the user's locale/timezone. */
export function formatTime(iso: string, locale?: string): string {
  return new Intl.DateTimeFormat(locale, { hour: '2-digit', minute: '2-digit' }).format(fromIso(iso));
}

export function formatDateTime(iso: string, locale?: string): string {
  return new Intl.DateTimeFormat(locale, {
    year: 'numeric',
    month: 'short',
    day: 'numeric',
    hour: '2-digit',
    minute: '2-digit',
  }).format(fromIso(iso));
}

function pad(n: number, width: number): string {
  return String(n).padStart(width, '0');
}
