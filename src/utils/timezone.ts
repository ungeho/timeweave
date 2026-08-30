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
