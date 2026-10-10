/**
 * What the share page shows for AVAILABLE time (migration 0024), and the two
 * sentences that belong to the states which have no slots to draw.
 *
 * A sibling of freeBusyPresentation, for the reason that file gives: vitest runs
 * with environment: 'node' and there is no component harness, so a decision
 * written inline in JSX cannot be tested at all. The copy lives here so a test
 * can assert what it does -- and does not -- say.
 *
 * THE DANGEROUS CASE IS `indeterminate`, and everything here is shaped around
 * it. 0024 answers that when the window holds a recurrence it cannot expand
 * exactly, in either the available or the busy set. The truthful rendering is a
 * sentence saying open time could not be determined. The tempting one -- an
 * empty availability strip, or "no open time" -- converts "we do not know" into
 * a claim about the owner's calendar, and a viewer acts on it either way.
 */

import type { AvailableResult, FreeBusySlot } from '../../types/share';

/** What the available section renders. */
export type AvailablePresentation =
  /** Nothing at all: no heading, no strip, no sentence. */
  | 'hidden'
  /** The sentence below, and NO slots. */
  | 'indeterminate'
  /** The slots that came back, which may be an empty set. */
  | 'slots';

/**
 * An opted-in link whose window could not be computed exactly.
 *
 * Says what is unknown and nothing else. It must NOT name the reason (an
 * unexpandable recurrence is a detail of the owner's calendar), and it must not
 * soften into "no open time at the moment", which is the claim this state
 * exists to avoid making.
 */
export const AVAILABLE_INDETERMINATE_MESSAGE =
  '空き時間を正確に判定できませんでした。この期間については、空いているかどうかを確認するには直接ご連絡ください。';

/**
 * An exact computation that disclosed no available time.
 *
 * This one CAN speak plainly, because `complete` means the subtraction was
 * exact. It still says "shared", not "has": the owner may have open time they
 * simply did not mark as available, and this page has no way to tell.
 */
export const AVAILABLE_EMPTY_MESSAGE = 'この期間に共有されている空き時間はありません。';

/**
 * Pick the presentation for one `available` result.
 *
 * `not_requested` maps to 'hidden' rather than to an empty strip: the link was
 * never opted in (or the backend predates 0024), so the page has not been told
 * anything about open time and must not imply it was. A viewer of an opted-out
 * link sees exactly the page they saw before this feature existed.
 */
export function availablePresentation(available: AvailableResult): AvailablePresentation {
  switch (available.status) {
    case 'complete':
      return 'slots';
    case 'indeterminate':
      return 'indeterminate';
    default:
      return 'hidden';
  }
}

/**
 * The slots to draw, and only in the one state that has any.
 *
 * Returns an empty array for every other state, so a caller cannot reach the
 * slots of a state that should not show them -- `indeterminate` has none by
 * construction, and this makes that structural rather than a rule to remember.
 */
export function availableSlots(available: AvailableResult): FreeBusySlot[] {
  return available.status === 'complete' ? available.slots : [];
}

/**
 * Whether any open time is actually drawn on the grid.
 *
 * Exists to stop ONE contradiction. The busy-empty notice reads "no events are
 * shared for this period", and it is driven by hasNoDisclosedBusy, which — as
 * its name says — looks at the BUSY set alone. That was the whole truth before
 * 0024. It no longer is: an owner whose week holds available events and no busy
 * ones produces `complete` busy with an empty array AND available blocks, so
 * the page would announce that nothing is shared directly above the blocks it
 * is sharing.
 *
 * The notice is suppressed in exactly that case and nowhere else. An opted-out
 * link, an indeterminate answer and an opted-in link that found nothing all
 * still get it, because for them the sentence is still true.
 */
export function hasDisclosedAvailable(available: AvailableResult): boolean {
  return availableSlots(available).length > 0;
}
