/**
 * What the anonymous share page's legend shows (P8-mobile-2).
 *
 * On a phone the page was a column of solid and hatched bars that read only
 * "09:00–09:30": nothing on screen said which kind meant busy and which meant
 * open time. The legend states it in words, above the week, without a tap or
 * a hover. It explains what is DRAWN and never adds to what is disclosed:
 *
 *   busy       always -- every live link discloses busy time
 *   available  only when open time is actually being shown, which is the one
 *              presentation that draws available blocks ('slots'): an opted-out
 *              link ('hidden') was never asked about open time, and an
 *              'indeterminate' answer draws none. The footer switches on the
 *              same condition, so the two can never disagree.
 *
 * The note always says that time with nothing on it is not necessarily free:
 * an empty stretch is never to be read as available.
 */
import type { AvailableResult } from '../../types/share';
import { availablePresentation } from './availablePresentation';

export interface FreeBusyLegend {
  /**
   * The heading's key. Named "heading", not "title", on purpose: the page is
   * guarded against ever reading an event's `.title`, and that guard must not
   * be loosened for a key name.
   */
  headingKey: 'legend.title';
  /** Whether the "time the owner marked as open" entry is shown. */
  available: boolean;
  /** The caveat, worded for what is on screen. */
  noteKey: 'legend.note' | 'legend.noteBusyOnly';
}

export function freeBusyLegend(available: AvailableResult): FreeBusyLegend {
  const shown = availablePresentation(available) === 'slots';
  return { headingKey: 'legend.title', available: shown, noteKey: shown ? 'legend.note' : 'legend.noteBusyOnly' };
}
