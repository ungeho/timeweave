import { describe, expect, it } from 'vitest';
import type { EventEditInput, EventRow, EventOccurrence } from '../types/event';
import { SeriesEditBlockedError, TimezoneClearedError, TimezoneRequiredError } from '../errors';
import { editTimezoneIntent } from './timezoneRules';
import {
  buildCancellation,
  buildException,
  exceptionPatchFromEdit,
  occurrenceSlot,
  rowPatchFromEdit,
} from './exceptionEdit';

/** A timed recurrence master. `timezone: null` = M0, the legacy pre-5b-2 state. */
function master(over: Partial<EventRow> = {}): EventRow {
  return {
    id: 'm', ownerId: 'u', title: '定例会', description: 'メモ', category: '仕事',
    visibility: 'busy_only', allDay: false,
    startAt: '2026-08-24T00:00:00.000Z', endAt: '2026-08-24T01:00:00.000Z',
    startDate: null, endDate: null, rrule: 'FREQ=WEEKLY;BYDAY=MO',
    recurrenceId: null, recurrenceSlotStart: null, recurrenceSlotDate: null,
    isCancelled: false, timezone: null,
    createdAt: '2026-01-01T00:00:00.000Z', updatedAt: '2026-01-01T00:00:00.000Z',
    ...over,
  };
}

/** A plain timed one-off (state N): no rule, no zone. */
const oneOff = (over: Partial<EventRow> = {}): EventRow =>
  master({ id: 'o', rrule: null, ...over });

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
    const edited: EventEditInput = {
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
    const edited: EventEditInput = { title: 'x', allDay: true, startDate: '2026-08-31', endDate: '2026-09-01' };
    expect(() => buildException(occ, edited)).toThrow(/all-day/);
  });
});

/** A timed edit that keeps the row a recurrence master. */
const timedSeriesEdit: EventEditInput = {
  title: '定例会（改）', description: null, category: '仕事', visibility: 'public',
  allDay: false, startAt: '2026-08-24T02:00:00.000Z', endAt: '2026-08-24T03:00:00.000Z',
  rrule: 'FREQ=WEEKLY;BYDAY=TU',
};

/** The same edit with the recurrence removed: the row becomes a timed one-off. */
const timedOneOffEdit: EventEditInput = { ...timedSeriesEdit, rrule: null };

/** The same edit turned all-day, which also stops the row being a timed master. */
const allDayEdit: EventEditInput = {
  title: '定例会（改）', description: null, category: '仕事', visibility: 'public',
  allDay: true, startDate: '2026-08-24', endDate: '2026-08-25', rrule: 'FREQ=WEEKLY;BYDAY=TU',
};

describe('rowPatchFromEdit — content', () => {
  it('carries the rrule and timed fields, clearing all-day columns', () => {
    expect(rowPatchFromEdit(master(), timedSeriesEdit)).toEqual({
      title: '定例会（改）', description: null, category: '仕事', visibility: 'public',
      rrule: 'FREQ=WEEKLY;BYDAY=TU',
      allDay: false, startAt: '2026-08-24T02:00:00.000Z', endAt: '2026-08-24T03:00:00.000Z',
      startDate: null, endDate: null,
    });
  });

  it('clears rrule to null when recurrence is removed', () => {
    expect(rowPatchFromEdit(master(), timedOneOffEdit).rrule).toBeNull();
  });
});

/**
 * The timezone half of the patch, case by case against the state machine in
 * services/timezoneRules (N / M0 / M1). What is asserted is not just the value
 * but whether the KEY IS PRESENT: an omitted key is what leaves a legacy null
 * alone and keeps an existing zone from being rewritten by an unrelated edit.
 */
describe('rowPatchFromEdit — timezone', () => {
  const M1 = master({ timezone: 'Asia/Tokyo' });
  const M0 = master({ timezone: null });

  it('omits the key when a zoned master stays a master (M1 -> M1)', () => {
    const patch = rowPatchFromEdit(M1, timedSeriesEdit);
    expect('timezone' in patch).toBe(false);
  });

  it('omits the key when a legacy master stays a master (M0 -> M0)', () => {
    const patch = rowPatchFromEdit(M0, timedSeriesEdit);
    expect('timezone' in patch).toBe(false);
  });

  it('nulls the zone in the same patch when the rrule is removed (M1 -> N)', () => {
    expect(rowPatchFromEdit(M1, timedOneOffEdit)).toMatchObject({ rrule: null, timezone: null });
  });

  it('nulls the zone in the same patch when the series turns all-day (M1 -> N)', () => {
    expect(rowPatchFromEdit(M1, allDayEdit)).toMatchObject({ allDay: true, timezone: null });
  });

  it('writes the adopted zone alongside the rrule when a one-off becomes a series', () => {
    const patch = rowPatchFromEdit(oneOff(), timedSeriesEdit, {
      kind: 'adopt',
      timezone: 'Asia/Tokyo',
    });
    expect(patch).toMatchObject({ rrule: 'FREQ=WEEKLY;BYDAY=TU', timezone: 'Asia/Tokyo' });
  });

  it('refuses to create a zone-less timed master (N -> M0 is unreachable)', () => {
    expect(() => rowPatchFromEdit(oneOff(), timedSeriesEdit)).toThrow(TimezoneRequiredError);
  });

});

/**
 * 'adopt' is valid on exactly one transition, N -> M1. Every other pairing is a
 * caller bug and must throw a PLAIN Error: reusing a domain error would blur its
 * meaning — TimezoneClearedError mirrors TIMEWEAVE_TZ_CLEARED (only M1 -> M0),
 * and SeriesEditBlockedError means "this series has exceptions" to the user.
 */
describe("rowPatchFromEdit — misplaced 'adopt'", () => {
  /** The error thrown by `call`, or undefined when it did not throw. */
  const thrownBy = (call: () => unknown): unknown => {
    try {
      call();
    } catch (e) {
      return e;
    }
    return undefined;
  };

  const expectPlainError = (caught: unknown) => {
    expect(caught).toBeInstanceOf(Error);
    expect(caught).not.toBeInstanceOf(TimezoneClearedError);
    expect(caught).not.toBeInstanceOf(SeriesEditBlockedError);
    expect(caught).not.toBeInstanceOf(TimezoneRequiredError);
  };

  it('throws a plain Error when the edit produces no timed master', () => {
    const caught = thrownBy(() =>
      rowPatchFromEdit(oneOff(), timedOneOffEdit, { kind: 'adopt', timezone: 'Asia/Tokyo' }),
    );
    expect(caught).toMatchObject({ message: expect.stringMatching(/adopt/) });
    expectPlainError(caught);
  });

  it('is equally refused when the edit turns the row all-day', () => {
    expect(() =>
      rowPatchFromEdit(oneOff(), { ...allDayEdit }, { kind: 'adopt', timezone: 'Asia/Tokyo' }),
    ).toThrow(/adopt/);
  });

  it('throws a plain Error on a row that is already a master (that is setSeriesTimezone)', () => {
    const caught = thrownBy(() =>
      rowPatchFromEdit(master({ timezone: 'Asia/Tokyo' }), timedSeriesEdit, {
        kind: 'adopt',
        timezone: 'Europe/Paris',
      }),
    );
    expect(caught).toMatchObject({ message: expect.stringMatching(/setSeriesTimezone/) });
    expectPlainError(caught);
  });

  it('throws a plain Error on a legacy master too (M0 stays setSeriesTimezone territory)', () => {
    expectPlainError(
      thrownBy(() =>
        rowPatchFromEdit(master({ timezone: null }), timedSeriesEdit, {
          kind: 'adopt',
          timezone: 'Asia/Tokyo',
        }),
      ),
    );
  });

  /**
   * ...and no natural UI path can get there. editTimezoneIntent is the only
   * place the dialog decides an intent, so running every row state against
   * every edit shape it can produce covers the whole reachable space.
   */
  it('is unreachable through editTimezoneIntent, for every row/edit combination', () => {
    const rows: EventRow[] = [oneOff(), master({ timezone: null }), master({ timezone: 'Asia/Tokyo' }),
      oneOff({ allDay: true, startAt: null, endAt: null, startDate: '2026-08-24', endDate: '2026-08-25' })];
    const edits: EventEditInput[] = [timedSeriesEdit, timedOneOffEdit, allDayEdit,
      { ...allDayEdit, rrule: null }];

    for (const row of rows) {
      for (const edited of edits) {
        const intent = editTimezoneIntent(
          row,
          { allDay: Boolean(edited.allDay), rrule: edited.rrule },
          'Asia/Tokyo',
        );
        expect(intent).not.toBeNull();
        // Never throws the caller-invariant Error, and never the "already a
        // master" refusal either: both are unreachable from the form.
        expect(() => rowPatchFromEdit(row, edited, intent!)).not.toThrow();
      }
    }
  });

  it('returns null instead of an intent when no zone could be resolved', () => {
    expect(editTimezoneIntent(oneOff(), { allDay: false, rrule: 'FREQ=DAILY' }, null)).toBeNull();
  });
});

describe('exceptionPatchFromEdit', () => {
  it('updates display/time fields but never touches recurrence identity or rrule', () => {
    const occ = timedOcc(master(), '2026-08-31T00:00:00.000Z', '2026-08-31T01:00:00.000Z');
    const edited: EventEditInput = {
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
    const edited: EventEditInput = { title: 'x', allDay: true, startDate: '2026-08-31', endDate: '2026-09-01' };
    expect(() => exceptionPatchFromEdit(occ, edited)).toThrow(/all-day/);
  });
});
