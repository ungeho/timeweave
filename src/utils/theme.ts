/**
 * Which theme a session starts in, kept out of the component so the precedence
 * rule is testable without a DOM.
 *
 * Precedence, highest first:
 *   1. an explicit choice the user has already made (persisted),
 *   2. the operating system's preference,
 *   3. light.
 *
 * A stored value wins over the OS on purpose: once someone has pressed the
 * toggle they have said what they want on this device, and an OS that disagrees
 * is not new information. Anything else in storage -- a value from an older
 * build, hand-edited, or corrupted -- is treated as no value at all rather than
 * trusted, so an unreadable setting falls through to the OS instead of forcing
 * light.
 *
 * Reading `localStorage` and `matchMedia` stays at the call site: this function
 * takes what they said, so the rule can be exercised on every combination
 * without a browser.
 */

export type Theme = 'light' | 'dark';

export function resolveInitialTheme(stored: string | null, prefersDark: boolean): Theme {
  if (stored === 'light' || stored === 'dark') return stored;
  return prefersDark ? 'dark' : 'light';
}
