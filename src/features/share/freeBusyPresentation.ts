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

import { t } from '../../i18n/t';
import { DEFAULT_LANGUAGE, type Language } from '../../i18n/types';
import type { FreeBusyResult } from '../../types/share';

/** What the page renders. */
export type FreeBusyPresentation = 'loading' | 'error' | 'unavailable' | 'calendar';

/**
 * The link cannot be read. No reason, ever.
 *
 * P6 STEP 2 TURNED THE TWO CONSTANTS INTO FUNCTIONS. They were resolved with
 * DEFAULT_LANGUAGE at import time, so the sentence a viewer saw was fixed
 * before the page knew who was reading it. On this route the reader is an
 * ANONYMOUS stranger whose language comes from their own browser, which is the
 * one case where a pinned string is certain to be wrong for someone.
 *
 * NO CACHE, unlike visibilityMeta. That one answers a hundred chips per month
 * grid; these two render at most once per page load, and a Map keyed by
 * language would be more machinery than the lookup it replaces. `t()` already
 * falls back to Japanese for an unrecognised language, so there is no
 * normalising left to do here either.
 */
export function unavailableMessage(lang: Language = DEFAULT_LANGUAGE): string {
  return t('share.unavailable', lang);
}

/**
 * An ACTIVE link that disclosed nothing for the requested period.
 *
 * Before 0023 this sentence carried a second clause saying a revoked or expired
 * link looked the same, because it did. It no longer does -- those links now
 * reach the unavailable state instead -- so the clause was removed rather than
 * left to mislead.
 *
 * `lang` DEFAULTS TO THE DEFAULT LANGUAGE, the shape every converted module in
 * this phase uses: the page passes the viewer's resolved language, and a call
 * with no argument still answers in the Japanese this page has always shown.
 */
export function activeEmptyMessage(lang: Language = DEFAULT_LANGUAGE): string {
  return t('share.activeEmpty', lang);
}

/**
 * The accessible name of ONE timed Busy/Available block.
 *
 * WHY IT EXISTS. The block renders its time range as text and carries an
 * `aria-label` for the state -- and an aria-label REPLACES the element's
 * contents for assistive technology, so a screen reader announced "Busy" and
 * the time was never read at all. Sighted viewers got the range and the colour;
 * screen-reader users got neither the range nor a way to ask for it. The name
 * now carries both.
 *
 * IT TAKES ALREADY-FORMATTED TIMES, not instants and a locale. That is the
 * point: the caller passes the very strings it is about to render, so the
 * spoken time cannot drift from the displayed one. Formatting here instead
 * would put two independent calls to `formatTime` in the same element and
 * invite exactly that.
 *
 * WHAT IT MUST NOT CARRY. A share link discloses that time is taken, never
 * what takes it. No title, description, category or visibility reaches this
 * function -- it is handed two clock strings and a state, and there is nothing
 * else for it to say.
 */
export function blockAccessibleName(
  state: 'busy' | 'available',
  /** The start, exactly as rendered -- e.g. formatTime(slot.start, locale). */
  start: string,
  /** The end, exactly as rendered. */
  end: string,
  lang: Language = DEFAULT_LANGUAGE,
): string {
  // The state label is looked up rather than passed in, so the two words stay
  // in one place and the guards that keep them distinct keep applying.
  const label = state === 'busy' ? t('sharePage.block.busy', lang) : t('sharePage.block.available', lang);
  return t('sharePage.block.timeRange', lang, { state: label, start, end });
}

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
