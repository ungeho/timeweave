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

import { formatInTimeZone, fromZonedTime } from 'date-fns-tz';

/** The user's timezone. The single place that reads the environment. */
export function getUserTimeZone(): string {
  return Intl.DateTimeFormat().resolvedOptions().timeZone || 'UTC';
}

/** Calendar day ("yyyy-MM-dd") that a UTC instant falls on, in the given zone. */
export function zonedDayKey(iso: string, timeZone: string): string {
  return formatInTimeZone(new Date(iso), timeZone, 'yyyy-MM-dd');
}

/**
 * Minutes from the zone's local midnight for a UTC instant, using wall-clock
 * time in the zone (DST-safe for positioning). Range [0, 1440).
 */
export function zonedMinutesOfDay(iso: string, timeZone: string): number {
  const [h, m, s] = formatInTimeZone(new Date(iso), timeZone, 'HH:mm:ss')
    .split(':')
    .map(Number);
  return h! * 60 + m! + s! / 60;
}

/** UTC instant (ISO) of local midnight for a calendar day ("yyyy-MM-dd") in the zone. */
export function dayStartInstantIso(dayKey: string, timeZone: string): string {
  return fromZonedTime(`${dayKey}T00:00:00`, timeZone).toISOString();
}

/**
 * UTC instant (ISO) for a wall-clock minute-of-day on a calendar day in the
 * zone (DST-correct). Used when creating an event from a clicked time slot.
 */
export function instantFromZonedDayMinutes(dayKey: string, minutes: number, timeZone: string): string {
  const h = Math.floor(minutes / 60);
  const m = Math.floor(minutes % 60);
  const hh = String(h).padStart(2, '0');
  const mm = String(m).padStart(2, '0');
  return fromZonedTime(`${dayKey}T${hh}:${mm}:00`, timeZone).toISOString();
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
  const s = formatInTimeZone(new Date(instantMs), timeZone, "yyyy-MM-dd'T'HH:mm:ss");
  const [datePart, timePart] = s.split('T');
  const [y, mo, d] = datePart!.split('-').map(Number);
  const [h, mi, sec] = timePart!.split(':').map(Number);
  // Every zone offset is a whole number of seconds, so the sub-second part of
  // the instant passes through the conversion unchanged.
  return Date.UTC(y!, mo! - 1, d!, h!, mi!, sec!, ((instantMs % 1000) + 1000) % 1000);
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
