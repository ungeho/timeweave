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
import {
  DuplicateExceptionError,
  InvalidTimezoneError,
  TimezoneClearedError,
  TimezoneRequiredError,
} from '../errors';
import {
  timezonePlacementOk,
  timezoneTransitionError,
  type TimezoneShape,
} from '../services/timezoneRules';
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
 * Enforce the events.timezone invariants that migration 0008 enforces in the
 * database, so local mode behaves the same way and the same domain errors reach
 * the UI. The decision itself lives in services/timezoneRules, which is the
 * TypeScript twin of the SQL trigger.
 *
 * The one rule that cannot be replicated is the VALUE check: the DB requires an
 * exact pg_timezone_names row, which no browser API exposes. Local mode falls
 * back to the shape rules in utils/timezone, so a name the DB would refuse can
 * survive here. That divergence is one-directional and harmless — local mode
 * has no Free/Busy sharing, and any row later written to Supabase is validated
 * there.
 */
function assertTimezoneRules(prev: EventRow | null, next: EventRow, isInsert: boolean): void {
  const shape = (row: EventRow): TimezoneShape => ({
    allDay: row.allDay,
    rrule: row.rrule,
    recurrenceId: row.recurrenceId,
    timezone: row.timezone,
  });

  if (!timezonePlacementOk(shape(next))) {
    throw new InvalidTimezoneError(
      'タイムゾーンを持てるのは時刻ありの繰り返し予定だけです',
    );
  }

  const violation = timezoneTransitionError(
    isInsert,
    prev === null ? null : shape(prev),
    shape(next),
  );
  if (violation === 'TIMEWEAVE_TZ_REQUIRED') throw new TimezoneRequiredError();
  if (violation === 'TIMEWEAVE_TZ_CLEARED') throw new TimezoneClearedError();
}

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
      // Only a timed recurrence master carries one; see eventToInsert.
      timezone: !input.allDay && input.rrule != null ? input.timezone : null,
      createdAt: now,
      updatedAt: now,
    };
    assertTimezoneRules(null, row, true);
    const all = this.readAll();
    all.push(row);
    this.writeAll(all);
    return row;
  }

  async update(id: string, patch: Partial<EventRow>): Promise<EventRow> {
    const all = this.readAll();
    const idx = all.findIndex((e) => e.id === id);
    if (idx === -1) throw new Error(`Event not found: ${id}`);
    const prev = all[idx]!;
    const updated: EventRow = {
      ...prev,
      ...patch,
      id,
      ownerId: prev.ownerId,
      updatedAt: nowIso(),
    };
    // A patch that omits `timezone` inherits the previous value, which is what
    // keeps a legacy master (M0) editable without acquiring a guessed zone.
    assertTimezoneRules(prev, updated, false);
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
      timezone: null, // a snapshot pins absolute times; a zone is never used
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
      if (!Array.isArray(parsed)) return [];
      // Rows written before Phase 5b-2 have no `timezone` key at all. Filling
      // in null is a read-time shape fix, NOT a backfill: a legacy timed master
      // stays a legacy timed master (M0) and never acquires a guessed zone.
      return (parsed as EventRow[]).map((row) => ({ ...row, timezone: row.timezone ?? null }));
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
