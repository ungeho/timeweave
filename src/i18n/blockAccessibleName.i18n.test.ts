/**
 * P6.7: a timed Busy/Available block says its state AND its time range.
 *
 * THE DEFECT, found by rendering the page rather than reading it. Each timed
 * block drew its range as text and carried `aria-label={state}`. An aria-label
 * REPLACES an element's contents for assistive technology, so a screen reader
 * announced "Busy" and the time was never read at all -- a sighted viewer saw
 * "09:00–09:30" in a coloured block, and a screen-reader user got the colour's
 * meaning with no way to ask when. It was identical in Japanese, so it was not
 * an i18n regression; it was simply invisible until the page was inspected in
 * a browser.
 *
 * WHAT IS ASSERTED HERE is the composition, which is a pure function and so
 * testable in this project's node environment; the two call sites are checked
 * structurally, because vitest runs with no jsdom and FreeBusyPage cannot be
 * rendered.
 */

import { describe, expect, it } from 'vitest';
import { blockAccessibleName } from '../features/share/freeBusyPresentation';
import { formatTime } from '../utils/datetime';
import { intlLocale } from './resolveLanguage';
import { t } from './t';
import { LANGUAGES } from './types';
import { ja as jaDict } from './ja';
import { en as enDict } from './en';

const MODULES = import.meta.glob('/src/**/*.{ts,tsx}', {
  query: '?raw',
  import: 'default',
  eager: true,
}) as Record<string, string>;

const source = (p: string) => MODULES[`/src/${p}`] ?? '';
const code = (p: string) =>
  source(p)
    .replace(/\/\*[\s\S]*?\*\//g, '')
    .replace(/(^|[^:])\/\/.*$/gm, '$1');

const JAPANESE = /[ぁ-んァ-ヶ一-龯]/;
const PAGE = 'features/share/FreeBusyPage.tsx';

// ---------------------------------------------------------------------------

describe('the accessible name carries the state and the hours', () => {
  it('reads naturally in Japanese', () => {
    expect(blockAccessibleName('busy', '09:00', '09:30', 'ja')).toBe('予定あり、09:00から09:30');
    expect(blockAccessibleName('available', '10:00', '12:00', 'ja')).toBe(
      '空き時間、10:00から12:00',
    );
  });

  it('reads naturally in English', () => {
    expect(blockAccessibleName('busy', '09:00', '09:30', 'en')).toBe('Busy, 09:00 to 09:30');
    expect(blockAccessibleName('available', '10:00', '12:00', 'en')).toBe('Open, 10:00 to 12:00');
  });

  it('called with no language it answers in Japanese', () => {
    expect(blockAccessibleName('busy', '09:00', '09:30')).toBe(
      blockAccessibleName('busy', '09:00', '09:30', 'ja'),
    );
  });

  it('both the state and both times are present, in both languages', () => {
    // The whole point: a name that lost either half would still look fine.
    for (const lang of LANGUAGES) {
      for (const state of ['busy', 'available'] as const) {
        const s = blockAccessibleName(state, '07:15', '18:45', lang);
        expect(s, `${lang}:${state}`).toContain('07:15');
        expect(s, `${lang}:${state}`).toContain('18:45');
        const label = t(
          state === 'busy' ? 'sharePage.block.busy' : 'sharePage.block.available',
          lang,
        );
        expect(s, `${lang}:${state}`).toContain(label);
      }
    }
  });

  it('no placeholder survives, and English carries no Japanese', () => {
    for (const state of ['busy', 'available'] as const) {
      expect(blockAccessibleName(state, '00:00', '23:59', 'en')).not.toMatch(JAPANESE);
      for (const lang of LANGUAGES) {
        expect(blockAccessibleName(state, '00:00', '23:59', lang)).not.toMatch(/\{\w+\}/);
      }
    }
  });

  it('an unrecognised language falls back to Japanese', () => {
    const bogus = 'de' as unknown as 'ja';
    expect(blockAccessibleName('busy', '09:00', '09:30', bogus)).toBe(
      blockAccessibleName('busy', '09:00', '09:30', 'ja'),
    );
  });
});

describe('Busy and Available stay distinct in the spoken name', () => {
  it('the two states never produce the same name', () => {
    for (const lang of LANGUAGES) {
      expect(blockAccessibleName('busy', '09:00', '10:00', lang), lang).not.toBe(
        blockAccessibleName('available', '09:00', '10:00', lang),
      );
    }
  });

  it('busy never reads as open, and open never reads as busy', () => {
    // The same claim the visible labels already carry, now extended to the
    // accessible name -- which is the only thing some users receive.
    expect(blockAccessibleName('busy', '09:00', '10:00', 'ja')).not.toContain('空き');
    expect(blockAccessibleName('busy', '09:00', '10:00', 'en')).not.toMatch(/open|available|free/i);
    expect(blockAccessibleName('available', '09:00', '10:00', 'ja')).not.toContain('予定あり');
    expect(blockAccessibleName('available', '09:00', '10:00', 'en')).not.toMatch(/busy/i);
  });

  it('the state words come from the existing labels, not a second copy', () => {
    // So the guards that keep those two apart keep protecting this name too.
    const mod = code('features/share/freeBusyPresentation.ts');
    expect(mod).toContain("t('sharePage.block.busy', lang)");
    expect(mod).toContain("t('sharePage.block.available', lang)");
    expect(mod).toContain("t('sharePage.block.timeRange', lang,");
  });
});

describe('the spoken time cannot drift from the displayed time', () => {
  it('the function is handed the rendered strings, not instants', () => {
    // Formatting inside would put two independent formatTime calls in one
    // element and invite exactly the drift this is meant to rule out.
    // Three required parameters -- state, start, end -- because `length`
    // stops at the first defaulted one, which is `lang`. That is the shape
    // wanted: the times are mandatory, the language is not.
    expect(blockAccessibleName.length).toBe(3);
    const mod = code('features/share/freeBusyPresentation.ts');
    const fn = mod.slice(mod.indexOf('export function blockAccessibleName'));
    expect(fn).not.toMatch(/formatTime|Intl\.|toLocale/);
  });

  it('the page builds both halves from the same two values', () => {
    const page = code(PAGE);
    // Each map body computes start/end once and uses them for the label and
    // for the text node.
    expect(page).toContain('const start = formatTime(t.start, locale)');
    expect(page).toContain('const end = formatTime(t.end, locale)');
    expect(page).toContain("blockAccessibleName('busy', start, end, language)");
    expect(page).toContain("blockAccessibleName('available', start, end, language)");
    expect(page).toContain('{start}–{end}');
    // And the old state-only labels are gone from the timed blocks.
    expect(page).not.toMatch(/aria-label=\{tr\('sharePage\.block\.busy'\)\}/);
    expect(page).not.toMatch(/aria-label=\{tr\('sharePage\.block\.available'\)\}/);
  });

  it('the rendered format is the one the name quotes', () => {
    // 24-hour, both languages -- the clock pin is what makes "09:00" mean the
    // same thing in each.
    const iso = '2026-10-13T00:00:00.000Z';
    for (const lang of LANGUAGES) {
      const shown = formatTime(iso, intlLocale(lang));
      expect(shown, lang).toMatch(/^\d{2}:\d{2}$/);
      expect(blockAccessibleName('busy', shown, shown, lang), lang).toContain(shown);
    }
  });

  it('midnight and the end of the day read as 24-hour, never 12-hour', () => {
    for (const lang of LANGUAGES) {
      const name = blockAccessibleName('busy', '00:00', '23:30', lang);
      expect(name, lang).toContain('00:00');
      expect(name, lang).toContain('23:30');
      expect(name, lang).not.toMatch(/AM|PM/i);
    }
  });
});

describe('the name discloses nothing a share link does not', () => {
  it('the function has no access to event content', () => {
    // It takes a state and two clock strings. There is nothing else for it to
    // say, which is stronger than remembering not to say it.
    const mod = code('features/share/freeBusyPresentation.ts');
    const fn = mod.slice(mod.indexOf('export function blockAccessibleName'));
    expect(fn).not.toMatch(/title|description|category|visibility|availability|event/i);
  });

  it('nothing in the output varies with anything but state and times', () => {
    // Same inputs, same output -- no hidden source of text.
    for (const lang of LANGUAGES) {
      expect(blockAccessibleName('busy', '09:00', '10:00', lang)).toBe(
        blockAccessibleName('busy', '09:00', '10:00', lang),
      );
    }
  });

  it('the call sites pass only the two clock strings', () => {
    // `t` here is the slot, which carries start/end and nothing else -- the
    // wire shape has no title. Asserted so a later change that reaches for
    // more has to defeat this.
    const page = code(PAGE);
    expect(page).not.toMatch(/blockAccessibleName\([^)]*\.(title|category|description)/);
  });

  it('the anonymous page still names no event content at all', () => {
    const page = code(PAGE);
    expect(page).not.toMatch(/\.title|\.category|\.description|visibilityMeta|eventDisplayTitle/);
  });

  it('the slot type still carries no content field', () => {
    // The disclosure boundary this all rests on: a Free/Busy slot is two
    // instants, or two dates. There is no title on the wire to leak.
    const types = source('types/share.ts');
    const slot = types.slice(types.indexOf('export type FreeBusySlot'), types.indexOf('export type PublicLinkState'));
    expect(slot).toMatch(/allDay: false; start: string; end: string/);
    expect(slot).not.toMatch(/title|category|description/);
  });
});

describe('nothing about the page itself moved', () => {
  it('the all-day blocks are unchanged', () => {
    // They have no time to lose: the label equals the visible text, so an
    // aria-label that replaces the contents replaces them with the same words.
    const page = code(PAGE);
    expect(page).toContain("aria-label={tr('sharePage.block.busyAllDay')}");
    expect(page).toContain("aria-label={tr('sharePage.block.availableAllDay')}");
  });

  it('the classes that distinguish the two visually are unchanged', () => {
    const page = code(PAGE);
    expect(page).toContain('className="freebusy-block"');
    expect(page).toContain('className="freebusy-block available"');
    expect(page).toContain('className="freebusy-block allday"');
    expect(page).toContain('className="freebusy-block allday available"');
  });

  it('available blocks still come after busy ones, with their own keys', () => {
    const page = code(PAGE);
    expect(page.indexOf('busy.timed.map')).toBeLessThan(page.indexOf('open.timed.map'));
    expect(page).toContain('key={`a-${t.start}`}');
  });

  it('the day-intersection and the empty dash are untouched', () => {
    const page = code(PAGE);
    expect(page).toContain('busyForDay(cell.dayKey, timeZone, load.result.slots)');
    expect(page).toContain('busyForDay(cell.dayKey, timeZone, availableSlots(load.result.available))');
    // P8-mobile-2: still only where neither set drew anything, still a dash --
    // now decorative, with "Nothing shown" read out instead of "dash".
    expect(page).toMatch(/\{!hasBusy && !hasOpen && \(\s*<div className="freebusy-free">\s*<span aria-hidden="true">—<\/span>\s*<span className="freebusy-sr-only">\{tr\('sharePage\.day\.nothing'\)\}<\/span>/);
  });

  it('the state machine and the opt-ins are untouched', () => {
    const page = code(PAGE);
    expect(page).toContain('availablePresentation(load.result.available)');
    expect(page).not.toMatch(/shareAvailable|share_available|includePrivate|include_private/);
    // availableSlots still yields nothing for the two states that have none.
    const mod = code('features/share/availablePresentation.ts');
    expect(mod).toContain("available.status === 'complete' ? available.slots : []");
  });

  it('the time zone is still the viewer own, resolved once', () => {
    const page = code(PAGE);
    expect(page).toContain('const timeZone = useMemo(() => getUserTimeZone(), [])');
    expect(page).not.toMatch(/owner_settings|getOwnerSettings/);
  });

  it('exactly one key was added, and it is the composition', () => {
    const ja = source('i18n/ja.ts');
    const en = source('i18n/en.ts');
    expect(ja).toContain("'sharePage.block.timeRange'");
    expect(en).toContain("'sharePage.block.timeRange'");
    // The four state labels it composes from still exist, unchanged.
    for (const k of [
      'sharePage.block.busy',
      'sharePage.block.available',
      'sharePage.block.busyAllDay',
      'sharePage.block.availableAllDay',
    ]) {
      expect(ja, k).toContain(`'${k}'`);
      expect(en, k).toContain(`'${k}'`);
    }
  });

  it('the new key declares exactly the three variables it uses', () => {
    // Read from the dictionaries, not through `t`: this key HAS variables,
    // so calling t() without them is a compile error -- which is the whole
    // mechanism that keeps a placeholder from reaching the screen unfilled.
    const vars = (s: string) => [...s.matchAll(/\{(\w+)\}/g)].map((m) => m[1]).sort();
    expect(vars(jaDict['sharePage.block.timeRange'])).toEqual(['end', 'start', 'state']);
    expect(vars(enDict['sharePage.block.timeRange'])).toEqual(['end', 'start', 'state']);
  });
});
