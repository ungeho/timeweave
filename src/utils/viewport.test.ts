/**
 * The mobile boundary, and the things that have to agree about it.
 *
 * The number itself is trivial. What is not trivial is that it exists in two
 * languages at once -- a `matchMedia` string in TypeScript and a `@media` rule
 * in CSS -- and nothing in a build checks that they match. A header styled for
 * mobile above a grid still laid out for desktop is the failure, and it would
 * appear only in the few pixels between two numbers that drifted apart.
 *
 * So these read the stylesheet. `dayAgenda.ts` names the same hazard for
 * COMPACT_MONTH_QUERY and defends it with a comment; this boundary moves more
 * of the screen, so it gets a test.
 */

import { describe, expect, it } from 'vitest';
import { MOBILE_MAX_WIDTH, MOBILE_QUERY, isMobileWidth } from './viewport';
import { readStylesheet } from '../../scripts/read-stylesheet.mjs';

/** The modules that name the boundary. */
const SOURCES = import.meta.glob('/src/**/*.{ts,tsx}', {
  query: '?raw',
  import: 'default',
  eager: true,
}) as Record<string, string>;

const CSS = readStylesheet();

describe('the mobile boundary', () => {
  it('is 719, so a 768px tablet keeps the desktop layout', () => {
    // Measured in the P8-a audit: at 768px there is no horizontal scroll, the
    // month cells are 102px and the toolbar is one row. Demoting a viewport
    // that works would be a regression dressed as an improvement.
    expect(MOBILE_MAX_WIDTH).toBe(719);
    expect(isMobileWidth(768)).toBe(false);
    expect(isMobileWidth(720)).toBe(false);
  });

  it('includes its own edge', () => {
    expect(isMobileWidth(719)).toBe(true);
    expect(isMobileWidth(718)).toBe(true);
    expect(isMobileWidth(320)).toBe(true);
  });

  it('the query says the same thing as the number', () => {
    expect(MOBILE_QUERY).toBe(`(max-width: ${MOBILE_MAX_WIDTH}px)`);
  });

  it('the stylesheet uses the same number', () => {
    // The half a build cannot check. CSS cannot read TypeScript, so this is
    // the only thing standing between the two copies.
    expect(CSS).toContain(`@media (max-width: ${MOBILE_MAX_WIDTH}px)`);
  });

  it('is not confused with the compact-month boundary', () => {
    // 640px tunes how many chips fit in a cell of the DESKTOP grid; 719px
    // decides whether there is a desktop grid at all. Different questions,
    // free to move independently -- but only while they are different
    // numbers, which is what this pins.
    const compact = SOURCES['/src/features/calendar/dayAgenda.ts'] ?? '';
    expect(compact).toContain("COMPACT_MONTH_QUERY = '(max-width: 640px)'");
    expect(MOBILE_MAX_WIDTH).not.toBe(640);
  });
});

describe('the hook reads the shared constant', () => {
  it('useIsMobile does not spell the query out again', () => {
    // A second literal is a second thing to update.
    const hook = SOURCES['/src/hooks/useIsMobile.ts'] ?? '';
    expect(hook).toContain('MOBILE_QUERY');
    expect(hook).not.toMatch(/max-width:\s*\d/);
  });

  it('it subscribes rather than reading the width during render', () => {
    // window.innerWidth read inline never updates on resize or rotation.
    const hook = SOURCES['/src/hooks/useIsMobile.ts'] ?? '';
    expect(hook).toContain('useMediaQuery');
    expect(hook).not.toContain('innerWidth');
  });
});

describe('the account email stays reachable', () => {
  const code = (t: string) =>
    t.replace(/\/\*[\s\S]*?\*\//g, '').replace(/(^|[^:])\/\/.*$/gm, '$1');

  it('the header hides it only below the boundary', () => {
    // It is the element that made the page scroll sideways at 320-375px.
    const block = CSS.slice(CSS.indexOf(`@media (max-width: ${MOBILE_MAX_WIDTH}px)`));
    expect(block).toContain('.user-email');
    expect(block).toMatch(/\.user-email\s*\{\s*display:\s*none/);
  });

  it('the settings dialog shows it instead', () => {
    // Hiding it in the header would otherwise remove the ONLY place the
    // signed-in address appears -- it was rendered in exactly one file.
    const dialog = code(SOURCES['/src/features/settings/SettingsDialog.tsx'] ?? '');
    expect(dialog).toContain('user?.email');
    expect(dialog).toContain("tr('settings.signedInAs')");
  });

  it('nothing hides the overflow instead of fixing it', () => {
    // `overflow-x: hidden` on a page ancestor leaves the content just as wide
    // and stops you seeing that it is. The fix is letting the flex row shrink.
    //
    // COMMENTS STRIPPED FIRST. The rule this guards is explained in a CSS
    // comment that names the thing it is deliberately NOT doing, and the
    // first version of this check matched that prose instead of a rule.
    const noComments = CSS.replace(/\/\*[\s\S]*?\*\//g, '');
    const app = noComments.slice(noComments.indexOf('.app {'), noComments.indexOf('.btn {'));
    expect(app).not.toMatch(/overflow-x:\s*hidden/);
    expect(CSS).toMatch(/\.app-header-actions\s*\{[^}]*min-width:\s*0/);
    expect(CSS).toMatch(/\.brand\s*\{[^}]*min-width:\s*0/);
  });
});
