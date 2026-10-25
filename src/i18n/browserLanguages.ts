/**
 * THE ONLY PLACE THAT READS THE BROWSER'S LANGUAGE.
 *
 * Kept to one function on purpose. The survey before this phase found zero
 * reads of `navigator.language` anywhere in the codebase, and the way that
 * stays true is by giving the read a single home before the first caller
 * exists. Scattered reads are how an app ends up with the header in one
 * language and a dialog in another.
 *
 * `languages` (plural) rather than `language`, because the ordered list is
 * what lets a viewer whose first preference is French and whose second is
 * English get English instead of the fallback. `language` alone would throw
 * that away.
 */

/**
 * The viewer's language preferences, best first.
 *
 * Returns an empty array rather than throwing when `navigator` is absent or
 * exposes neither field: resolveLanguage treats that as "unplaceable" and
 * answers Japanese, which is the behaviour the app already has. This runs in
 * vitest's node environment during the provider tests, where there is no
 * navigator at all.
 */
export function browserLanguages(): readonly string[] {
  try {
    const nav = typeof navigator === 'undefined' ? undefined : navigator;
    if (!nav) return [];
    if (Array.isArray(nav.languages) && nav.languages.length > 0) {
      return nav.languages;
    }
    return typeof nav.language === 'string' && nav.language !== '' ? [nav.language] : [];
  } catch {
    return [];
  }
}
