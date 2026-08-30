import { describe, expect, it } from 'vitest';
import type { EventRow } from '../types/event';
import { expandEvents, normalizedSlotKey } from './occurrences';

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
