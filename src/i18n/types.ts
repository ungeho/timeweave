/**
 * The types the whole i18n layer is built on. No runtime values live here, so
 * anything may import it without pulling a dictionary in.
 *
 * SCOPE. This module and its siblings carry UI STRINGS ONLY. Long-form content
 * -- help pages, guides, FAQ -- is deliberately NOT a dictionary entry: it will
 * live as Markdown under `docs/content/<lang>/<page-id>.md`, keyed by a
 * language-independent page id (see docs/i18n-architecture.md section 3). The
 * two share exactly one thing, the `Language` type and the resolver, and
 * nothing else. Mixing prose into the dictionary would make every page edit a
 * code change and put translators in the source tree.
 */

/** The languages the UI can render. Shared with the future docs routing. */
export type Language = 'ja' | 'en';

/**
 * The fallback, named rather than written as a literal at each use site.
 *
 * Japanese, not English, and that is a product decision rather than a default:
 * every string in the app is Japanese today, so a viewer whose language we
 * cannot place sees a complete UI instead of a half-translated one.
 */
export const DEFAULT_LANGUAGE: Language = 'ja';

/** All supported languages, in the order a picker should offer them. */
export const LANGUAGES: readonly Language[] = ['ja', 'en'];

/**
 * Whether the UI actually renders in the resolved language yet. **P6 flips it.**
 *
 * WITHOUT THIS FLAG, P3 WOULD SHIP A HALF-TRANSLATED APP. Resolution already
 * works: a viewer whose browser is English resolves to `en` today. So the
 * moment the first component starts reading the resolved language, that
 * viewer sees that component in English while every string not yet migrated
 * stays Japanese -- which is exactly the state the phase ordering exists to
 * avoid, and it would last for the whole of P3 to P5.
 *
 * So components may be migrated to `useTranslate()` from now on, and until
 * this is `true` they are handed the default language regardless of what was
 * resolved. P6 is then one line here plus removing the "not live yet" notice,
 * rather than a second sweep over every file that P3 touched.
 *
 * The resolution itself is NOT suppressed -- `resolvedLanguage` on the context
 * keeps reporting the real answer, so the provider's behaviour stays testable
 * and observable while the screen does not move.
 */
export const LANGUAGE_SWITCH_ENABLED = true;

/** Narrow an arbitrary string to a Language. Used on stored and wire values. */
export function isLanguage(value: unknown): value is Language {
  return value === 'ja' || value === 'en';
}

/**
 * The placeholder names inside a message, read off the string's literal type.
 *
 * `'{n} / {max}'` yields `'n' | 'max'`; a message with no braces yields `never`.
 * This is what makes `t()` demand exactly the right variables at compile time
 * instead of discovering a missing one as a stray `{max}` on screen.
 *
 * The recursion walks the string one placeholder at a time. It only works on a
 * LITERAL type, which is why the dictionaries are declared `as const` -- a
 * plain `Record<string, string>` would widen every message to `string` and
 * collapse this to `never`, silently turning every call into a zero-argument
 * one.
 */
export type ExtractVars<S extends string> =
  S extends `${string}{${infer Name}}${infer Rest}`
    ? Name | ExtractVars<Rest>
    : never;

/** The values a placeholder may be given. Numbers are formatted by `String`. */
export type VarValue = string | number;
