/**
 * Horizontal band layout for all-day (incl. multi-day) events. Pure.
 *
 * Works purely on calendar dates: each all-day occurrence spans
 * [startDate, endDate) (endDate exclusive — unchanged DB semantics), so no UTC
 * conversion is needed. Bands are laid out over a fixed list of consecutive day
 * keys (a week row for the month view, 7 days for week view, 1 for day view);
 * calling per week row makes week-boundary splitting automatic.
 *
 * Lanes stack overlapping bands. To keep month rows from growing unbounded, at
 * most `maxLanes` lanes are returned as visible; bands beyond that are reported
 * as per-column `overflow` counts so a future "+N more" affordance can render.
 */

import type { EventOccurrence } from '../../types/event';
import { addDaysToDateString, localDayKey } from '../../utils/datetime';

/** Default cap on stacked all-day lanes (month view). */
export const MAX_ALL_DAY_LANES = 3;

export interface AllDayBand {
  occurrence: EventOccurrence;
  /** Column index (into the given days) where the visible segment starts. */
  startIndex: number;
  /** Number of columns the segment spans within the given days. */
  span: number;
  /** 0-based lane (stacking row) within the all-day area. */
  lane: number;
  /** The event begins before the first given day. */
  continuesLeft: boolean;
  /** The event ends after the last given day. */
  continuesRight: boolean;
}

export interface AllDayLayout {
  /** Visible bands (lane < maxLanes). */
  bands: AllDayBand[];
  /** Number of visible lanes = min(lanes used, maxLanes). */
  laneCount: number;
  /** Per-column count of bands hidden by the lane cap (length = days.length). */
  overflow: number[];
}

/** Whole-day difference from day key `a` to `b` (b - a). */
function dayDiff(a: string, b: string): number {
  const ms = Date.parse(`${b}T00:00:00Z`) - Date.parse(`${a}T00:00:00Z`);
  return Math.round(ms / 86_400_000);
}

interface RawBand extends AllDayBand {}

export function buildAllDayBands(
  occurrences: EventOccurrence[],
  dayKeys: string[],
  maxLanes: number = MAX_ALL_DAY_LANES,
): AllDayLayout {
  const overflow = new Array(dayKeys.length).fill(0) as number[];
  if (dayKeys.length === 0) return { bands: [], laneCount: 0, overflow };

  const firstKey = dayKeys[0]!;
  const afterLastKey = addDaysToDateString(dayKeys[dayKeys.length - 1]!, 1);

  const raw: RawBand[] = [];
  for (const occ of occurrences) {
    if (!occ.allDay) continue;
    // Derive the span from the PER-OCCURRENCE instants, not occ.event's dates:
    // for a recurring master, occ.event is shared across every instance, so its
    // start_date/end_date would collapse all instances onto the master's day.
    // localDayKey inverts the local-midnight instants back to their date keys.
    const startKey = localDayKey(occ.start);
    const endKeyExcl = localDayKey(occ.end);
    if (!startKey || !endKeyExcl) continue; // all-day rows always carry dates

    const segStart = startKey > firstKey ? startKey : firstKey;
    const segEndExcl = endKeyExcl < afterLastKey ? endKeyExcl : afterLastKey;
    if (segStart >= segEndExcl) continue; // outside this day window

    const startIndex = dayDiff(firstKey, segStart);
    const span = dayDiff(segStart, segEndExcl);
    raw.push({
      occurrence: occ,
      startIndex,
      span,
      lane: -1,
      continuesLeft: startKey < firstKey,
      continuesRight: endKeyExcl > afterLastKey,
    });
  }

  // Longer/earlier bands first for tidy packing and stable output.
  raw.sort(
    (a, b) =>
      a.startIndex - b.startIndex ||
      b.span - a.span ||
      a.occurrence.start.localeCompare(b.occurrence.start),
  );

  const laneEnds: number[] = []; // next free column per lane
  for (const band of raw) {
    let lane = laneEnds.findIndex((end) => end <= band.startIndex);
    if (lane === -1) {
      lane = laneEnds.length;
      laneEnds.push(0);
    }
    laneEnds[lane] = band.startIndex + band.span;
    band.lane = lane;
  }

  const bands: AllDayBand[] = [];
  for (const band of raw) {
    if (band.lane < maxLanes) {
      bands.push(band);
    } else {
      for (let c = band.startIndex; c < band.startIndex + band.span; c++) {
        overflow[c] = (overflow[c] ?? 0) + 1;
      }
    }
  }

  return { bands, laneCount: Math.min(laneEnds.length, maxLanes), overflow };
}
