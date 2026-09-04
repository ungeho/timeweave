/**
 * The events.timezone state machine, mirrored from migration 0008.
 *
 * The database is the authority: `events_timezone_placement` (a CHECK) and
 * `events_validate_timezone` (a BEFORE INSERT OR UPDATE trigger, delegating to
 * `events_timezone_transition_error`) enforce these rules for every writer.
 * This module is the TypeScript twin, so that
 *
 *   - the localStorage repository behaves the same way in local mode, where
 *     there is no database at all, and
 *   - the rules are unit-testable case by case, against the same table the SQL
 *     suite asserts (supabase/tests/0008_events_timezone_test.sql, section 3).
 *
 * THE STATE MODEL
 *   isTimedMaster(row) := row.allDay === false && row.rrule !== null
 *
 *     N  = not a timed master (all-day rows, timed one-offs, exceptions).
 *          timezone is null.
 *     M0 = timed master, timezone null -- LEGACY only, rows predating 5b-2.
 *     M1 = timed master with a zone.
 *
 *   INSERT -> N   ok      INSERT -> M0  REJECT     INSERT -> M1  ok
 *   N  -> N       ok      N  -> M0      REJECT     N  -> M1      ok
 *   M0 -> N       ok      M0 -> M0      ok         M0 -> M1      ok
 *   M1 -> N       ok      M1 -> M0      REJECT     M1 -> M1'     ok
 *
 * M0 -> M0 is the grandfather clause: a legacy series stays fully editable
 * without being made to guess the zone it was authored in. M0 is otherwise
 * unreachable -- no transition leads into it -- so the only M0 rows that exist
 * are the ones that predate the migration.
 *
 * M1 -> M0 is refused both because it silently regresses a supported series to
 * unsupported, and because without it the INSERT rule could be bypassed by
 * inserting with a zone and then nulling it.
 */

import type { TimezoneIntent } from '../types/event';

/** The three tokens the DB puts in a failure's DETAIL field. */
export type TimezoneViolation =
  | 'TIMEWEAVE_TZ_INVALID'
  | 'TIMEWEAVE_TZ_REQUIRED'
  | 'TIMEWEAVE_TZ_CLEARED';

/** The parts of a row these rules look at. */
export interface TimezoneShape {
  allDay: boolean;
  rrule: string | null;
  recurrenceId: string | null;
  timezone: string | null;
}

/** Mirrors `is_timed_master(row)` in migration 0008. */
export function isTimedMaster(row: Pick<TimezoneShape, 'allDay' | 'rrule'>): boolean {
  return row.allDay === false && row.rrule !== null;
}

/** The shape an edit form currently describes. `rrule` undefined = don't touch. */
export interface EditShape {
  allDay: boolean;
  rrule: string | null | undefined;
}

/**
 * The `TimezoneIntent` an ORDINARY edit should carry — the single place the UI
 * decides it, so the invariant `rowPatchFromEdit` enforces cannot be broken by
 * a form path. 'adopt' comes back ONLY when the edit's result is a timed master
 * and the row was not one, which is exactly the acquisition case; every other
 * combination is 'keep', including a row that is already a master (changing an
 * existing series' zone is setSeriesTimezone's job).
 *
 * Returns null when the edit needs a zone but `resolvedZone` is null: there is
 * no defensible value, so the caller must refuse to save rather than guess one.
 */
export function editTimezoneIntent(
  row: Pick<TimezoneShape, 'allDay' | 'rrule'>,
  next: EditShape,
  resolvedZone: string | null,
): TimezoneIntent | null {
  const willBeTimedMaster = next.allDay === false && next.rrule != null;
  if (!willBeTimedMaster || isTimedMaster(row)) return { kind: 'keep' };
  if (resolvedZone === null) return null;
  return { kind: 'adopt', timezone: resolvedZone };
}

/**
 * Mirrors the `events_timezone_placement` CHECK: only a timed recurrence MASTER
 * may carry a zone. The recurrenceId test is redundant in the DB (a row cannot
 * hold both an rrule and a recurrenceId) but is spelled out there and here, so
 * that "a zone belongs to a master, never to an exception snapshot" is legible
 * without chasing another constraint.
 */
export function timezonePlacementOk(row: TimezoneShape): boolean {
  if (row.timezone === null) return true;
  return row.allDay === false && row.rrule !== null && row.recurrenceId === null;
}

/**
 * Mirrors `events_timezone_transition_error()`. Returns null when the
 * transition is allowed, or the token naming the reason when it is not.
 *
 * `prev` is null for an insert. Branch order matches the SQL CASE exactly.
 */
export function timezoneTransitionError(
  isInsert: boolean,
  prev: TimezoneShape | null,
  next: TimezoneShape,
): TimezoneViolation | null {
  // The resulting row is not a timed master: nothing to enforce here. The
  // placement rule already forces its timezone to be null.
  if (!isTimedMaster(next)) return null;

  // A timed master that carries a zone. Its VALUE is checked separately.
  if (next.timezone !== null) return null;

  // From here down: a timed master with NO zone.
  if (isInsert) return 'TIMEWEAVE_TZ_REQUIRED';

  // Grandfathered: it was already a zone-less timed master and still is.
  if (prev !== null && isTimedMaster(prev) && prev.timezone === null) return null;

  // It had a zone and this update would drop it.
  if (prev !== null && isTimedMaster(prev) && prev.timezone !== null) {
    return 'TIMEWEAVE_TZ_CLEARED';
  }

  // Anything else becoming a zone-less timed master: a one-off promoted to a
  // series, an all-day series turned timed, an exception rewritten into a
  // master. All of these are NEW recurrences and must declare their zone.
  return 'TIMEWEAVE_TZ_REQUIRED';
}
