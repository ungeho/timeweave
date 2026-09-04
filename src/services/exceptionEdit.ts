/**
 * Pure builders that turn a recurring occurrence (+ optional edit) into the
 * `ExceptionInput` a repository will persist. No side effects, so the exact
 * shape (slot key type, cancellation flag, time fields) is unit-testable.
 *
 * These operate on GENERATED occurrences of a master (occurrence.event is the
 * master). Editing/deleting an occurrence that is ALREADY an exception is done
 * via a plain update, not through here.
 */

import type {
  EventEditInput,
  EventOccurrence,
  EventRow,
  ExceptionInput,
  TimezoneIntent,
} from '../types/event';
import { addDaysToDateString } from '../utils/datetime';
import { isTimedMaster } from './timezoneRules';
import { TimezoneRequiredError } from '../errors';

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
export function buildException(occ: EventOccurrence, edited: EventEditInput): ExceptionInput {
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
 * Patch for editing an existing row from form input — a one-off, or a whole
 * series (scope 'all', applied to the master). Carries the recurrence rule
 * (a row that owns an rrule is a master) and the all-day-matched time fields,
 * explicitly nulling the unused time representation so switching all-day <->
 * timed stays consistent. For a series it is only used when there are no
 * exceptions (see seriesGuards).
 *
 * THIS IS THE ONLY PLACE AN ORDINARY EDIT DECIDES ANYTHING ABOUT `timezone`,
 * and the decision is deliberately narrow:
 *
 *   - the row stops being a timed master (becomes all-day, or loses its rrule)
 *     -> `timezone: null`, in the SAME patch, because a non-master may not
 *        carry one (DB: events_timezone_placement)
 *   - the row is already a timed master and stays one
 *     -> the key is OMITTED. A legacy master (timezone null, created before
 *        5b-2) therefore keeps its null and is never handed a guessed zone,
 *        and a master that has one never has it rewritten by an edit that was
 *        really about the title. Changing it is setSeriesTimezone's job alone.
 *   - the row is BECOMING a timed master
 *     -> `intent` must be 'adopt', and its zone is written alongside the rrule.
 *        The DB rejects a timed master without one, and the rule and the zone
 *        have to arrive in one statement, so this cannot be split.
 *
 * 'adopt' means ACQUISITION and nothing else, so it is valid on exactly one
 * transition: N -> M1. Pairing it with anything else — a row that is already a
 * master, or an edit that produces no timed master at all — is a caller
 * invariant violation and throws a plain Error. Both refusals are deliberately
 * NOT domain errors: TimezoneClearedError keeps its single meaning (M1 -> M0),
 * and SeriesEditBlockedError stays the user-facing "this series has exceptions".
 * editTimezoneIntent never produces either combination, and the unit tests pin
 * that down for every row state against every edit shape the form can make.
 */
export function rowPatchFromEdit(
  row: EventRow,
  edited: EventEditInput,
  intent: TimezoneIntent = { kind: 'keep' },
): Partial<EventRow> {
  const display = {
    title: edited.title,
    description: edited.description ?? null,
    category: edited.category ?? null,
    visibility: edited.visibility ?? 'private',
    rrule: edited.rrule ?? null,
  };
  const base: Partial<EventRow> = edited.allDay
    ? { ...display, allDay: true, startAt: null, endAt: null, startDate: edited.startDate, endDate: edited.endDate }
    : { ...display, allDay: false, startAt: edited.startAt, endAt: edited.endAt, startDate: null, endDate: null };

  const willBeTimedMaster = isTimedMaster({
    allDay: base.allDay === true,
    rrule: base.rrule ?? null,
  });
  const wasTimedMaster = isTimedMaster(row);

  if (!willBeTimedMaster) {
    if (intent.kind === 'adopt') {
      throw new Error(
        "rowPatchFromEdit: intent 'adopt' requires the edit to produce a timed recurrence master.",
      );
    }
    return { ...base, timezone: null };
  }

  if (wasTimedMaster) {
    if (intent.kind === 'adopt') {
      // A row that is already a master is not ACQUIRING a zone, it is changing
      // one, and setSeriesTimezone is the only path for that (it carries the
      // exception-staleness guard). Not SeriesEditBlockedError: that error means
      // "this series has exceptions" to the user, and this is a caller bug.
      throw new Error(
        "rowPatchFromEdit: intent 'adopt' is invalid for a row that is already a timed recurrence master; use setSeriesTimezone.",
      );
    }
    return base; // key omitted on purpose -- see the doc comment
  }

  if (intent.kind !== 'adopt') throw new TimezoneRequiredError();
  return { ...base, timezone: intent.timezone };
}

/**
 * Patch for editing an occurrence that is ALREADY an exception row, in place
 * (scope 'only'). Updates only the display/time fields; the row keeps its
 * recurrenceId, slot key, and rrule=null. Must not change all-day-ness (the slot
 * key type is fixed). isCancelled is reset to false: editing re-materialises the
 * occurrence as an override.
 *
 * `timezone` stays null: an exception is a snapshot with absolute times, and
 * the DB refuses a zone on anything but a master.
 */
export function exceptionPatchFromEdit(
  occ: EventOccurrence,
  edited: EventEditInput,
): Partial<EventRow> {
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
