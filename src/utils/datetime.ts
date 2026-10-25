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

/**
 * Shift a "YYYY-MM-DD" date by whole days, returning "YYYY-MM-DD".
 *
 * Pure calendar arithmetic, in UTC fields (P8-c1). It used to go through a
 * LOCAL Date midnight, which is the same answer everywhere except where the
 * OS zone skipped a whole day: with the OS on Pacific/Apia, 2011-12-29 + 1
 * came out as 2011-12-31. A calendar date has no zone; adding to one must not
 * depend on where the computer is.
 */
export function addDaysToDateString(dateStr: string, days: number): string {
  const [y, m, d] = dateStr.split('-').map(Number);
  if (!y || !m || !d) {
    throw new Error(`Invalid date string: ${dateStr}`);
  }
  const shifted = new Date(Date.UTC(y, m - 1, d + days));
  return `${pad(shifted.getUTCFullYear(), 4)}-${pad(shifted.getUTCMonth() + 1, 2)}-${pad(shifted.getUTCDate(), 2)}`;
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

/**
 * THE 24-HOUR CLOCK, PINNED FOR EVERY LOCALE.
 *
 * Without this, `en-US` renders "09:00 AM" where `ja-JP` renders "09:00", and
 * the time-grid gutter next to it is a hardcoded 00:00..23:00 ladder -- so an
 * English viewer would read event times on one clock and the axis beside them
 * on another. Pinning the clock is cheaper and clearer than teaching the
 * gutter to switch, and it is what P4's brief asked for.
 *
 * `'h23'` and NOT `'h24'`: the two differ only at midnight, where h24 renders
 * "24:00". The grid's own axis starts at 00:00, and an event at midnight has
 * to agree with it.
 *
 * It is an option fragment rather than a whole format because the three
 * functions below need different DATE parts while sharing one clock.
 */
export const CLOCK_24H: Intl.DateTimeFormatOptions = { hourCycle: 'h23' };

/**
 * Clock time of an instant, in the viewer's zone.
 *
 * `locale` is the BCP 47 tag, which callers get from `intlLocale(language)`.
 * Omitting it falls back to the runtime's locale, which is what every caller
 * did before P4 -- the parameter has existed since this function was written.
 *
 * NO `timeZone` OPTION, deliberately: the zone is the viewer's own, and which
 * zone a time is shown in is a separate concern from which language names it.
 */
export function formatTime(iso: string, locale?: string): string {
  return new Intl.DateTimeFormat(locale, {
    hour: '2-digit',
    minute: '2-digit',
    ...CLOCK_24H,
  }).format(fromIso(iso));
}

/**
 * Date and time of an instant, with an abbreviated month.
 *
 * NOTHING CALLS THIS as of P4 step 2. It is kept, and kept consistent with
 * the clock above, so that the next caller gets a 24-hour time rather than
 * discovering the inconsistency in review.
 */
export function formatDateTime(iso: string, locale?: string): string {
  return new Intl.DateTimeFormat(locale, {
    year: 'numeric',
    month: 'short',
    day: 'numeric',
    hour: '2-digit',
    minute: '2-digit',
    ...CLOCK_24H,
  }).format(fromIso(iso));
}

/**
 * Date and time of an instant, in each locale's own SHORT form.
 *
 * `toLocaleString` with no date or time parts, which is exactly what the share
 * dialog's expiry line has always called -- so the Japanese comes out byte for
 * byte as it did ("2026/8/29 9:00:00"). The only thing added is the clock pin,
 * which the Japanese output already satisfied and the English did not.
 *
 * Distinct from `formatDateTime` on purpose: that one names the month and
 * zero-pads the hour, which would have rewritten the Japanese expiry line.
 */
export function formatInstant(iso: string, locale?: string): string {
  return fromIso(iso).toLocaleString(locale, CLOCK_24H);
}

function pad(n: number, width: number): string {
  return String(n).padStart(width, '0');
}
