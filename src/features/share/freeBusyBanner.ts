/**
 * The one line the share page shows when Free/Busy could not be fetched.
 *
 * Kept as a pure function, UI-free, for two reasons:
 *   * it is the only place that decides WHICH failure gets which words, so it
 *     can be unit-tested without a component test harness (this project has
 *     none, and this change does not add one);
 *   * the safety note is appended HERE, once, rather than written into each
 *     branch. That is what makes "an error can never be read as 'no events'"
 *     structural instead of a rule someone has to remember.
 *
 * An unrecognised failure keeps the wording the page has always used. The
 * database message is deliberately NOT shown: it is English prose aimed at
 * logs, and for a revoked-or-unknown token the page must stay uninformative.
 */

import { FreeBusyRateLimitedError } from '../../errors';

/** Always appended: an error state is never a claim that the owner is free. */
const NOT_FREE_NOTE = '（この画面は「予定なし」を意味しません）';

const GENERIC = '空き時間を取得できませんでした。時間をおいて再読み込みしてください。';

/**
 * Banner text for a failed Free/Busy load, including the safety note.
 *
 * `cause` is whatever the promise rejected with, so it is typed as unknown:
 * network failures reject with a DOMException, the RPC with an Error, and a bug
 * could reject with anything at all.
 */
export function freeBusyErrorBanner(cause: unknown): string {
  const lead = cause instanceof FreeBusyRateLimitedError ? cause.message : GENERIC;
  return `${lead}${NOT_FREE_NOTE}`;
}
