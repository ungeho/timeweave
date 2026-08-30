/**
 * Data-access seam for events.
 *
 * The UI and hooks depend ONLY on the `EventRepository` interface.
 * `getEventRepository()` returns the Supabase-backed implementation when
 * Supabase is configured, otherwise a localStorage one ("local mode"). Swapping
 * the backing store requires no UI changes.
 */

import type { EventRow, ExceptionInput, NewEvent } from '../types/event';
import { newId } from '../utils/id';
import { nowIso } from '../utils/datetime';
import { isSupabaseConfigured } from '../lib/supabase';
import { DuplicateExceptionError } from '../errors';
import { SupabaseEventRepository } from './supabaseEventRepository';

export interface EventRepository {
  /** All events for the current user (RLS enforces this server-side in Supabase). */
  list(): Promise<EventRow[]>;
  create(input: NewEvent): Promise<EventRow>;
  update(id: string, patch: Partial<EventRow>): Promise<EventRow>;
  /**
   * Delete a row. Deleting a recurring MASTER cascades to its exception rows
   * (Supabase: FK ON DELETE CASCADE; localStorage: replicated here).
   */
  remove(id: string): Promise<void>;
  /**
   * Insert an exception row (override or cancellation of one master occurrence).
   * Throws DuplicateExceptionError if that slot already has an exception (DB
   * partial unique index / SQLSTATE 23505; localStorage: checked in-memory).
   */
  createException(input: ExceptionInput): Promise<EventRow>;
}

const STORAGE_KEY = 'timeweave.events.v1';

/**
 * Local-only implementation backed by `localStorage`, used when Supabase is not
 * configured. `ownerId` is a fixed placeholder (no auth in local mode).
 */
export class LocalStorageEventRepository implements EventRepository {
  private readonly ownerId = 'local-user';

  async list(): Promise<EventRow[]> {
    return this.readAll();
  }

  async create(input: NewEvent): Promise<EventRow> {
    const now = nowIso();
    const timeFields = input.allDay
      ? { allDay: true as const, startAt: null, endAt: null, startDate: input.startDate, endDate: input.endDate }
      : { allDay: false as const, startAt: input.startAt, endAt: input.endAt, startDate: null, endDate: null };

    const row: EventRow = {
      id: newId(),
      ownerId: this.ownerId,
      title: input.title,
      description: input.description ?? null,
      category: input.category ?? null,
      visibility: input.visibility ?? 'private',
      ...timeFields,
      rrule: input.rrule ?? null,
      recurrenceId: null,
      recurrenceSlotStart: null,
      recurrenceSlotDate: null,
      isCancelled: false,
      createdAt: now,
      updatedAt: now,
    };
    const all = this.readAll();
    all.push(row);
    this.writeAll(all);
    return row;
  }

  async update(id: string, patch: Partial<EventRow>): Promise<EventRow> {
    const all = this.readAll();
    const idx = all.findIndex((e) => e.id === id);
    if (idx === -1) throw new Error(`Event not found: ${id}`);
    const updated: EventRow = {
      ...all[idx]!,
      ...patch,
      id,
      ownerId: all[idx]!.ownerId,
      updatedAt: nowIso(),
    };
    all[idx] = updated;
    this.writeAll(all);
    return updated;
  }

  async remove(id: string): Promise<void> {
    // Cascade like the DB FK: drop the row and any exception rows pointing at it.
    this.writeAll(this.readAll().filter((e) => e.id !== id && e.recurrenceId !== id));
  }

  async createException(input: ExceptionInput): Promise<EventRow> {
    const all = this.readAll();
    const duplicate = all.some(
      (r) =>
        r.recurrenceId === input.recurrenceId &&
        (input.recurrenceSlotStart !== null
          ? r.recurrenceSlotStart === input.recurrenceSlotStart
          : r.recurrenceSlotDate === input.recurrenceSlotDate),
    );
    if (duplicate) throw new DuplicateExceptionError();

    const now = nowIso();
    const row: EventRow = {
      id: newId(),
      ownerId: this.ownerId,
      title: input.title,
      description: input.description,
      category: input.category,
      visibility: input.visibility,
      allDay: input.allDay,
      startAt: input.startAt,
      endAt: input.endAt,
      startDate: input.startDate,
      endDate: input.endDate,
      rrule: null,
      recurrenceId: input.recurrenceId,
      recurrenceSlotStart: input.recurrenceSlotStart,
      recurrenceSlotDate: input.recurrenceSlotDate,
      isCancelled: input.isCancelled,
      createdAt: now,
      updatedAt: now,
    };
    all.push(row);
    this.writeAll(all);
    return row;
  }

  private readAll(): EventRow[] {
    const raw = localStorage.getItem(STORAGE_KEY);
    if (!raw) return [];
    try {
      const parsed = JSON.parse(raw);
      return Array.isArray(parsed) ? (parsed as EventRow[]) : [];
    } catch {
      return [];
    }
  }

  private writeAll(rows: EventRow[]): void {
    localStorage.setItem(STORAGE_KEY, JSON.stringify(rows));
  }
}

let instance: EventRepository | null = null;

/** App-wide repository. Supabase when configured, else localStorage. */
export function getEventRepository(): EventRepository {
  if (!instance) {
    instance = isSupabaseConfigured
      ? new SupabaseEventRepository()
      : new LocalStorageEventRepository();
  }
  return instance;
}
