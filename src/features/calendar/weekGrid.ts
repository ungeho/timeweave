/**
 * Week/day date-grid helpers. Pure and timezone-explicit: the visible days and
 * the UTC ranges to fetch/expand are derived from calendar dates in the user's
 * zone, never from the runtime's local timezone. Week starts on Monday.
 */

import { addDaysToDateString } from '../../utils/datetime';
import {
  dayStartInstantIso,
  weekdayOfDayKey,
  zonedDayKey,
} from '../../utils/timezone';

export interface DayCell {
  /** "yyyy-MM-dd" in the user's zone. */
  dayKey: string;
  /** 0 = Monday .. 6 = Sunday. */
  weekdayIndex: number;
  /** Day-of-month number for display. */
  dayOfMonth: number;
  isToday: boolean;
}

/** Monday (as a day key) of the week containing `anchor`, in the zone. */
export function weekStartDayKey(anchor: Date, timeZone: string): string {
  const anchorKey = zonedDayKey(anchor.toISOString(), timeZone);
  return addDaysToDateString(anchorKey, -weekdayOfDayKey(anchorKey));
}

function toCell(dayKey: string, todayKey: string): DayCell {
  return {
    dayKey,
    weekdayIndex: weekdayOfDayKey(dayKey),
    dayOfMonth: Number(dayKey.slice(8, 10)),
    isToday: dayKey === todayKey,
  };
}

/** The 7 days (Mon..Sun) of the week containing `anchor`. */
export function buildWeekDays(anchor: Date, timeZone: string, now: Date = new Date()): DayCell[] {
  const monday = weekStartDayKey(anchor, timeZone);
  const todayKey = zonedDayKey(now.toISOString(), timeZone);
  return Array.from({ length: 7 }, (_, i) => toCell(addDaysToDateString(monday, i), todayKey));
}

/** The single day containing `anchor`. */
export function buildDayCell(anchor: Date, timeZone: string, now: Date = new Date()): DayCell {
  const dayKey = zonedDayKey(anchor.toISOString(), timeZone);
  return toCell(dayKey, zonedDayKey(now.toISOString(), timeZone));
}

/** Half-open UTC range [start, end) covering the whole week. */
export function weekRange(anchor: Date, timeZone: string): { startIso: string; endIso: string } {
  const monday = weekStartDayKey(anchor, timeZone);
  return {
    startIso: dayStartInstantIso(monday, timeZone),
    endIso: dayStartInstantIso(addDaysToDateString(monday, 7), timeZone),
  };
}

/** Half-open UTC range [start, end) covering the single day. */
export function dayRange(anchor: Date, timeZone: string): { startIso: string; endIso: string } {
  const dayKey = zonedDayKey(anchor.toISOString(), timeZone);
  return {
    startIso: dayStartInstantIso(dayKey, timeZone),
    endIso: dayStartInstantIso(addDaysToDateString(dayKey, 1), timeZone),
  };
}

/** A day key ("yyyy-MM-dd") formatted for display, e.g. "8月24日(月)". */
function formatDayKey(dayKey: string, opts: Intl.DateTimeFormatOptions, locale?: string): string {
  // Use UTC noon so the calendar date is unaffected by any zone conversion.
  return new Intl.DateTimeFormat(locale, { ...opts, timeZone: 'UTC' }).format(
    new Date(`${dayKey}T12:00:00Z`),
  );
}

/** Title for the week view, e.g. "8/24 – 8/30". */
export function weekTitle(anchor: Date, timeZone: string, locale?: string): string {
  const monday = weekStartDayKey(anchor, timeZone);
  const sunday = addDaysToDateString(monday, 6);
  const fmt: Intl.DateTimeFormatOptions = { month: 'numeric', day: 'numeric' };
  return `${formatDayKey(monday, fmt, locale)} – ${formatDayKey(sunday, fmt, locale)}`;
}

/** The option set shared by the day-view title and the day-agenda heading. */
const FULL_DAY: Intl.DateTimeFormatOptions = {
  year: 'numeric',
  month: 'long',
  day: 'numeric',
  weekday: 'short',
};

/** Title for the day view, e.g. "2026年8月29日(土)". */
export function dayTitle(anchor: Date, timeZone: string, locale?: string): string {
  return formatDayKey(zonedDayKey(anchor.toISOString(), timeZone), FULL_DAY, locale);
}

/**
 * A calendar DATE formatted with its weekday, e.g. "2026年8月29日(土)".
 *
 * The same words `dayTitle` produces, but taken from a day key rather than an
 * instant plus a zone -- which is what the day-agenda dialog holds. It used to
 * build this inline with `toLocaleDateString(undefined, ...)`: the same option
 * set written a second time, and the only place left in the app that reached
 * for the browser's locale instead of the resolved language.
 *
 * Going through `formatDayKey` also drops a fragility. The dialog converted
 * the day key to LOCAL midnight and formatted in the runtime's zone; correct,
 * but one zone argument away from showing the previous day. `formatDayKey`
 * uses UTC noon with `timeZone: 'UTC'`, so no conversion can move the date.
 * The rendered string is identical either way, which dateLocale.test.ts pins.
 */
export function dayKeyTitle(dayKey: string, locale?: string): string {
  return formatDayKey(dayKey, FULL_DAY, locale);
}

/**
 * Just the weekday from a day key, e.g. "月" or "Mon".
 *
 * For the mobile date strip and the compact month, whose cells are too narrow
 * for a full date. It goes through `formatDayKey` for the reason the comment
 * above gives: UTC noon formatted in UTC, so no zone conversion can move the
 * date and hand back the wrong weekday.
 */
export function dayKeyWeekday(
  dayKey: string,
  locale?: string,
  width: "short" | "narrow" = "short",
): string {
  return formatDayKey(dayKey, { weekday: width }, locale);
}
