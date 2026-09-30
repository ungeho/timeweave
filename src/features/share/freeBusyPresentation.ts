/**
 * Which of the four things the share page shows, and the two sentences that
 * belong to the link-state outcomes (migration 0023).
 *
 * Kept as a pure function next to freeBusyBanner, for the reason that file
 * gives: this project has no component test harness, so a decision written
 * inline in JSX cannot be tested at all. The copy lives here so a test can
 * assert what it does and does not say.
 *
 * DELIBERATELY SEPARATE FROM freeBusyBanner. That module answers "the fetch
 * failed, what do we say". An unavailable link is not a failure -- it is a
 * successful API result with link_state='unavailable'. Folding the two together
 * would make the page treat a normal answer as an error, which is exactly the
 * confusion 0023 exists to remove.
 *
 * THE UNAVAILABLE COPY NAMES NO REASON. Expired, revoked, deleted, unknown and
 * malformed all arrive here as the same state, and the backend does not tell us
 * which it was. Even if it did, saying so would hand an observer the reason
 * oracle the whole design withholds.
 */

import type { FreeBusyResult } from '../../types/share';

/** What the page renders. */
export type FreeBusyPresentation = 'loading' | 'error' | 'unavailable' | 'calendar';

/** The link cannot be read. No reason, ever. */
export const UNAVAILABLE_MESSAGE = 'この共有リンクは利用できません。';

/**
 * An ACTIVE link that disclosed nothing for the requested period.
 *
 * Before 0023 this sentence carried a second clause saying a revoked or expired
 * link looked the same, because it did. It no longer does -- those links now
 * reach the unavailable state instead -- so the clause was removed rather than
 * left to mislead.
 */
export const ACTIVE_EMPTY_MESSAGE = 'この期間に共有されている予定はありません。';

/** The page's load state, structurally: only what this decision needs. */
export type FreeBusyLoad =
  | { status: 'loading' }
  | { status: 'error' }
  | { status: 'ok'; result: Pick<FreeBusyResult, 'linkState'> };

/**
 * Pick the presentation. `unavailable` is chosen only for an ok result whose
 * linkState is exactly 'unavailable' -- the repository has already normalised
 * anything unrecognised to 'active', so nothing ambiguous reaches here.
 */
export function freeBusyPresentation(load: FreeBusyLoad): FreeBusyPresentation {
  if (load.status === 'loading') return 'loading';
  if (load.status === 'error') return 'error';
  return load.result.linkState === 'unavailable' ? 'unavailable' : 'calendar';
}
