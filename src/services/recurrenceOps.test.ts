import { describe, expect, it } from 'vitest';
import type { EventEditInput, EventOccurrence, EventRow } from '../types/event';
import type { EventRepository } from '../repositories/eventRepository';
import { InvalidTimezoneError, SeriesEditBlockedError } from '../errors';
import { deleteOccurrence, editOccurrence, masterIdOf, setSeriesTimezone } from './recurrenceOps';

/** A repository that records every call (method + args) instead of persisting. */
interface Call {
  method: 'list' | 'create' | 'update' | 'remove' | 'createException';
  args: unknown[];
}
function fakeRepo() {
  const calls: Call[] = [];
  const stub = {} as EventRow;
  const repo: EventRepository = {
    list: async () => {
      calls.push({ method: 'list', args: [] });
      return [];
    },
    create: async (input) => {
      calls.push({ method: 'create', args: [input] });
      return stub;
    },
    update: async (id, patch) => {
      calls.push({ method: 'update', args: [id, patch] });
      return stub;
    },
    remove: async (id) => {
      calls.push({ method: 'remove', args: [id] });
    },
    createException: async (input) => {
      calls.push({ method: 'createException', args: [input] });
      return stub;
    },
  };
  return { repo, calls };
}

const SLOT = '2026-08-31T00:00:00.000Z';

const master: EventRow = {
  id: 'm', ownerId: 'u', title: '定例会', description: 'メモ', category: '仕事', visibility: 'busy_only',
  allDay: false, startAt: '2026-08-24T00:00:00.000Z', endAt: '2026-08-24T01:00:00.000Z',
  startDate: null, endDate: null, rrule: 'FREQ=WEEKLY;BYDAY=MO', recurrenceId: null,
  recurrenceSlotStart: null, recurrenceSlotDate: null, isCancelled: false, timezone: null,
  createdAt: '2026-01-01T00:00:00.000Z', updatedAt: '2026-01-01T00:00:00.000Z',
};

const exceptionRow: EventRow = {
  ...master, id: 'e', rrule: null, recurrenceId: 'm', recurrenceSlotStart: SLOT,
  startAt: '2026-08-31T06:00:00.000Z', endAt: '2026-08-31T07:00:00.000Z',
};

const generatedOcc: EventOccurrence = {
  event: master, start: SLOT, end: '2026-08-31T01:00:00.000Z',
  allDay: false, occurrenceKey: SLOT, isException: false,
};

const exceptionOcc: EventOccurrence = {
  event: exceptionRow, start: '2026-08-31T06:00:00.000Z', end: '2026-08-31T07:00:00.000Z',
  allDay: false, occurrenceKey: SLOT, isException: true,
};

const edited: EventEditInput = {
  title: '変更後', description: null, category: null, visibility: 'private',
  allDay: false, startAt: '2026-08-31T02:00:00.000Z', endAt: '2026-08-31T03:00:00.000Z',
};

/** An all-day series (state N: a zone is neither carried nor needed). */
const allDayMaster: EventRow = {
  ...master, id: 'a', allDay: true, startAt: null, endAt: null,
  startDate: '2026-08-24', endDate: '2026-08-25', rrule: 'FREQ=WEEKLY;BYDAY=MO',
};

const allDayOcc: EventOccurrence = {
  event: allDayMaster, start: '2026-08-31T00:00:00.000Z', end: '2026-09-01T00:00:00.000Z',
  allDay: true, occurrenceKey: '2026-08-31', isException: false,
};

describe('masterIdOf', () => {
  it('is the row id for a generated occurrence, the recurrenceId for an exception', () => {
    expect(masterIdOf(generatedOcc)).toBe('m');
    expect(masterIdOf(exceptionOcc)).toBe('m');
  });
});

describe('editOccurrence scope="only"', () => {
  it('inserts an override exception for a generated occurrence', async () => {
    const { repo, calls } = fakeRepo();
    await editOccurrence(repo, [master], generatedOcc, edited, 'only');
    expect(calls).toHaveLength(1);
    expect(calls[0]!.method).toBe('createException');
    expect(calls[0]!.args[0]).toMatchObject({
      recurrenceId: 'm', recurrenceSlotStart: SLOT, isCancelled: false, title: '変更後',
    });
  });

  it('updates the existing exception row in place (no new INSERT)', async () => {
    const { repo, calls } = fakeRepo();
    await editOccurrence(repo, [master, exceptionRow], exceptionOcc, edited, 'only');
    expect(calls).toHaveLength(1);
    expect(calls[0]!.method).toBe('update');
    expect(calls[0]!.args[0]).toBe('e'); // the exception row's own id
    const patch = calls[0]!.args[1] as Record<string, unknown>;
    // Must not silently rewrite recurrence identity or turn it into a master.
    expect('recurrenceId' in patch).toBe(false);
    expect('recurrenceSlotStart' in patch).toBe(false);
    expect('recurrenceSlotDate' in patch).toBe(false);
    expect('rrule' in patch).toBe(false);
    expect(patch).toMatchObject({ title: '変更後', isCancelled: false });
  });
});

describe('editOccurrence scope="all"', () => {
  it('updates the master when the series has no exceptions', async () => {
    const { repo, calls } = fakeRepo();
    await editOccurrence(repo, [master], generatedOcc, { ...edited, rrule: 'FREQ=WEEKLY;BYDAY=TU' }, 'all');
    expect(calls).toHaveLength(1);
    expect(calls[0]!.method).toBe('update');
    expect(calls[0]!.args[0]).toBe('m');
    expect(calls[0]!.args[1]).toMatchObject({ title: '変更後', rrule: 'FREQ=WEEKLY;BYDAY=TU' });
  });

  it('throws SeriesEditBlockedError and touches nothing when exceptions exist', async () => {
    const { repo, calls } = fakeRepo();
    await expect(editOccurrence(repo, [master, exceptionRow], generatedOcc, edited, 'all'))
      .rejects.toBeInstanceOf(SeriesEditBlockedError);
    expect(calls).toHaveLength(0);
  });

  it('targets the master (not the exception row) when invoked from an exception occurrence', async () => {
    // rows is the guard's source of truth; with no exception rows the edit proceeds
    // and must resolve the target to the master id, never the exception's own id.
    const { repo, calls } = fakeRepo();
    await editOccurrence(repo, [master], exceptionOcc, edited, 'all');
    expect(calls[0]!.method).toBe('update');
    expect(calls[0]!.args[0]).toBe('m');
  });
});

/**
 * The timezone half of a scope-'all' edit. Only this path reaches
 * rowPatchFromEdit, so it is the only place an edit can touch the column.
 */
describe('editOccurrence scope="all" — timezone', () => {
  it('adopts a zone in the same patch when an all-day series turns timed', async () => {
    const { repo, calls } = fakeRepo();
    await editOccurrence(
      repo,
      [allDayMaster],
      allDayOcc,
      { ...edited, rrule: 'FREQ=WEEKLY;BYDAY=TU' },
      'all',
      { kind: 'adopt', timezone: 'Asia/Tokyo' },
    );
    expect(calls[0]!.args[1]).toMatchObject({
      allDay: false,
      rrule: 'FREQ=WEEKLY;BYDAY=TU',
      timezone: 'Asia/Tokyo',
    });
  });

  it('leaves the column out of the patch for an ordinary edit of a zoned series', async () => {
    const { repo, calls } = fakeRepo();
    const zoned: EventRow = { ...master, timezone: 'Asia/Tokyo' };
    await editOccurrence(repo, [zoned], generatedOcc, { ...edited, rrule: master.rrule }, 'all');
    expect('timezone' in (calls[0]!.args[1] as object)).toBe(false);
  });

  it('ignores the intent for scope "only": an exception row never carries a zone', async () => {
    const { repo, calls } = fakeRepo();
    await editOccurrence(repo, [master], generatedOcc, edited, 'only', {
      kind: 'adopt',
      timezone: 'Asia/Tokyo',
    });
    expect(calls[0]!.method).toBe('createException');
    expect('timezone' in (calls[0]!.args[0] as object)).toBe(false);
  });
});

/**
 * setSeriesTimezone is the ONLY way an existing series' zone changes. It is
 * guarded like "edit all" because moving the zone moves every occurrence, which
 * would leave existing exception rows pinned to slots that no longer exist.
 */
describe('setSeriesTimezone', () => {
  it('updates only the timezone column of the master', async () => {
    const { repo, calls } = fakeRepo();
    await setSeriesTimezone(repo, [master], 'm', 'Asia/Tokyo');
    expect(calls).toEqual([{ method: 'update', args: ['m', { timezone: 'Asia/Tokyo' }] }]);
  });

  it('writes nothing when the zone is unchanged, even with exceptions present', async () => {
    const zoned: EventRow = { ...master, timezone: 'Asia/Tokyo' };
    const { repo, calls } = fakeRepo();
    await setSeriesTimezone(repo, [zoned, exceptionRow], 'm', 'Asia/Tokyo');
    expect(calls).toHaveLength(0);
  });

  it('is blocked when the series already has exceptions', async () => {
    const { repo, calls } = fakeRepo();
    await expect(setSeriesTimezone(repo, [master, exceptionRow], 'm', 'Asia/Tokyo'))
      .rejects.toBeInstanceOf(SeriesEditBlockedError);
    expect(calls).toHaveLength(0);
  });

  it('refuses a row that is not a timed master', async () => {
    const { repo, calls } = fakeRepo();
    await expect(setSeriesTimezone(repo, [allDayMaster], 'a', 'Asia/Tokyo'))
      .rejects.toBeInstanceOf(InvalidTimezoneError);
    expect(calls).toHaveLength(0);
  });

  it('refuses a zone the database would not store', async () => {
    const { repo, calls } = fakeRepo();
    await expect(setSeriesTimezone(repo, [master], 'm', 'posix/Asia/Tokyo'))
      .rejects.toBeInstanceOf(InvalidTimezoneError);
    expect(calls).toHaveLength(0);
  });
});

describe('deleteOccurrence scope="only"', () => {
  it('creates a cancellation exception for a generated occurrence', async () => {
    const { repo, calls } = fakeRepo();
    await deleteOccurrence(repo, generatedOcc, 'only');
    expect(calls).toHaveLength(1);
    expect(calls[0]!.method).toBe('createException');
    expect(calls[0]!.args[0]).toMatchObject({
      recurrenceId: 'm', recurrenceSlotStart: SLOT, isCancelled: true,
    });
  });

  it('flips an existing exception to a tombstone (isCancelled=true)', async () => {
    const { repo, calls } = fakeRepo();
    await deleteOccurrence(repo, exceptionOcc, 'only');
    expect(calls).toHaveLength(1);
    expect(calls[0]!.method).toBe('update');
    expect(calls[0]!.args).toEqual(['e', { isCancelled: true }]);
  });
});

describe('deleteOccurrence scope="all"', () => {
  it('removes the master (cascade handled by the repository)', async () => {
    const { repo, calls } = fakeRepo();
    await deleteOccurrence(repo, generatedOcc, 'all');
    expect(calls).toEqual([{ method: 'remove', args: ['m'] }]);
  });

  it('removes the master when invoked from an exception occurrence', async () => {
    const { repo, calls } = fakeRepo();
    await deleteOccurrence(repo, exceptionOcc, 'all');
    expect(calls).toEqual([{ method: 'remove', args: ['m'] }]);
  });
});
