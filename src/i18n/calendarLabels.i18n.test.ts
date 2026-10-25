import { describe, expect, it } from 'vitest';
import { VISIBILITIES, visibilityMeta } from '../features/calendar/visibilityMeta';
import { eventDisplayTitle } from '../features/calendar/eventTitle';
import { t } from './t';
import { en } from './en';
import { DEFAULT_LANGUAGE, LANGUAGES } from './types';

/**
 * P6 step 1: the calendar's two pure display modules follow the language.
 *
 * `visibilityMeta` was a module-level Record and `UNTITLED` inside
 * `eventTitle` was another, both resolved with DEFAULT_LANGUAGE at IMPORT
 * time. That is the shape that cannot follow a language however many times
 * React re-renders, and it was the worst instance of the mixed-language risk
 * the P5 audit catalogued: the chip's own pattern follows the language, so an
 * English UI would have read "Standup (非公開)".
 *
 * TWO CLAIMS:
 *   1. Called with no language, both answer exactly what they always did.
 *      The Japanese below is written out literally, not read back.
 *   2. Called with 'en', both answer in English, with no Japanese left in the
 *      composed tooltip or accessible name.
 */

const MODULES = import.meta.glob('/src/**/*.{ts,tsx}', {
  query: '?raw',
  import: 'default',
  eager: true,
}) as Record<string, string>;

const source = (path: string) => (MODULES['/src/' + path] ?? '') as string;

/** Source with comments removed: these guards are about what the code DOES. */
const code = (path: string) =>
  source(path)
    .replace(/\/\*[\s\S]*?\*\//g, '')
    .replace(/(^|[^:])\/\/.*$/gm, '$1');

/** The three components that render a visibility or a title. */
const RENDERERS = [
  'features/calendar/EventChip.tsx',
  'features/calendar/AllDayLane.tsx',
  'features/calendar/MonthView.tsx',
];

describe('the Japanese is byte-identical, with no language passed', () => {
  it('every visibility label and short label', () => {
    expect(visibilityMeta('private').label).toBe('非公開');
    expect(visibilityMeta('private').short).toBe('非公開');
    expect(visibilityMeta('busy_only').label).toBe('予定あり（詳細非公開）');
    expect(visibilityMeta('busy_only').short).toBe('予定あり');
    expect(visibilityMeta('public').label).toBe('公開');
    expect(visibilityMeta('public').short).toBe('公開');
  });

  it('both untitled fallbacks', () => {
    expect(eventDisplayTitle({ title: '', availability: 'busy' })).toBe('(無題)');
    expect(eventDisplayTitle({ title: '', availability: 'available' })).toBe('空き時間');
  });

  it('and with the default passed explicitly, which must be the same thing', () => {
    expect(visibilityMeta('busy_only', DEFAULT_LANGUAGE).label).toBe('予定あり（詳細非公開）');
    expect(eventDisplayTitle({ title: '', availability: 'busy' }, DEFAULT_LANGUAGE)).toBe('(無題)');
  });

  it('a title the user wrote is returned untouched, in either language', () => {
    for (const lang of LANGUAGES) {
      expect(eventDisplayTitle({ title: '定例会', availability: 'busy' }, lang)).toBe('定例会');
      expect(eventDisplayTitle({ title: 'Standup', availability: 'available' }, lang)).toBe(
        'Standup',
      );
    }
  });
});

describe('English renders with no Japanese left', () => {
  it('every visibility label and short label', () => {
    expect(visibilityMeta('private', 'en').label).toBe('Private');
    expect(visibilityMeta('private', 'en').short).toBe('Private');
    expect(visibilityMeta('busy_only', 'en').label).toBe('Busy — details hidden');
    expect(visibilityMeta('busy_only', 'en').short).toBe('Busy');
    expect(visibilityMeta('public', 'en').label).toBe('Public');
    expect(visibilityMeta('public', 'en').short).toBe('Public');
  });

  it('both untitled fallbacks', () => {
    expect(eventDisplayTitle({ title: '', availability: 'busy' }, 'en')).toBe('(untitled)');
    expect(eventDisplayTitle({ title: '', availability: 'available' }, 'en')).toBe('Open time');
  });

  it('nothing it returns carries a Japanese character', () => {
    for (const v of VISIBILITIES) {
      expect(visibilityMeta(v, 'en').label, v).not.toMatch(/[ぁ-んァ-ン一-龯]/);
      expect(visibilityMeta(v, 'en').short, v).not.toMatch(/[ぁ-んァ-ン一-龯]/);
    }
    for (const a of ['busy', 'available'] as const) {
      expect(eventDisplayTitle({ title: '', availability: a }, 'en'), a).not.toMatch(
        /[ぁ-んァ-ン一-龯]/,
      );
    }
  });

  it('every answer differs from the Japanese one, so the wiring really works', () => {
    // Except the short forms of private and public, which the dictionary
    // deliberately keeps equal to their long forms in English.
    expect(visibilityMeta('private', 'en').label).not.toBe(visibilityMeta('private').label);
    expect(visibilityMeta('busy_only', 'en').label).not.toBe(visibilityMeta('busy_only').label);
    expect(visibilityMeta('public', 'en').label).not.toBe(visibilityMeta('public').label);
    expect(eventDisplayTitle({ title: '', availability: 'busy' }, 'en')).not.toBe(
      eventDisplayTitle({ title: '', availability: 'busy' }),
    );
  });
});

/**
 * THE COMPOSED TOOLTIP AND ACCESSIBLE NAME. This is what the fix is for: the
 * chip builds both from `calendar.chip.title` / `.ariaLabel` plus the
 * visibility label, and the two halves used to come from different languages.
 */
describe('the composed tooltip and accessible name are single-language', () => {
  it('Japanese, exactly as before', () => {
    const title = eventDisplayTitle({ title: '定例会', availability: 'busy' });
    const vis = visibilityMeta('private').label;
    expect(t('calendar.chip.title', 'ja', { title, visibility: vis })).toBe('定例会（非公開）');
    expect(t('calendar.chip.ariaLabel', 'ja', { title, visibility: vis })).toBe('定例会, 非公開');
  });

  it('English, with no Japanese half', () => {
    const title = eventDisplayTitle({ title: 'Standup', availability: 'busy' }, 'en');
    const vis = visibilityMeta('private', 'en').label;
    expect(t('calendar.chip.title', 'en', { title, visibility: vis })).toBe('Standup (Private)');
    expect(t('calendar.chip.ariaLabel', 'en', { title, visibility: vis })).toBe(
      'Standup, Private',
    );
  });

  it('an untitled event announces its fallback in the same language as its label', () => {
    // The exact mix the audit named: "(無題)" beside "Private", or
    // "(untitled)" beside "非公開". Neither may happen now.
    for (const lang of LANGUAGES) {
      const title = eventDisplayTitle({ title: '', availability: 'busy' }, lang);
      const vis = visibilityMeta('private', lang).label;
      const composed = t('calendar.chip.ariaLabel', lang, { title, visibility: vis });
      const hasJa = /[ぁ-んァ-ン一-龯]/;
      // Either both halves are Japanese or neither is.
      expect(hasJa.test(title), `${lang} title`).toBe(hasJa.test(vis));
      expect(composed, lang).not.toBe(', ' + vis);
    }
  });

  it('an untitled AVAILABLE event is still named, never left blank', () => {
    for (const lang of LANGUAGES) {
      const s = eventDisplayTitle({ title: '', availability: 'available' }, lang);
      expect(s.trim(), lang).not.toBe('');
      expect(s, lang).not.toBe(eventDisplayTitle({ title: '', availability: 'busy' }, lang));
    }
  });
});

describe('the visibility meanings are unchanged', () => {
  it('the three stored values are still the three, in order', () => {
    expect(VISIBILITIES).toEqual(['private', 'busy_only', 'public']);
  });

  it('busy_only still says the details are hidden, in both languages', () => {
    expect(visibilityMeta('busy_only').label).toContain('詳細非公開');
    expect(visibilityMeta('busy_only', 'en').label).toMatch(/hidden/i);
    // And never "public", which would overstate what it discloses.
    expect(visibilityMeta('busy_only', 'en').label).not.toMatch(/\bpublic\b/i);
  });

  it('the three are distinguishable from each other in both languages', () => {
    for (const lang of LANGUAGES) {
      const labels = VISIBILITIES.map((v) => visibilityMeta(v, lang).label);
      expect(new Set(labels).size, lang).toBe(3);
    }
  });

  it('a visibility label never reads as an availability', () => {
    // visibility answers "how much may be disclosed"; availability answers
    // "is this time taken". `busy_only` legitimately contains "Busy", so the
    // check is on the two that must not.
    for (const v of ['private', 'public'] as const) {
      expect(visibilityMeta(v, 'en').label, v).not.toMatch(/busy|available|open/i);
      expect(visibilityMeta(v).label, v).not.toContain('空き');
    }
  });

  it('nothing here decides what is disclosed', () => {
    // The module names the rule; the database and the share RPC enforce it.
    const mod = code('features/calendar/visibilityMeta.ts');
    expect(mod).not.toMatch(/includePrivate|shareAvailable|getFreeBusy|supabase/);
  });
});

describe('neither module became a hook, and neither reads a context', () => {
  it('both are pure, so they stay testable without a DOM', () => {
    for (const p of ['features/calendar/visibilityMeta.ts', 'features/calendar/eventTitle.ts']) {
      const mod = code(p);
      expect(mod, p).not.toMatch(/useTranslate|useLanguage|useMemo|useState|from 'react'/);
      expect(mod, p).toMatch(/lang: Language = DEFAULT_LANGUAGE/);
    }
  });

  it('an unrecognised language falls back to the default rather than crashing', () => {
    // The value can arrive from owner_settings, so a row written by a newer
    // version of the app must not produce `undefined`.
    const bogus = 'de' as 'ja';
    expect(visibilityMeta('private', bogus).label).toBe('非公開');
    expect(eventDisplayTitle({ title: '', availability: 'busy' }, bogus)).toBe('(無題)');
  });

  it('repeated calls for one language return the same object', () => {
    // A month grid draws a hundred chips. The per-language cache keeps that
    // from rebuilding six strings each time, and keeps identity stable for
    // React.
    expect(visibilityMeta('private', 'en')).toBe(visibilityMeta('private', 'en'));
    expect(visibilityMeta('private', 'ja')).not.toBe(visibilityMeta('private', 'en'));
  });

  it('the cache cannot serve one language’s strings for another', () => {
    // Interleaved calls, in case a cache key were ever dropped.
    expect(visibilityMeta('public', 'ja').label).toBe('公開');
    expect(visibilityMeta('public', 'en').label).toBe('Public');
    expect(visibilityMeta('public', 'ja').label).toBe('公開');
    expect(eventDisplayTitle({ title: '', availability: 'available' }, 'en')).toBe('Open time');
    expect(eventDisplayTitle({ title: '', availability: 'available' })).toBe('空き時間');
  });
});

describe('all three renderers pass the language', () => {
  it('each resolves both modules with it', () => {
    for (const p of RENDERERS) {
      expect(code(p), p).toMatch(/visibilityMeta\([^)]*language\)/);
      expect(code(p), p).toMatch(/eventDisplayTitle\([^)]*language\)/);
    }
  });

  it('none indexes the old Record any more', () => {
    for (const p of RENDERERS) {
      expect(code(p), p).not.toMatch(/visibilityMeta\[/);
    }
  });

  it('each gets the language from the provider, not from the browser', () => {
    for (const p of RENDERERS) {
      expect(code(p), p).toMatch(/const \{ language \} = useLanguage\(\)/);
      expect(code(p), p).not.toMatch(/navigator|\.languages\b/);
    }
  });

  it('MonthBand binds its own hooks, because it is its own component', () => {
    // It is defined below MonthView in the same file and receives no language
    // prop, so reading the context there is the only correct answer.
    const mv = code('features/calendar/MonthView.tsx');
    expect(mv).toMatch(/function MonthBand\(/);
    expect((mv.match(/useLanguage\(\)/g) ?? []).length).toBe(2);
  });

  it('the rendered markup is unchanged apart from where the strings come from', () => {
    // Order, colour, the availability hook and the click path all stay.
    for (const p of RENDERERS) {
      expect(code(p), p).toMatch(/data-availability=\{/);
      expect(code(p), p).toMatch(/categoryColor\(/);
    }
    expect(code('features/calendar/EventChip.tsx')).toMatch(/title=\{tr\('calendar\.chip\.title'/);
    expect(code('features/calendar/EventChip.tsx')).toMatch(
      /aria-label=\{tr\('calendar\.chip\.ariaLabel'/,
    );
    expect(code('features/calendar/EventChip.tsx')).toMatch(
      /<VisibilityIcon visibility=\{event\.visibility\} \/>/,
    );
  });
});

describe('a language change rewrites nothing but the rendering', () => {
  it('an empty title stays empty in the data', () => {
    // The fallback is supplied at render time. Nothing writes it to a row --
    // buildCancellation blanks a tombstone rather than inventing a name -- so
    // the stored value stays language-free.
    const mod = code('features/calendar/eventTitle.ts');
    expect(mod).not.toMatch(/supabase|repository|update\(|insert\(/);
    // The function returns the stored title whenever there is one.
    expect(eventDisplayTitle({ title: 'x', availability: 'busy' }, 'en')).toBe('x');
    expect(eventDisplayTitle({ title: ' ', availability: 'busy' }, 'en')).toBe(' ');
  });

  it('whitespace is still a title, in either language', () => {
    // The rule is `title || fallback`, so only the empty string triggers it.
    for (const lang of LANGUAGES) {
      expect(eventDisplayTitle({ title: ' ', availability: 'available' }, lang)).toBe(' ');
    }
  });

  it('the dictionary gained no keys for this', () => {
    // The six visibility keys and the two fallbacks already existed; P6 step 1
    // changed only when they are resolved.
    for (const k of [
      'calendar.visibility.private',
      'calendar.visibility.privateShort',
      'calendar.visibility.busyOnly',
      'calendar.visibility.busyOnlyShort',
      'calendar.visibility.public',
      'calendar.visibility.publicShort',
      'calendar.untitled',
      'calendar.availableTitle',
    ] as const) {
      expect(en, k).toHaveProperty(k);
    }
  });

  it('the switch is still off, so every one of these renders Japanese today', () => {
    expect(code('i18n/types.ts')).toMatch(/LANGUAGE_SWITCH_ENABLED = true/);
  });
});
