import { describe, expect, it } from 'vitest';
import type { EventOccurrence, EventRow } from '../../types/event';
import { isoFromDateString } from '../../utils/datetime';
import {
  MAX_MONTH_CHIPS_COMPACT,
  MAX_MONTH_CHIPS_REGULAR,
  buildDayAgenda,
  monthChipCap,
  overflowEntries,
  splitMonthCellChips,
} from './dayAgenda';

const TZ = 'Asia/Tokyo';

const WEEK = [
  '2026-08-24', '2026-08-25', '2026-08-26', '2026-08-27',
  '2026-08-28', '2026-08-29', '2026-08-30',
];

/**
 * All-day occurrence. start/end are LOCAL-midnight instants, exactly as
 * expandEvents builds them, so localDayKey inverts them cleanly on any machine
 * — the same fixture shape allDayBands.test.ts uses.
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

/**
 * Timed occurrence, given as a wall clock in TZ. Written as an explicit +09:00
 * offset rather than built from a Date, so the fixture does not depend on the
 * machine's own zone.
 */
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

describe('monthChipCap', () => {
  it('gives the roomier cap on a regular viewport', () => {
    expect(monthChipCap(false)).toBe(MAX_MONTH_CHIPS_REGULAR);
    expect(monthChipCap(false)).toBe(3);
  });

  it('gives the smaller cap on a compact viewport', () => {
    expect(monthChipCap(true)).toBe(MAX_MONTH_CHIPS_COMPACT);
    expect(monthChipCap(true)).toBe(2);
  });

  it('never gives the compact viewport MORE room than the regular one', () => {
    expect(monthChipCap(true)).toBeLessThan(monthChipCap(false));
  });
});

describe('splitMonthCellChips', () => {
  it('shows everything and hides nothing when at or under the cap', () => {
    const three = [timed('2026-08-25', '09:00'), timed('2026-08-25', '10:00'), timed('2026-08-25', '11:00')];
    const { visible, hiddenCount } = splitMonthCellChips(three, monthChipCap(false));
    expect(visible).toHaveLength(3);
    expect(hiddenCount).toBe(0);
  });

  it('desktop: shows 3 and reports +2 for five timed events', () => {
    const five = ['a', 'b', 'c', 'd', 'e'].map((id, i) =>
      timed('2026-08-25', `0${9 + i}:00`.slice(-5), id),
    );
    const { visible, hiddenCount } = splitMonthCellChips(five, monthChipCap(false));
    expect(visible.map((o) => o.event.id)).toEqual(['a', 'b', 'c']);
    expect(hiddenCount).toBe(2);
  });

  it('mobile: shows 2 and reports +3 for the same five events', () => {
    const five = ['a', 'b', 'c', 'd', 'e'].map((id, i) =>
      timed('2026-08-25', `0${9 + i}:00`.slice(-5), id),
    );
    const { visible, hiddenCount } = splitMonthCellChips(five, monthChipCap(true));
    expect(visible.map((o) => o.event.id)).toEqual(['a', 'b']);
    expect(hiddenCount).toBe(3);
  });

  it('shows 3 and reports +1 for four timed events (desktop)', () => {
    const four = [
      timed('2026-08-25', '09:00', 'a'),
      timed('2026-08-25', '10:00', 'b'),
      timed('2026-08-25', '11:00', 'c'),
      timed('2026-08-25', '12:00', 'd'),
    ];
    const { visible, hiddenCount } = splitMonthCellChips(four, monthChipCap(false));
    expect(visible.map((o) => o.event.id)).toEqual(['a', 'b', 'c']);
    expect(hiddenCount).toBe(1);
  });

  it('reports the full remainder for a very busy day, at either cap', () => {
    const many = Array.from({ length: 992 }, (_, i) =>
      timed('2026-08-25', '09:00', `e${i}`),
    );
    const desktop = splitMonthCellChips(many, monthChipCap(false));
    expect(desktop.visible).toHaveLength(MAX_MONTH_CHIPS_REGULAR);
    expect(desktop.hiddenCount).toBe(992 - MAX_MONTH_CHIPS_REGULAR);

    const mobile = splitMonthCellChips(many, monthChipCap(true));
    expect(mobile.visible).toHaveLength(MAX_MONTH_CHIPS_COMPACT);
    expect(mobile.hiddenCount).toBe(992 - MAX_MONTH_CHIPS_COMPACT);
  });

  it('preserves the order it was given', () => {
    const four = ['d', 'c', 'b', 'a'].map((id) => timed('2026-08-25', '09:00', id));
    expect(
      splitMonthCellChips(four, monthChipCap(false)).visible.map((o) => o.event.id),
    ).toEqual(['d', 'c', 'b']);
  });

  it('handles an empty day and a zero cap without throwing', () => {
    expect(splitMonthCellChips([], 3)).toEqual({ visible: [], hiddenCount: 0 });
    const one = [timed('2026-08-25', '09:00', 'a')];
    expect(splitMonthCellChips(one, 0)).toEqual({ visible: [], hiddenCount: 1 });
    expect(splitMonthCellChips(one, -5).hiddenCount).toBe(1);
  });
});

describe('overflowEntries', () => {
  it('resolves each overflowing column to its own day key', () => {
    const overflow = [0, 0, 5, 0, 0, 2, 0];
    expect(overflowEntries(WEEK, overflow)).toEqual([
      { columnIndex: 2, dayKey: '2026-08-26', count: 5 },
      { columnIndex: 5, dayKey: '2026-08-29', count: 2 },
    ]);
  });

  it('drops columns with nothing hidden', () => {
    expect(overflowEntries(WEEK, [0, 0, 0, 0, 0, 0, 0])).toEqual([]);
  });

  it('never yields a dayKey the caller did not supply', () => {
    // A short overflow array must not produce undefined entries.
    const entries = overflowEntries(WEEK, [1, 1]);
    expect(entries.map((e) => e.dayKey)).toEqual(['2026-08-24', '2026-08-25']);
    for (const e of entries) expect(WEEK).toContain(e.dayKey);
  });

  it('opens the day under the column, not the first day of the week', () => {
    // The regression this join exists to prevent: a "+N" on Saturday must open
    // Saturday. The count alone would look correct either way.
    const [entry] = overflowEntries(WEEK, [0, 0, 0, 0, 0, 0, 9]);
    expect(entry).toEqual({ columnIndex: 6, dayKey: '2026-08-30', count: 9 });
  });
});

describe('buildDayAgenda', () => {
  it('lists every timed event of the day, including those a cell would hide', () => {
    const day = '2026-08-25';
    const occs = [
      timed(day, '09:00', 'a'),
      timed(day, '10:00', 'b'),
      timed(day, '11:00', 'c'),
      timed(day, '12:00', 'd'),
      timed(day, '13:00', 'e'),
    ];
    // Whatever the cell truncated, the agenda lists the day in full — and the
    // cap it truncated at makes no difference to that.
    expect(splitMonthCellChips(occs, monthChipCap(false)).hiddenCount).toBe(2);
    expect(splitMonthCellChips(occs, monthChipCap(true)).hiddenCount).toBe(3);

    const agenda = buildDayAgenda(day, occs, TZ);
    expect(agenda.timed.map((o) => o.event.id)).toEqual(['a', 'b', 'c', 'd', 'e']);
  });

  it('sorts timed events by start time regardless of input order', () => {
    const day = '2026-08-25';
    const occs = [
      timed(day, '17:00', 'evening'),
      timed(day, '08:00', 'morning'),
      timed(day, '12:30', 'noon'),
    ];
    expect(buildDayAgenda(day, occs, TZ).timed.map((o) => o.event.id)).toEqual([
      'morning', 'noon', 'evening',
    ]);
  });

  it('includes every all-day event covering the date, not just those starting on it', () => {
    const occs = [
      allDay('2026-08-24', '2026-08-28', 'spanning'), // covers 24,25,26,27
      allDay('2026-08-26', '2026-08-27', 'onTheDay'),
      allDay('2026-08-30', '2026-08-31', 'later'),
    ];
    const ids = buildDayAgenda('2026-08-26', occs, TZ).allDay.map((o) => o.event.id);
    expect(ids).toContain('spanning');
    expect(ids).toContain('onTheDay');
    expect(ids).not.toContain('later');
  });

  it('treats the all-day end date as EXCLUSIVE', () => {
    const occs = [allDay('2026-08-24', '2026-08-26', 'twoDays')]; // 24 and 25 only
    expect(buildDayAgenda('2026-08-25', occs, TZ).allDay).toHaveLength(1);
    expect(buildDayAgenda('2026-08-26', occs, TZ).allDay).toHaveLength(0);
  });

  it('lists all-day bands hidden by the lane cap', () => {
    // Five overlapping single-day bands: MAX_ALL_DAY_LANES (3) are drawn and two
    // are counted into `overflow`. The agenda must show all five.
    const day = '2026-08-26';
    const occs = ['a', 'b', 'c', 'd', 'e'].map((id) => allDay(day, '2026-08-27', id));
    expect(buildDayAgenda(day, occs, TZ).allDay).toHaveLength(5);
  });

  it('keeps all-day and timed separate and returns both', () => {
    const day = '2026-08-26';
    const agenda = buildDayAgenda(
      day,
      [allDay(day, '2026-08-27', 'ad'), timed(day, '09:00', 't')],
      TZ,
    );
    expect(agenda.dayKey).toBe(day);
    expect(agenda.allDay.map((o) => o.event.id)).toEqual(['ad']);
    expect(agenda.timed.map((o) => o.event.id)).toEqual(['t']);
  });

  it('excludes other days entirely', () => {
    const occs = [timed('2026-08-25', '09:00', 'yesterday'), timed('2026-08-26', '09:00', 'today')];
    const agenda = buildDayAgenda('2026-08-26', occs, TZ);
    expect(agenda.timed.map((o) => o.event.id)).toEqual(['today']);
  });

  it('groups a timed event by its START day in the user zone', () => {
    // 23:30 JST on the 26th is 14:30Z on the 26th; it must not land on the 27th.
    const occ = timed('2026-08-26', '23:30', 'late');
    expect(buildDayAgenda('2026-08-26', [occ], TZ).timed).toHaveLength(1);
    expect(buildDayAgenda('2026-08-27', [occ], TZ).timed).toHaveLength(0);
  });

  it('returns an empty agenda for a day with nothing on it', () => {
    const agenda = buildDayAgenda('2026-08-31', [timed('2026-08-26', '09:00')], TZ);
    expect(agenda).toEqual({ dayKey: '2026-08-31', allDay: [], timed: [] });
  });

  /**
   * The agenda hands a click handler the OCCURRENCE OBJECT it was given, not a
   * copy. DayAgendaDialog passes that straight to onOccurrenceClick, which is
   * CalendarPage's openEdit -- the same function the month chips call. Identity
   * is what makes the two paths equivalent: openEdit reads occ.isException and
   * occ.event.recurrenceId to resolve the series master, so a reconstructed
   * object would silently lose the edit-scope choice.
   */
  it('passes occurrences through by identity, so the existing edit path works', () => {
    const day = '2026-08-26';
    const ad = allDay(day, '2026-08-27', 'ad');
    const t = timed(day, '09:00', 't');
    const agenda = buildDayAgenda(day, [ad, t], TZ);
    expect(agenda.allDay[0]).toBe(ad);
    expect(agenda.timed[0]).toBe(t);
  });
});
