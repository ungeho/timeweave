/**
 * What the mobile header owes, and what it must not quietly drop.
 *
 * The header cannot be rendered here -- vitest runs with `environment:
 * 'node'` and jsdom is deliberately not added -- so these read the source and
 * the stylesheet. The split is deliberate: STRUCTURE is asserted here (which
 * controls exist, what ARIA is claimed, which rules are in the stylesheet),
 * and BEHAVIOUR was measured in a browser and recorded in docs/p8-tasks.md.
 * A test that claimed to prove Escape works would be claiming more than
 * reading source can show.
 */

import { describe, expect, it } from 'vitest';
import { readStylesheet } from '../../../scripts/read-stylesheet.mjs';

const SRC = import.meta.glob(
  ['/src/App.tsx', '/src/features/shell/HeaderMenu.tsx', '/src/i18n/ja.ts', '/src/i18n/en.ts'],
  { query: '?raw', import: 'default', eager: true },
) as Record<string, string>;

const code = (t: string) =>
  t.replace(/\/\*[\s\S]*?\*\//g, '').replace(/(^|[^:])\/\/.*$/gm, '$1');

const APP = code(SRC['/src/App.tsx'] as string);
const MENU = code(SRC['/src/features/shell/HeaderMenu.tsx'] as string);
const JA = SRC['/src/i18n/ja.ts'] as string;
const EN = SRC['/src/i18n/en.ts'] as string;
const CSS = readStylesheet();

describe('nothing is reachable on one layout only', () => {
  /*
    THE POINT OF THE WHOLE EXERCISE. Moving a control behind a trigger is
    fine; losing it is not. Both arrangements are built in App.tsx from the
    same `signedIn`, so a control added to the desktop row without a menu
    entry would be one the phone cannot reach -- and nobody checks the phone
    when adding a desktop button.
  */
  it.each([
    ['settings', "tr('settings.title')"],
    ['sign out', "tr('app.signOut')"],
    ['the guide', "tr('docs.indexTitle')"],
  ])('%s appears in both the menu list and the desktop row', (_name, call) => {
    expect(APP.split(call).length - 1, `${call} is not in both arrangements`).toBe(2);
  });

  it('the menu list and the desktop row read the same auth condition', () => {
    expect(APP).toContain('const signedIn = Boolean(authEnabled && user)');
    expect(APP).toContain('authEnabled && user');
  });

  it('the theme toggle is NOT buried', () => {
    // It is already an icon, it is a toggle rather than a destination, and
    // it is the control people flip most. It stays in the header on both.
    expect(APP.split("aria-label={tr('app.themeToggle')}").length - 1).toBe(1);
    expect(MENU).not.toContain('themeToggle');
  });

  it('the signed-out header keeps the guide out of the menu', () => {
    // One link behind a button costs a tap and gains nothing, and the guide
    // matters most on the sign-in screen.
    expect(APP).toContain('const useMenu = isMobile && signedIn');
  });
});

describe('a disclosure, and honest about it', () => {
  it('claims aria-expanded and points at what it opens', () => {
    expect(MENU).toContain('aria-expanded={open}');
    expect(MENU).toContain('aria-controls={panelId}');
    expect(MENU).toContain('id={panelId}');
    // useId, not a hand-made string: two headers on one page would collide.
    expect(MENU).toContain('useId()');
  });

  it('does not claim role="menu" it has not implemented', () => {
    /*
      role="menu" owes an arrow-key model -- Up/Down, Home/End, typeahead,
      roving tabindex. This has ordinary buttons and links in a <nav>, so it
      says so, and Tab does the moving. Claiming the role without the keys
      would describe the widget wrongly to the people who rely on it most.
    */
    expect(MENU).not.toContain('role="menu"');
    expect(MENU).not.toContain('role="menuitem"');
    expect(MENU).toContain('<nav aria-label=');
  });

  it('the trigger has an accessible name, since it is a glyph', () => {
    expect(MENU).toContain("aria-label={tr('app.menu')}");
    expect(MENU).toContain('aria-hidden="true"');
  });

  it('both languages name it', () => {
    expect(JA).toContain("'app.menu':");
    expect(EN).toContain("'app.menu':");
  });
});

describe('it closes, and puts focus back', () => {
  it('Escape closes and restores focus to the trigger', () => {
    expect(MENU).toContain("e.key === 'Escape'");
    const i = MENU.indexOf("e.key === 'Escape'");
    expect(MENU.slice(i, i + 140)).toContain('close(true)');
    // close(true) is what restores; the function must actually do it.
    expect(MENU).toContain('if (restoreFocus) triggerRef.current?.focus()');
  });

  it('a press outside closes it, and the trigger is not double-handled', () => {
    expect(MENU).toContain("addEventListener('pointerdown'");
    // Without this the trigger's own click would close and reopen in one press.
    expect(MENU).toContain('triggerRef.current?.contains(t)');
    expect(MENU).toContain('panelRef.current?.contains(t)');
  });

  it('choosing an item closes it', () => {
    expect(MENU.split('close(false)').length - 1).toBeGreaterThanOrEqual(3);
  });

  it('closes before running an action that may unmount the header', () => {
    // Signing out unmounts this. Setting state afterwards would be setting it
    // on something gone.
    const close = MENU.indexOf('close(false);');
    const select = MENU.indexOf('item.onSelect?.()');
    expect(select, 'onSelect is missing').toBeGreaterThan(-1);
    expect(close, 'onSelect runs before close').toBeLessThan(select);
  });

  it('opening moves focus inside', () => {
    expect(MENU).toContain('firstItemRef.current?.focus()');
  });

  it('listeners are removed when it closes', () => {
    expect(MENU).toContain("removeEventListener('keydown'");
    expect(MENU).toContain("removeEventListener('pointerdown'");
  });

  it('crossing to the desktop discards an open menu', () => {
    // Keyed, so the component is replaced rather than carried across with
    // its open state intact.
    expect(APP).toContain('<HeaderMenu key="mobile"');
  });
});

describe('the stylesheet', () => {
  const mobile = CSS.slice(CSS.indexOf('mobile header menu (P8-b5.5)'));

  it('is actually there to read', () => {
    expect(mobile.length).toBeGreaterThan(500);
  });

  it('stops header labels wrapping between characters', () => {
    /*
      THE FAULT THAT STARTED P8-b5.5. A .btn narrow enough wraps its label
      after every character, and a five-character Japanese label became a
      column of five. This makes the fix structural rather than a thing that
      happens to be true at the widths measured.
    */
    expect(mobile).toMatch(/\.app-header \.btn\s*\{[^}]*white-space:\s*nowrap/);
  });

  it('lets the brand have the row rather than ellipsing it', () => {
    expect(mobile).toMatch(/\.app-header \.brand\s*\{[^}]*flex:\s*1 1 auto/);
    expect(mobile).toMatch(/\.app-header \.brand\s*\{[^}]*min-width:\s*0/);
  });

  it('anchors the panel to the right and caps its width', () => {
    // Anchored left, a panel runs off a 320px screen; uncapped, a long
    // translated label widens it past the viewport.
    expect(mobile).toMatch(/\.header-menu-panel\s*\{[\s\S]*?right:\s*0/);
    expect(mobile).toMatch(/\.header-menu-panel\s*\{[\s\S]*?max-width:\s*calc\(100vw/);
  });

  it('gives every item a 44px line', () => {
    expect(mobile).toMatch(/\.header-menu-item\s*\{[\s\S]*?min-height:\s*44px/);
    expect(mobile).toMatch(/\.header-menu-trigger\s*\{[\s\S]*?min-width:\s*44px/);
  });

  it('does not hide the problem instead of fixing it', () => {
    // An explicit instruction for this task, and the thing that would make
    // every measurement above meaningless.
    expect(mobile).not.toContain('overflow-x: hidden');
  });
});
