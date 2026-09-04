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
