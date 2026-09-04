/**
 * High-level edit/delete operations on recurring occurrences, orchestrating the
 * repository. Pure of React (takes a repository + current rows) so the routing
 * — which repository method runs, with which argument — is directly testable.
 *
 * useEvents wraps these and reloads afterwards.
 */

import type {
  EditScope,
  EventEditInput,
  EventOccurrence,
  EventRow,
  TimezoneIntent,
} from '../types/event';
import type { EventRepository } from '../repositories/eventRepository';
import {
  buildCancellation,
  buildException,
  exceptionPatchFromEdit,
  rowPatchFromEdit,
} from './exceptionEdit';
import { seriesHasExceptions } from './seriesGuards';
import { isTimedMaster } from './timezoneRules';
import { isStorableTimeZone } from '../utils/timezone';
import { InvalidTimezoneError, SeriesEditBlockedError } from '../errors';

/** The master id a recurring occurrence belongs to (itself if it's a master). */
export function masterIdOf(occ: EventOccurrence): string {
  return occ.isException ? occ.event.recurrenceId! : occ.event.id;
}

/** The current row behind an id. Missing means the caller's state is stale. */
function requireRow(rows: EventRow[], id: string): EventRow {
  const row = rows.find((r) => r.id === id);
  if (!row) throw new Error(`Event row not found: ${id}`);
  return row;
}

/**
 * Edit a recurring occurrence.
 * - scope 'all': edit the master, unless the series already has exceptions
 *   (then SeriesEditBlockedError — exceptions are snapshots and would go stale).
 * - scope 'only', already an exception: update that exception row in place (no
 *   new INSERT, which would collide on the slot).
 * - scope 'only', generated occurrence: insert a new override exception.
 *
 * `intent` reaches only the scope-'all' path, and only matters when the edit
 * turns an all-day series into a timed one: that row is BECOMING a timed master
 * and must acquire a zone in the same UPDATE as the rrule (see rowPatchFromEdit).
 * Both 'only' paths write exception rows, which never carry a zone at all.
 */
export async function editOccurrence(
  repo: EventRepository,
  rows: EventRow[],
  occ: EventOccurrence,
  edited: EventEditInput,
  scope: EditScope,
  intent: TimezoneIntent = { kind: 'keep' },
): Promise<void> {
  if (scope === 'all') {
    const masterId = masterIdOf(occ);
    if (seriesHasExceptions(masterId, rows)) throw new SeriesEditBlockedError();
    const master = requireRow(rows, masterId);
    await repo.update(masterId, rowPatchFromEdit(master, edited, intent));
  } else if (occ.isException) {
    await repo.update(occ.event.id, exceptionPatchFromEdit(occ, edited));
  } else {
    await repo.createException(buildException(occ, edited));
  }
}

/**
 * Delete a recurring occurrence.
 * - scope 'all': remove the master (cascades to its exceptions).
 * - scope 'only', already an exception: flip it to a cancellation tombstone.
 * - scope 'only', generated occurrence: insert a cancellation exception.
 */
export async function deleteOccurrence(
  repo: EventRepository,
  occ: EventOccurrence,
  scope: EditScope,
): Promise<void> {
  if (scope === 'all') {
    await repo.remove(masterIdOf(occ));
  } else if (occ.isException) {
    await repo.update(occ.event.id, { isCancelled: true });
  } else {
    await repo.createException(buildCancellation(occ));
  }
}

/**
 * Set or change the time zone of an EXISTING timed recurrence master. This is
 * the only path that writes `timezone` on a row that is already a master — an
 * ordinary edit deliberately cannot (rowPatchFromEdit omits the key), so that
 * renaming an event never rewrites what its series means.
 *
 * It is a separate operation because the zone is part of the rule: change it and
 * every future occurrence lands on a different instant, so the slot keys that
 * existing exception rows are pinned to would no longer name a real occurrence.
 * Hence the same staleness guard that blocks "edit all".
 *
 * Setting the zone a master already has writes nothing, so a no-op is never
 * blocked by that guard. A legacy master (M0) acquiring its first zone goes
 * through here too — that is M0 -> M1, which the DB allows.
 */
export async function setSeriesTimezone(
  repo: EventRepository,
  rows: EventRow[],
  masterId: string,
  timezone: string,
): Promise<void> {
  const master = requireRow(rows, masterId);
  if (!isTimedMaster(master)) {
    throw new InvalidTimezoneError('タイムゾーンを持てるのは時刻ありの繰り返し予定だけです');
  }
  if (master.timezone === timezone) return;
  if (!isStorableTimeZone(timezone)) throw new InvalidTimezoneError();
  if (seriesHasExceptions(masterId, rows)) {
    throw new SeriesEditBlockedError(
      '個別に変更した回があるため、繰り返しのタイムゾーンは変更できません',
    );
  }
  await repo.update(masterId, { timezone });
}
