/**
 * Turn a caught value into words, in a language.
 *
 * The one place that answers "something was thrown; what does the screen say?"
 * -- so the answer is the same on every screen, and so the three cases are
 * decided once rather than re-argued at each catch site.
 *
 * WHY IT IS HERE AND NOT BESIDE A FEATURE. It began as
 * `features/calendar/loadErrorText.ts` in P6 step 5, which was the right place
 * while the calendar was the only caller. ShareDialog needs the identical
 * decision, and reusing that module would have carried two pieces of calendar
 * into the share screen: the NAME (`loadErrorDetail` -- nothing is being
 * loaded when a revoke fails) and, worse, the fallback KEY, which was
 * `calendar.loadErrorUnknown`. A share dialog rendering a calendar-namespaced
 * string is the kind of thing that is correct today and wrong the first time
 * either message is reworded. So the logic moved here and the key became
 * `error.unknownCause`; the wording did not change, in either language.
 *
 * A PURE MODULE, because vitest runs with `environment: 'node'` and jsdom is
 * not added -- a decision written inline in JSX could not be tested at all.
 */

import { isDomainError } from '../errors';
import { t } from './t';
import { DEFAULT_LANGUAGE, type Language } from './types';

/**
 * What to show for a value a `catch` received.
 *
 * THE THREE CASES, in the order they are tested:
 *
 *   A DomainError answers through `localize(lang)`. This is the only branch
 *   that can follow the language: the class knows its own key, its own
 *   variables, and whether the thrower supplied wording of its own.
 *
 *   A plain Error keeps `.message`, which is exactly what every call site
 *   showed before P6. Deliberately NOT translated -- an arbitrary message is a
 *   string somebody chose, and replacing it with a generic sentence would
 *   discard information the owner can act on. The same contract
 *   `hasCustomMessage` enforces inside the error classes, applied one level up.
 *
 *   ANYTHING ELSE gets a generic sentence rather than `String(cause)`. That is
 *   a deliberate narrowing: `String(null)` is "null", `String({})` is
 *   "[object Object]" -- neither tells the owner anything -- while
 *   `String(someThrownObject)` runs whatever `toString` that object carries
 *   and puts the result on screen. A non-Error throw is a bug path, not a
 *   diagnosis, so the value stays out of the DOM.
 *
 * `lang` defaults to the default language, the shape every module converted in
 * this phase uses, so a call with no argument answers in Japanese.
 */
export function caughtErrorText(cause: unknown, lang: Language = DEFAULT_LANGUAGE): string {
  // Order matters: isDomainError is a narrowing of `instanceof Error`, so it
  // has to be asked first or every domain error would take the plain branch
  // and lose its localize().
  if (isDomainError(cause)) return cause.localize(lang);
  if (cause instanceof Error) return cause.message;
  return t('error.unknownCause', lang);
}
