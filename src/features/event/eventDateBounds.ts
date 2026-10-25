/**
 * The dates and instants the database can store (K18, P8-finish-3b).
 *
 * 0013 bounds every event to
 *   events_allday_range  start_date, end_date (EXCLUSIVE)  in [0100-01-01, 10000-01-01)
 *   events_timed_range   start_at,   end_at                in [0100-01-01Z, 10000-01-01Z)
 * The form used to let an all-day event end ON 9999-12-31 (its exclusive end
 * is then 10000-01-01) and a timed one end past 10000-01-01 in UTC (9999-12-31
 * 22:00 in New York): the database refused them with a generic error, and local
 * mode saved them, so the two modes disagreed. These are the same bounds, so
 * the form can refuse first, with its own message, in both modes.
 *
 * The timed bound is an INSTANT: the same wall clock is inside in Tokyo and
 * outside in New York. Stored rows are never checked or changed here; this is
 * only what may be written. eventDateBounds.test.ts reads 0013 to keep the
 * numbers equal.
 */

/** First all-day date the database stores (start or exclusive end). */
export const DB_FIRST_DATE = '0100-01-01';
/** The exclusive end date may be at most the day before this. */
export const DB_END_DATE_EXCLUSIVE = '10000-01-01';
/** The last day an all-day event can cover (its exclusive end is 9999-12-31). */
export const LAST_ALL_DAY_DATE = '9999-12-30';
export const DB_FIRST_INSTANT_MS = Date.UTC(100, 0, 1);
export const DB_END_INSTANT_MS = Date.UTC(10000, 0, 1);

/**
 * "YYYY-MM-DD" keys (and the five-digit "10000-01-01" the date arithmetic
 * produces) compare correctly only at equal length, so compare as numbers.
 */
function dayNumber(key: string): number {
  const m = /^(\d{4,5})-(\d{2})-(\d{2})$/.exec(key);
  if (!m) return Number.NaN;
  return Number(m[1]) * 10000 + Number(m[2]) * 100 + Number(m[3]);
}

/** True when an all-day [startDate, endExclusive) is outside what the database stores. */
export function allDayOutOfRange(startDate: string, endExclusive: string): boolean {
  const first = dayNumber(DB_FIRST_DATE);
  const end = dayNumber(DB_END_DATE_EXCLUSIVE);
  const s = dayNumber(startDate);
  const e = dayNumber(endExclusive);
  return !(s >= first && s < end && e >= first && e < end);
}

/** True when a timed [startAt, endAt] is outside what the database stores. */
export function timedOutOfRange(startAt: string, endAt: string): boolean {
  const s = new Date(startAt).getTime();
  const e = new Date(endAt).getTime();
  const inside = (t: number) => t >= DB_FIRST_INSTANT_MS && t < DB_END_INSTANT_MS;
  return !(inside(s) && inside(e));
}
