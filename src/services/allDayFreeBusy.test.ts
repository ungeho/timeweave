/**
 * Reference expectations for the all-day Free/Busy expansion added in Phase 5b-1
 * (supabase/migrations/0007_allday_recurrence_freebusy.sql).
 *
 * This file is one half of a two-sided differential test. It derives the busy
 * intervals from the SHIPPED TypeScript pipeline -- `expandEvents` followed by
 * `mergeAllDay` -- and pins them as literals. The SQL suite
 * (supabase/tests/0007_allday_recurrence_freebusy_test.sql) asserts the SAME
 * literals for the SAME fixtures, under matching case numbers, so a reviewer can
 * read the two files side by side and see the two implementations agree.
 *
 * Scope note: `expandEvents` has no visibility layer, so every case here is the
 * include_private = true situation. The visibility matrix and the completeness
 * rules live only in SQL and are asserted only there.
 */

import { describe, expect, it } from 'vitest';
import type { EventRow, Visibility } from '../types/event';
import { addDaysToDateString, isoFromDateString, localDayKey } from '../utils/datetime';
import { mergeAllDay, type DateRange } from './mergeIntervals';
import { expandEvents } from './occurrences';

const OWNER = 'owner-1';

interface RowInput {
  id: string;
  startDate?: string;
  endDate?: string;
  rrule?: string | null;
  recurrenceId?: string | null;
  recurrenceSlotDate?: string | null;
  isCancelled?: boolean;
  visibility?: Visibility;
  /** Timed rows only; used to prove timed and all-day never mix. */
  startAt?: string;
  endAt?: string;
  allDay?: boolean;
}

function row(input: RowInput): EventRow {
  const allDay = input.allDay ?? true;
  return {
    id: input.id,
    ownerId: OWNER,
    title: 'SECRET',
    description: null,
    category: null,
    visibility: input.visibility ?? 'busy_only',
    allDay,
    startAt: allDay ? null : (input.startAt ?? null),
    endAt: allDay ? null : (input.endAt ?? null),
    startDate: allDay ? (input.startDate ?? null) : null,
    endDate: allDay ? (input.endDate ?? null) : null,
    rrule: input.rrule ?? null,
    recurrenceId: input.recurrenceId ?? null,
    recurrenceSlotStart: null,
    recurrenceSlotDate: input.recurrenceSlotDate ?? null,
    isCancelled: input.isCancelled ?? false,
    createdAt: '2026-01-01T00:00:00.000Z',
    updatedAt: '2026-01-01T00:00:00.000Z',
  };
}

/**
 * The all-day busy intervals a share link must report for [fromDate, toDate),
 * as half-open "YYYY-MM-DD" ranges. Mirrors what get_free_busy builds: expand,
 * clip to the window, then merge overlapping AND adjacent ranges.
 */
function allDayBusy(rows: EventRow[], fromDate: string, toDate: string): DateRange[] {
  const occurrences = expandEvents(
    rows,
    isoFromDateString(fromDate),
    isoFromDateString(toDate),
  ).filter((o) => o.allDay);

  const clipped: DateRange[] = [];
  for (const o of occurrences) {
    const s = localDayKey(o.start);
    const e = localDayKey(o.end);
    const startDate = s > fromDate ? s : fromDate;
    const endDate = e < toDate ? e : toDate;
    if (startDate < endDate) clipped.push({ startDate, endDate });
  }
  return mergeAllDay(clipped);
}

/** Shorthand for a one-interval expectation. */
const span = (startDate: string, endDate: string): DateRange => ({ startDate, endDate });

const FROM = '2026-09-01'; // Tuesday
const TO = '2026-09-08'; // Tuesday, exclusive

describe('all-day Free/Busy expansion — DAILY', () => {
  it('C1: FREQ=DAILY covers every day of the window and merges into one span', () => {
    const rows = [
      row({ id: 'm', startDate: '2026-08-01', endDate: '2026-08-02', rrule: 'FREQ=DAILY' }),
    ];
    expect(allDayBusy(rows, FROM, TO)).toEqual([span('2026-09-01', '2026-09-08')]);
  });

  it('C2: FREQ=DAILY;INTERVAL=3 lands only on the stepped days', () => {
    const rows = [
      row({
        id: 'm',
        startDate: '2026-08-01',
        endDate: '2026-08-02',
        rrule: 'FREQ=DAILY;INTERVAL=3',
      }),
    ];
    // 2026-08-01 + 3k -> ... 2026-09-03, 2026-09-06 inside the window.
    expect(allDayBusy(rows, FROM, TO)).toEqual([
      span('2026-09-03', '2026-09-04'),
      span('2026-09-06', '2026-09-07'),
    ]);
  });

  it('C8: DATE UNTIL is inclusive on the occurrence start', () => {
    const rows = [
      row({
        id: 'm',
        startDate: '2026-08-01',
        endDate: '2026-08-02',
        rrule: 'FREQ=DAILY;UNTIL=20260903',
      }),
    ];
    // 09-01, 09-02, 09-03 -> merged; 09-04 onwards is past UNTIL.
    expect(allDayBusy(rows, FROM, TO)).toEqual([span('2026-09-01', '2026-09-04')]);
  });

  it('C8b: an occurrence starting exactly ON the UNTIL date is included', () => {
    const rows = [
      row({
        id: 'm',
        startDate: '2026-08-01',
        endDate: '2026-08-02',
        rrule: 'FREQ=DAILY;UNTIL=20260901',
      }),
    ];
    expect(allDayBusy(rows, FROM, TO)).toEqual([span('2026-09-01', '2026-09-02')]);
  });

  it('C10: multi-day occurrences overlap each other and collapse to one span', () => {
    // duration 3 days, every 2 days: 09-01, 09-03, 09-05, 09-07 -> continuous.
    const rows = [
      row({
        id: 'm',
        startDate: '2026-09-01',
        endDate: '2026-09-04',
        rrule: 'FREQ=DAILY;INTERVAL=2',
      }),
    ];
    expect(allDayBusy(rows, FROM, TO)).toEqual([span('2026-09-01', '2026-09-08')]);
  });

  it('C12: a multi-day occurrence starting BEFORE the window is clipped into it', () => {
    // duration 3 days, every 7: the 2026-08-30 occurrence spans [08-30, 09-02)
    // and reaches into the window, so it must appear clipped to [09-01, 09-02).
    // The next start, 09-06, spans [09-06, 09-09) and clips to 09-08.
    const rows = [
      row({
        id: 'm',
        startDate: '2026-08-30',
        endDate: '2026-09-02',
        rrule: 'FREQ=DAILY;INTERVAL=7',
      }),
    ];
    expect(allDayBusy(rows, FROM, TO)).toEqual([
      span('2026-09-01', '2026-09-02'),
      span('2026-09-06', '2026-09-08'),
    ]);
  });
});

describe('all-day Free/Busy expansion — WEEKLY', () => {
  // 2026-08-05 is a Wednesday; the Monday of its week is 2026-08-03.
  const WED_START = '2026-08-05';

  it('C3: FREQ=WEEKLY;BYDAY=WE', () => {
    const rows = [
      row({
        id: 'm',
        startDate: WED_START,
        endDate: '2026-08-06',
        rrule: 'FREQ=WEEKLY;BYDAY=WE',
      }),
    ];
    expect(allDayBusy(rows, FROM, TO)).toEqual([span('2026-09-02', '2026-09-03')]);
  });

  it('C4: FREQ=WEEKLY;BYDAY=MO,WE,FR', () => {
    const rows = [
      row({
        id: 'm',
        startDate: WED_START,
        endDate: '2026-08-06',
        rrule: 'FREQ=WEEKLY;BYDAY=MO,WE,FR',
      }),
    ];
    expect(allDayBusy(rows, FROM, TO)).toEqual([
      span('2026-09-02', '2026-09-03'),
      span('2026-09-04', '2026-09-05'),
      span('2026-09-07', '2026-09-08'),
    ]);
  });

  it('C5: INTERVAL=2 counts active weeks from DTSTART week (Monday anchor)', () => {
    // Anchor Monday 2026-08-03; active weeks 08-03, 08-17, 08-31, 09-14, ...
    // Wednesdays: 08-05, 08-19, 09-02, 09-16.
    const rows = [
      row({
        id: 'm',
        startDate: WED_START,
        endDate: '2026-08-06',
        rrule: 'FREQ=WEEKLY;INTERVAL=2;BYDAY=WE',
      }),
    ];
    expect(allDayBusy(rows, '2026-09-01', '2026-09-22')).toEqual([
      span('2026-09-02', '2026-09-03'),
      span('2026-09-16', '2026-09-17'),
    ]);
  });

  it('C5b: the same rule with INTERVAL=1 fires every week (guards the anchor maths)', () => {
    const rows = [
      row({
        id: 'm',
        startDate: WED_START,
        endDate: '2026-08-06',
        rrule: 'FREQ=WEEKLY;BYDAY=WE',
      }),
    ];
    expect(allDayBusy(rows, '2026-09-01', '2026-09-22')).toEqual([
      span('2026-09-02', '2026-09-03'),
      span('2026-09-09', '2026-09-10'),
      span('2026-09-16', '2026-09-17'),
    ]);
  });

  it('C6: BYDAY omitted falls back to the weekday of DTSTART', () => {
    const rows = [
      row({ id: 'm', startDate: WED_START, endDate: '2026-08-06', rrule: 'FREQ=WEEKLY' }),
    ];
    expect(allDayBusy(rows, FROM, TO)).toEqual([span('2026-09-02', '2026-09-03')]);
  });

  it('C7: in the DTSTART week, BYDAY days before DTSTART are skipped', () => {
    // DTSTART Wed 08-05; the Monday of that week (08-03) must NOT be emitted,
    // but the following Monday (08-10) must.
    const rows = [
      row({
        id: 'm',
        startDate: WED_START,
        endDate: '2026-08-06',
        rrule: 'FREQ=WEEKLY;BYDAY=MO,WE',
      }),
    ];
    expect(allDayBusy(rows, '2026-08-03', '2026-08-12')).toEqual([
      span('2026-08-05', '2026-08-06'),
      span('2026-08-10', '2026-08-11'),
    ]);
  });
});

describe('all-day Free/Busy expansion — exceptions', () => {
  const master = () =>
    row({ id: 'm', startDate: '2026-08-01', endDate: '2026-08-02', rrule: 'FREQ=DAILY' });

  it('C11: a moved exception detaches its slot and lands on its new date', () => {
    // Slot 09-03 is removed; the snapshot is a two-day event on 09-03..09-05.
    const rows = [
      master(),
      row({
        id: 'x',
        recurrenceId: 'm',
        recurrenceSlotDate: '2026-09-03',
        startDate: '2026-09-03',
        endDate: '2026-09-05',
      }),
    ];
    // Every other day still fires, so the whole window is busy either way; the
    // interesting part is that nothing is lost or double counted.
    expect(allDayBusy(rows, FROM, TO)).toEqual([span('2026-09-01', '2026-09-08')]);
  });

  it('C13: a slot moved OUT of the window leaves that day free', () => {
    // INTERVAL=3 so the neighbouring days are free and the hole is visible.
    const rows = [
      row({
        id: 'm',
        startDate: '2026-08-01',
        endDate: '2026-08-02',
        rrule: 'FREQ=DAILY;INTERVAL=3',
      }),
      row({
        id: 'x',
        recurrenceId: 'm',
        recurrenceSlotDate: '2026-09-03',
        startDate: '2026-10-01',
        endDate: '2026-10-02',
      }),
    ];
    // 09-03 detached and its snapshot is outside the window; only 09-06 remains.
    expect(allDayBusy(rows, FROM, TO)).toEqual([span('2026-09-06', '2026-09-07')]);
  });

  it('C12b: a slot moved INTO the window from outside adds busy there', () => {
    // The master itself contributes nothing here (it ends long before), but an
    // exception whose ORIGINAL slot is outside the window moved into it.
    const rows = [
      row({
        id: 'm',
        startDate: '2026-06-01',
        endDate: '2026-06-02',
        rrule: 'FREQ=DAILY;UNTIL=20260630',
      }),
      row({
        id: 'x',
        recurrenceId: 'm',
        recurrenceSlotDate: '2026-06-10',
        startDate: '2026-09-04',
        endDate: '2026-09-05',
      }),
    ];
    expect(allDayBusy(rows, FROM, TO)).toEqual([span('2026-09-04', '2026-09-05')]);
  });

  it('C14: a cancellation removes its slot and adds nothing', () => {
    const rows = [
      row({
        id: 'm',
        startDate: '2026-08-01',
        endDate: '2026-08-02',
        rrule: 'FREQ=DAILY;INTERVAL=3',
      }),
      row({
        id: 'x',
        recurrenceId: 'm',
        recurrenceSlotDate: '2026-09-03',
        startDate: '2026-09-03',
        endDate: '2026-09-04',
        isCancelled: true,
      }),
    ];
    expect(allDayBusy(rows, FROM, TO)).toEqual([span('2026-09-06', '2026-09-07')]);
  });

  /**
   * The counterpart to C12: the 2026-08-30 occurrence IS generated (it overlaps
   * the window), and the exception detaches it. Without the C12 fix this passed
   * for the wrong reason, because the occurrence was never generated at all.
   */
  it('C12c: a multi-day slot BEFORE the window still detaches an occurrence inside it', () => {
    const rows = [
      row({
        id: 'm',
        startDate: '2026-08-30',
        endDate: '2026-09-02',
        rrule: 'FREQ=DAILY;INTERVAL=7',
      }),
      row({
        id: 'x',
        recurrenceId: 'm',
        recurrenceSlotDate: '2026-08-30',
        startDate: '2026-11-01',
        endDate: '2026-11-04',
      }),
    ];
    expect(allDayBusy(rows, FROM, TO)).toEqual([span('2026-09-06', '2026-09-08')]);
  });
});

describe('all-day Free/Busy expansion — mixing with other rows', () => {
  it('C15: single all-day events merge with recurrence occurrences', () => {
    const rows = [
      row({
        id: 'm',
        startDate: '2026-08-01',
        endDate: '2026-08-02',
        rrule: 'FREQ=DAILY;INTERVAL=3',
      }), // 09-03, 09-06
      row({ id: 's', startDate: '2026-09-04', endDate: '2026-09-06' }), // single
    ];
    // 09-03..09-04 + 09-04..09-06 + 09-06..09-07 are adjacent -> one span.
    expect(allDayBusy(rows, FROM, TO)).toEqual([span('2026-09-03', '2026-09-07')]);
  });

  it('C16: timed rows never enter the all-day set', () => {
    const rows = [
      row({
        id: 'm',
        startDate: '2026-08-01',
        endDate: '2026-08-02',
        rrule: 'FREQ=DAILY;INTERVAL=3',
      }),
      row({
        id: 't',
        allDay: false,
        startAt: '2026-09-02T01:00:00.000Z',
        endAt: '2026-09-02T02:00:00.000Z',
      }),
    ];
    expect(allDayBusy(rows, FROM, TO)).toEqual([
      span('2026-09-03', '2026-09-04'),
      span('2026-09-06', '2026-09-07'),
    ]);
  });

  it('C17: an all-day series with no window overlap contributes nothing', () => {
    const rows = [
      row({
        id: 'm',
        startDate: '2026-01-01',
        endDate: '2026-01-02',
        rrule: 'FREQ=DAILY;UNTIL=20260131',
      }),
    ];
    expect(allDayBusy(rows, FROM, TO)).toEqual([]);
  });
});

describe('all-day Free/Busy expansion — helper sanity', () => {
  it('addDaysToDateString stays consistent with the half-open duration model', () => {
    // A one-day all-day event is [d, d+1); the SQL side computes the same span
    // as start_date + (end_date - start_date).
    expect(addDaysToDateString('2026-09-01', 1)).toBe('2026-09-02');
  });
});
