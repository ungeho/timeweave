/**
 * One month-grid week: all-day bands and timed chips sharing ONE fixed budget of
 * rows per day. Pure.
 *
 * WHY THIS EXISTS
 *
 * The month view used to cap its two kinds of event separately -- at most
 * MAX_ALL_DAY_LANES bands in a lane stacked ABOVE the week, and at most
 * MAX_MONTH_CHIPS timed chips inside each cell -- and neither cap was a height.
 * The lane added its own rows on top of `--month-row-h`, and a full cell was
 * taller than the row it sat in, so a busy week grew to roughly two and a half
 * times an empty one. Counting chips bounded the DOM but not the layout.
 *
 * Here both kinds draw from the same `slots` rows of a day, so a week is always
 * a date row plus `slots` rows, whatever is in it:
 *
 *   rows 0 .. bandRows-1     all-day bands (the deepest visible lane over this day)
 *   rows bandRows ..         timed chips, in the order given
 *   row  slots-1             "+N", when anything on this day is hidden
 *
 * RULES
 *
 *   * Bands use at most `slots - 1` lanes, so the last row of every day is never
 *     a band: it is always free for a chip or for "+N". Lane packing is exactly
 *     `buildAllDayBands`, called with that cap -- this module adds no packing of
 *     its own.
 *   * A day's band rows are the deepest visible lane covering it, plus one. A
 *     band in lane 2 over a day where lanes 0 and 1 are empty still pushes that
 *     day's chips below it: rows are shared across the week, and a chip slotted
 *     into the gap above a band would sit in a row other days use for bands.
 *   * If nothing is hidden and every timed event fits in the remaining rows, all
 *     of them are shown and there is no "+N". Otherwise the last row becomes
 *     "+N" and the chips get the rows above it.
 *   * ONE "+N" per day. Its count is the all-day bands the lane cap hid on this
 *     day PLUS the timed events that did not get a row. Both open the same day
 *     agenda, which lists the whole day (`buildDayAgenda`), so two separate
 *     counts would only split one answer across two buttons.
 *
 * WHAT IT DOES NOT DECIDE
 *
 *   Which instants exist (expandEvents), which day an all-day occurrence covers
 *   (localDayKey, inside buildAllDayBands), which day a timed occurrence belongs
 *   to (zonedDayKey, in groupMonthOccurrences), or the order of the chips (the
 *   caller's; expandEvents sorts by start). Occurrence objects are passed
 *   through by identity, so a chip or band hands the edit path the very object
 *   it was given.
 *
 * PURITY
 *
 *   No React, no DOM, no clock. The viewport only chooses `slots`
 *   (monthSlotCount), the same split `monthChipCap` uses.
 */

import type { EventOccurrence } from '../../types/event';
import { zonedDayKey } from '../../utils/timezone';
import { buildAllDayBands, type AllDayBand } from './allDayBands';

/**
 * Rows per day below the date label. Regular keeps the three band lanes the
 * month view has always allowed, plus the one row that is never a band.
 * Compact gives up one of each.
 *
 * These are row COUNTS. The pixel height of a row is a CSS token, and the two
 * must be sized together when the view adopts this layout.
 */
export const MONTH_SLOTS_REGULAR = 4;
export const MONTH_SLOTS_COMPACT = 3;

/** Rows per day for a viewport. Pure; the caller reads the media query. */
export function monthSlotCount(isCompact: boolean): number {
  return isCompact ? MONTH_SLOTS_COMPACT : MONTH_SLOTS_REGULAR;
}

/** A month's occurrences split the way the grid draws them. */
export interface MonthOccurrenceGroups {
  /** All-day and multi-day occurrences, in the order given. */
  allDay: EventOccurrence[];
  /** Timed occurrences by START day in the user's zone, each list in the order given. */
  timedByDay: Map<string, EventOccurrence[]>;
}

/**
 * Split occurrences into all-day and timed-by-start-day.
 *
 * The same grouping MonthView has always done inline, moved here so the layout
 * and its tests see exactly what the grid will: timed events keyed by
 * `zonedDayKey(start, timeZone)`, the rule `buildDayAgenda` also uses, so a
 * day's "+N" and the agenda it opens can never disagree about which day an
 * event is on.
 */
export function groupMonthOccurrences(
  occurrences: EventOccurrence[],
  timeZone: string,
): MonthOccurrenceGroups {
  const allDay: EventOccurrence[] = [];
  const timedByDay = new Map<string, EventOccurrence[]>();
  for (const occ of occurrences) {
    if (occ.allDay) {
      allDay.push(occ);
      continue;
    }
    const key = zonedDayKey(occ.start, timeZone);
    const list = timedByDay.get(key);
    if (list) list.push(occ);
    else timedByDay.set(key, [occ]);
  }
  return { allDay, timedByDay };
}

/** What one day column of a week draws. */
export interface MonthDayLayout {
  /** Column index within the week's day keys. */
  columnIndex: number;
  /** The date of this column -- what "+N" opens. */
  dayKey: string;
  /**
   * Rows at the top of this day occupied by visible bands: the deepest visible
   * lane covering this day, plus one. Chip k sits in row `bandRows + k`.
   */
  bandRows: number;
  /** Timed chips to draw, a prefix of this day's timed list. */
  chips: EventOccurrence[];
  /** Hidden on this day: all-day bands cut by the lane cap + timed without a row. */
  hiddenCount: number;
  /** Row of this day's single "+N": `slots - 1` when hiddenCount > 0, else null. */
  moreRow: number | null;
}

/** A whole week row. */
export interface MonthWeekLayout {
  /** Rows per day actually used for this layout (after clamping). */
  slots: number;
  /** Visible bands. Every lane is at most `slots - 2`. */
  bands: AllDayBand[];
  /** One entry per day key, in column order. */
  days: MonthDayLayout[];
}

/**
 * Lay out one week of the month grid in a fixed number of rows per day.
 *
 * `slots` is clamped to a whole number of at least 1. With a single row there
 * is no room for a band, so every band is hidden and a busy day shows only its
 * "+N".
 *
 * Invariant, for every day: bandRows + chips.length + (moreRow === null ? 0 : 1)
 * is at most `slots`. That is what makes the week's height independent of how
 * many events it holds.
 */
export function buildMonthWeekLayout(
  dayKeys: string[],
  groups: MonthOccurrenceGroups,
  slots: number,
): MonthWeekLayout {
  const rows = Math.max(1, Math.floor(slots));

  // Lanes 0 .. rows-2. The last row is kept for a chip or the "+N".
  const { bands, overflow } = buildAllDayBands(groups.allDay, dayKeys, rows - 1);

  const bandRows = new Array<number>(dayKeys.length).fill(0);
  for (const band of bands) {
    for (let c = band.startIndex; c < band.startIndex + band.span; c++) {
      if (band.lane + 1 > (bandRows[c] ?? 0)) bandRows[c] = band.lane + 1;
    }
  }

  const days = dayKeys.map((dayKey, columnIndex): MonthDayLayout => {
    const used = bandRows[columnIndex] ?? 0;
    const available = rows - used; // >= 1: no visible lane reaches the last row
    const timed = groups.timedByDay.get(dayKey) ?? [];
    const allDayHidden = overflow[columnIndex] ?? 0;

    if (allDayHidden === 0 && timed.length <= available) {
      return {
        columnIndex,
        dayKey,
        bandRows: used,
        chips: timed.slice(),
        hiddenCount: 0,
        moreRow: null,
      };
    }

    const chips = timed.slice(0, available - 1);
    return {
      columnIndex,
      dayKey,
      bandRows: used,
      chips,
      hiddenCount: allDayHidden + (timed.length - chips.length),
      moreRow: rows - 1,
    };
  });

  return { slots: rows, bands, days };
}
