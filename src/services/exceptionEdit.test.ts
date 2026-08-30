import { describe, expect, it } from 'vitest';
import type { EventOccurrence, EventRow, NewEvent } from '../types/event';
import {
  buildCancellation,
  buildException,
  exceptionPatchFromEdit,
  masterPatchFromEdit,
  occurrenceSlot,
} from './exceptionEdit';

function master(over: Partial<EventRow> = {}): EventRow {
  return {
    id: 'm', ownerId: 'u', title: '定例会', description: 'メモ', category: '仕事',
    visibility: 'busy_only', allDay: false,
    startAt: '2026-08-24T00:00:00.000Z', endAt: '2026-08-24T01:00:00.000Z',
    startDate: null, endDate: null, rrule: 'FREQ=WEEKLY;BYDAY=MO',
    recurrenceId: null, recurrenceSlotStart: null, recurrenceSlotDate: null,
    isCancelled: false, createdAt: '2026-01-01T00:00:00.000Z', updatedAt: '2026-01-01T00:00:00.000Z',
    ...over,
  };
}

const timedOcc = (m: EventRow, startIso: string, endIso: string): EventOccurrence => ({
  event: m, start: startIso, end: endIso, allDay: false, occurrenceKey: startIso, isException: false,
});

const allDayOcc = (m: EventRow, dayKey: string): EventOccurrence => ({
  event: m, start: `${dayKey}T00:00:00.000Z`, end: `${dayKey}T00:00:00.000Z`,
  allDay: true, occurrenceKey: dayKey, isException: false,
});

describe('occurrenceSlot', () => {
  it('keys a timed occurrence by slot start', () => {
    expect(occurrenceSlot(timedOcc(master(), '2026-08-31T00:00:00.000Z', '2026-08-31T01:00:00.000Z')))
      .toEqual({ recurrenceSlotStart: '2026-08-31T00:00:00.000Z', recurrenceSlotDate: null });
  });
  it('keys an all-day occurrence by slot date', () => {
    const m = master({ allDay: true, startAt: null, endAt: null, startDate: '2026-08-24', endDate: '2026-08-25' });
    expect(occurrenceSlot(allDayOcc(m, '2026-08-31')))
      .toEqual({ recurrenceSlotStart: null, recurrenceSlotDate: '2026-08-31' });
  });
});

describe('buildCancellation', () => {
  it('builds a timed tombstone with the master display fields', () => {
    const occ = timedOcc(master(), '2026-08-31T00:00:00.000Z', '2026-08-31T01:00:00.000Z');
    expect(buildCancellation(occ)).toEqual({
      recurrenceId: 'm',
      recurrenceSlotStart: '2026-08-31T00:00:00.000Z',
      recurrenceSlotDate: null,
      isCancelled: true,
      allDay: false,
      startAt: '2026-08-31T00:00:00.000Z',
      endAt: '2026-08-31T01:00:00.000Z',
      startDate: null,
      endDate: null,
      title: '定例会', description: 'メモ', category: '仕事', visibility: 'busy_only',
    });
  });

  it('builds an all-day tombstone with a valid exclusive-end date', () => {
    const m = master({ allDay: true, startAt: null, endAt: null, startDate: '2026-08-24', endDate: '2026-08-25' });
    const c = buildCancellation(allDayOcc(m, '2026-08-31'));
    expect(c).toMatchObject({
      allDay: true, recurrenceSlotDate: '2026-08-31', recurrenceSlotStart: null,
      startDate: '2026-08-31', endDate: '2026-09-01', startAt: null, endAt: null, isCancelled: true,
    });
  });
});

describe('buildException', () => {
  it('carries edited fields but points at the original slot', () => {
    const occ = timedOcc(master(), '2026-08-31T00:00:00.000Z', '2026-08-31T01:00:00.000Z');
    const edited: NewEvent = {
      title: '定例会（変更）', description: null, category: '仕事', visibility: 'private',
      allDay: false, startAt: '2026-08-31T06:00:00.000Z', endAt: '2026-08-31T07:00:00.000Z',
    };
    expect(buildException(occ, edited)).toEqual({
      recurrenceId: 'm',
      recurrenceSlotStart: '2026-08-31T00:00:00.000Z', // ORIGINAL slot, not the moved time
      recurrenceSlotDate: null,
      isCancelled: false,
      allDay: false,
      startAt: '2026-08-31T06:00:00.000Z',
      endAt: '2026-08-31T07:00:00.000Z',
      startDate: null, endDate: null,
      title: '定例会（変更）', description: null, category: '仕事', visibility: 'private',
    });
  });

  it('rejects changing the all-day setting of a single occurrence', () => {
    const occ = timedOcc(master(), '2026-08-31T00:00:00.000Z', '2026-08-31T01:00:00.000Z');
    const edited: NewEvent = { title: 'x', allDay: true, startDate: '2026-08-31', endDate: '2026-09-01' };
    expect(() => buildException(occ, edited)).toThrow(/all-day/);
  });
});

describe('masterPatchFromEdit', () => {
  it('carries the rrule and timed fields, clearing all-day columns', () => {
    const edited: NewEvent = {
      title: '定例会（改）', description: null, category: '仕事', visibility: 'public',
      allDay: false, startAt: '2026-08-24T02:00:00.000Z', endAt: '2026-08-24T03:00:00.000Z',
      rrule: 'FREQ=WEEKLY;BYDAY=TU',
    };
    expect(masterPatchFromEdit(edited)).toEqual({
      title: '定例会（改）', description: null, category: '仕事', visibility: 'public',
      rrule: 'FREQ=WEEKLY;BYDAY=TU',
      allDay: false, startAt: '2026-08-24T02:00:00.000Z', endAt: '2026-08-24T03:00:00.000Z',
      startDate: null, endDate: null,
    });
  });

  it('clears rrule to null when recurrence is removed', () => {
    const edited: NewEvent = {
      title: 'x', allDay: false, startAt: '2026-08-24T00:00:00.000Z', endAt: '2026-08-24T01:00:00.000Z',
    };
    expect(masterPatchFromEdit(edited).rrule).toBeNull();
  });
});

describe('exceptionPatchFromEdit', () => {
  it('updates display/time fields but never touches recurrence identity or rrule', () => {
    const occ = timedOcc(master(), '2026-08-31T00:00:00.000Z', '2026-08-31T01:00:00.000Z');
    const edited: NewEvent = {
      title: '個別変更', description: 'x', category: null, visibility: 'private',
      allDay: false, startAt: '2026-08-31T05:00:00.000Z', endAt: '2026-08-31T06:00:00.000Z',
    };
    const patch = exceptionPatchFromEdit(occ, edited);
    expect(patch).toEqual({
      title: '個別変更', description: 'x', category: null, visibility: 'private',
      isCancelled: false,
      allDay: false, startAt: '2026-08-31T05:00:00.000Z', endAt: '2026-08-31T06:00:00.000Z',
      startDate: null, endDate: null,
    });
    expect('rrule' in patch).toBe(false);
    expect('recurrenceId' in patch).toBe(false);
    expect('recurrenceSlotStart' in patch).toBe(false);
  });

  it('rejects changing all-day-ness of an existing exception', () => {
    const occ = timedOcc(master(), '2026-08-31T00:00:00.000Z', '2026-08-31T01:00:00.000Z');
    const edited: NewEvent = { title: 'x', allDay: true, startDate: '2026-08-31', endDate: '2026-09-01' };
    expect(() => exceptionPatchFromEdit(occ, edited)).toThrow(/all-day/);
  });
});
