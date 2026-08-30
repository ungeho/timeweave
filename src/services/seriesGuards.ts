/**
 * Guards for editing recurring series. Pure so the policy is testable.
 *
 * Phase 4 policy: because exception rows are full snapshots (their title/etc.
 * are independent of the master), a whole-series "edit all" would silently keep
 * stale values on existing exceptions. So an "edit all" is blocked entirely for
 * any series that already has exceptions. ("Delete all" and "this occurrence
 * only" remain allowed.) When field-level override/inherit is implemented later,
 * this single guard can be relaxed.
 */

import type { EventRow } from '../types/event';

/** True if the master identified by `masterId` has any exception rows. */
export function seriesHasExceptions(masterId: string, rows: EventRow[]): boolean {
  return rows.some((r) => r.recurrenceId === masterId);
}
