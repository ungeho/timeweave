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

const masterInput: NewEvent = {
  title: '定例会', allDay: false,
  startAt: '2026-08-24T00:00:00.000Z', endAt: '2026-08-24T01:00:00.000Z',
  rrule: 'FREQ=WEEKLY;BYDAY=MO',
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
