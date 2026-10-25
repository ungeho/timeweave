/**
 * Timezone-aware primitives, isolated so calendar layout logic never depends
 * implicitly on the JavaScript runtime's local timezone.
 *
 * The app operates in a single "user timezone" (an IANA zone name). Pure
 * functions take the zone explicitly; only `getUserTimeZone()` reads the
 * environment. Timed instants are UTC ISO strings; positions are derived from
 * the wall-clock time IN THE ZONE (so a 09:00 event sits at 09:00 regardless of
 * DST). All-day values remain calendar dates and never go through these.
 */

import { fromZonedTime } from 'date-fns-tz';

/** The user's timezone. The single place that reads the environment. */
export function getUserTimeZone(): string {
  return Intl.DateTimeFormat().resolvedOptions().timeZone || 'UTC';
}

/*
  READING A WALL CLOCK (P8-c1). Straight from Intl, one cached formatter per
  zone. This replaced date-fns-tz formatInTimeZone, which builds a LOCAL Date
  whose fields are the zone's wall clock and formats that: when the wall clock
  does not exist in the OS zone, the local Date silently moves it. MEASURED
  with the OS on America/New_York: the instant that is 2026-03-08 02:30 in
  Tokyo came back as 03:30, because 02:30 does not exist in New York that day.
  Every helper below reads the wall clock through here, so none of them
  depends on the computer's own zone any more.
*/
const WALL_FORMATS = new Map<string, Intl.DateTimeFormat>();

interface WallFields {
  year: number;
  month: number;
  day: number;
  hour: number;
  minute: number;
  second: number;
}

function zonedWallFields(instantMs: number, timeZone: string): WallFields {
  let fmt = WALL_FORMATS.get(timeZone);
  if (!fmt) {
    fmt = new Intl.DateTimeFormat('en-US', {
      timeZone,
      hourCycle: 'h23',
      year: 'numeric',
      month: '2-digit',
      day: '2-digit',
      hour: '2-digit',
      minute: '2-digit',
      second: '2-digit',
    });
    WALL_FORMATS.set(timeZone, fmt);
  }
  const p: Record<string, string> = {};
  for (const part of fmt.formatToParts(new Date(instantMs))) p[part.type] = part.value;
  return {
    year: Number(p.year),
    month: Number(p.month),
    day: Number(p.day),
    // h23 never says 24, but an engine that ignores hourCycle may; 24 is 0.
    hour: Number(p.hour) % 24,
    minute: Number(p.minute),
    second: Number(p.second),
  };
}

const pad2 = (n: number) => String(n).padStart(2, '0');

/** Calendar day ("yyyy-MM-dd") that a UTC instant falls on, in the given zone. */
export function zonedDayKey(iso: string, timeZone: string): string {
  const w = zonedWallFields(new Date(iso).getTime(), timeZone);
  return `${String(w.year).padStart(4, '0')}-${pad2(w.month)}-${pad2(w.day)}`;
}

/**
 * Minutes from the zone's local midnight for a UTC instant, using wall-clock
 * time in the zone (DST-safe for positioning). Range [0, 1440).
 */
export function zonedMinutesOfDay(iso: string, timeZone: string): number {
  const w = zonedWallFields(new Date(iso).getTime(), timeZone);
  return w.hour * 60 + w.minute + w.second / 60;
}

/**
 * UTC instant (ISO) at which a calendar day ("yyyy-MM-dd") STARTS in the zone:
 * the earliest instant whose wall-clock date there is that day or later. A day
 * is the half-open range [start of day, start of next day).
 *
 * R1 (P8-c1, docs/p8-datetime-contract.md §9). This used to be
 * fromZonedTime(day + 'T00:00:00'), which is right for an ordinary midnight
 * and wrong exactly where a day boundary matters most. MEASURED on the
 * runtime's tzdata:
 *   - a midnight that never happens (America/Havana 2026-03-08, Santiago,
 *     Cairo: 23:59:59 is followed by 01:00) came out as 23:00 the evening
 *     BEFORE, so the previous day lost its last hour to this one;
 *   - a midnight that happens twice (Havana 2026-11-01) came out as the first
 *     or the SECOND one depending on the OS zone;
 *   - a day that never happens (Pacific/Apia 2011-12-30) came out as the
 *     previous midnight, swallowing the whole of 29 December.
 * Now: an ordinary midnight is that instant (unchanged); a missing midnight is
 * the instant the clocks jump; a doubled midnight is the first of the two; a
 * missing day starts and ends where the next day starts, i.e. it is empty.
 * This is also what a JavaScript Date makes of a local midnight, so the month
 * view (local Date midnights, monthGrid.ts) and this function now agree.
 *
 * Built on classifyZonedWallClock below, so the gap/fold detection is the one
 * the event form already uses; the OS zone plays no part.
 */
export function dayStartInstantIso(dayKey: string, timeZone: string): string {
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(dayKey);
  if (!m) return fromZonedTime(`${dayKey}T00:00:00`, timeZone).toISOString(); // unchanged failure mode
  const c = classifyZonedWallClock(
    { year: Number(m[1]), month: Number(m[2]), day: Number(m[3]), hour: 0, minute: 0, second: 0, ms: 0 },
    timeZone,
  );
  const ms = c.kind === 'normal' ? c.instantMs : c.kind === 'fold' ? c.earlierMs : c.firstAfterMs;
  return new Date(ms).toISOString();
}

/** Weekday of a calendar date, 0 = Monday .. 6 = Sunday (zone-independent). */
export function weekdayOfDayKey(dayKey: string): number {
  const jsDay = new Date(`${dayKey}T00:00:00Z`).getUTCDay(); // 0=Sun..6=Sat
  return (jsDay + 6) % 7;
}

// ---------------------------------------------------------------------------
// Persistence-side timezone handling (Phase 5b-2).
//
// getUserTimeZone() above falls back to 'UTC' because a layout that cannot
// determine the zone still has to draw something. Persistence is the opposite
// case: storing a guessed zone silently decides what a recurring series MEANS,
// so the functions below never fall back. They return null instead, and the
// caller refuses to save.
// ---------------------------------------------------------------------------

/** Names refused outright, matching migration 0008's timezone_is_supported(). */
const FORBIDDEN_EXACT = new Set(['localtime']);
const FORBIDDEN_PREFIXES = ['posix/', 'right/'];

/** One to three path segments: UTC, Asia/Tokyo, America/Argentina/Buenos_Aires. */
const ZONE_NAME_RE = /^[A-Za-z][A-Za-z0-9_+-]*(\/[A-Za-z0-9_+-]+){0,2}$/;

/**
 * Best-effort mirror of the DB's `timezone_is_supported()` (migration 0008).
 *
 * Replicated exactly: the 1..64 length cap, the lexical shape, and the refusal
 * of `localtime` (server-configuration dependent) and the `posix/` / `right/`
 * prefixes (duplicate spelling / leap-second counting).
 *
 * Approximated: existence. The DB requires an exact row in pg_timezone_names;
 * here we ask Intl, which uses the browser's own tzdata. Two consequences,
 * both deliberate:
 *   - Aliases pass. `Asia/Calcutta` is a tzdata link and resolves to the same
 *     rules as its primary name, and neither side canonicalises.
 *   - Case is NOT checked. The DB compares case sensitively, so 'asia/tokyo'
 *     is rejected there but accepted here. That is the safe direction: this
 *     function exists to fail EARLY, never to decide. The DB stays
 *     authoritative and reports TIMEWEAVE_TZ_INVALID for anything it refuses.
 */
export function isStorableTimeZone(tz: string): boolean {
  if (tz.length < 1 || tz.length > 64) return false;
  if (!ZONE_NAME_RE.test(tz)) return false;
  if (FORBIDDEN_EXACT.has(tz)) return false;
  if (FORBIDDEN_PREFIXES.some((p) => tz.startsWith(p))) return false;
  try {
    new Intl.DateTimeFormat('en-US', { timeZone: tz });
    return true;
  } catch {
    return false; // RangeError: the runtime does not know this zone
  }
}

/**
 * The zone to PERSIST with a timed recurrence, or null when it cannot be
 * established.
 *
 * Unlike getUserTimeZone() this NEVER falls back to 'UTC'. A timed recurrence
 * repeats at a wall-clock time, so its zone is part of the rule; inventing one
 * would quietly change which instants the series occupies. Returning null is
 * the signal that a timed recurrence must not be saved at all.
 *
 * The returned string is stored verbatim -- no canonicalisation, matching the
 * database, which accepts aliases and does not normalise them either.
 */
export function resolveStorableTimeZone(): string | null {
  let resolved: string | undefined;
  try {
    resolved = Intl.DateTimeFormat().resolvedOptions().timeZone;
  } catch {
    return null;
  }
  if (!resolved) return null;
  return isStorableTimeZone(resolved) ? resolved : null;
}

// ---------------------------------------------------------------------------
// PostgreSQL-compatible wall-clock resolution (Phase 5b-4).
//
// A timed recurrence repeats at a WALL CLOCK time in its master's zone, so
// expanding one means turning a wall clock into an instant. Two wall clocks per
// year have no single answer:
//
//   gap  -- a local time that does not exist (clocks jumped forward)
//   fold -- a local time that happens twice   (clocks jumped back)
//
// Migration 0009 delegates this to `AT TIME ZONE`, so the SQL and TypeScript
// expanders agree only if this function reproduces what PostgreSQL does. The
// rule was MEASURED, not assumed:
//
//   America/New_York  gap  2026-03-08 02:30 -> 2026-03-08T07:30:00Z
//                     fold 2026-11-01 01:30 -> 2026-11-01T06:30:00Z
//     (supabase/tests/0009_timed_recurrence_freebusy_preflight.sql, section B)
//   Europe/Dublin     gap  2026-03-29 01:30 -> 2026-03-29T01:30:00Z
//                     fold 2026-10-25 01:30 -> 2026-10-25T01:30:00Z
//     (Phase 5b-4 probe, hand-run against the same server)
//
// ALL FOUR ARE "THE LATER OF THE TWO CANDIDATE INSTANTS", and that is the whole
// rule. It is deliberately NOT phrased as "use the standard-time offset": those
// two descriptions agree in every zone with POSITIVE DST, which is why
// New_York alone could not tell them apart. Europe/Dublin is modelled by tzdata
// with NEGATIVE DST, so there the standard offset (IST, UTC+1) would give the
// EARLIER instant -- and the measurement says PostgreSQL returns the LATER one.
// Dublin's role here is exactly that: the case where LATER and "standard"
// disagree, and LATER is what happens.
//
// Unambiguous wall clocks have one valid candidate and are unaffected.
//
// WHY 26 HOURS. The probe points must straddle the transition. The true instant
// is `wall - offset`, so a window w works whenever w > max|offset|; anything
// smaller can sample the same side twice. Measured over every zone this runtime
// knows (418 zones, 5286 transitions, 2020-2040):
//   largest |UTC offset|            14.00 h  (Pacific/Apia, Pacific/Chatham)
//   largest single transition        3.00 h
//   closest two transitions in one zone   672 h  (28 days)
// so 26 h clears the 14 h floor with 12 h to spare, and the 52 h span is 12x
// smaller than the closest transition pair (no third offset can intrude).
// Differentially tested against a ground-truth resolver built from each
// transition's own two offsets: 153,434 wall clocks, ZERO disagreements.
// +/-13h was measured to FAIL (Pacific/Apia, Pacific/Chatham); +/-15h and above
// all pass. A window-free two-step refinement was also tried and rejected: it
// reports the New_York fold as unambiguous and returns the EARLIER instant.
//
// Scope: this is engineered for the modern dates TimeWeave stores, not for
// arbitrary historical tzdata. Pre-1900 LMT offsets exceeded 15 hours in a few
// zones; such an input still returns an answer rather than throwing, but it is
// outside what the numbers above certify.
// ---------------------------------------------------------------------------

/** A wall-clock reading in some zone. `month` is 1-12, as in LocalDateTimeParts. */
export interface ZonedWallClock {
  year: number;
  month: number;
  day: number;
  hour: number;
  minute: number;
  second: number;
  ms: number;
}

/** Half-width of the offset-probe window. See the note above for the derivation. */
const OFFSET_PROBE_MS = 26 * 60 * 60 * 1000;

/**
 * The wall clock in `timeZone` at `instantMs`, expressed as a UTC-NUMBERED
 * millisecond value (i.e. `Date.UTC` of the zone's calendar/clock fields). That
 * representation makes wall clocks directly comparable and subtractable.
 */
function zonedWallMsAt(instantMs: number, timeZone: string): number {
  const w = zonedWallFields(instantMs, timeZone);
  // Every zone offset is a whole number of seconds, so the sub-second part of
  // the instant passes through the conversion unchanged. setUTCFullYear keeps
  // years 0-99 literal, which Date.UTC would read as 1900-1999.
  const d = new Date(0);
  d.setUTCFullYear(w.year, w.month - 1, w.day);
  d.setUTCHours(w.hour, w.minute, w.second, ((instantMs % 1000) + 1000) % 1000);
  return d.getTime();
}

/** The zone's UTC offset, in ms, in effect at `instantMs`. */
function zoneOffsetMsAt(instantMs: number, timeZone: string): number {
  return zonedWallMsAt(instantMs, timeZone) - instantMs;
}

/** The wall clock `timeZone` shows at `instantMs`. */
export function zonedWallClockOf(instantMs: number, timeZone: string): ZonedWallClock {
  const w = new Date(zonedWallMsAt(instantMs, timeZone));
  return {
    year: w.getUTCFullYear(),
    month: w.getUTCMonth() + 1,
    day: w.getUTCDate(),
    hour: w.getUTCHours(),
    minute: w.getUTCMinutes(),
    second: w.getUTCSeconds(),
    ms: w.getUTCMilliseconds(),
  };
}

/**
 * The instant (ms) a wall clock names in `timeZone`, resolved the way
 * PostgreSQL's `AT TIME ZONE` resolves it: when the wall clock is ambiguous or
 * nonexistent, the LATER of the two candidate instants wins.
 */
export function resolveZonedWallClock(wall: ZonedWallClock, timeZone: string): number {
  const wallMs = Date.UTC(
    wall.year, wall.month - 1, wall.day,
    wall.hour, wall.minute, wall.second, wall.ms,
  );
  const offBefore = zoneOffsetMsAt(wallMs - OFFSET_PROBE_MS, timeZone);
  const offAfter = zoneOffsetMsAt(wallMs + OFFSET_PROBE_MS, timeZone);

  const candidates =
    offBefore === offAfter ? [wallMs - offBefore] : [wallMs - offBefore, wallMs - offAfter];
  // A candidate is VALID when rendering it back in the zone reproduces the wall
  // clock we started from. Normal times have exactly one; a fold has two; a gap
  // has none. In the last two cases the LATER candidate is the answer.
  const valid = candidates.filter((c) => zonedWallMsAt(c, timeZone) === wallMs);
  return Math.max(...(valid.length > 0 ? valid : candidates));
}

// ---------------------------------------------------------------------------
// Classifying a wall clock (P8-b5.6b-2).
//
// resolveZonedWallClock above ANSWERS a gap or a fold (the later instant, as
// PostgreSQL does) because an expander has to produce something. The event
// form must not answer on the owner's behalf: a time that does not exist is
// refused, and a time that happens twice is put back to the owner as two
// choices. This function only COUNTS -- it never picks -- and resolves nothing
// on its own. Same probe window, same validity test, so the two cannot
// disagree about which wall clocks are awkward.
// ---------------------------------------------------------------------------

export type WallClockClass =
  | { kind: 'normal'; instantMs: number }
  /** Clocks jumped forward over it. `lastBeforeMs`/`firstAfterMs` bracket the jump. */
  | { kind: 'gap'; lastBeforeMs: number; firstAfterMs: number; gapMinutes: number }
  /** Clocks went back over it. `earlierMs` is the 1st occurrence, `laterMs` the 2nd. */
  | { kind: 'fold'; earlierMs: number; laterMs: number };

export function classifyZonedWallClock(wall: ZonedWallClock, timeZone: string): WallClockClass {
  const wallMs = Date.UTC(
    wall.year, wall.month - 1, wall.day,
    wall.hour, wall.minute, wall.second, wall.ms,
  );
  const offBefore = zoneOffsetMsAt(wallMs - OFFSET_PROBE_MS, timeZone);
  const offAfter = zoneOffsetMsAt(wallMs + OFFSET_PROBE_MS, timeZone);
  const candidates =
    offBefore === offAfter ? [wallMs - offBefore] : [wallMs - offBefore, wallMs - offAfter];
  const valid = candidates
    .filter((c) => zonedWallMsAt(c, timeZone) === wallMs)
    .sort((a, b) => a - b);

  if (valid.length === 2) return { kind: 'fold', earlierMs: valid[0]!, laterMs: valid[1]! };
  if (valid.length === 1) return { kind: 'normal', instantMs: valid[0]! };

  // A gap: reading the wall with the NEW offset lands before the switch and
  // with the OLD offset after it. Find the switch to the minute by asking the
  // zone, never by assuming the jump is an hour (Lord Howe moves 30 minutes).
  let lo = Math.min(wallMs - offBefore, wallMs - offAfter);
  let hi = Math.max(wallMs - offBefore, wallMs - offAfter);
  while (hi - lo > 60_000) {
    const mid = lo + Math.floor((hi - lo) / 120_000) * 60_000;
    if (zoneOffsetMsAt(mid, timeZone) === offAfter) hi = mid;
    else lo = mid;
  }
  return {
    kind: 'gap',
    lastBeforeMs: hi - 60_000,
    firstAfterMs: hi,
    gapMinutes: Math.round((offAfter - offBefore) / 60_000),
  };
}

/** The zone's UTC offset at an instant, in whole minutes (e.g. -240). */
export function zoneOffsetMinutesAt(instantMs: number, timeZone: string): number {
  return Math.round(zoneOffsetMsAt(instantMs, timeZone) / 60_000);
}

/**
 * The zone's short name at an instant ("EDT", "EST", "BST"), or '' when the
 * runtime only has a numeric one ("GMT+9") -- the caller shows the UTC offset
 * anyway, so a numeric name would only repeat it. Always the en-US spelling:
 * these abbreviations are not translated, and Intl's ja short names are the
 * numeric form.
 */
export function zoneAbbreviation(instantMs: number, timeZone: string): string {
  try {
    const name = new Intl.DateTimeFormat('en-US', { timeZone, timeZoneName: 'short' })
      .formatToParts(new Date(instantMs))
      .find((p) => p.type === 'timeZoneName')?.value ?? '';
    return /^(GMT|UTC)/.test(name) ? '' : name;
  } catch {
    return '';
  }
}
