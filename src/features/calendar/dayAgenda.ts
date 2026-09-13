/**
 * "What is on this day", and how much of it a month cell may draw. Pure.
 *
 * WHY THIS EXISTS
 *
 * The month grid has to fit six week rows into a fixed height (`--month-row-h`),
 * so it can only ever show a few events per day. Both halves of that truncation
 * were previously broken, in opposite directions:
 *
 *   all-day  `buildAllDayBands` capped lanes at MAX_ALL_DAY_LANES and reported
 *            the remainder as per-column `overflow` counts, which the lane
 *            rendered as a bare `+N`. The number was correct and completely
 *            inert -- no click target, no way to reach the hidden events.
 *   timed    the cell mapped over EVERY timed occurrence with no cap at all.
 *            `.month-cell-events` is `overflow: hidden`, so anything past the
 *            third or fourth chip was silently clipped: no count, no affordance,
 *            no trace that it existed.
 *
 * So the month view hid too much on one side and drew too much on the other, and
 * neither side could be opened. This module supplies the data for one affordance
 * that fixes both: a cell shows at most `MAX_MONTH_CHIPS` timed chips, all-day
 * keeps its lane cap, and either overflow opens the SAME day agenda listing
 * everything on that date.
 *
 * WHY THE AGENDA IS NOT "THE HIDDEN ONES"
 *
 * `buildDayAgenda` deliberately ignores what the grid happened to truncate and
 * rebuilds the whole day from the occurrence list. Listing only the remainder
 * would mean the popover's contents depended on the cell's pixel height, would
 * split a day's events across two places, and would answer a question nobody
 * asks ("what did you hide?") instead of the one everyone does ("what is on
 * this day?").
 *
 * PURITY
 *
 * No React, no DOM, no clock, no locale. The component layer renders these
 * values and owns nothing else -- the same split `allDayBands`, `monthGrid`,
 * `weekGrid` and `loadState` already use, which is what makes all of it
 * testable without a browser.
 */

import type { EventOccurrence } from '../../types/event';
import { localDayKey } from '../../utils/datetime';
import { zonedDayKey } from '../../utils/timezone';

/**
 * How many timed chips one month cell may draw before collapsing the rest into
 * a "+N" button. The cap depends on the viewport because the row height does.
 *
 * MEASURED, not guessed. `--month-row-h` is 84px normally and 64px at <=640px
 * (`global.css`), and the cell spends part of that on its date label. On a
 * 390px-wide device three chips plus the overflow row did fit, but only by
 * wrapping the button onto a second line -- technically inside the box and
 * visibly cramped. Two chips leave it on one line. (That was measured when the
 * button still read "他 N 件"; the shorter "+N" label no longer wraps, but the
 * cap stays where the row budget put it -- re-measured at 390px, two chips plus
 * "+N" come to 57px with nothing clipped.)
 *
 * The cap is on CHIPS, not rows: the "+N" button takes one further row, so a
 * cell at its limit draws cap + 1 rows.
 */
export const MAX_MONTH_CHIPS_REGULAR = 3;
export const MAX_MONTH_CHIPS_COMPACT = 2;

/**
 * The viewport at which the month cell switches caps.
 *
 * MUST MATCH the `@media (max-width: 640px)` block in `global.css` that lowers
 * `--month-row-h` to 64px. They are two expressions of one breakpoint, and the
 * duplication is unavoidable -- CSS cannot hand a number to JS, and reading the
 * token back would mean measuring layout during render. Change one, change the
 * other; a mismatch shows up as chips clipped on exactly one side of the
 * boundary.
 */
export const COMPACT_MONTH_QUERY = '(max-width: 640px)';

/**
 * The chip cap for a viewport. Pure, so the responsive DECISION is testable and
 * only the media QUERY needs a browser -- the split `utils/theme.ts` already
 * uses, where `resolveInitialTheme` is pure and the caller reads `matchMedia`.
 */
export function monthChipCap(isCompact: boolean): number {
  return isCompact ? MAX_MONTH_CHIPS_COMPACT : MAX_MONTH_CHIPS_REGULAR;
}

/** What a month cell draws for its timed events, and what it defers. */
export interface MonthCellChips {
  /** The chips to render, in the order given. */
  visible: EventOccurrence[];
  /** How many were withheld. 0 means no "+N" affordance is needed. */
  hiddenCount: number;
}

/**
 * Split a day's timed occurrences into what a month cell shows and what it
 * hides. Order is preserved exactly: the caller decides the sort.
 *
 * At or below the cap everything is shown and `hiddenCount` is 0, so the caller
 * can branch on that single number rather than re-deriving lengths.
 *
 * A cap of exactly `maxChips + 1` still collapses to `maxChips` chips plus
 * "+1" rather than simply drawing the extra one. That costs the same vertical
 * space, so it is a deliberate choice for a UNIFORM cell height: a grid where
 * some cells hold four chips and others three is harder to scan than one where
 * every full cell looks the same.
 *
 * `maxChips` is REQUIRED rather than defaulted: the cap is viewport-dependent
 * (see `monthChipCap`), and a default here would let a caller silently render
 * the desktop cap on a phone.
 */
export function splitMonthCellChips(
  dayEvents: EventOccurrence[],
  maxChips: number,
): MonthCellChips {
  const cap = Math.max(0, maxChips);
  if (dayEvents.length <= cap) {
    return { visible: dayEvents, hiddenCount: 0 };
  }
  return {
    visible: dayEvents.slice(0, cap),
    hiddenCount: dayEvents.length - cap,
  };
}

/** One column's worth of hidden all-day bands, resolved to the day it sits on. */
export interface OverflowEntry {
  /** Column index within the given day keys. */
  columnIndex: number;
  /** The date that column represents -- what the agenda should open on. */
  dayKey: string;
  /** How many bands the lane cap hid in this column. Always > 0. */
  count: number;
}

/**
 * Pair `buildAllDayBands`'s per-column overflow counts with the day each column
 * stands for.
 *
 * This is the join the "+N" affordance needs and the one place it can go wrong:
 * `overflow` is indexed by COLUMN, and the column-to-date mapping lives in the
 * caller's `dayKeys`. Doing it inline in JSX is how a "+N" ends up opening the
 * wrong day -- and it would look right in every screenshot, because the number
 * would still be correct.
 *
 * Columns with no hidden bands are dropped, so the caller renders exactly what
 * it gets back. Counts are read positionally and a short `overflow` array simply
 * yields fewer entries rather than `undefined` ones.
 */
export function overflowEntries(dayKeys: string[], overflow: number[]): OverflowEntry[] {
  const entries: OverflowEntry[] = [];
  for (let i = 0; i < dayKeys.length; i++) {
    const count = overflow[i] ?? 0;
    const dayKey = dayKeys[i];
    if (count > 0 && dayKey !== undefined) {
      entries.push({ columnIndex: i, dayKey, count });
    }
  }
  return entries;
}

/** Everything scheduled on one date, split by how it is displayed. */
export interface DayAgenda {
  dayKey: string;
  /** All-day and multi-day events COVERING this date, longest first. */
  allDay: EventOccurrence[];
  /** Timed events STARTING on this date, earliest first. */
  timed: EventOccurrence[];
}

/**
 * Collect everything on `dayKey`, ignoring whatever the grid truncated.
 *
 * The two halves are selected on different rules, matching how each is drawn:
 *
 *   all-day  COVERAGE. A band is on this day if `[startKey, endKeyExcl)`
 *            contains it, so a multi-day event appears in the agenda of every
 *            day it spans -- which is what the band on screen claims. The keys
 *            come from the occurrence's own instants via `localDayKey`, never
 *            from `occ.event.startDate`: a recurring master's row is shared by
 *            every instance, so reading the event would collapse them all onto
 *            the master's date. `allDayBands` derives its spans the same way.
 *
 *   timed    START DAY, resolved in the user's zone with `zonedDayKey` -- the
 *            same grouping `MonthView` uses to place chips, so the agenda can
 *            never disagree with the cell that opened it. An event running past
 *            midnight belongs to the day it starts on, and appears once.
 *
 * Occurrence objects are passed through by IDENTITY, not copied. Whatever the
 * agenda hands to a click handler is the very object the caller supplied, so it
 * routes into the existing edit path unchanged.
 */
export function buildDayAgenda(
  dayKey: string,
  occurrences: EventOccurrence[],
  timeZone: string,
): DayAgenda {
  const allDay: EventOccurrence[] = [];
  const timed: EventOccurrence[] = [];

  for (const occ of occurrences) {
    if (occ.allDay) {
      const startKey = localDayKey(occ.start);
      const endKeyExcl = localDayKey(occ.end);
      if (!startKey || !endKeyExcl) continue;
      // Half-open [start, end): endDate is exclusive throughout the project.
      if (startKey <= dayKey && dayKey < endKeyExcl) allDay.push(occ);
    } else if (zonedDayKey(occ.start, timeZone) === dayKey) {
      timed.push(occ);
    }
  }

  // Longest-running first, matching the band packing order the user just saw.
  allDay.sort(
    (a, b) =>
      a.start.localeCompare(b.start) ||
      b.end.localeCompare(a.end) ||
      a.event.id.localeCompare(b.event.id),
  );

  // Chronological. The id tiebreak keeps the order stable for events sharing an
  // instant, so the list does not reshuffle between renders.
  timed.sort(
    (a, b) => a.start.localeCompare(b.start) || a.event.id.localeCompare(b.event.id),
  );

  return { dayKey, allDay, timed };
}
