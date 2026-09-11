/**
 * Pure helpers for laying out Free/Busy slots onto calendar days. Kept UI-free
 * so the day-intersection logic is unit-testable.
 *
 * Timed slots are clipped to each day's [start, end) instants (in the viewer's
 * zone); all-day slots are matched by calendar date ("YYYY-MM-DD"), never via a
 * timezone conversion.
 */

import type { FreeBusySlot } from '../../types/share';
import { addDaysToDateString } from '../../utils/datetime';
import { dayStartInstantIso } from '../../utils/timezone';

export interface DayBusy {
  /** Timed busy blocks clipped to this day, ascending. */
  timed: { start: string; end: string }[];
  /** How many all-day busy blocks cover this day. */
  allDayCount: number;
}

/** Busy blocks intersecting one calendar day (`dayKey`, "YYYY-MM-DD"). */
export function busyForDay(dayKey: string, timeZone: string, slots: FreeBusySlot[]): DayBusy {
  const dayStart = Date.parse(dayStartInstantIso(dayKey, timeZone));
  const dayEnd = Date.parse(dayStartInstantIso(addDaysToDateString(dayKey, 1), timeZone));

  const timed: { start: string; end: string }[] = [];
  let allDayCount = 0;

  for (const s of slots) {
    if (s.allDay) {
      // Half-open [startDate, endDate); lexicographic compare is valid for ISO dates.
      if (dayKey >= s.startDate && dayKey < s.endDate) allDayCount += 1;
    } else {
      const st = Date.parse(s.start);
      const en = Date.parse(s.end);
      if (en > dayStart && st < dayEnd) {
        timed.push({
          start: new Date(Math.max(st, dayStart)).toISOString(),
          end: new Date(Math.min(en, dayEnd)).toISOString(),
        });
      }
    }
  }

  timed.sort((a, b) => Date.parse(a.start) - Date.parse(b.start));
  return { timed, allDayCount };
}

/**
 * True when the RPC gave a COMPLETE answer that discloses no busy at all.
 *
 * This is deliberately NOT "the token is invalid". `get_free_busy` answers
 * `{ complete: true, slots: [] }` for a revoked, expired or unknown token AND
 * for a valid token whose owner is simply free — the same bytes, on purpose, so
 * that no caller can use the RPC as an existence oracle (migration 0009, step 2).
 *
 * The view therefore cannot say "this link is dead", only "nothing is shown
 * here", which is why the note this drives has to cover both readings. What it
 * must never do is let an empty grid stand as a positive claim of availability.
 */
export function hasNoDisclosedBusy(result: { complete: boolean; slots: FreeBusySlot[] }): boolean {
  return result.complete && result.slots.length === 0;
}
