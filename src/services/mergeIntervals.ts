/**
 * Pure interval merging for Free/Busy slots. The RPC already merges server-side;
 * this is the canonical reference algorithm (mirrored in SQL) and a defensive
 * re-merge for the public page. Overlapping AND adjacent (touching) intervals
 * merge, so the output leaks only availability, not event count or boundaries.
 *
 * Timed and all-day are NEVER mixed: timed compares by instant, all-day by
 * calendar date (date ordinals are used only for comparison, not stored).
 */

import type { FreeBusySlot } from '../types/share';

export interface TimedInterval {
  start: string;
  end: string;
}
export interface DateRange {
  startDate: string;
  endDate: string;
}

/** Merge timed intervals (UTC ISO) by instant. */
export function mergeTimed(items: TimedInterval[]): TimedInterval[] {
  const sorted = items
    .map((i) => ({ s: Date.parse(i.start), e: Date.parse(i.end), start: i.start, end: i.end }))
    .filter((i) => !Number.isNaN(i.s) && !Number.isNaN(i.e) && i.e > i.s)
    .sort((a, b) => a.s - b.s || a.e - b.e);

  const out: TimedInterval[] = [];
  for (const cur of sorted) {
    const last = out[out.length - 1];
    if (last && cur.s <= Date.parse(last.end)) {
      // Overlap or adjacency: extend the current island if this one reaches further.
      if (cur.e > Date.parse(last.end)) last.end = cur.end;
    } else {
      out.push({ start: cur.start, end: cur.end });
    }
  }
  return out;
}

/** Date ordinal (UTC noon avoids any DST edge) for comparison only. */
const dateOrd = (d: string): number => Date.parse(`${d}T00:00:00Z`);

/** Merge all-day date ranges ("YYYY-MM-DD", end exclusive) by calendar date. */
export function mergeAllDay(items: DateRange[]): DateRange[] {
  const sorted = items
    .map((i) => ({ s: dateOrd(i.startDate), e: dateOrd(i.endDate), startDate: i.startDate, endDate: i.endDate }))
    .filter((i) => !Number.isNaN(i.s) && !Number.isNaN(i.e) && i.e > i.s)
    .sort((a, b) => a.s - b.s || a.e - b.e);

  const out: DateRange[] = [];
  for (const cur of sorted) {
    const last = out[out.length - 1];
    if (last && cur.s <= dateOrd(last.endDate)) {
      if (cur.e > dateOrd(last.endDate)) last.endDate = cur.endDate;
    } else {
      out.push({ startDate: cur.startDate, endDate: cur.endDate });
    }
  }
  return out;
}

/**
 * Re-merge a mixed FreeBusy slot list per type, returning all-day slots first
 * (matching the RPC's fixed type order), then timed. Callers may re-sort for
 * display.
 */
export function mergeFreeBusySlots(slots: FreeBusySlot[]): FreeBusySlot[] {
  const timed: TimedInterval[] = [];
  const allDay: DateRange[] = [];
  for (const s of slots) {
    if (s.allDay) allDay.push({ startDate: s.startDate, endDate: s.endDate });
    else timed.push({ start: s.start, end: s.end });
  }
  return [
    ...mergeAllDay(allDay).map((r): FreeBusySlot => ({ allDay: true, startDate: r.startDate, endDate: r.endDate })),
    ...mergeTimed(timed).map((i): FreeBusySlot => ({ allDay: false, start: i.start, end: i.end })),
  ];
}
