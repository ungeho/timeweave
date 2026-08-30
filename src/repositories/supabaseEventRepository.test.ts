import { describe, expect, it, vi } from 'vitest';
import type { ExceptionInput } from '../types/event';
import { DuplicateExceptionError } from '../errors';

// A chainable fake Supabase client whose terminal `.single()` returns whatever
// `state` holds. `requireSupabase` is mocked to return it.
const h = vi.hoisted(() => {
  const state: { data: unknown; error: unknown } = { data: null, error: null };
  const single = () => Promise.resolve({ data: state.data, error: state.error });
  const client = {
    from: () => ({ insert: () => ({ select: () => ({ single }) }) }),
  };
  return { state, client };
});

vi.mock('../lib/supabase', () => ({ requireSupabase: () => h.client }));

import { SupabaseEventRepository } from './supabaseEventRepository';

const input: ExceptionInput = {
  recurrenceId: 'm', recurrenceSlotStart: '2026-08-31T00:00:00.000Z', recurrenceSlotDate: null,
  isCancelled: false, allDay: false,
  startAt: '2026-08-31T06:00:00.000Z', endAt: '2026-08-31T07:00:00.000Z',
  startDate: null, endDate: null,
  title: '個別変更', description: null, category: null, visibility: 'private',
};

describe('SupabaseEventRepository.createException', () => {
  it('maps a unique-violation (23505) to DuplicateExceptionError', async () => {
    h.state.data = null;
    h.state.error = { code: '23505', message: 'duplicate key value violates unique constraint' };
    const repo = new SupabaseEventRepository();
    await expect(repo.createException(input)).rejects.toBeInstanceOf(DuplicateExceptionError);
  });

  it('rethrows other errors as a generic Error', async () => {
    h.state.data = null;
    h.state.error = { code: '42501', message: 'permission denied' };
    const repo = new SupabaseEventRepository();
    await expect(repo.createException(input)).rejects.toThrow(/permission denied/);
  });

  it('returns the mapped row on success', async () => {
    h.state.error = null;
    h.state.data = {
      id: 'e', owner_id: 'u', title: '個別変更', description: null, category: null,
      visibility: 'private', all_day: false,
      start_at: '2026-08-31T06:00:00.000Z', end_at: '2026-08-31T07:00:00.000Z',
      start_date: null, end_date: null, rrule: null, recurrence_id: 'm',
      recurrence_slot_start: '2026-08-31T00:00:00.000Z', recurrence_slot_date: null,
      is_cancelled: false, created_at: '2026-01-01T00:00:00.000Z', updated_at: '2026-01-01T00:00:00.000Z',
    };
    const repo = new SupabaseEventRepository();
    const row = await repo.createException(input);
    expect(row).toMatchObject({ id: 'e', recurrenceId: 'm', rrule: null });
  });
});
