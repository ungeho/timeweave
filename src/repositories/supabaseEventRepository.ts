/**
 * Supabase-backed EventRepository.
 *
 * owner_id is never sent from the client: the DB column defaults to
 * `auth.uid()` and RLS's WITH CHECK guarantees it matches the caller. SELECT is
 * automatically scoped to the current user's rows by RLS, so no explicit owner
 * filter is required (one is added anyway for clarity/robustness).
 */

import type { EventRepository } from './eventRepository';
import type { EventRow, ExceptionInput, NewEvent } from '../types/event';
import { requireSupabase } from '../lib/supabase';
import { DuplicateExceptionError } from '../errors';
import {
  eventPatchToColumns,
  eventToInsert,
  exceptionToInsert,
  rowToEvent,
  type EventDbRow,
} from './eventMapping';

const TABLE = 'events';

export class SupabaseEventRepository implements EventRepository {
  async list(): Promise<EventRow[]> {
    const { data, error } = await requireSupabase().from(TABLE).select('*');
    if (error) throw new Error(error.message);
    return (data as EventDbRow[]).map(rowToEvent);
  }

  async create(input: NewEvent): Promise<EventRow> {
    const { data, error } = await requireSupabase()
      .from(TABLE)
      .insert(eventToInsert(input))
      .select()
      .single();
    if (error) throw new Error(error.message);
    return rowToEvent(data as EventDbRow);
  }

  async update(id: string, patch: Partial<EventRow>): Promise<EventRow> {
    const { data, error } = await requireSupabase()
      .from(TABLE)
      .update(eventPatchToColumns(patch))
      .eq('id', id)
      .select()
      .single();
    if (error) throw new Error(error.message);
    return rowToEvent(data as EventDbRow);
  }

  async remove(id: string): Promise<void> {
    // Deleting a master cascades to exception rows via the FK ON DELETE CASCADE.
    const { error } = await requireSupabase().from(TABLE).delete().eq('id', id);
    if (error) throw new Error(error.message);
  }

  async createException(input: ExceptionInput): Promise<EventRow> {
    const { data, error } = await requireSupabase()
      .from(TABLE)
      .insert(exceptionToInsert(input))
      .select()
      .single();
    if (error) {
      // Partial unique index violation -> a domain error the UI can present.
      if (error.code === '23505') throw new DuplicateExceptionError();
      throw new Error(error.message);
    }
    return rowToEvent(data as EventDbRow);
  }
}
