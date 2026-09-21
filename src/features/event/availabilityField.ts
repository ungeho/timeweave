/**
 * The two things the dialog needs to know about availability, kept out of the
 * component so the rule can be tested: what the control offers, and when a
 * title has to be filled in.
 *
 * This sits beside recurrenceForm and timezoneField, the other pure helpers the
 * event dialog reads.
 */

import type { Availability } from '../../types/event';

/**
 * Options for the control, in lifecycle order: the default first.
 *
 * Labels are left untranslated for now, and they live here rather than in the
 * component for the same reason eventTitle's fallbacks do -- one place to swap
 * when a ja/en switch arrives, and no string repeated across files.
 */
export const AVAILABILITIES: { value: Availability; label: string }[] = [
  { value: 'busy', label: 'Busy' },
  { value: 'available', label: 'Available' },
];

/**
 * Whether the form must refuse an empty title.
 *
 * A BUSY event without a title is almost certainly a mistake -- the owner meant
 * to write something and did not -- and that check has been in place since the
 * dialog existed. An AVAILABLE event is different: "these two hours are open"
 * is complete on its own, and demanding a name for it is the cost this feature
 * is meant to avoid paying on every entry.
 *
 * What it does NOT license is inventing one. An untitled available event stores
 * the empty string and eventDisplayTitle supplies the words at render time, so
 * nothing in the database is written in a particular language.
 */
export function isTitleRequired(availability: Availability): boolean {
  return availability === 'busy';
}
