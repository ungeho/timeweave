/**
 * Single place that translates between the DB row shape (snake_case, nullable
 * timed/all-day pairs) and the app's EventRow (camelCase). Both the Supabase
 * and localStorage repositories go through here so the representation gap is
 * fixed in exactly one location.
 */

import type { Availability, EventRow, ExceptionInput, NewEvent } from '../types/event';

/** Raw row as returned by `select('*')` from the `events` table. */
export interface EventDbRow {
  id: string;
  owner_id: string;
  title: string;
  description: string | null;
  category: string | null;
  visibility: EventRow['visibility'];
  /**
   * OPTIONAL on purpose: a row written before the column existed comes back
   * without the key, and this type has to be able to say so. Writes do NOT
   * inherit that optionality -- see EventInsert.
   */
  availability?: Availability;
  all_day: boolean;
  start_at: string | null;
  end_at: string | null;
  start_date: string | null;
  end_date: string | null;
  rrule: string | null;
  recurrence_id: string | null;
  recurrence_slot_start: string | null;
  recurrence_slot_date: string | null;
  is_cancelled: boolean;
  timezone: string | null;
  created_at: string;
  updated_at: string;
}

export function rowToEvent(row: EventDbRow): EventRow {
  return {
    id: row.id,
    ownerId: row.owner_id,
    title: row.title,
    description: row.description,
    category: row.category,
    visibility: row.visibility,
    // A row written before the column existed, exactly like the localStorage
    // shape fix. A read-time default, never written back by the act of reading.
    availability: row.availability ?? 'busy',
    allDay: row.all_day,
    startAt: row.start_at,
    endAt: row.end_at,
    startDate: row.start_date,
    endDate: row.end_date,
    rrule: row.rrule,
    recurrenceId: row.recurrence_id,
    recurrenceSlotStart: row.recurrence_slot_start,
    recurrenceSlotDate: row.recurrence_slot_date,
    isCancelled: row.is_cancelled,
    timezone: row.timezone ?? null,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
  };
}

/**
 * Columns for an INSERT. owner_id/id/timestamps are set by DB defaults.
 *
 * `availability` is narrowed back to REQUIRED here. Reading tolerates a row
 * that predates the column; writing one that omits it would leave the decision
 * to a database default, and this app would rather state it.
 */
export type EventInsert = Omit<
  EventDbRow,
  'id' | 'owner_id' | 'created_at' | 'updated_at'
> & { availability: Availability };

/**
 * Build INSERT columns from create input, honouring the all-day discriminant.
 *
 * `timezone` is set only for a timed recurrence master, matching the DB's
 * `events_timezone_placement` CHECK. The NewEvent union already makes the other
 * shapes unable to carry one, so this is where that guarantee turns into an
 * explicit null rather than an absent column.
 */
export function eventToInsert(input: NewEvent): EventInsert {
  const common = {
    title: input.title,
    description: input.description ?? null,
    category: input.category ?? null,
    visibility: input.visibility ?? 'private',
    // Absent means 'busy', exactly as absent visibility means 'private'.
    availability: input.availability ?? 'busy',
    rrule: input.rrule ?? null,
    recurrence_id: null,
    recurrence_slot_start: null,
    recurrence_slot_date: null,
    is_cancelled: false,
  } as const;

  if (input.allDay) {
    return {
      ...common,
      all_day: true,
      start_at: null,
      end_at: null,
      start_date: input.startDate,
      end_date: input.endDate,
      timezone: null, // all-day is pure date arithmetic; a zone is never used
    };
  }
  return {
    ...common,
    all_day: false,
    start_at: input.startAt,
    end_at: input.endAt,
    start_date: null,
    end_date: null,
    // Only the recurring arm of NewEvent carries one; a timed one-off pins an
    // absolute instant and needs no zone.
    timezone: input.rrule != null ? input.timezone : null,
  };
}

/**
 * Build INSERT columns for an exception row (override or cancellation of one
 * master occurrence). Exceptions never carry their own rrule. owner_id/id/
 * timestamps come from DB defaults; the slot-key/all_day shape is already
 * validated upstream (buildException/buildCancellation) and by DB CHECKs.
 *
 * `timezone` is always null: a zone describes a recurrence RULE, and an
 * exception is a snapshot that already pins absolute times, so there is nothing
 * for one to affect. The DB's placement CHECK refuses it outright.
 */
export function exceptionToInsert(input: ExceptionInput): EventInsert {
  return {
    timezone: null,
    title: input.title,
    description: input.description,
    category: input.category,
    visibility: input.visibility,
    availability: input.availability,
    all_day: input.allDay,
    start_at: input.startAt,
    end_at: input.endAt,
    start_date: input.startDate,
    end_date: input.endDate,
    rrule: null,
    recurrence_id: input.recurrenceId,
    recurrence_slot_start: input.recurrenceSlotStart,
    recurrence_slot_date: input.recurrenceSlotDate,
    is_cancelled: input.isCancelled,
  };
}

const FIELD_TO_COLUMN: Record<keyof EventRow, keyof EventDbRow> = {
  id: 'id',
  ownerId: 'owner_id',
  title: 'title',
  description: 'description',
  category: 'category',
  visibility: 'visibility',
  availability: 'availability',
  allDay: 'all_day',
  startAt: 'start_at',
  endAt: 'end_at',
  startDate: 'start_date',
  endDate: 'end_date',
  rrule: 'rrule',
  recurrenceId: 'recurrence_id',
  recurrenceSlotStart: 'recurrence_slot_start',
  recurrenceSlotDate: 'recurrence_slot_date',
  isCancelled: 'is_cancelled',
  timezone: 'timezone',
  createdAt: 'created_at',
  updatedAt: 'updated_at',
};

/** Translate a partial EventRow patch into snake_case DB columns for UPDATE. */
export function eventPatchToColumns(patch: Partial<EventRow>): Record<string, unknown> {
  const out: Record<string, unknown> = {};
  for (const key of Object.keys(patch) as (keyof EventRow)[]) {
    // id/owner/timestamps are never client-writable.
    if (key === 'id' || key === 'ownerId' || key === 'createdAt' || key === 'updatedAt') continue;
    out[FIELD_TO_COLUMN[key]] = patch[key];
  }
  return out;
}
