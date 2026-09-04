/**
 * Core domain types for scheduled events.
 *
 * Design notes:
 * - Timed events store UTC ISO 8601 instants (`startAt`/`endAt`). All-day
 *   events store calendar dates (`startDate`/`endDate`, "YYYY-MM-DD") with
 *   `endDate` EXCLUSIVE, so both share half-open [start, end) semantics and
 *   all-day handling never goes through a timezone conversion.
 * - Exactly one representation is populated, keyed by `allDay`. This mirrors
 *   the Supabase `events` table 1:1 (the DB CHECK constraint enforces it).
 * - A row can be a one-off event, a recurring "master" (`rrule`), or an
 *   exception overriding one occurrence of a master (`recurrenceId` + a slot
 *   key). The slot key is type-safe: `recurrenceSlotStart` for timed masters,
 *   `recurrenceSlotDate` for all-day masters.
 * - Tasks (flexible, auto-schedulable work) are intentionally NOT here; they
 *   live in `types/task.ts` so fixed events and flexible tasks never conflate.
 */

export type Visibility = 'private' | 'busy_only' | 'public';

/** A persisted event row (one-off, recurring master, or exception). */
export interface EventRow {
  id: string;
  ownerId: string;
  title: string;
  description: string | null;
  category: string | null;
  visibility: Visibility;

  allDay: boolean;

  /** Timed events (allDay === false). UTC ISO 8601. null when all-day. */
  startAt: string | null;
  /** Timed end, exclusive. null when all-day. */
  endAt: string | null;

  /** All-day events (allDay === true). "YYYY-MM-DD" local calendar date. null when timed. */
  startDate: string | null;
  /** All-day end date, EXCLUSIVE. null when timed. */
  endDate: string | null;

  /**
   * iCalendar RRULE for a recurring master, e.g. "FREQ=WEEKLY;BYDAY=MO".
   * null for one-off events and exception rows. See services/recurrence.ts.
   */
  rrule: string | null;

  /** When this row is an exception, the id of the master it overrides. */
  recurrenceId: string | null;
  /** RECURRENCE-ID for a timed master's overridden occurrence (UTC ISO). */
  recurrenceSlotStart: string | null;
  /** RECURRENCE-ID for an all-day master's overridden occurrence ("YYYY-MM-DD"). */
  recurrenceSlotDate: string | null;
  /** "Delete this occurrence" tombstone (only meaningful on exception rows). */
  isCancelled: boolean;

  /**
   * IANA zone a TIMED recurrence master's wall clock is anchored in — the zone
   * `startAt` should be read in to recover the rule's DTSTART. null everywhere
   * else (all-day rows, timed one-offs, exception snapshots) and null on
   * masters created before Phase 5b-2. Stored verbatim, never canonicalised:
   * an alias such as "Asia/Calcutta" resolves to the same rules as its primary
   * name, and the database does not normalise it either.
   */
  timezone: string | null;

  createdAt: string;
  updatedAt: string;
}

/** Display fields shared by create and edit inputs. */
interface EventContent {
  title: string;
  description?: string | null;
  category?: string | null;
  visibility?: Visibility;
}

/**
 * Input for CREATING an event. Discriminated on `allDay` so callers must
 * provide the matching time representation — the compiler prevents mixing
 * instants and dates.
 *
 * A new TIMED RECURRENCE must declare its time zone: the series repeats at a
 * wall-clock time, so across a DST boundary the instants shift, and `startAt`
 * alone cannot reproduce them. There is no defensible default, and guessing one
 * would silently decide what the series means. The other three shapes cannot
 * carry a zone at all (`timezone?: never`), mirroring the DB's placement CHECK.
 */
export type NewEvent =
  // all-day, one-off or recurring
  | (EventContent & {
      allDay: true;
      startDate: string;
      endDate: string;
      rrule?: string | null;
      timezone?: never;
    })
  // timed one-off
  | (EventContent & {
      allDay?: false;
      startAt: string;
      endAt: string;
      rrule?: null;
      timezone?: never;
    })
  // timed recurrence master
  | (EventContent & {
      allDay?: false;
      startAt: string;
      endAt: string;
      rrule: string;
      timezone: string;
    });

/**
 * Input for EDITING an existing event or occurrence. Deliberately has NO
 * `timezone` member in any shape.
 *
 * An ordinary edit must never touch the column. A legacy master (timezone null,
 * created before 5b-2) has to stay editable without acquiring a guessed zone,
 * and a master that already has one must not have it rewritten as a side effect
 * of renaming the event. Both follow from the field simply not being
 * expressible here. Acquiring a zone travels in `TimezoneIntent`; changing an
 * existing series' zone goes through `setSeriesTimezone` and nowhere else.
 */
export type EventEditInput =
  | (EventContent & {
      allDay: true;
      startDate: string;
      endDate: string;
      rrule?: string | null;
      timezone?: never;
    })
  | (EventContent & {
      allDay?: false;
      startAt: string;
      endAt: string;
      rrule?: string | null;
      timezone?: never;
    });

/**
 * What an edit should do to `timezone`. Kept OUT of `EventEditInput` so an
 * ordinary edit cannot carry a zone even by accident.
 *
 * - `keep`  — every ordinary edit. The column is left untouched (the patch
 *   omits the key, so a legacy null stays null and an existing zone survives)
 *   or explicitly nulled when the row stops being a timed master.
 * - `adopt` — the row is BECOMING a timed recurrence master: a one-off gains an
 *   rrule, or an all-day series turns timed. It is acquiring a zone for the
 *   first time, in the same UPDATE that adds the rule — which is why the value
 *   travels with the edit rather than through `setSeriesTimezone`.
 *
 * `adopt` on a row that is ALREADY a timed master is rejected: that would be
 * changing an existing series' zone, and `setSeriesTimezone` is the only path.
 */
export type TimezoneIntent =
  | { kind: 'keep' }
  | { kind: 'adopt'; timezone: string };

/** Scope of an edit/delete on a recurring occurrence. */
export type EditScope = 'only' | 'all';

/**
 * Fields for creating an exception row (an override or cancellation of one
 * master occurrence). owner_id/id/timestamps come from DB defaults. The slot key
 * type must match `allDay` (DB CHECK): timed -> recurrenceSlotStart, all-day ->
 * recurrenceSlotDate.
 */
export interface ExceptionInput {
  recurrenceId: string;
  recurrenceSlotStart: string | null;
  recurrenceSlotDate: string | null;
  isCancelled: boolean;
  allDay: boolean;
  startAt: string | null;
  endAt: string | null;
  startDate: string | null;
  endDate: string | null;
  title: string;
  description: string | null;
  category: string | null;
  visibility: Visibility;
}

/**
 * A single concrete instance produced by expanding events over a date range.
 * Never persisted — computed for rendering only. `start`/`end` are always UTC
 * ISO instants (for all-day rows these are the local-midnight boundaries) so
 * the UI can group and sort uniformly; `allDay` tells the UI how to render.
 */
export interface EventOccurrence {
  event: EventRow;
  start: string;
  end: string;
  allDay: boolean;
  /**
   * Stable key of the master's original slot for this instance, used to match
   * exceptions/cancellations. For timed rows a UTC ISO instant; for all-day
   * rows a "YYYY-MM-DD" date. Equals the instance's own start key otherwise.
   */
  occurrenceKey: string;
  isException: boolean;
}
