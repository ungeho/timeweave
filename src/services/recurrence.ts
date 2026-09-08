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

  /**
   * The calendar date an instant falls on, in the SAME frame `instantOn` builds
   * from. Used to turn the requested window into candidate indices; the inverse
   * direction of `instantOn`.
   */
  const civilOf = (instantMs: number): Civil => {
    if (timeZone === null) {
      const d = new Date(instantMs);
      return { year: d.getFullYear(), month: d.getMonth() + 1, day: d.getDate() };
    }
    const w = zonedWallClockOf(instantMs, timeZone);
    return { year: w.year, month: w.month, day: w.day };
  };

  const results: string[] = [];

  const pastUntil = (d: Date): boolean => {
    if (untilInstant !== undefined) return d.getTime() > untilInstant;
    if (untilDate !== undefined) return localDateStr(d) > untilDate;
    return false;
  };

  // BYDAY defaults to DTSTART's own weekday, read in the SAME zone the wall
  // clock above came from -- browser-local for M0, the master's zone for M1. A
  // hybrid (zone wall clock, browser weekday) would put occurrences on the
  // wrong day whenever the two zones disagree about DTSTART's date.
  const dtWeekdayIndex = civilWeekdayIndex(dtCivil);

  // ==========================================================================
  // DAILY and WEEKLY -- Phase 5b-5A.
  //
  // Candidates are indexed from DTSTART, but the index RANGE is derived from
  // the requested window, exactly as migrations 0007/0009 derive theirs. The
  // loop therefore costs O(window), never O(distance from DTSTART), and the
  // series being infinite is no longer a reason to iterate at all. That is why
  // this branch does NOT consult MAX_ITERATIONS: with a window-derived range
  // there is no unbounded loop left for it to guard. (The constant stays for
  // MONTHLY below, whose candidates are still walked from DTSTART.)
  //
  // BEFORE 5b-5A this branch walked from index 0 and stopped at
  // MAX_ITERATIONS = 3660, so a FREQ=DAILY series silently vanished from any
  // window more than ~10 years after DTSTART -- with or without COUNT.
  //
  // COUNT is an ORDINAL BOUND, not a running tally. The ordinal of a candidate
  // is closed-form for both frequencies, so "is this the N-th occurrence of the
  // series" is answered without generating the ones before it. The previous
  // implementation counted by walking, which is what made COUNT > 3660 lossy.
  //
  // The index range is deliberately WIDER than needed (a day of margin at each
  // end absorbs any zone offset); exactness comes from the per-candidate filter
  // in `emit`, which is the same arrangement the SQL side uses.
  // ==========================================================================
  if (rule.freq === 'DAILY' || rule.freq === 'WEEKLY') {
    const emit = (d: Date, ordinal: number): void => {
      if (d.getTime() < dtstartMs) return; // nothing before DTSTART
      if (pastUntil(d)) return;
      // A negative ordinal means "week 0, before DTSTART's weekday", which the
      // DTSTART test above has already rejected. Checked anyway so the two
      // guards stay independent.
      if (rule.count !== undefined && (ordinal < 0 || ordinal >= rule.count)) return;
      const t = d.getTime();
      if (t >= rangeStart && t < rangeEnd) results.push(d.toISOString());
    };

    const d0Day = civilDayNumber(dtCivil);
    const fromDay = civilDayNumber(civilOf(rangeStart)) - 1;
    const toDay = civilDayNumber(civilOf(rangeEnd)) + 1;

    if (rule.freq === 'DAILY') {
      // Candidate i is DTSTART + i * INTERVAL days, and its ordinal IS i.
      const lo = Math.max(0, Math.floor((fromDay - d0Day) / rule.interval));
      let hi = Math.floor((toDay - d0Day) / rule.interval);
      if (rule.count !== undefined) hi = Math.min(hi, rule.count - 1);

      for (let i = lo; i <= hi; i++) {
        emit(instantOn(civil(dtCivil.year, dtCivil.month, dtCivil.day + i * rule.interval)), i);
      }
    } else {
      // WEEKLY. Offsets are NORMALISED TO WEEKDAY ORDER (0 = Monday .. 6 =
      // Sunday) before anything else: the SQL side sorts them
      // (`array_agg(o.idx order by o.idx)`), and with COUNT the order decides
      // WHICH occurrences exist, not merely the order they are reported in. An
      // unsorted BYDAY would otherwise make the two implementations disagree on
      // the occurrence SET.
      const offsets = [...(rule.byDay ?? [WEEKDAYS[dtWeekdayIndex]!])]
        .map(weekdayIndex)
        .sort((a, b) => a - b);
      const k = offsets.length;
      // Week 0 is PARTIAL: only offsets at or after DTSTART's own weekday
      // survive. Because `offsets` is sorted, the ones before it are exactly
      // the first (k - weekZeroCount) entries, so the rank of entry j within
      // week 0 is j - (k - weekZeroCount).
      const weekZeroCount = offsets.filter((o) => o >= dtWeekdayIndex).length;

      const w0Day = d0Day - dtWeekdayIndex; // Monday of DTSTART's week
      const step = 7 * rule.interval;
      const lo = Math.max(0, Math.floor((fromDay - 7 - w0Day) / step));
      let hi = Math.floor((toDay - w0Day) / step) + 1;
      if (rule.count !== undefined) {
        hi = Math.min(
          hi,
          rule.count <= weekZeroCount
            ? 0
            : 1 + Math.floor((rule.count - 1 - weekZeroCount) / k),
        );
      }

      const weekStart = civil(dtCivil.year, dtCivil.month, dtCivil.day - dtWeekdayIndex);
      for (let i = lo; i <= hi; i++) {
        for (let j = 0; j < k; j++) {
          const ordinal =
            i === 0 ? j - (k - weekZeroCount) : weekZeroCount + (i - 1) * k + j;
          emit(
            instantOn(
              civil(weekStart.year, weekStart.month, weekStart.day + i * step + offsets[j]!),
            ),
            ordinal,
          );
        }
      }
    }

    return results;
  }

  // ==========================================================================
  // MONTHLY -- unchanged by 5b-5A, deliberately.
  //
  // Its candidates are still walked from DTSTART because a skipped month breaks
  // the arithmetic progression, so there is no closed-form ordinal to use. That
  // walk is what MAX_ITERATIONS still guards; at one iteration per month it
  // spans ~305 years, so it does not clip any realistic series.
  // ==========================================================================
  let emitted = 0;

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

  for (let i = 0; i < MAX_ITERATIONS; i++) {
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
    if (!push(d)) break;
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

/**
 * A civil date as a whole number of days, so candidate indices can be derived
 * from the window by plain arithmetic. Only DIFFERENCES of these numbers are
 * ever used, so the epoch they are counted from does not matter.
 */
function civilDayNumber(c: Civil): number {
  return Date.UTC(c.year, c.month - 1, c.day) / 86_400_000;
}
