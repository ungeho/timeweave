/**
 * What the mobile calendar decides, as pure functions.
 *
 * The screens themselves cannot be rendered in this project's tests -- vitest
 * runs with `environment: 'node'` and jsdom is deliberately not added -- so
 * every judgement lives here and the components hold markup. The same split
 * `dayAgenda.ts`, `route.ts` and `languageState.ts` already use.
 */

import type { EventOccurrence } from '../../types/event';
import type { ViewMode } from '../../hooks/useCalendarView';
import { buildDayAgenda } from './dayAgenda';

/**
 * The modes a phone offers.
 *
 * Two, not four. A 7-column week or day grid at 360px gives 47px columns --
 * measured in the P8-a audit, where chips collapsed to a single character --
 * so offering them would be offering something unreadable. The desktop keeps
 * all three; this is about what fits.
 */
export const MOBILE_MODES = ['agenda', 'month'] as const;
export type MobileMode = (typeof MOBILE_MODES)[number];

export function isMobileMode(mode: ViewMode): mode is MobileMode {
  return (MOBILE_MODES as readonly string[]).includes(mode);
}

/**
 * The mode to show when a viewport becomes narrow.
 *
 * WHY MAP RATHER THAN RESET. Resizing is not a request to go somewhere else.
 * A reader on the week view who rotates their phone wants the same days, in a
 * form that fits -- so week and day both become the agenda, which shows one of
 * those days in full, and the anchor carries the date across unchanged. Month
 * survives as month because the phone has a month of its own.
 */
export function toMobileMode(mode: ViewMode): MobileMode {
  return mode === 'month' ? 'month' : 'agenda';
}

/**
 * The mode to show when a viewport becomes wide.
 *
 * `agenda` has no desktop equivalent, and `day` is the closest thing: one
 * date, everything on it. Picking `month` instead would throw away the day the
 * reader had selected.
 */
export function toDesktopMode(mode: ViewMode): Exclude<ViewMode, 'agenda'> {
  return mode === 'agenda' ? 'day' : mode;
}

/** How full a day looks at a glance. */
export type DayDensity = 'none' | 'few' | 'many';

/** Above this many events a day reads as busy rather than as having a few. */
export const DENSITY_FEW_MAX = 2;

export function densityFor(count: number): DayDensity {
  if (count <= 0) return 'none';
  return count <= DENSITY_FEW_MAX ? 'few' : 'many';
}

/**
 * How many events each day holds.
 *
 * COUNTED THROUGH `buildDayAgenda`, deliberately, rather than by a second
 * filter written for this purpose. The two selection rules are not obvious --
 * an all-day event belongs to every date it COVERS, a timed one only to the
 * date it STARTS on, both resolved in the owner's zone -- and a day marked
 * busy that opens to an empty list, or the reverse, is exactly the kind of
 * disagreement a reader cannot explain. One rule, one implementation.
 *
 * The cost is one pass per day over the occurrences already in memory: a month
 * grid is 42 days, and the caller memoises on the same inputs the grid does.
 */
export function countsByDay(
  dayKeys: readonly string[],
  occurrences: EventOccurrence[],
  timeZone: string,
): Map<string, number> {
  const out = new Map<string, number>();
  for (const key of dayKeys) {
    const agenda = buildDayAgenda(key, occurrences, timeZone);
    out.set(key, agenda.allDay.length + agenda.timed.length);
  }
  return out;
}

/** The densities for a set of days, ready for the strip or the month grid. */
export function densitiesByDay(
  dayKeys: readonly string[],
  occurrences: EventOccurrence[],
  timeZone: string,
): Map<string, DayDensity> {
  const counts = countsByDay(dayKeys, occurrences, timeZone);
  const out = new Map<string, DayDensity>();
  for (const [key, n] of counts) out.set(key, densityFor(n));
  return out;
}
