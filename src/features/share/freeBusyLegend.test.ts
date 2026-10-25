import { describe, expect, it } from 'vitest';
import { freeBusyLegend } from './freeBusyLegend';
import { ja } from '../../i18n/ja';
import { en } from '../../i18n/en';

/*
  P8-mobile-2: the anonymous share page names what it draws.

  On an Android phone the page showed solid and hatched bars that read only
  "09:00–09:30", and the viewer could not tell busy from open time. Now a
  legend above the week says it in words, every block carries its state in
  visible text, and an empty day reads "Nothing shown". Nothing new is
  disclosed: the legend lists only what this link can draw, and every caveat
  says empty time is not necessarily free.
*/

const PAGE = (import.meta.glob('/src/features/share/FreeBusyPage.tsx', { query: '?raw', import: 'default', eager: true }) as Record<string, string>)[
  '/src/features/share/FreeBusyPage.tsx'
]!.replace(/\/\*[\s\S]*?\*\//g, '').replace(/(^|[^:])\/\/.*$/gm, '$1');

describe('freeBusyLegend: the legend names only what this link can draw', () => {
  it('open time shown (opted in, exact answer): busy AND available, with the open-time caveat', () => {
    expect(freeBusyLegend({ status: 'complete', slots: [] })).toEqual({ headingKey: 'legend.title', available: true, noteKey: 'legend.note' });
  });
  it('opted out: busy only -- open time was never asked about', () => {
    expect(freeBusyLegend({ status: 'not_requested' })).toEqual({ headingKey: 'legend.title', available: false, noteKey: 'legend.noteBusyOnly' });
  });
  it('indeterminate: busy only -- no open time is drawn', () => {
    expect(freeBusyLegend({ status: 'indeterminate' })).toEqual({ headingKey: 'legend.title', available: false, noteKey: 'legend.noteBusyOnly' });
  });
  it('every caveat says empty time is not necessarily free, in both languages', () => {
    for (const k of ['legend.note', 'legend.noteBusyOnly'] as const) {
      expect(ja[k]).toContain('空いているとは限りません');
      expect(en[k]).toMatch(/not necessarily free/i);
    }
  });
});

describe('the page', () => {
  it('shows the legend whenever the week is drawn, before the banners and the week', () => {
    const legend = PAGE.indexOf('<section className="freebusy-legend"');
    expect(legend).toBeGreaterThan(-1);
    expect(PAGE).toMatch(/\{load\.status === 'ok' && \(\(\) => \{\s*const legend = freeBusyLegend\(load\.result\.available\);/);
    expect(legend).toBeLessThan(PAGE.indexOf('<div className="freebusy-week">'));
    expect(PAGE).toMatch(/aria-labelledby="freebusy-legend-title"/);
    expect(PAGE).toMatch(/\{legend\.available && \(/);
  });

  it('the swatches are decorative; the words carry the meaning', () => {
    expect(PAGE).toMatch(/<span className="freebusy-swatch" aria-hidden="true" \/>\s*<span>\{tr\('legend\.busy'\)\}<\/span>/);
    expect(PAGE).toMatch(/<span className="freebusy-swatch available" aria-hidden="true" \/>\s*<span>\{tr\('legend\.available'\)\}<\/span>/);
  });

  it('every timed block says what it is in visible text, then the range', () => {
    expect(PAGE).toMatch(/<span className="freebusy-block-state">\{tr\('sharePage\.block\.busy'\)\}<\/span>\{' '\}\s*<span className="freebusy-block-time">\{start\}–\{end\}<\/span>/);
    expect(PAGE).toMatch(/<span className="freebusy-block-state">\{tr\('sharePage\.block\.available'\)\}<\/span>\{' '\}\s*<span className="freebusy-block-time">\{start\}–\{end\}<\/span>/);
  });

  it('the page is marked in the language it is written in (lang), on every root', () => {
    expect(PAGE.match(/<div className="freebusy-page" lang=\{language\}>/g)?.length).toBe(3);
    expect(PAGE).not.toMatch(/<div className="freebusy-page">/);
  });

  it('busy wins and nothing new is disclosed: the same two inputs feed the blocks as before', () => {
    expect(PAGE).toContain('busyForDay(cell.dayKey, timeZone, load.result.slots)');
    expect(PAGE).toContain('busyForDay(cell.dayKey, timeZone, availableSlots(load.result.available))');
    expect(PAGE).not.toMatch(/\.title|\.category|\.description|visibilityMeta|eventDisplayTitle/);
  });
});

describe('the words', () => {
  it('the subtitle no longer calls a busy page "open time"', () => {
    expect(ja['sharePage.subtitle']).toBe('予定の空き状況（読み取り専用）');
    expect(en['sharePage.subtitle']).toBe('Free/busy (read-only)');
  });
  it('an empty day is read out as "nothing shown", never as free', () => {
    expect(ja['sharePage.day.nothing']).toBe('表示なし');
    expect(en['sharePage.day.nothing']).toBe('Nothing shown');
    for (const s of [ja['sharePage.day.nothing'], en['sharePage.day.nothing']]) expect(s).not.toMatch(/空き|free|open/i);
  });
});
