import { describe, expect, it } from 'vitest';
import type { EventRow } from '../types/event';
import { expandEvents, normalizedSlotKey } from './occurrences';
import { expandRule } from './recurrence';

/** A timed one-off base row; override per test. */
const base = (over: Partial<EventRow>): EventRow => ({
  id: 'x',
  ownerId: 'u',
  title: 't',
  description: null,
  category: null,
  visibility: 'private',
  allDay: false,
  startAt: new Date(2026, 7, 3, 10).toISOString(),
  endAt: new Date(2026, 7, 3, 11).toISOString(),
  startDate: null,
  endDate: null,
  rrule: null,
  recurrenceId: null,
  recurrenceSlotStart: null,
  recurrenceSlotDate: null,
  isCancelled: false,
  timezone: null,
  createdAt: '2026-01-01T00:00:00.000Z',
  updatedAt: '2026-01-01T00:00:00.000Z',
  ...over,
});

const range = {
  start: new Date(2026, 7, 1).toISOString(),
  end: new Date(2026, 8, 1).toISOString(),
};

describe('expandEvents — one-off', () => {
  it('includes timed events overlapping the range', () => {
    const occ = expandEvents([base({ id: 'a' })], range.start, range.end);
    expect(occ).toHaveLength(1);
    expect(occ[0]!.event.id).toBe('a');
    expect(occ[0]!.isException).toBe(false);
  });

  it('excludes events outside the range', () => {
    const rows = [
      base({
        startAt: new Date(2025, 0, 1, 10).toISOString(),
        endAt: new Date(2025, 0, 1, 11).toISOString(),
      }),
    ];
    expect(expandEvents(rows, range.start, range.end)).toHaveLength(0);
  });

  it('includes an all-day event on its start day', () => {
    const rows = [
      base({
        id: 'ad',
        allDay: true,
        startAt: null,
        endAt: null,
        startDate: '2026-08-15',
        endDate: '2026-08-16', // exclusive
      }),
    ];
    const occ = expandEvents(rows, range.start, range.end);
    expect(occ).toHaveLength(1);
    expect(occ[0]!.allDay).toBe(true);
    // start is local midnight of 2026-08-15
    expect(new Date(occ[0]!.start).getDate()).toBe(15);
  });
});

describe('expandEvents — recurring', () => {
  it('expands a weekly master and preserves duration', () => {
    const rows = [base({ id: 'm', rrule: 'FREQ=WEEKLY;BYDAY=MO' })];
    const occ = expandEvents(rows, range.start, range.end);
    // Mondays in Aug 2026: 3,10,17,24,31
    expect(occ).toHaveLength(5);
    const durationMs = new Date(occ[0]!.end).getTime() - new Date(occ[0]!.start).getTime();
    expect(durationMs).toBe(60 * 60 * 1000);
  });

  it('drops an occurrence cancelled by a tombstone exception (timed)', () => {
    const slot = new Date(2026, 7, 10, 10).toISOString();
    const rows = [
      base({ id: 'm', rrule: 'FREQ=WEEKLY;BYDAY=MO' }),
      base({
        id: 'cancel',
        recurrenceId: 'm',
        recurrenceSlotStart: slot,
        isCancelled: true,
      }),
    ];
    const occ = expandEvents(rows, range.start, range.end);
    expect(occ).toHaveLength(4);
    expect(occ.map((o) => o.start)).not.toContain(slot);
  });

  it('replaces an occurrence with a moved exception (timed)', () => {
    const slot = new Date(2026, 7, 10, 10).toISOString();
    const moved = new Date(2026, 7, 10, 15).toISOString();
    const rows = [
      base({ id: 'm', rrule: 'FREQ=WEEKLY;BYDAY=MO' }),
      base({
        id: 'ex',
        recurrenceId: 'm',
        recurrenceSlotStart: slot,
        startAt: moved,
        endAt: new Date(2026, 7, 10, 16).toISOString(),
      }),
    ];
    const occ = expandEvents(rows, range.start, range.end);
    expect(occ).toHaveLength(5); // 4 generated (slot removed) + 1 exception
    const exception = occ.find((o) => o.isException);
    expect(exception?.start).toBe(moved);
    expect(occ.filter((o) => !o.isException).map((o) => o.start)).not.toContain(slot);
  });

  // The exact R2 defect: the exception's recurrence_slot_start comes back from a
  // Postgres timestamptz in a different ISO textual form than the expander emits.
  const zForm = new Date(2026, 7, 10, 10).toISOString(); // "...T..:00:00.000Z"
  const offsetForm = zForm.replace('.000Z', '+00:00'); // DB round-trip: +00:00, no ms
  const noMsZForm = zForm.replace('.000Z', 'Z'); // Z but milliseconds omitted

  it('replaces the original occurrence when the slot is a DB timestamptz form (+00:00, no ms)', () => {
    const moved = new Date(2026, 7, 10, 15).toISOString();
    const rows = [
      base({ id: 'm', rrule: 'FREQ=WEEKLY;BYDAY=MO' }),
      base({
        id: 'ex',
        recurrenceId: 'm',
        recurrenceSlotStart: offsetForm, // differs textually from zForm, same instant
        startAt: moved,
        endAt: new Date(2026, 7, 10, 16).toISOString(),
      }),
    ];
    const occ = expandEvents(rows, range.start, range.end);
    expect(occ).toHaveLength(5); // original removed, moved shown — not both
    expect(occ.filter((o) => !o.isException).map((o) => o.start)).not.toContain(zForm);
    expect(occ.find((o) => o.isException)?.start).toBe(moved);
  });

  it('cancels the original occurrence when the tombstone slot is a +00:00 form', () => {
    const rows = [
      base({ id: 'm', rrule: 'FREQ=WEEKLY;BYDAY=MO' }),
      base({ id: 'cancel', recurrenceId: 'm', recurrenceSlotStart: offsetForm, isCancelled: true }),
    ];
    const occ = expandEvents(rows, range.start, range.end);
    expect(occ).toHaveLength(4);
    expect(occ.map((o) => o.start)).not.toContain(zForm);
  });

  it('matches even when milliseconds are omitted (…:00Z)', () => {
    const rows = [
      base({ id: 'm', rrule: 'FREQ=WEEKLY;BYDAY=MO' }),
      base({ id: 'cancel', recurrenceId: 'm', recurrenceSlotStart: noMsZForm, isCancelled: true }),
    ];
    const occ = expandEvents(rows, range.start, range.end);
    expect(occ).toHaveLength(4);
  });

  it('does not drop occurrences for a slot at a different instant', () => {
    const otherInstant = new Date(2026, 7, 11, 10).toISOString(); // Tuesday, not an occurrence
    const rows = [
      base({ id: 'm', rrule: 'FREQ=WEEKLY;BYDAY=MO' }),
      base({ id: 'cancel', recurrenceId: 'm', recurrenceSlotStart: otherInstant, isCancelled: true }),
    ];
    const occ = expandEvents(rows, range.start, range.end);
    expect(occ).toHaveLength(5); // nothing detached
  });

  it('expands an all-day weekly master to distinct days (R7: not collapsed)', () => {
    const rows = [
      base({
        id: 'm', allDay: true, startAt: null, endAt: null,
        startDate: '2026-08-31', endDate: '2026-09-01',
        rrule: 'FREQ=WEEKLY;BYDAY=MO;UNTIL=20260928',
      }),
    ];
    const start = new Date(2026, 7, 31).toISOString();
    const end = new Date(2026, 9, 5).toISOString(); // Oct 5
    const occ = expandEvents(rows, start, end);
    expect(occ.map((o) => o.occurrenceKey)).toEqual([
      '2026-08-31', '2026-09-07', '2026-09-14', '2026-09-21', '2026-09-28',
    ]);
    // Each instance's own start/end differ (per-week), not the master's fixed dates.
    expect(new Set(occ.map((o) => o.start)).size).toBe(5);
  });

  it('drops an all-day occurrence by its date slot (string compare preserved)', () => {
    const rows = [
      base({
        id: 'm', allDay: true, startAt: null, endAt: null,
        startDate: '2026-08-03', endDate: '2026-08-04', rrule: 'FREQ=WEEKLY;BYDAY=MO',
      }),
      base({
        id: 'cancel', allDay: true, startAt: null, endAt: null,
        startDate: '2026-08-10', endDate: '2026-08-11',
        recurrenceId: 'm', recurrenceSlotDate: '2026-08-10', isCancelled: true,
      }),
    ];
    const occ = expandEvents(rows, range.start, range.end);
    // Mondays 3,10,17,24,31 minus the cancelled 10 => 4.
    expect(occ).toHaveLength(4);
    expect(occ.map((o) => o.occurrenceKey)).not.toContain('2026-08-10');
  });
});

/**
 * A recurring occurrence is a SPAN, so range membership is a half-open OVERLAP
 * test -- occurrenceStart < rangeEnd && occurrenceEnd > rangeStart -- not
 * "does the start fall inside the range".
 *
 * Before this was fixed, expandEvents asked the expander only for starts inside
 * the range, so a multi-day recurring event that began before the range and ran
 * into it disappeared. On a shared Free/Busy page that reads as free time where
 * the owner is busy, which is why the boundaries below are pinned explicitly.
 */
describe('expandEvents — recurring occurrence range overlap', () => {
  // A 3-day timed series repeating every 7 days from 2026-08-30 10:00 local.
  const multiDay = (over: Partial<EventRow> = {}): EventRow =>
    base({
      id: 'm',
      startAt: new Date(2026, 7, 30, 10).toISOString(),
      endAt: new Date(2026, 8, 2, 10).toISOString(), // +3 days
      rrule: 'FREQ=DAILY;INTERVAL=7',
      ...over,
    });

  it('includes an occurrence that starts before the range and runs into it', () => {
    const occ = expandEvents(
      [multiDay()],
      new Date(2026, 8, 1).toISOString(), // range starts mid-occurrence
      new Date(2026, 8, 4).toISOString(),
    );
    expect(occ).toHaveLength(1);
    expect(occ[0]!.start).toBe(new Date(2026, 7, 30, 10).toISOString());
    // The occurrence keeps its true span; clipping is the caller's job.
    expect(occ[0]!.end).toBe(new Date(2026, 8, 2, 10).toISOString());
  });

  it('excludes an occurrence whose end lands exactly on the range start', () => {
    // Occurrence [08-30 10:00, 09-02 10:00); range begins exactly at its end.
    const occ = expandEvents(
      [multiDay()],
      new Date(2026, 8, 2, 10).toISOString(),
      new Date(2026, 8, 4).toISOString(),
    );
    expect(occ).toHaveLength(0);
  });

  it('excludes an occurrence whose start lands exactly on the range end', () => {
    const occ = expandEvents(
      [multiDay()],
      new Date(2026, 7, 20).toISOString(),
      new Date(2026, 7, 30, 10).toISOString(), // exclusive end == occurrence start
    );
    expect(occ).toHaveLength(0);
  });

  it('includes an occurrence lying entirely inside the range', () => {
    const occ = expandEvents(
      [multiDay()],
      new Date(2026, 7, 29).toISOString(),
      new Date(2026, 8, 3).toISOString(),
    );
    expect(occ).toHaveLength(1);
    expect(occ[0]!.start).toBe(new Date(2026, 7, 30, 10).toISOString());
  });

  it('includes an occurrence that covers the whole range', () => {
    const occ = expandEvents(
      [multiDay()],
      new Date(2026, 7, 31).toISOString(),
      new Date(2026, 8, 1).toISOString(), // strictly inside the 3-day occurrence
    );
    expect(occ).toHaveLength(1);
    expect(occ[0]!.start).toBe(new Date(2026, 7, 30, 10).toISOString());
  });

  it('still detaches a pre-range occurrence when an exception replaces its slot', () => {
    const master = multiDay();
    const exception = base({
      id: 'x',
      recurrenceId: 'm',
      recurrenceSlotStart: new Date(2026, 7, 30, 10).toISOString(),
      startAt: new Date(2026, 9, 1, 10).toISOString(), // moved far outside
      endAt: new Date(2026, 9, 1, 11).toISOString(),
    });
    const occ = expandEvents(
      [master, exception],
      new Date(2026, 8, 1).toISOString(),
      new Date(2026, 8, 4).toISOString(),
    );
    // The pre-range occurrence is generated, then removed by the exception; the
    // exception's own snapshot is outside the range, so nothing remains.
    expect(occ).toHaveLength(0);
  });

  it('applies the same overlap rule to all-day multi-day recurrences', () => {
    const allDayMaster = base({
      id: 'a',
      allDay: true,
      startAt: null,
      endAt: null,
      startDate: '2026-08-30',
      endDate: '2026-09-02', // 3 days
      rrule: 'FREQ=DAILY;INTERVAL=7',
    });
    const occ = expandEvents(
      [allDayMaster],
      new Date(2026, 8, 1).toISOString(),
      new Date(2026, 8, 4).toISOString(),
    );
    expect(occ).toHaveLength(1);
    expect(occ[0]!.occurrenceKey).toBe('2026-08-30');
  });
});

describe('normalizedSlotKey', () => {
  it('treats different ISO forms of one instant as equal (timed)', () => {
    const z = '2026-09-14T00:00:00.000Z';
    const offset = '2026-09-14T00:00:00+00:00';
    const noMs = '2026-09-14T00:00:00Z';
    const a = normalizedSlotKey(z, false);
    expect(a).not.toBeNull();
    expect(normalizedSlotKey(offset, false)).toBe(a);
    expect(normalizedSlotKey(noMs, false)).toBe(a);
  });

  it('keeps different instants distinct', () => {
    expect(normalizedSlotKey('2026-09-14T00:00:00.000Z', false))
      .not.toBe(normalizedSlotKey('2026-09-14T01:00:00.000Z', false));
  });

  it('returns null for a missing or unparseable timed value (never a silent collision)', () => {
    expect(normalizedSlotKey(null, false)).toBeNull();
    expect(normalizedSlotKey('not-a-date', false)).toBeNull();
  });

  it('compares all-day keys verbatim as YYYY-MM-DD', () => {
    expect(normalizedSlotKey('2026-09-14', true)).toBe('2026-09-14');
    expect(normalizedSlotKey('2026-09-14', true)).not.toBe(normalizedSlotKey('2026-09-15', true));
  });
});

/**
 * Phase 5b-4 — the zone reaches the expander from the ROW.
 *
 * `expandEvents` keeps its signature: the zone a timed master is anchored to
 * lives on the row (`events.timezone`), not on the view, so it is read here
 * rather than threaded down from the calendar. These cases pin that wiring, and
 * the boundaries around it — all-day, and legacy M0.
 *
 * Instants are explicit UTC, so nothing below depends on the runtime's zone.
 * (Every OTHER test in this file builds rows with `timezone: null`, which makes
 * the whole existing suite the M0 regression suite for this change.)
 */
describe('expandEvents — zone-anchored masters (5b-4)', () => {
  const NY = 'America/New_York';
  const dstRange = { start: '2026-10-29T00:00:00.000Z', end: '2026-11-03T00:00:00.000Z' };

  /** A DAILY master at 01:30 New York, i.e. straight through the autumn fold. */
  const nyMaster = (over: Partial<EventRow> = {}): EventRow =>
    base({
      id: 'm',
      startAt: '2026-10-30T05:30:00.000Z', // 01:30 EDT
      endAt: '2026-10-30T06:30:00.000Z',
      rrule: 'FREQ=DAILY',
      timezone: NY,
      ...over,
    });

  it('C1 expands a master in ITS zone, resolving the fold the way 0009 does', () => {
    const occ = expandEvents([nyMaster()], dstRange.start, dstRange.end);
    expect(occ.map((o) => o.start)).toEqual([
      '2026-10-30T05:30:00.000Z', // 01:30 EDT (DTSTART, emitted verbatim)
      '2026-10-31T05:30:00.000Z', // 01:30 EDT
      '2026-11-01T06:30:00.000Z', // 01:30 EST — the LATER of the two 01:30s
      '2026-11-02T06:30:00.000Z', // 01:30 EST
    ]);
    // The occurrence key an exception would be pinned to is that same instant.
    expect(occ[2]!.occurrenceKey).toBe('2026-11-01T06:30:00.000Z');
  });

  it('C2 leaves a legacy M0 master (timezone null) on the local-time path', () => {
    const row = nyMaster({ timezone: null });
    const occ = expandEvents([row], dstRange.start, dstRange.end);
    // Identical to asking the expander directly with no zone. `expandEvents`
    // widens the window left by the duration before expanding, so the same
    // widening is applied here.
    const durationMs = Date.parse(row.endAt!) - Date.parse(row.startAt!);
    const expected = expandRule(
      row.rrule!,
      row.startAt!,
      new Date(Date.parse(dstRange.start) - durationMs).toISOString(),
      dstRange.end,
    );
    expect(occ.map((o) => o.start)).toEqual(expected);
  });

  it('C3 never lets a zone reach the all-day path', () => {
    // The database forbids a zone on an all-day row (events_timezone_placement),
    // so this shape is defensive: even if one appeared, all-day expansion is
    // pure date arithmetic and must be bit-for-bit what it was before 5b-4.
    const allDay = (timezone: string | null): EventRow =>
      base({
        id: 'a',
        allDay: true,
        startAt: null,
        endAt: null,
        startDate: '2026-11-01',
        endDate: '2026-11-02',
        rrule: 'FREQ=DAILY',
        timezone,
      });
    const from = new Date(2026, 10, 1).toISOString();
    const to = new Date(2026, 10, 4).toISOString();

    const withZone = expandEvents([allDay(NY)], from, to);
    const withoutZone = expandEvents([allDay(null)], from, to);
    expect(withZone.map((o) => o.start)).toEqual(withoutZone.map((o) => o.start));
    expect(withZone.map((o) => o.occurrenceKey)).toEqual(['2026-11-01', '2026-11-02', '2026-11-03']);
  });

  it('C4 detaches an exception whose slot matches the newly generated instant', () => {
    const ex = base({
      id: 'x',
      recurrenceId: 'm',
      recurrenceSlotStart: '2026-11-01T06:30:00.000Z', // what C1 now generates
      startAt: '2026-11-01T10:00:00.000Z',
      endAt: '2026-11-01T11:00:00.000Z',
      isCancelled: false,
    });
    const occ = expandEvents([nyMaster(), ex], dstRange.start, dstRange.end);
    expect(occ.map((o) => o.start)).toEqual([
      '2026-10-30T05:30:00.000Z',
      '2026-10-31T05:30:00.000Z',
      '2026-11-01T10:00:00.000Z', // the override, in place of the 06:30Z slot
      '2026-11-02T06:30:00.000Z',
    ]);
    expect(occ.filter((o) => o.isException)).toHaveLength(1);
  });

  it('C5 does NOT rescue a slot written by the pre-5b-4 expander (case C is out of scope)', () => {
    // A slot recorded before this change may name the EARLIER instant of a fold
    // (05:30Z here). Nothing generates that any more, so the original occurrence
    // is not detached and the day shows both rows. Rescuing those keys was
    // deliberately excluded from 5b-4; this test states the consequence rather
    // than hiding it.
    const stale = base({
      id: 'x',
      recurrenceId: 'm',
      recurrenceSlotStart: '2026-11-01T05:30:00.000Z', // pre-5b-4 value
      startAt: '2026-11-01T10:00:00.000Z',
      endAt: '2026-11-01T11:00:00.000Z',
      isCancelled: false,
    });
    const occ = expandEvents([nyMaster(), stale], dstRange.start, dstRange.end);
    expect(occ.map((o) => o.start)).toEqual([
      '2026-10-30T05:30:00.000Z',
      '2026-10-31T05:30:00.000Z',
      '2026-11-01T06:30:00.000Z', // still there: the slot key no longer matches
      '2026-11-01T10:00:00.000Z',
      '2026-11-02T06:30:00.000Z',
    ]);
  });
});
