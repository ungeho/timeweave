/**
 * High-level edit/delete operations on recurring occurrences, orchestrating the
 * repository. Pure of React (takes a repository + current rows) so the routing
 * — which repository method runs, with which argument — is directly testable.
 *
 * useEvents wraps these and reloads afterwards.
 */

import type { EditScope, EventOccurrence, EventRow, NewEvent } from '../types/event';
import type { EventRepository } from '../repositories/eventRepository';
import {
  buildCancellation,
  buildException,
  exceptionPatchFromEdit,
  masterPatchFromEdit,
} from './exceptionEdit';
import { seriesHasExceptions } from './seriesGuards';
import { SeriesEditBlockedError } from '../errors';

/** The master id a recurring occurrence belongs to (itself if it's a master). */
export function masterIdOf(occ: EventOccurrence): string {
  return occ.isException ? occ.event.recurrenceId! : occ.event.id;
}

/**
 * Edit a recurring occurrence.
 * - scope 'all': edit the master, unless the series already has exceptions
 *   (then SeriesEditBlockedError — exceptions are snapshots and would go stale).
 * - scope 'only', already an exception: update that exception row in place (no
 *   new INSERT, which would collide on the slot).
 * - scope 'only', generated occurrence: insert a new override exception.
 */
export async function editOccurrence(
  repo: EventRepository,
  rows: EventRow[],
  occ: EventOccurrence,
  edited: NewEvent,
  scope: EditScope,
): Promise<void> {
  if (scope === 'all') {
    const masterId = masterIdOf(occ);
    if (seriesHasExceptions(masterId, rows)) throw new SeriesEditBlockedError();
    await repo.update(masterId, masterPatchFromEdit(edited));
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
