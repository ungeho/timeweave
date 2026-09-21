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
 * WHY THE STRINGS LIVE IN A MAP. They are the only display strings in this
 * module, and swapping the map for a lookup is the whole change a future
 * ja/en switch needs here. That is deliberately as far as it goes: no message
 * catalogue, no key indirection, no library. The fallbacks are UI copy, not
 * data -- nothing writes them to a row (see buildCancellation, which blanks a
 * tombstone's title rather than inventing one), so the stored value stays
 * language-free and a later translation changes only what is rendered.
 */

import type { Availability } from '../../types/event';

/** Stand-in text per availability, used only when `title` is empty. */
const UNTITLED: Record<Availability, string> = {
  busy: '(無題)',
  // An available event is often JUST a span of reachable time, so having no
  // title is a normal state for one rather than a missing value.
  available: '空き時間',
};

/**
 * The title to render for an event, its tooltip and its accessible name.
 *
 * Takes the two fields it reads rather than an EventRow, so an occurrence, a
 * row or a test literal can all be passed without constructing the rest.
 */
export function eventDisplayTitle(event: { title: string; availability: Availability }): string {
  return event.title || UNTITLED[event.availability];
}
