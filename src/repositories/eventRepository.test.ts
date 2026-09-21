import { beforeEach, describe, expect, it } from 'vitest';
import type { ExceptionInput, NewEvent } from '../types/event';
import { DuplicateExceptionError } from '../errors';
import { LocalStorageEventRepository } from './eventRepository';

// Minimal in-memory localStorage for the node test environment.
beforeEach(() => {
  const store = new Map<string, string>();
  (globalThis as { localStorage: Storage }).localStorage = {
    getItem: (k: string) => store.get(k) ?? null,
    setItem: (k: string, v: string) => void store.set(k, v),
    removeItem: (k: string) => void store.delete(k),
    clear: () => store.clear(),
    key: () => null,
    length: 0,
  } as Storage;
});

// A timed recurrence master. Since Phase 5b-2 the zone is part of the input:
// the series repeats at a wall-clock time, so it cannot be inferred later.
const masterInput: NewEvent = {
  title: '定例会', allDay: false,
  startAt: '2026-08-24T00:00:00.000Z', endAt: '2026-08-24T01:00:00.000Z',
  rrule: 'FREQ=WEEKLY;BYDAY=MO', timezone: 'Asia/Tokyo',
};

const exceptionInput = (recurrenceId: string): ExceptionInput => ({
  recurrenceId, recurrenceSlotStart: '2026-08-31T00:00:00.000Z', recurrenceSlotDate: null,
  isCancelled: false, allDay: false,
  startAt: '2026-08-31T06:00:00.000Z', endAt: '2026-08-31T07:00:00.000Z',
  startDate: null, endDate: null,
  title: '個別変更', description: null, category: null, visibility: 'private',
});

describe('LocalStorageEventRepository.remove (cascade)', () => {
  it('deletes a master and its exception rows together', async () => {
    const repo = new LocalStorageEventRepository();
    const master = await repo.create(masterInput);
    await repo.createException(exceptionInput(master.id));
    expect(await repo.list()).toHaveLength(2);

    await repo.remove(master.id);
    expect(await repo.list()).toEqual([]);
  });

  it('leaves unrelated events alone', async () => {
    const repo = new LocalStorageEventRepository();
    const master = await repo.create(masterInput);
    const other = await repo.create({
      title: '別件', allDay: false,
      startAt: '2026-09-01T00:00:00.000Z', endAt: '2026-09-01T01:00:00.000Z',
    });
    await repo.createException(exceptionInput(master.id));

    await repo.remove(master.id);
    const rows = await repo.list();
    expect(rows).toHaveLength(1);
    expect(rows[0]!.id).toBe(other.id);
  });
});

describe('LocalStorageEventRepository.createException (duplicate)', () => {
  it('rejects a second exception for the same master slot', async () => {
    const repo = new LocalStorageEventRepository();
    const master = await repo.create(masterInput);
    await repo.createException(exceptionInput(master.id));
    await expect(repo.createException(exceptionInput(master.id)))
      .rejects.toBeInstanceOf(DuplicateExceptionError);
    expect(await repo.list()).toHaveLength(2); // no third row written
  });

  it('stores an exception row with rrule cleared', async () => {
    const repo = new LocalStorageEventRepository();
    const master = await repo.create(masterInput);
    const ex = await repo.createException(exceptionInput(master.id));
    expect(ex.rrule).toBeNull();
    expect(ex.recurrenceId).toBe(master.id);
    expect(ex.recurrenceSlotStart).toBe('2026-08-31T00:00:00.000Z');
  });
});

/**
 * Rows written before `availability` existed have no such key. Reading must
 * report them as 'busy' -- not because that is a safe guess, but because it is
 * what a row that exists has always meant.
 *
 * The write side of the same rule is asserted too: reading a legacy row must
 * not rewrite storage, since a read that repairs data is a read that can lose
 * it. This mirrors how `timezone` was added in Phase 5b-2.
 */
describe('LocalStorageEventRepository: rows written before availability existed', () => {
  const KEY = 'timeweave.events.v1';

  /** A legacy row: valid apart from having no `availability` key at all. */
  const legacyRow = (over: Record<string, unknown> = {}) => ({
    id: 'legacy', ownerId: 'local-user', title: '古い予定',
    description: null, category: null, visibility: 'private',
    allDay: false,
    startAt: '2026-08-24T00:00:00.000Z', endAt: '2026-08-24T01:00:00.000Z',
    startDate: null, endDate: null, rrule: null, recurrenceId: null,
    recurrenceSlotStart: null, recurrenceSlotDate: null, isCancelled: false,
    createdAt: '2026-01-01T00:00:00.000Z', updatedAt: '2026-01-01T00:00:00.000Z',
    ...over,
  });

  it('reads a missing availability as busy', async () => {
    localStorage.setItem(KEY, JSON.stringify([legacyRow()]));
    const rows = await new LocalStorageEventRepository().list();
    expect(rows).toHaveLength(1);
    expect(rows[0]!.availability).toBe('busy');
  });

  it('still fills in a missing timezone at the same time', async () => {
    // The two shape fixes share one map; neither may displace the other.
    localStorage.setItem(KEY, JSON.stringify([legacyRow()]));
    const rows = await new LocalStorageEventRepository().list();
    expect(rows[0]!.timezone).toBeNull();
    expect(rows[0]!.availability).toBe('busy');
  });

  it('does not rewrite storage when reading one', async () => {
    const raw = JSON.stringify([legacyRow()]);
    localStorage.setItem(KEY, raw);
    await new LocalStorageEventRepository().list();
    expect(localStorage.getItem(KEY)).toBe(raw);
  });

  it('keeps an availability that is already stored', async () => {
    localStorage.setItem(KEY, JSON.stringify([legacyRow({ availability: 'available' })]));
    const rows = await new LocalStorageEventRepository().list();
    expect(rows[0]!.availability).toBe('available');
  });

  it('writes busy on every row it creates, since no input can carry one yet', async () => {
    const repo = new LocalStorageEventRepository();
    const master = await repo.create(masterInput);
    expect(master.availability).toBe('busy');
    const ex = await repo.createException(exceptionInput(master.id));
    expect(ex.availability).toBe('busy');
  });
});
