/**
 * Structured representation of the RRULE subset TimeWeave supports.
 *
 * This is intentionally a small, explicit subset of RFC 5545 RRULE. The parser
 * in `services/recurrence.ts` rejects anything outside this subset instead of
 * silently misinterpreting it. If we later adopt a full library (e.g.
 * rrule.js), only `services/recurrence.ts` changes — callers depend on the
 * occurrence-expansion API, not on this shape.
 */

export type Weekday = 'MO' | 'TU' | 'WE' | 'TH' | 'FR' | 'SA' | 'SU';

export const WEEKDAYS: readonly Weekday[] = ['MO', 'TU', 'WE', 'TH', 'FR', 'SA', 'SU'];

export type Freq = 'DAILY' | 'WEEKLY' | 'MONTHLY';

/**
 * Inclusive series end. Timed recurrences end at a UTC instant; all-day
 * recurrences end on a calendar DATE (no timezone conversion), matching RFC
 * 5545 where UNTIL follows the value type of DTSTART.
 */
export type RecurrenceUntil =
  | { kind: 'instant'; instant: string } // UTC ISO 8601 (timed)
  | { kind: 'date'; date: string }; // "YYYY-MM-DD" (all-day)

/**
 * Supported subset:
 * - FREQ: DAILY | WEEKLY | MONTHLY                (required)
 * - INTERVAL: positive integer, default 1         (e.g. bi-weekly = 2)
 * - BYDAY: plain weekdays only (MO..SU)           (WEEKLY only; no ordinals like 2MO)
 * - COUNT xor UNTIL                               (never both; omit both = infinite)
 *
 * Explicitly UNSUPPORTED (parser throws UnsupportedRRuleError):
 *   BYMONTHDAY, BYMONTH, BYSETPOS, BYHOUR, WKST, ordinal BYDAY, COUNT+UNTIL together, etc.
 */
export interface RecurrenceRule {
  freq: Freq;
  /** >= 1. Defaults to 1 when absent from the RRULE string. */
  interval: number;
  /** Weekdays for WEEKLY rules. undefined = derive from the master's own weekday. */
  byDay?: Weekday[];
  /** Number of occurrences. Mutually exclusive with `until`. */
  count?: number;
  /** Inclusive series end (instant for timed, date for all-day). Mutually exclusive with `count`. */
  until?: RecurrenceUntil;
}
