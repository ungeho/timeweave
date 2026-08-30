/**
 * Pure builders that turn a recurring occurrence (+ optional edit) into the
 * `ExceptionInput` a repository will persist. No side effects, so the exact
 * shape (slot key type, cancellation flag, time fields) is unit-testable.
 *
 * These operate on GENERATED occurrences of a master (occurrence.event is the
 * master). Editing/deleting an occurrence that is ALREADY an exception is done
 * via a plain update, not through here.
 */

import type { EventOccurrence, EventRow, ExceptionInput, NewEvent } from '../types/event';
import { addDaysToDateString } from '../utils/datetime';

/**
 * The master slot key an occurrence overrides. Keyed by the occurrence's
 * all-day-ness (which mirrors the master), matching the DB CHECK constraint.
 */
export function occurrenceSlot(occ: EventOccurrence): {
  recurrenceSlotStart: string | null;
  recurrenceSlotDate: string | null;
} {
  return occ.allDay
    ? { recurrenceSlotStart: null, recurrenceSlotDate: occ.occurrenceKey }
    : { recurrenceSlotStart: occ.occurrenceKey, recurrenceSlotDate: null };
}

/**
 * A cancellation tombstone for "delete this occurrence". Carries valid (unused)
 * time fields to satisfy the DB shape CHECK; display fields copy the master.
 */
export function buildCancellation(occ: EventOccurrence): ExceptionInput {
  const master = occ.event;
  const slot = occurrenceSlot(occ);
  const time = occ.allDay
    ? {
        allDay: true,
        startAt: null,
        endAt: null,
        startDate: occ.occurrenceKey,
        endDate: addDaysToDateString(occ.occurrenceKey, 1),
      }
    : { allDay: false, startAt: occ.start, endAt: occ.end, startDate: null, endDate: null };

  return {
    recurrenceId: master.id,
    ...slot,
    isCancelled: true,
    ...time,
    title: master.title,
    description: master.description,
    category: master.category,
    visibility: master.visibility,
  };
}

/**
 * A modified exception for "edit this occurrence only". The slot key points at
 * the ORIGINAL occurrence; the time/display fields come from the edit. The edit
 * must keep the master's all-day-ness (the dialog enforces this) so the row's
 * all_day matches its slot-key type.
 */
export function buildException(occ: EventOccurrence, edited: NewEvent): ExceptionInput {
  if (Boolean(edited.allDay) !== occ.allDay) {
    throw new Error('Per-occurrence edit cannot change the all-day setting of a recurring event.');
  }
  const master = occ.event;
  const slot = occurrenceSlot(occ);
  const time = edited.allDay
    ? {
        allDay: true,
        startAt: null,
        endAt: null,
        startDate: edited.startDate,
        endDate: edited.endDate,
      }
    : { allDay: false, startAt: edited.startAt, endAt: edited.endAt, startDate: null, endDate: null };

  return {
    recurrenceId: master.id,
    ...slot,
    isCancelled: false,
    ...time,
    title: edited.title,
    description: edited.description ?? null,
    category: edited.category ?? null,
    visibility: edited.visibility ?? 'private',
  };
}

/**
 * Patch for editing the WHOLE series (scope 'all'): applied to the master row.
 * Carries the recurrence rule (masters own the rrule) and the all-day-matched
 * time fields. Only used when the series has no exceptions (see seriesGuards).
 */
export function masterPatchFromEdit(edited: NewEvent): Partial<EventRow> {
  const display = {
    title: edited.title,
    description: edited.description ?? null,
    category: edited.category ?? null,
    visibility: edited.visibility ?? 'private',
    rrule: edited.rrule ?? null,
  };
  return edited.allDay
    ? { ...display, allDay: true, startAt: null, endAt: null, startDate: edited.startDate, endDate: edited.endDate }
    : { ...display, allDay: false, startAt: edited.startAt, endAt: edited.endAt, startDate: null, endDate: null };
}

/**
 * Patch for editing an occurrence that is ALREADY an exception row, in place
 * (scope 'only'). Updates only the display/time fields; the row keeps its
 * recurrenceId, slot key, and rrule=null. Must not change all-day-ness (the slot
 * key type is fixed). isCancelled is reset to false: editing re-materialises the
 * occurrence as an override.
 */
export function exceptionPatchFromEdit(occ: EventOccurrence, edited: NewEvent): Partial<EventRow> {
  if (Boolean(edited.allDay) !== occ.allDay) {
    throw new Error('Per-occurrence edit cannot change the all-day setting of a recurring event.');
  }
  const display = {
    title: edited.title,
    description: edited.description ?? null,
    category: edited.category ?? null,
    visibility: edited.visibility ?? 'private',
    isCancelled: false,
  };
  return edited.allDay
    ? { ...display, allDay: true, startAt: null, endAt: null, startDate: edited.startDate, endDate: edited.endDate }
    : { ...display, allDay: false, startAt: edited.startAt, endAt: edited.endAt, startDate: null, endDate: null };
}
