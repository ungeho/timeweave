import { describe, expect, it } from 'vitest';
import type { EventDbRow } from './eventMapping';
import {
  eventPatchToColumns,
  eventToInsert,
  exceptionToInsert,
  rowToEvent,
} from './eventMapping';
import type { ExceptionInput, NewEvent } from '../types/event';

/**
 * These cover the two halves of adding `availability` ahead of its column:
 * reading tolerates its absence, and writing must not mention it at all.
 *
 * The write half is the one that matters operationally. The production database
 * has no `availability` column, so a payload that names it is rejected outright
 * and every save in the app fails. Until the migration lands, "the key is never
 * in the payload" is a property to assert, not a convention to remember.
 */

/** A row as PostgREST returns it TODAY: no `availability` key at all. */
const dbRow = (over: Partial<EventDbRow> = {}): EventDbRow => ({
  id: 'r1',
  owner_id: 'u1',
  title: '定例会',
  description: null,
  category: null,
  visibility: 'private',
  all_day: false,
  start_at: '2026-08-24T00:00:00.000Z',
  end_at: '2026-08-24T01:00:00.000Z',
  start_date: null,
  end_date: null,
  rrule: null,
  recurrence_id: null,
  recurrence_slot_start: null,
  recurrence_slot_date: null,
  is_cancelled: false,
  timezone: null,
  created_at: '2026-01-01T00:00:00.000Z',
  updated_at: '2026-01-01T00:00:00.000Z',
  ...over,
});

describe('rowToEvent: availability', () => {
  it('reads a row that has no availability column as busy', () => {
    expect(rowToEvent(dbRow()).availability).toBe('busy');
  });

  it('keeps the value once the column exists', () => {
    expect(rowToEvent(dbRow({ availability: 'available' })).availability).toBe('available');
    expect(rowToEvent(dbRow({ availability: 'busy' })).availability).toBe('busy');
  });

  it('changes nothing else about a legacy row', () => {
    const row = rowToEvent(dbRow());
    expect(row.title).toBe('定例会');
    expect(row.visibility).toBe('private');
    expect(row.timezone).toBeNull();
  });
});

/**
 * The safety invariant of this commit. Written against `Object.keys` rather
 * than a value, because the failure being guarded is a key existing at all --
 * `{ availability: undefined }` would still be serialised as a column name.
 */
describe('write payloads do not name the availability column', () => {
  const newTimed: NewEvent = {
    title: '定例会',
    allDay: false,
    startAt: '2026-08-24T00:00:00.000Z',
    endAt: '2026-08-24T01:00:00.000Z',
  };
  const newAllDay: NewEvent = {
    title: '休暇',
    allDay: true,
    startDate: '2026-08-24',
    endDate: '2026-08-25',
  };
  const newMaster: NewEvent = {
    title: '定例会',
    allDay: false,
    startAt: '2026-08-24T00:00:00.000Z',
    endAt: '2026-08-24T01:00:00.000Z',
    rrule: 'FREQ=WEEKLY;BYDAY=MO',
    timezone: 'Asia/Tokyo',
  };
  const exception: ExceptionInput = {
    recurrenceId: 'm',
    recurrenceSlotStart: '2026-08-31T00:00:00.000Z',
    recurrenceSlotDate: null,
    isCancelled: false,
    allDay: false,
    startAt: '2026-08-31T06:00:00.000Z',
    endAt: '2026-08-31T07:00:00.000Z',
    startDate: null,
    endDate: null,
    title: '個別変更',
    description: null,
    category: null,
    visibility: 'private',
  };

  it.each([
    ['a timed one-off', newTimed],
    ['an all-day event', newAllDay],
    ['a timed recurrence master', newMaster],
  ] as const)('eventToInsert omits it for %s', (_label, input) => {
    expect(Object.keys(eventToInsert(input))).not.toContain('availability');
  });

  it('exceptionToInsert omits it', () => {
    expect(Object.keys(exceptionToInsert(exception))).not.toContain('availability');
  });

  it('eventPatchToColumns omits it for every patch the app builds', () => {
    // The shapes recurrenceOps and exceptionEdit actually produce.
    const patches = [
      { title: '変更後', description: null, category: null, visibility: 'private' as const },
      { isCancelled: true },
      { timezone: 'Asia/Tokyo' },
      { allDay: false, startAt: 'a', endAt: 'b', startDate: null, endDate: null },
    ];
    for (const p of patches) {
      expect(Object.keys(eventPatchToColumns(p))).not.toContain('availability');
    }
  });

  it('would send the column if a patch ever carried the field', () => {
    // Not a wish -- a statement of how the generic patch mapper works, and the
    // reason exceptionEdit.ts is untouched by this commit. When the column
    // exists this becomes the mechanism; until then it is the hazard.
    expect(Object.keys(eventPatchToColumns({ availability: 'available' })))
      .toContain('availability');
  });
});
