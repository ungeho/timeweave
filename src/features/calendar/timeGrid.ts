/**
 * Time-grid layout for week/day views. Pure and timezone-explicit.
 *
 * A timed occurrence is placed by its WALL-CLOCK time in the user's zone, so a
 * 09:00 event sits at 09:00 regardless of DST. Events crossing midnight are
 * clipped to each day's [00:00, 24:00). Overlap columns are computed per
 * COLLISION GROUP (a maximal run of mutually-overlapping events), so isolated
 * events stay full-width. Half-open intervals: touching edges do not overlap.
 */

import type { EventOccurrence } from '../../types/event';
import { zonedDayKey, zonedMinutesOfDay } from '../../utils/timezone';

export const MINUTES_PER_DAY = 1440;
/** Default initial scroll target (08:00) for week/day views. */
export const DEFAULT_SCROLL_MINUTES = 480;

export interface PositionedOccurrence {
  occurrence: EventOccurrence;
  /** Top position as a fraction of the day [0, 1). */
  topFraction: number;
  /** Height as a fraction of the day (0, 1]. */
  heightFraction: number;
  /** Column index within its collision group. */
  colIndex: number;
  /** Number of columns in its collision group. */
  colCount: number;
}

interface Segment {
  occurrence: EventOccurrence;
  startMin: number;
  endMin: number;
}

/** Clip an occurrence to `dayKey`'s [00:00, 24:00) in the zone; null if absent. */
function segmentForDay(
  occ: EventOccurrence,
  dayKey: string,
  timeZone: string,
): Segment | null {
  const startKey = zonedDayKey(occ.start, timeZone);
  const endKey = zonedDayKey(occ.end, timeZone);

  // Exclude occurrences that don't intersect this day: those that start after it
  // or ended before it. Without this, the min/max math below would place a
  // later-day event onto every earlier day of the view.
  if (startKey > dayKey || endKey < dayKey) return null;

  const startMin = startKey < dayKey ? 0 : zonedMinutesOfDay(occ.start, timeZone);
  const endMin = endKey > dayKey ? MINUTES_PER_DAY : zonedMinutesOfDay(occ.end, timeZone);

  // Half-open: an occurrence ending exactly at this day's 00:00 (endKey === dayKey
  // with endMin === 0) collapses to endMin <= startMin and is excluded here.
  if (endMin <= startMin) return null;
  return { occurrence: occ, startMin, endMin };
}

/**
 * Position timed occurrences within a single day column.
 * @param occurrences occurrences overlapping the day (all-day ones are ignored)
 * @param dayKey "yyyy-MM-dd" in the zone
 */
export function layoutDayColumn(
  occurrences: EventOccurrence[],
  dayKey: string,
  timeZone: string,
): PositionedOccurrence[] {
  const segments: Segment[] = [];
  for (const occ of occurrences) {
    if (occ.allDay) continue;
    const seg = segmentForDay(occ, dayKey, timeZone);
    if (seg) segments.push(seg);
  }
  segments.sort((a, b) => a.startMin - b.startMin || a.endMin - b.endMin);

  const positioned: PositionedOccurrence[] = [];

  // Walk collision groups: a maximal run where each event overlaps the group.
  let group: Segment[] = [];
  let groupMaxEnd = -Infinity;

  const flush = () => {
    if (group.length === 0) return;
    // Greedy column assignment within the group.
    const columnEnds: number[] = []; // last endMin per column
    const colOf = new Map<Segment, number>();
    for (const seg of group) {
      let col = columnEnds.findIndex((end) => end <= seg.startMin);
      if (col === -1) {
        col = columnEnds.length;
        columnEnds.push(seg.endMin);
      } else {
        columnEnds[col] = seg.endMin;
      }
      colOf.set(seg, col);
    }
    const colCount = columnEnds.length;
    for (const seg of group) {
      positioned.push({
        occurrence: seg.occurrence,
        topFraction: seg.startMin / MINUTES_PER_DAY,
        heightFraction: (seg.endMin - seg.startMin) / MINUTES_PER_DAY,
        colIndex: colOf.get(seg)!,
        colCount,
      });
    }
    group = [];
    groupMaxEnd = -Infinity;
  };

  for (const seg of segments) {
    if (group.length > 0 && seg.startMin >= groupMaxEnd) flush();
    group.push(seg);
    groupMaxEnd = Math.max(groupMaxEnd, seg.endMin);
  }
  flush();

  return positioned;
}

/**
 * Initial vertical scroll target (in minutes from midnight) for the view.
 * Defaults to 08:00; if the earliest timed occurrence starts before that,
 * targets it (with a little padding) so early-morning events are visible.
 */
export function initialScrollMinutes(
  occurrences: EventOccurrence[],
  timeZone: string,
  defaultMinutes: number = DEFAULT_SCROLL_MINUTES,
): number {
  let earliest = defaultMinutes;
  for (const occ of occurrences) {
    if (occ.allDay) continue;
    earliest = Math.min(earliest, zonedMinutesOfDay(occ.start, timeZone));
  }
  if (earliest >= defaultMinutes) return defaultMinutes;
  return Math.max(0, earliest - 30);
}
