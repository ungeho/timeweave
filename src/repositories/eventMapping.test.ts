import { describe, expect, it } from 'vitest';
import type { EventDbRow } from './eventMapping';
import {
  eventPatchToColumns,
  eventToInsert,
  exceptionToInsert,
  rowToEvent,
} from './eventMapping';
import type { Availability, ExceptionInput, NewEvent, Visibility } from '../types/event';

/**
 * Reading tolerates a row written before the column existed; writing always
 * states the value.
 *
 * The write half inverts what Phase 1A asserted here, and deliberately: that
 * commit had to keep the key OUT of every payload because the production
 * database has no such column. From this commit it goes in, which is exactly
 * why the commit that introduced it must not be deployed until migration 0020
 * has added the column.
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
 * The write payloads now carry the field. Asserted on `Object.keys` as well as
 * on the value, because the bug being guarded in both directions is about the
 * key existing: `{ availability: undefined }` serialises a column name with no
 * value, which is neither omission nor a usable write.
 */
describe('write payloads carry availability', () => {
  /**
   * A timed one-off. The override type names the fields these tests vary
   * instead of Partial<NewEvent>, so the result still narrows to one arm of the
   * union and no cast is needed to hide a shape the repository would reject.
   */
  const timed = (
    over: { title?: string; availability?: Availability; visibility?: Visibility } = {},
  ): NewEvent => ({
    title: '定例会',
    allDay: false,
    startAt: '2026-08-24T00:00:00.000Z',
    endAt: '2026-08-24T01:00:00.000Z',
    ...over,
  });

  const exception = (
    availability: Availability,
    visibility: Visibility = 'private',
  ): ExceptionInput => ({
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
    visibility,
    availability,
  });

  it('eventToInsert defaults an unspecified availability to busy', () => {
    // The backward-compatibility rule: a caller that never heard of the field
    // writes what the app has always written.
    const insert = eventToInsert(timed());
    expect(Object.keys(insert)).toContain('availability');
    expect(insert.availability).toBe('busy');
  });

  it('eventToInsert carries an explicit availability', () => {
    expect(
      eventToInsert(timed({ availability: 'available' })).availability,
    ).toBe('available');
    expect(eventToInsert(timed({ availability: 'busy' })).availability).toBe('busy');
  });

  it('eventToInsert carries it on an all-day event too', () => {
    const allDay: NewEvent = {
      title: '',
      allDay: true,
      startDate: '2026-08-24',
      endDate: '2026-08-25',
      availability: 'available',
    };
    expect(eventToInsert(allDay).availability).toBe('available');
    // An untitled available event stores the empty string, never a label.
    expect(eventToInsert(allDay).title).toBe('');
  });

  it('eventToInsert carries it on a timed recurrence master', () => {
    const master: NewEvent = {
      title: '空き',
      allDay: false,
      startAt: '2026-08-24T09:00:00.000Z',
      endAt: '2026-08-24T13:00:00.000Z',
      rrule: 'FREQ=WEEKLY;BYDAY=TU',
      timezone: 'Asia/Tokyo',
      availability: 'available',
    };
    expect(eventToInsert(master).availability).toBe('available');
  });

  it('exceptionToInsert passes the builder’s value through, both ways', () => {
    expect(exceptionToInsert(exception('available')).availability).toBe('available');
    expect(exceptionToInsert(exception('busy')).availability).toBe('busy');
  });

  it('eventPatchToColumns maps it to the availability column', () => {
    const cols = eventPatchToColumns({ availability: 'available' });
    expect(Object.keys(cols)).toContain('availability');
    expect(cols.availability).toBe('available');
  });

  it('eventPatchToColumns still omits it from a patch that has no such key', () => {
    // recurrenceOps sends these two verbatim; neither should touch the column.
    expect(Object.keys(eventPatchToColumns({ isCancelled: true }))).not.toContain('availability');
    expect(Object.keys(eventPatchToColumns({ timezone: 'Asia/Tokyo' }))).not.toContain('availability');
  });
});

/**
 * visibility and availability are INDEPENDENT, and all six combinations are
 * legal -- private+available included.
 *
 * Pinned explicitly because the pair reads like it ought to have a rule. It
 * does not. `visibility` decides how much a share link may disclose,
 * `availability` decides whether the time is open, and a private available
 * event is a coherent thing to store: open time the owner is willing to publish
 * only through links that are trusted with their private events. Whether it
 * ever reaches an anonymous viewer is decided downstream, by the link's
 * include_private and share_available and by 0024's own filtering -- never by
 * refusing to store the row.
 */
describe('visibility and availability are independent on the write paths', () => {
  const VISIBILITIES: Visibility[] = ['private', 'busy_only', 'public'];
  const AVAILABILITIES: Availability[] = ['busy', 'available'];

  const timedWith = (visibility: Visibility, availability: Availability): NewEvent => ({
    title: '予定', allDay: false,
    startAt: '2026-08-24T00:00:00.000Z', endAt: '2026-08-24T01:00:00.000Z',
    visibility, availability,
  });

  const exception = (availability: Availability, visibility: Visibility): ExceptionInput => ({
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
    visibility,
    availability,
  });

  it('eventToInsert writes every one of the six combinations', () => {
    for (const v of VISIBILITIES) {
      for (const a of AVAILABILITIES) {
        const insert = eventToInsert(timedWith(v, a));
        expect(insert.visibility).toBe(v);
        expect(insert.availability).toBe(a);
      }
    }
  });

  it('eventToInsert writes private+available, the combination that looks special', () => {
    const insert = eventToInsert(timedWith('private', 'available'));
    expect(insert.visibility).toBe('private');
    expect(insert.availability).toBe('available');
  });

  it('eventToInsert defaults to private+busy, and an available event keeps that private default', () => {
    // Omitting visibility means 'private'. An input that asks only for
    // availability therefore produces private+available, and must still write.
    const defaulted = eventToInsert({
      title: '空き', allDay: false,
      startAt: '2026-08-24T00:00:00.000Z', endAt: '2026-08-24T01:00:00.000Z',
      availability: 'available',
    });
    expect(defaulted.visibility).toBe('private');
    expect(defaulted.availability).toBe('available');
  });

  it('exceptionToInsert carries every combination through', () => {
    for (const v of VISIBILITIES) {
      for (const a of AVAILABILITIES) {
        const insert = exceptionToInsert(exception(a, v));
        expect(insert.visibility).toBe(v);
        expect(insert.availability).toBe(a);
      }
    }
  });

  it('eventPatchToColumns maps both columns, in every combination', () => {
    for (const v of VISIBILITIES) {
      for (const a of AVAILABILITIES) {
        const cols = eventPatchToColumns({ visibility: v, availability: a });
        expect(cols.visibility).toBe(v);
        expect(cols.availability).toBe(a);
      }
    }
  });

  it('eventPatchToColumns moves ONE of the two without the other', () => {
    // An edit that only changes the visibility of an available event, and one
    // that only makes a private event available. Neither needs the other key.
    expect(eventPatchToColumns({ visibility: 'private' })).toEqual({ visibility: 'private' });
    expect(eventPatchToColumns({ availability: 'available' })).toEqual({ availability: 'available' });
  });

  it('rowToEvent reads a stored private+available row back unchanged', () => {
    const row = rowToEvent(dbRow({ visibility: 'private', availability: 'available' }));
    expect(row.visibility).toBe('private');
    expect(row.availability).toBe('available');
  });
});
