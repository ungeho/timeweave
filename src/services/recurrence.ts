/**
 * RRULE parsing and occurrence expansion for TimeWeave's supported subset.
 *
 * This module is the ONLY place that understands RRULE strings. Callers use
 * `parseRRule` / `expandRule` and never touch the raw string. If we later swap
 * in a full library (rrule.js), we keep these signatures and replace the body.
 *
 * Supported subset (see types/recurrence.ts). Anything outside it throws
 * `UnsupportedRRuleError` — we never silently misinterpret an RRULE.
 */

import type { Freq, RecurrenceRule, RecurrenceUntil, Weekday } from '../types/recurrence';
import { WEEKDAYS } from '../types/recurrence';
import { fromIso } from '../utils/datetime';

export class UnsupportedRRuleError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'UnsupportedRRuleError';
  }
}

const SUPPORTED_KEYS = new Set(['FREQ', 'INTERVAL', 'BYDAY', 'COUNT', 'UNTIL']);
const SUPPORTED_FREQ = new Set<Freq>(['DAILY', 'WEEKLY', 'MONTHLY']);
const WEEKDAY_SET = new Set<string>(WEEKDAYS);

/** Safety cap so an infinite (no COUNT/UNTIL) rule can never loop forever. */
const MAX_ITERATIONS = 3660;

/**
 * Parse an RRULE string into a validated RecurrenceRule.
 * Throws UnsupportedRRuleError for any key/value outside the supported subset.
 */
export function parseRRule(rrule: string): RecurrenceRule {
  const parts = rrule
    .trim()
    .split(';')
    .filter((p) => p.length > 0);

  const map = new Map<string, string>();
  for (const part of parts) {
    const eq = part.indexOf('=');
    if (eq === -1) {
      throw new UnsupportedRRuleError(`Malformed RRULE segment: "${part}"`);
    }
    const key = part.slice(0, eq).trim().toUpperCase();
    const value = part.slice(eq + 1).trim();
    if (!SUPPORTED_KEYS.has(key)) {
      throw new UnsupportedRRuleError(`Unsupported RRULE key: ${key}`);
    }
    if (map.has(key)) {
      throw new UnsupportedRRuleError(`Duplicate RRULE key: ${key}`);
    }
    map.set(key, value);
  }

  const freqRaw = map.get('FREQ');
  if (!freqRaw) {
    throw new UnsupportedRRuleError('RRULE is missing FREQ');
  }
  const freq = freqRaw.toUpperCase() as Freq;
  if (!SUPPORTED_FREQ.has(freq)) {
    throw new UnsupportedRRuleError(`Unsupported FREQ: ${freqRaw}`);
  }

  let interval = 1;
  const intervalRaw = map.get('INTERVAL');
  if (intervalRaw !== undefined) {
    interval = Number(intervalRaw);
    if (!Number.isInteger(interval) || interval < 1) {
      throw new UnsupportedRRuleError(`Invalid INTERVAL: ${intervalRaw}`);
    }
  }

  let byDay: Weekday[] | undefined;
  const byDayRaw = map.get('BYDAY');
  if (byDayRaw !== undefined) {
    if (freq !== 'WEEKLY') {
      throw new UnsupportedRRuleError('BYDAY is only supported with FREQ=WEEKLY');
    }
    byDay = byDayRaw.split(',').map((token) => {
      const t = token.trim().toUpperCase();
      if (!WEEKDAY_SET.has(t)) {
        // Catches ordinals like "2MO" and typos alike.
        throw new UnsupportedRRuleError(`Unsupported BYDAY value: ${token}`);
      }
      return t as Weekday;
    });
    if (byDay.length === 0) {
      throw new UnsupportedRRuleError('BYDAY is empty');
    }
  }

  const hasCount = map.has('COUNT');
  const hasUntil = map.has('UNTIL');
  if (hasCount && hasUntil) {
    throw new UnsupportedRRuleError('COUNT and UNTIL cannot both be present');
  }

  let count: number | undefined;
  if (hasCount) {
    count = Number(map.get('COUNT'));
    if (!Number.isInteger(count) || count < 1) {
      throw new UnsupportedRRuleError(`Invalid COUNT: ${map.get('COUNT')}`);
    }
  }

  let until: RecurrenceUntil | undefined;
  if (hasUntil) {
    until = parseUntil(map.get('UNTIL')!);
  }

  return { freq, interval, byDay, count, until };
}

/**
 * Serialize a RecurrenceRule back to an RRULE string. Guaranteed round-trip:
 * `parseRRule(formatRRule(rule))` deep-equals `rule`. UNTIL follows its kind
 * (timed instant -> "...T...Z", all-day date -> "YYYYMMDD").
 */
export function formatRRule(rule: RecurrenceRule): string {
  const parts = [`FREQ=${rule.freq}`];
  if (rule.interval !== 1) parts.push(`INTERVAL=${rule.interval}`);
  if (rule.byDay && rule.byDay.length > 0) parts.push(`BYDAY=${rule.byDay.join(',')}`);
  if (rule.count !== undefined) parts.push(`COUNT=${rule.count}`);
  if (rule.until) {
    parts.push(
      `UNTIL=${
        rule.until.kind === 'instant'
          ? toBasicUtc(rule.until.instant)
          : rule.until.date.replace(/-/g, '')
      }`,
    );
  }
  return parts.join(';');
}

/**
 * Expand a recurring master into occurrence START instants (UTC ISO) that fall
 * within [rangeStartIso, rangeEndIso). COUNT/UNTIL limits are honoured against
 * the full series, not just the visible range.
 *
 * Time-of-day is preserved as local wall-clock across occurrences.
 */
export function expandRule(
  rrule: string,
  dtstartIso: string,
  rangeStartIso: string,
  rangeEndIso: string,
): string[] {
  const rule = parseRRule(rrule);
  const dtstart = fromIso(dtstartIso);
  const rangeStart = fromIso(rangeStartIso).getTime();
  const rangeEnd = fromIso(rangeEndIso).getTime();

  // Until is compared in instant space for timed series, and in local calendar
  // date space for all-day series (no timezone conversion), matching its kind.
  const untilInstant =
    rule.until?.kind === 'instant' ? fromIso(rule.until.instant).getTime() : undefined;
  const untilDate = rule.until?.kind === 'date' ? rule.until.date : undefined;
  const hasUntil = rule.until !== undefined;

  const hour = dtstart.getHours();
  const minute = dtstart.getMinutes();
  const second = dtstart.getSeconds();
  const ms = dtstart.getMilliseconds();

  const results: string[] = [];
  let emitted = 0;

  const pastUntil = (d: Date): boolean => {
    if (untilInstant !== undefined) return d.getTime() > untilInstant;
    if (untilDate !== undefined) return localDateStr(d) > untilDate;
    return false;
  };

  const push = (d: Date): boolean => {
    if (pastUntil(d)) return false;
    const t = d.getTime();
    emitted += 1;
    if (t >= rangeStart && t < rangeEnd) {
      results.push(d.toISOString());
    }
    if (rule.count !== undefined && emitted >= rule.count) return false;
    return true;
  };

  const byDayIndices =
    rule.freq === 'WEEKLY'
      ? (rule.byDay ?? [weekdayOf(dtstart)]).map(weekdayIndex)
      : [];

  for (let i = 0; i < MAX_ITERATIONS; i++) {
    let keepGoing = true;

    if (rule.freq === 'DAILY') {
      const d = new Date(
        dtstart.getFullYear(),
        dtstart.getMonth(),
        dtstart.getDate() + i * rule.interval,
        hour, minute, second, ms,
      );
      if (d.getTime() >= rangeEnd && rule.count === undefined && !hasUntil) break;
      keepGoing = push(d);
    } else if (rule.freq === 'WEEKLY') {
      // Move to the Monday of dtstart's week, then step `interval` weeks.
      const weekStart = mondayOfWeek(dtstart);
      for (const dayIdx of byDayIndices) {
        const d = new Date(
          weekStart.getFullYear(),
          weekStart.getMonth(),
          weekStart.getDate() + i * rule.interval * 7 + dayIdx,
          hour, minute, second, ms,
        );
        if (d.getTime() < dtstart.getTime()) continue; // skip days before series start
        keepGoing = push(d);
        if (!keepGoing) break;
      }
      const probe = new Date(
        weekStart.getFullYear(),
        weekStart.getMonth(),
        weekStart.getDate() + i * rule.interval * 7,
        hour, minute, second, ms,
      );
      if (probe.getTime() >= rangeEnd && rule.count === undefined && !hasUntil) break;
    } else {
      // MONTHLY: same day-of-month as dtstart, stepping `interval` months.
      const d = new Date(
        dtstart.getFullYear(),
        dtstart.getMonth() + i * rule.interval,
        dtstart.getDate(),
        hour, minute, second, ms,
      );
      if (d.getTime() >= rangeEnd && rule.count === undefined && !hasUntil) break;
      keepGoing = push(d);
    }

    if (!keepGoing) break;
  }

  return results;
}

function parseUntil(raw: string): RecurrenceUntil {
  // Timed: RFC 5545 basic UTC date-time "YYYYMMDDTHHMMSSZ".
  const dt = /^(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})Z$/.exec(raw);
  if (dt) {
    const [y, mo, d, h, mi, s] = dt.slice(1).map(Number);
    return { kind: 'instant', instant: new Date(Date.UTC(y!, mo! - 1, d!, h!, mi!, s!)).toISOString() };
  }
  // All-day: RFC 5545 DATE form "YYYYMMDD" (no timezone conversion).
  const date = /^(\d{4})(\d{2})(\d{2})$/.exec(raw);
  if (date) {
    return { kind: 'date', date: `${date[1]}-${date[2]}-${date[3]}` };
  }
  throw new UnsupportedRRuleError(`Invalid UNTIL: ${raw}`);
}

/** UTC ISO instant -> RFC 5545 basic form "YYYYMMDDTHHMMSSZ". */
function toBasicUtc(iso: string): string {
  const d = fromIso(iso);
  const p = (n: number) => String(n).padStart(2, '0');
  return (
    `${d.getUTCFullYear()}${p(d.getUTCMonth() + 1)}${p(d.getUTCDate())}` +
    `T${p(d.getUTCHours())}${p(d.getUTCMinutes())}${p(d.getUTCSeconds())}Z`
  );
}

/** Local calendar date "YYYY-MM-DD" of a Date, in the same frame it was built. */
function localDateStr(d: Date): string {
  const p = (n: number) => String(n).padStart(2, '0');
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}`;
}

function weekdayIndex(w: Weekday): number {
  // 0 = Monday .. 6 = Sunday (matches mondayOfWeek offset math).
  return WEEKDAYS.indexOf(w);
}

function weekdayOf(d: Date): Weekday {
  // JS getDay(): 0=Sun..6=Sat -> our MO-first array.
  const jsDay = d.getDay();
  const idx = (jsDay + 6) % 7;
  return WEEKDAYS[idx]!;
}

function mondayOfWeek(d: Date): Date {
  const idx = (d.getDay() + 6) % 7; // days since Monday
  return new Date(d.getFullYear(), d.getMonth(), d.getDate() - idx, 0, 0, 0, 0);
}
