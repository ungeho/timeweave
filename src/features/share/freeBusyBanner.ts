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

import { t } from '../../i18n/t';
import { DEFAULT_LANGUAGE, type Language } from '../../i18n/types';
import { FreeBusyRateLimitedError } from '../../errors';

/**
 * Banner text for a failed Free/Busy load, including the safety note.
 *
 * `cause` is whatever the promise rejected with, so it is typed as unknown:
 * network failures reject with a DOMException, the RPC with an Error, and a bug
 * could reject with anything at all.
 *
 * P6 STEP 2 GAVE IT THE LANGUAGE, and that had to include the LEAD as well as
 * the note. The note and the generic sentence used to be module constants
 * resolved with DEFAULT_LANGUAGE at import time; translating only those two
 * would have produced the worst possible result for a rate-limit refusal --
 * a Japanese lead from `cause.message` with an English note glued to it, one
 * sentence in two languages. So the refusal is read through its own
 * `localize(lang)`, which 0019's error class already carries.
 *
 * NOTHING ABOUT THE JAPANESE MOVES. `localize` returns `this.message` verbatim
 * when the error was constructed with an explicit message, and otherwise
 * re-resolves the same key with the same `retryAdvice` -- so for `lang` = ja
 * every branch is byte-identical to the string this function used to build.
 */
export function freeBusyErrorBanner(cause: unknown, lang: Language = DEFAULT_LANGUAGE): string {
  const lead =
    cause instanceof FreeBusyRateLimitedError
      ? cause.localize(lang)
      : t('share.error.generic', lang);
  return `${lead}${t('share.error.notFreeNote', lang)}`;
}
