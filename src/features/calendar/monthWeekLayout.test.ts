import { describe, expect, it } from 'vitest';
import type { EventOccurrence, EventRow } from '../../types/event';
import { addDaysToDateString, isoFromDateString } from '../../utils/datetime';
import { buildDayAgenda } from './dayAgenda';
import {
  MONTH_SLOTS_COMPACT,
  MONTH_SLOTS_REGULAR,
  buildMonthWeekLayout,
  groupMonthOccurrences,
  monthSlotCount,
  type MonthDayLayout,
  type MonthWeekLayout,
} from './monthWeekLayout';

const TZ = 'Asia/Tokyo';

// Monday .. Sunday, as buildMonthGrid lays a week out.
const WEEK = [
  '2026-08-24', '2026-08-25', '2026-08-26', '2026-08-27',
  '2026-08-28', '2026-08-29', '2026-08-30',
];
const MON = 0;
const TUE = 1;
const WED = 2;
const THU = 3;
const FRI = 4;
const SAT = 5;

/**
 * All-day occurrence. start/end are LOCAL-midnight instants, exactly as
 * expandEvents builds them -- the fixture allDayBands.test.ts and
 * dayAgenda.test.ts use.
 */
function allDay(startDate: string, endDate: string, id = `ad-${startDate}`): EventOccurrence {
  const event = { id, allDay: true, startDate, endDate } as unknown as EventRow;
  return {
    event,
    start: isoFromDateString(startDate),
    end: isoFromDateString(endDate),
    allDay: true,
    occurrenceKey: startDate,
    isException: false,
  };
}

/** Timed occurrence at a wall clock in TZ, written with an explicit +09:00. */
function timed(dayKey: string, hhmm: string, id = `t-${dayKey}-${hhmm}`): EventOccurrence {
  const startIso = new Date(`${dayKey}T${hhmm}:00+09:00`).toISOString();
  const endIso = new Date(Date.parse(startIso) + 3_600_000).toISOString();
  const event = { id, allDay: false, startAt: startIso, endAt: endIso } as unknown as EventRow;
  return {
    event,
    start: startIso,
    end: endIso,
    allDay: false,
    occurrenceKey: startIso,
    isException: false,
  };
}

/** `n` timed events on one day, distinct ids, in the given order. */
function manyTimed(dayKey: string, n: number, prefix = 't'): EventOccurrence[] {
  return Array.from({ length: n }, (_, i) => timed(dayKey, '09:00', `${prefix}${i}`));
}

function layoutOf(occs: EventOccurrence[], slots = MONTH_SLOTS_REGULAR): MonthWeekLayout {
  return buildMonthWeekLayout(WEEK, groupMonthOccurrences(occs, TZ), slots);
}

function day(layout: MonthWeekLayout, column: number): MonthDayLayout {
  const d = layout.days[column];
  if (!d) throw new Error(`no day at column ${column}`);
  return d;
}

/** Rows a day actually draws below its date label. */
function rowsUsed(d: MonthDayLayout): number {
  return d.bandRows + d.chips.length + (d.moreRow === null ? 0 : 1);
}

function visibleBandsOn(layout: MonthWeekLayout, column: number): number {
  return layout.bands.filter((b) => b.startIndex <= column && column < b.startIndex + b.span).length;
}

/**
 * The height contract and the "+N" contract, checked on every day of a layout:
 *   - no day draws more rows than the budget;
 *   - "+N" exists exactly when something is hidden, and always in the last row;
 *   - no band occupies the last row.
 */
function expectWithinBudget(layout: MonthWeekLayout): void {
  for (const d of layout.days) {
    expect(rowsUsed(d)).toBeLessThanOrEqual(layout.slots);
    if (d.hiddenCount > 0) expect(d.moreRow).toBe(layout.slots - 1);
    else expect(d.moreRow).toBeNull();
  }
  for (const b of layout.bands) expect(b.lane).toBeLessThanOrEqual(layout.slots - 2);
}

/**
 * Nothing disappears: for every day, what the grid draws plus what "+N" counts
 * equals what the day agenda -- the list "+N" opens -- will show.
 */
function expectAgendaAgrees(layout: MonthWeekLayout, occs: EventOccurrence[]): void {
  for (const d of layout.days) {
    const agenda = buildDayAgenda(d.dayKey, occs, TZ);
    expect(visibleBandsOn(layout, d.columnIndex) + d.chips.length + d.hiddenCount).toBe(
      agenda.allDay.length + agenda.timed.length,
    );
  }
}

describe('monthSlotCount', () => {
  it('gives 4 rows on a regular viewport and 3 on a compact one', () => {
    expect(monthSlotCount(false)).toBe(MONTH_SLOTS_REGULAR);
    expect(monthSlotCount(false)).toBe(4);
    expect(monthSlotCount(true)).toBe(MONTH_SLOTS_COMPACT);
    expect(monthSlotCount(true)).toBe(3);
  });
});

describe('groupMonthOccurrences', () => {
  it('splits all-day from timed and keeps the input order in both', () => {
    const a1 = allDay('2026-08-25', '2026-08-26', 'a1');
    const t1 = timed('2026-08-25', '10:00', 't1');
    const a2 = allDay('2026-08-24', '2026-08-27', 'a2');
    const t2 = timed('2026-08-25', '09:00', 't2');
    const g = groupMonthOccurrences([a1, t1, a2, t2], TZ);
    expect(g.allDay).toEqual([a1, a2]);
    expect(g.timedByDay.get('2026-08-25')).toEqual([t1, t2]);
  });

  it('keys a timed event by its START day in the user zone', () => {
    // 23:30 JST on the 26th is 14:30Z on the 26th; it belongs to the 26th.
    const late = timed('2026-08-26', '23:30', 'late');
    const g = groupMonthOccurrences([late], TZ);
    expect(g.timedByDay.get('2026-08-26')).toEqual([late]);
    expect(g.timedByDay.has('2026-08-27')).toBe(false);
  });

  it('passes occurrences through by identity', () => {
    const t = timed('2026-08-25', '09:00', 't');
    const a = allDay('2026-08-25', '2026-08-26', 'a');
    const g = groupMonthOccurrences([t, a], TZ);
    expect(g.timedByDay.get('2026-08-25')![0]).toBe(t);
    expect(g.allDay[0]).toBe(a);
  });
});

describe('buildMonthWeekLayout: the shared row budget', () => {
  it('lays out an empty week as seven empty days', () => {
    const layout = layoutOf([]);
    expect(layout.slots).toBe(4);
    expect(layout.bands).toEqual([]);
    expect(layout.days.map((d) => d.dayKey)).toEqual(WEEK);
    for (const d of layout.days) {
      expect(d).toMatchObject({ bandRows: 0, chips: [], hiddenCount: 0, moreRow: null });
    }
  });

  it('shows everything when a band and timed chips exactly fill the rows', () => {
    const occs = [
      allDay('2026-08-25', '2026-08-26', 'band'),
      timed('2026-08-25', '09:00', 'a'),
      timed('2026-08-25', '10:00', 'b'),
      timed('2026-08-25', '11:00', 'c'),
    ];
    const tue = day(layoutOf(occs), TUE);
    expect(tue.bandRows).toBe(1);
    expect(tue.chips.map((o) => o.event.id)).toEqual(['a', 'b', 'c']);
    expect(tue.hiddenCount).toBe(0);
    expect(tue.moreRow).toBeNull();
    expect(rowsUsed(tue)).toBe(4);
  });

  it('turns the last row into "+N" as soon as one more timed event arrives', () => {
    const occs = [
      allDay('2026-08-25', '2026-08-26', 'band'),
      timed('2026-08-25', '09:00', 'a'),
      timed('2026-08-25', '10:00', 'b'),
      timed('2026-08-25', '11:00', 'c'),
      timed('2026-08-25', '12:00', 'd'),
    ];
    const tue = day(layoutOf(occs), TUE);
    // 1 band row + 2 chips + "+N" = 4 rows; c and d are hidden.
    expect(tue.chips.map((o) => o.event.id)).toEqual(['a', 'b']);
    expect(tue.hiddenCount).toBe(2);
    expect(tue.moreRow).toBe(3);
  });

  it('with no bands, fits four timed events and collapses five into 3 + "+2"', () => {
    const four = day(layoutOf(manyTimed('2026-08-26', 4)), WED);
    expect(four.chips).toHaveLength(4);
    expect(four.moreRow).toBeNull();

    const five = day(layoutOf(manyTimed('2026-08-26', 5)), WED);
    expect(five.chips.map((o) => o.event.id)).toEqual(['t0', 't1', 't2']);
    expect(five.hiddenCount).toBe(2);
    expect(five.moreRow).toBe(3);
  });

  it('never gives bands the last row', () => {
    // Five overlapping single-day bands: with 4 rows only lanes 0..2 are visible.
    const occs = ['a', 'b', 'c', 'd', 'e'].map((id) => allDay('2026-08-26', '2026-08-27', id));
    const layout = layoutOf(occs);
    expect(layout.bands.map((b) => b.lane).sort()).toEqual([0, 1, 2]);
    expect(day(layout, WED).bandRows).toBe(3);
    expectWithinBudget(layout);
  });
});

describe('buildMonthWeekLayout: one "+N" per day, counting both kinds', () => {
  it('adds hidden all-day bands and hidden timed events into one count', () => {
    const occs = [
      ...['a', 'b', 'c', 'd', 'e'].map((id) => allDay('2026-08-26', '2026-08-27', id)),
      timed('2026-08-26', '09:00', 'x'),
      timed('2026-08-26', '10:00', 'y'),
    ];
    const wed = day(layoutOf(occs), WED);
    // 3 visible bands take rows 0..2, row 3 must be "+N" because 2 bands are
    // hidden, which leaves no row for a chip: 2 bands + 2 timed are hidden.
    expect(wed.bandRows).toBe(3);
    expect(wed.chips).toEqual([]);
    expect(wed.hiddenCount).toBe(4);
    expect(wed.moreRow).toBe(3);
  });

  it('shows "+N" for hidden bands even when the day has no timed events', () => {
    const occs = ['a', 'b', 'c', 'd'].map((id) => allDay('2026-08-24', '2026-08-27', id));
    const layout = layoutOf(occs);
    for (const col of [MON, TUE, WED]) {
      expect(day(layout, col)).toMatchObject({ bandRows: 3, chips: [], hiddenCount: 1, moreRow: 3 });
    }
    expect(day(layout, THU)).toMatchObject({ bandRows: 0, hiddenCount: 0, moreRow: null });
  });

  it('attaches each "+N" to the day under its column', () => {
    // A "+N" on Saturday must open Saturday; the count alone would look right either way.
    const layout = layoutOf(manyTimed('2026-08-29', 9));
    const withMore = layout.days.filter((d) => d.moreRow !== null);
    expect(withMore).toHaveLength(1);
    expect(withMore[0]).toMatchObject({ columnIndex: SAT, dayKey: '2026-08-29', hiddenCount: 6 });
  });

  it('agrees with the day agenda on every day: drawn + hidden = listed', () => {
    const occs = [
      ...['a', 'b', 'c', 'd'].map((id) => allDay('2026-08-24', '2026-08-27', id)),
      allDay('2026-08-20', '2026-08-26', 'fromLastWeek'),
      allDay('2026-08-29', '2026-09-02', 'intoNextWeek'),
      ...manyTimed('2026-08-25', 6, 'tue'),
      ...manyTimed('2026-08-29', 2, 'sat'),
      timed('2026-08-30', '23:30', 'lateSunday'),
    ];
    const layout = layoutOf(occs);
    expectWithinBudget(layout);
    expectAgendaAgrees(layout, occs);
  });
});

describe('buildMonthWeekLayout: band rows per day', () => {
  it('pushes chips below the deepest band over that day, even with empty lanes above it', () => {
    // A Mon-Wed -> lane 0; B Mon-Tue -> lane 1; C Tue-Fri finds lanes 0 and 1
    // busy on Tuesday -> lane 2. On Thursday only C is present, in lane 2.
    const occs = [
      allDay('2026-08-24', '2026-08-27', 'A'),
      allDay('2026-08-24', '2026-08-26', 'B'),
      allDay('2026-08-25', '2026-08-29', 'C'),
      timed('2026-08-27', '09:00', 'thu1'),
    ];
    const layout = layoutOf(occs);
    expect(layout.bands.find((b) => b.occurrence.event.id === 'C')!.lane).toBe(2);
    const thu = day(layout, THU);
    expect(thu.bandRows).toBe(3);
    expect(thu.chips.map((o) => o.event.id)).toEqual(['thu1']);
    expect(thu.moreRow).toBeNull();

    const busier = layoutOf([...occs, timed('2026-08-27', '10:00', 'thu2')]);
    expect(day(busier, THU)).toMatchObject({ bandRows: 3, chips: [], hiddenCount: 2, moreRow: 3 });
  });

  it('counts a band continuing from the previous week on the first column', () => {
    const layout = layoutOf([allDay('2026-08-20', '2026-08-26', 'carry')]);
    expect(layout.bands[0]).toMatchObject({ startIndex: MON, span: 2, continuesLeft: true });
    expect(day(layout, MON).bandRows).toBe(1);
    expect(day(layout, TUE).bandRows).toBe(1);
    expect(day(layout, WED).bandRows).toBe(0);
  });
});

describe('buildMonthWeekLayout: compact viewport', () => {
  it('uses 3 rows: at most 2 band lanes, 3 chips fit, 4 become 2 + "+2"', () => {
    const slots = monthSlotCount(true);
    const bandsLayout = layoutOf(['a', 'b', 'c'].map((id) => allDay('2026-08-26', '2026-08-27', id)), slots);
    expect(bandsLayout.bands.map((b) => b.lane).sort()).toEqual([0, 1]);
    expect(day(bandsLayout, WED)).toMatchObject({ bandRows: 2, hiddenCount: 1, moreRow: 2 });

    expect(day(layoutOf(manyTimed('2026-08-26', 3), slots), WED)).toMatchObject({ hiddenCount: 0, moreRow: null });
    const four = day(layoutOf(manyTimed('2026-08-26', 4), slots), WED);
    expect(four.chips).toHaveLength(2);
    expect(four.hiddenCount).toBe(2);
    expect(four.moreRow).toBe(2);
  });
});

describe('buildMonthWeekLayout: large data', () => {
  it('draws the same bounded number of rows whether a day holds 0 or 2000 events', () => {
    for (const slots of [MONTH_SLOTS_REGULAR, MONTH_SLOTS_COMPACT]) {
      for (const timedCount of [0, 1, 5, 50, 2000]) {
        for (const allDayCount of [0, 3, 40]) {
          const occs = [
            ...Array.from({ length: allDayCount }, (_, i) =>
              allDay('2026-08-24', addDaysToDateString('2026-08-24', 1 + (i % 7)), `ad${i}`),
            ),
            ...manyTimed('2026-08-27', timedCount),
          ];
          const layout = layoutOf(occs, slots);
          expectWithinBudget(layout);
          // The output -- and so the DOM built from it -- is bounded by the grid,
          // not by the data.
          expect(layout.bands.length).toBeLessThanOrEqual(7 * (slots - 1));
          expect(layout.days.reduce((n, d) => n + d.chips.length, 0)).toBeLessThanOrEqual(7 * slots);
        }
      }
    }
  });

  it('still accounts for every one of 2000 timed events and 40 all-day bands', () => {
    const occs = [
      ...Array.from({ length: 40 }, (_, i) => allDay('2026-08-24', '2026-08-31', `week${i}`)),
      ...manyTimed('2026-08-27', 2000),
    ];
    const layout = layoutOf(occs);
    const thu = day(layout, THU);
    // Three bands visible over the whole week, 37 hidden on every day; no row
    // left for a chip on Thursday, so all 2000 timed are hidden too.
    expect(visibleBandsOn(layout, THU)).toBe(3);
    expect(thu.chips).toEqual([]);
    expect(thu.hiddenCount).toBe(37 + 2000);
    expectAgendaAgrees(layout, occs);
  });
});

describe('buildMonthWeekLayout: recurring occurrences', () => {
  it('places each instance of a daily all-day series on its own day (shared master)', () => {
    const master = { id: 'daily', allDay: true, startDate: '2026-08-01', endDate: '2026-08-02' } as unknown as EventRow;
    const occs = WEEK.map((d): EventOccurrence => ({
      event: master,
      start: isoFromDateString(d),
      end: isoFromDateString(addDaysToDateString(d, 1)),
      allDay: true,
      occurrenceKey: d,
      isException: false,
    }));
    const layout = layoutOf(occs);
    expect(layout.bands).toHaveLength(7);
    for (const d of layout.days) {
      expect(d).toMatchObject({ bandRows: 1, hiddenCount: 0, moreRow: null });
    }
    expect(layout.bands.map((b) => b.occurrence.occurrenceKey)).toEqual(WEEK);
  });

  it('places each instance of a daily timed series on its own day (shared master)', () => {
    const master = { id: 'standup', allDay: false, rrule: 'FREQ=DAILY' } as unknown as EventRow;
    const occs = WEEK.map((d): EventOccurrence => {
      const start = new Date(`${d}T10:00:00+09:00`).toISOString();
      return {
        event: master,
        start,
        end: new Date(Date.parse(start) + 900_000).toISOString(),
        allDay: false,
        occurrenceKey: start,
        isException: false,
      };
    });
    const layout = layoutOf(occs);
    for (const [i, d] of layout.days.entries()) {
      expect(d.chips).toHaveLength(1);
      expect(d.chips[0]).toBe(occs[i]);
      expect(d.hiddenCount).toBe(0);
    }
  });
});

describe('buildMonthWeekLayout: contracts with the caller', () => {
  it('shows a prefix of the day in the order given, by identity', () => {
    const occs = ['d', 'c', 'b', 'a', 'z'].map((id) => timed('2026-08-28', '09:00', id));
    const fri = day(layoutOf(occs), FRI);
    expect(fri.chips).toHaveLength(3);
    fri.chips.forEach((chip, i) => expect(chip).toBe(occs[i]));
  });

  it('hands bands the same occurrence objects it was given', () => {
    const band = allDay('2026-08-25', '2026-08-26', 'band');
    expect(layoutOf([band]).bands[0]!.occurrence).toBe(band);
  });

  it('does not mutate the grouped input', () => {
    const occs = manyTimed('2026-08-25', 6);
    const groups = groupMonthOccurrences(occs, TZ);
    const before = groups.timedByDay.get('2026-08-25')!.slice();
    const layout = buildMonthWeekLayout(WEEK, groups, 4);
    expect(groups.timedByDay.get('2026-08-25')).toEqual(before);
    expect(day(layout, TUE).chips).not.toBe(groups.timedByDay.get('2026-08-25'));
  });

  it('ignores timed events on days outside the week', () => {
    const layout = layoutOf([timed('2026-08-31', '09:00', 'nextMonday')]);
    for (const d of layout.days) expect(d).toMatchObject({ chips: [], hiddenCount: 0 });
  });

  it('clamps slots to a whole number of at least 1', () => {
    const one = layoutOf([allDay('2026-08-25', '2026-08-26', 'band'), timed('2026-08-25', '09:00', 't')], 1);
    expect(one.slots).toBe(1);
    expect(one.bands).toEqual([]);
    expect(day(one, TUE)).toMatchObject({ bandRows: 0, chips: [], hiddenCount: 2, moreRow: 0 });
    expectWithinBudget(one);

    expect(layoutOf([], 0).slots).toBe(1);
    expect(layoutOf([], -3).slots).toBe(1);
    expect(layoutOf([], 2.7).slots).toBe(2);
  });
});
