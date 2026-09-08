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
import type { ZonedWallClock } from '../utils/timezone';
import { resolveZonedWallClock, zonedWallClockOf } from '../utils/timezone';

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
 * Time-of-day is preserved as wall-clock across occurrences. WHICH ZONE that
 * wall clock belongs to is `timeZone` (Phase 5b-4):
 *
 *   timeZone = an IANA name -- FREQ=DAILY and FREQ=WEEKLY are anchored to that
 *     zone and resolved exactly as migration 0009 resolves them, gaps and folds
 *     included (see utils/timezone.resolveZonedWallClock). This is the case for
 *     a timed recurrence master that carries `events.timezone` (state M1).
 *
 *   timeZone = null -- the runtime's local zone, which is what every caller got
 *     before 5b-4. All-day series pass null (they are pure date arithmetic and
 *     0007 owns them), and so do legacy M0 masters, whose authoring zone is
 *     unknowable and must not be guessed. The default keeps that the behaviour
 *     of every existing caller.
 *
 * FREQ=MONTHLY is deliberately NOT zone-aware even when `timeZone` is given:
 * 0009 does not expand MONTHLY at all (it reports the window incomplete), so
 * there is no SQL semantics to match, and inventing one here would be a change
 * nothing pins down. It keeps its pre-5b-4 local-time behaviour exactly.
 */
export function expandRule(
  rrule: string,
  dtstartIso: string,
  rangeStartIso: string,
  rangeEndIso: string,
  timeZone: string | null = null,
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

  // DTSTART's wall clock, read in whichever zone this expansion is anchored to.
  const dtstartMs = dtstart.getTime();
  const dtWall: ZonedWallClock =
    timeZone === null
      ? {
          year: dtstart.getFullYear(),
          month: dtstart.getMonth() + 1,
          day: dtstart.getDate(),
          hour: dtstart.getHours(),
          minute: dtstart.getMinutes(),
          second: dtstart.getSeconds(),
          ms: dtstart.getMilliseconds(),
        }
      : zonedWallClockOf(dtstartMs, timeZone);

  const hour = dtWall.hour;
  const minute = dtWall.minute;
  const second = dtWall.second;
  const ms = dtWall.ms;
  const dtCivil: Civil = { year: dtWall.year, month: dtWall.month, day: dtWall.day };

  /**
   * The instant of an occurrence falling on civil date `c`, at DTSTART's
   * time-of-day.
   *
   * DTSTART ITSELF IS NEVER RECONSTRUCTED (mirrors 0009's
   * `if v_cl = v_dtl then v_start := p_start_at`). `start_at` is a stored
   * instant; rendering it into the zone and converting back is lossy exactly on
   * a fold, which would move the first occurrence of the series by an hour. All
   * candidates share DTSTART's time of day and differ only in date, so the date
   * test below identifies that one candidate exactly.
   */
  const instantOn = (c: Civil): Date => {
    if (timeZone === null) {
      return new Date(c.year, c.month - 1, c.day, hour, minute, second, ms);
    }
    if (c.year === dtCivil.year && c.month === dtCivil.month && c.day === dtCivil.day) {
      return new Date(dtstartMs);
    }
    return new Date(
      resolveZonedWallClock({ ...c, hour, minute, second, ms }, timeZone),
    );
  };

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

  // BYDAY defaults to DTSTART's own weekday, read in the SAME zone the wall
  // clock above came from -- browser-local for M0, the master's zone for M1. A
  // hybrid (zone wall clock, browser weekday) would put occurrences on the
  // wrong day whenever the two zones disagree about DTSTART's date.
  const dtWeekdayIndex = civilWeekdayIndex(dtCivil);
  const byDayIndices =
    rule.freq === 'WEEKLY'
      ? (rule.byDay ?? [WEEKDAYS[dtWeekdayIndex]!]).map(weekdayIndex)
      : [];

  for (let i = 0; i < MAX_ITERATIONS; i++) {
    let keepGoing = true;

    if (rule.freq === 'DAILY') {
      const d = instantOn(civil(dtCivil.year, dtCivil.month, dtCivil.day + i * rule.interval));
      if (d.getTime() >= rangeEnd && rule.count === undefined && !hasUntil) break;
      keepGoing = push(d);
    } else if (rule.freq === 'WEEKLY') {
      // Move to the Monday of dtstart's week, then step `interval` weeks.
      const weekStart = civil(dtCivil.year, dtCivil.month, dtCivil.day - dtWeekdayIndex);
      for (const dayIdx of byDayIndices) {
        const d = instantOn(
          civil(weekStart.year, weekStart.month, weekStart.day + i * rule.interval * 7 + dayIdx),
        );
        if (d.getTime() < dtstartMs) continue; // skip days before series start
        keepGoing = push(d);
        if (!keepGoing) break;
      }
      const probe = instantOn(
        civil(weekStart.year, weekStart.month, weekStart.day + i * rule.interval * 7),
      );
      if (probe.getTime() >= rangeEnd && rule.count === undefined && !hasUntil) break;
    } else {
      // MONTHLY: same day-of-month as dtstart, stepping `interval` months.
      //
      // NOT zone-aware, on purpose (see the function's doc comment): every field
      // below is read straight off `dtstart` in the runtime's local zone, never
      // from the zoned wall clock, so passing a `timeZone` cannot turn this into
      // a half-converted hybrid. 0009 leaves MONTHLY unexpanded, so there is
      // nothing here to agree with.
      //
      // RFC 5545: a month that has no such day-of-month (e.g. Feb 31, or Feb 29
      // in a common year) is SKIPPED — it yields no occurrence and does not
      // count toward COUNT. The JS Date constructor instead rolls the date over
      // into the next month (Jan 31 + 1 month -> Mar 3), so detect that by
      // checking whether the day-of-month survived construction.
      const monthIndex = dtstart.getMonth() + i * rule.interval;
      const d = new Date(
        dtstart.getFullYear(),
        monthIndex,
        dtstart.getDate(),
        dtstart.getHours(), dtstart.getMinutes(), dtstart.getSeconds(), dtstart.getMilliseconds(),
      );

      if (d.getDate() !== dtstart.getDate()) {
        // Skipped month. `d` rolled forward, so it is strictly LATER than the
        // (nonexistent) intended date; if even that is past UNTIL, every later
        // month is too and the series is over.
        if (pastUntil(d)) break;
        // Probe the month itself, not the rolled-over date, so a skipped month
        // can never end the loop before a later valid month is reached.
        const monthStart = new Date(dtstart.getFullYear(), monthIndex, 1).getTime();
        if (monthStart >= rangeEnd && rule.count === undefined && !hasUntil) break;
        continue;
      }

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
  // 0 = Monday .. 6 = Sunday (matches the civilWeekdayIndex offset math and the
  // array['MO'..'SU'] ordering in migration 0009).
  return WEEKDAYS.indexOf(w);
}

/**
 * A calendar date with no zone and no time attached — the frame the candidate
 * dates of a series are generated in. Keeping the date arithmetic separate from
 * the wall-clock-to-instant step is what lets one loop serve both the
 * local-time and the zone-anchored modes. `month` is 1-12.
 */
interface Civil {
  year: number;
  month: number;
  day: number;
}

/** Normalise a civil date whose day may be out of range (Jan 32 -> Feb 1). */
function civil(year: number, month: number, day: number): Civil {
  const t = new Date(Date.UTC(year, month - 1, day));
  return { year: t.getUTCFullYear(), month: t.getUTCMonth() + 1, day: t.getUTCDate() };
}

/** Weekday of a civil date, 0 = Monday .. 6 = Sunday. Zone-independent. */
function civilWeekdayIndex(c: Civil): number {
  const jsDay = new Date(Date.UTC(c.year, c.month - 1, c.day)).getUTCDay(); // 0=Sun..6=Sat
  return (jsDay + 6) % 7;
}
