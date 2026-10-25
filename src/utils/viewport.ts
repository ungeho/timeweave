/**
 * Where the mobile layout begins.
 *
 * ONE NUMBER, NAMED ONCE. P8-b2 onwards splits the calendar into a desktop
 * grid and a mobile agenda, and that split has to agree with the CSS that
 * styles each of them. Two copies of a breakpoint drift, and the drift shows
 * up only in the handful of pixels between them -- a header styled for mobile
 * above a grid still laid out for desktop.
 *
 * The same hazard `dayAgenda.ts` already names for COMPACT_MONTH_QUERY: the
 * TypeScript decides the chip cap, the CSS decides the row height, and a
 * mismatch clips chips on exactly one side of the boundary. There the comment
 * is the whole defence; here a test reads the stylesheet and checks the number
 * appears in it, because this boundary moves more of the screen.
 *
 * WHY 720 AND NOT 768. A 768px tablet runs the DESKTOP layout well -- measured
 * in the P8-a audit: no horizontal scroll, 102px month cells, a single-row
 * toolbar. Putting the boundary at 768 would demote a viewport that works.
 *
 * SEPARATE FROM THE 640px COMPACT MONTH QUERY, deliberately. That one tunes
 * how many chips fit in a cell of the desktop grid; this one decides whether
 * there is a desktop grid at all. They answer different questions and are
 * free to move independently.
 */

/** The widest viewport that still gets the mobile layout. */
export const MOBILE_MAX_WIDTH = 719;

/**
 * The media query, for `matchMedia` and for the stylesheet.
 *
 * Written out rather than built from MOBILE_MAX_WIDTH so the literal a test
 * can search the CSS for is visible here too.
 */
export const MOBILE_QUERY = '(max-width: 719px)';

/**
 * Whether a width gets the mobile layout.
 *
 * Pure, so the DECISION is testable in this project's node environment and
 * only the subscription needs a browser -- the split `utils/theme.ts` uses,
 * where `resolveInitialTheme` is pure and the caller reads `matchMedia`.
 */
export function isMobileWidth(width: number): boolean {
  return width <= MOBILE_MAX_WIDTH;
}
