/**
 * The one place that decides what text stands in for an event with no title of
 * its own. Kept beside visibilityMeta for the same reason: a label that appears
 * in several components is defined once, so the chip, the band and their
 * tooltips and aria-labels can never drift apart.
 *
 * WHY IT IS A MODULE NOW. The fallback was written inline in three components
 * (EventChip, MonthView's band, AllDayLane) and in only one of the three places
 * each of them shows a title: the visible text used it, while `title` and
 * `aria-label` interpolated the raw value, so an untitled event announced
 * itself as ", 非公開". A second fallback is about to exist -- an AVAILABLE
 * event may legitimately have no title, and "(無題)" would be the wrong word
 * for it -- and adding that to six sites was not an option.
 *
 * WHERE THE STRINGS COME FROM. They are the only display copy in this module,
 * and since P6 step 1 they are resolved through t() against the ja/en
 * dictionaries instead of being written here, so each fallback is defined once
 * and follows whatever language the caller passes. They are UI copy, not data
 * -- nothing writes them to a row (see buildCancellation, which blanks a
 * tombstone's title rather than inventing one), so the stored value stays
 * language-free and a change of language rewrites nothing.
 */

import { t } from '../../i18n/t';
import { DEFAULT_LANGUAGE, isLanguage, type Language } from '../../i18n/types';
import type { Availability } from '../../types/event';

/**
 * Stand-in text per availability, used only when `title` is empty, one table
 * per language and built on first use.
 *
 * It was a single module-level Record resolved with DEFAULT_LANGUAGE at import
 * time, so the fallback could never follow the display language -- an untitled
 * event in an English UI would have read "(無題)". Caching per language keeps
 * that fixed without resolving two strings for every chip in a month grid.
 */
const CACHE = new Map<Language, Record<Availability, string>>();

function untitledFor(lang: Language): Record<Availability, string> {
  const hit = CACHE.get(lang);
  if (hit) return hit;
  const built: Record<Availability, string> = {
    busy: t('calendar.untitled', lang),
    // An available event is often JUST a span of reachable time, so having no
    // title is a normal state for one rather than a missing value.
    available: t('calendar.availableTitle', lang),
  };
  CACHE.set(lang, built);
  return built;
}

/**
 * The title to render for an event, its tooltip and its accessible name.
 *
 * Takes the two fields it reads rather than an EventRow, so an occurrence, a
 * row or a test literal can all be passed without constructing the rest.
 *
 * `lang` DEFAULTS TO THE DEFAULT LANGUAGE, the same shape contentLengthError
 * and labelLengthError use. The three rendering callers pass the resolved
 * language; the default is what keeps this change invisible until the switch
 * flips, and what lets a test call it with one argument.
 *
 * THE FALLBACK IS STILL ONLY A RENDERING. An empty title stays empty in the
 * row (see buildCancellation, which blanks a tombstone rather than inventing a
 * name), so the stored value remains language-free and switching language
 * rewrites nothing.
 */
export function eventDisplayTitle(
  event: { title: string; availability: Availability },
  lang: Language = DEFAULT_LANGUAGE,
): string {
  return event.title || untitledFor(isLanguage(lang) ? lang : DEFAULT_LANGUAGE)[event.availability];
}
