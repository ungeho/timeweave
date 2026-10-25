/**
 * Which language to render in. The single decision, shared by the UI and by
 * the future documentation routes.
 *
 * THE ASYMMETRY WITH TIME ZONE IS THE POINT, and getting it backwards is the
 * mistake this function exists to make impossible:
 *
 *   time zone  belongs to the OWNER. An all-day event means a day in the
 *              owner's calendar, so anonymous Free/Busy reads the owner's
 *              declared zone and never the viewer's -- deriving it from
 *              caller-supplied input would let a viewer move the boundary
 *              (migration 0025, section 6a).
 *   language   belongs to WHOEVER IS LOOKING. An anonymous viewer has no
 *              stored preference and must get their own browser's language;
 *              rendering the owner's choice would hand a stranger a page they
 *              cannot read.
 *
 * So `stored` is null for every anonymous caller, and that is not a missing
 * value to be filled in from somewhere else -- it is the correct input.
 */

import { DEFAULT_LANGUAGE, isLanguage, type Language } from './types';

export interface LanguageInput {
  /**
   * `owner_settings.language`, or null.
   *
   * null means "follow the browser", which is both the unset state for a
   * signed-in owner and the only possible state for an anonymous viewer.
   */
  stored: Language | null;
  /**
   * The viewer's preferences, best first -- `navigator.languages` as it comes.
   *
   * Taken as an argument rather than read from `navigator` here so the
   * function stays pure and testable in this project's node environment.
   */
  browser: readonly string[];
}

/**
 * Match one BCP 47 tag against the supported set.
 *
 * Compares only the PRIMARY SUBTAG, case-insensitively: `en-GB`, `en-US` and
 * `EN` all resolve to `en`. Matching the whole tag would leave most of the
 * world's English and Japanese speakers falling through to the default for no
 * reason, since browsers almost always send a region.
 */
function primarySubtag(tag: string): Language | null {
  const primary = tag.split('-')[0]?.toLowerCase();
  return isLanguage(primary) ? primary : null;
}

/**
 * Resolve the language.
 *
 *   1. an explicit stored choice wins outright;
 *   2. otherwise the first browser preference that names a supported language;
 *   3. otherwise Japanese.
 *
 * Step 2 scans in order rather than looking only at `browser[0]`: a viewer
 * whose first preference is French and whose second is English should get
 * English, not the default.
 */
export function resolveLanguage(input: LanguageInput): Language {
  if (isLanguage(input.stored)) return input.stored;

  for (const tag of input.browser) {
    if (typeof tag !== 'string') continue;
    const match = primarySubtag(tag);
    if (match) return match;
  }

  return DEFAULT_LANGUAGE;
}

/**
 * The BCP 47 tag to hand `Intl` for a resolved language.
 *
 * Kept here so P4 has one place to change when date formatting starts reading
 * it, and so nobody passes a bare `'ja'` to `Intl.DateTimeFormat` and gets a
 * locale whose region conventions are unspecified.
 *
 * NOT used for the zone-validity probe in utils/timezone.ts, which pins
 * `'en-US'` on purpose: that call checks whether a zone name is usable, not
 * how to show it, and localising it would change what it tests.
 */
export function intlLocale(lang: Language): string {
  return lang === 'en' ? 'en-US' : 'ja-JP';
}
