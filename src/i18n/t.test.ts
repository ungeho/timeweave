import { describe, expect, it } from 'vitest';
import { t, translator } from './t';
import { dictionaries } from './dictionaries';
import { ja } from './ja';
import { en } from './en';
import { LANGUAGES, type Language } from './types';

/**
 * Call t with a key whose type is only known as the UNION of all keys.
 *
 * The compiler cannot decide whether such a key needs variables -- which is
 * the whole point of VarArgs and must not be softened in t itself. These two
 * sweeps are the only place that needs it, so the cast is quarantined here
 * rather than widening the real signature.
 */
const tAny = (key: string, lang: Language): string =>
  (t as unknown as (k: string, l: Language) => string)(key, lang);

describe('t: lookup', () => {
  it('returns the Japanese message', () => {
    expect(t('common.save', 'ja')).toBe('保存');
  });

  it('returns the English message', () => {
    expect(t('common.save', 'en')).toBe('Save');
  });

  it('resolves every key in both languages to a non-empty string', () => {
    for (const key of Object.keys(ja) as (keyof typeof ja)[]) {
      for (const lang of LANGUAGES) {
        const s = tAny(key, lang);
        expect(typeof s).toBe('string');
        expect(s).not.toBe('');
        // A key echoed back means the dictionary lacked it.
        expect(s).not.toBe(key);
      }
    }
  });
});

describe('t: interpolation', () => {
  it('fills a single placeholder', () => {
    expect(t('share.label.count', 'ja', { count: 12, max: 50 })).toBe('12 / 50');
  });

  it('formats numbers with String', () => {
    expect(t('share.label.count', 'en', { count: 0, max: 50 })).toBe('0 / 50');
  });

  it('fills several placeholders', () => {
    expect(t('share.link.status', 'ja', { label: '取引先A', status: '有効' }))
      .toBe('取引先A — 有効');
  });

  it('leaves a message with no placeholders untouched', () => {
    expect(t('common.close', 'ja')).toBe('閉じる');
  });

  it('interpolates identically in both languages', () => {
    expect(t('share.label.count', 'ja', { count: 3, max: 9 })).toBe('3 / 9');
    expect(t('share.label.count', 'en', { count: 3, max: 9 })).toBe('3 / 9');
  });
});

describe('t: runtime robustness at the untyped boundary', () => {
  it('falls back to Japanese for an unrecognised language', () => {
    // `lang` can arrive from owner_settings or navigator; a row written by a
    // newer build must not render `undefined`.
    expect(t('common.save', 'fr' as unknown as Language)).toBe('保存');
    expect(t('common.save', undefined as unknown as Language)).toBe('保存');
  });

  it('returns the key itself for an unknown key rather than a blank', () => {
    // Unreachable through the typed signature; this guards the boundary. A
    // searchable key on screen beats an invisible gap.
    expect(tAny('nope.missing', 'ja')).toBe('nope.missing');
  });

  it('leaves an unknown placeholder verbatim', () => {
    // A stray {x} is a visible bug that gets reported; an empty gap reads as
    // intended copy and survives.
    const out = t('share.label.count', 'ja', { count: 1 } as unknown as { count: number; max: number });
    expect(out).toBe('1 / {max}');
  });
});

describe('translator', () => {
  it('binds the language', () => {
    const tr = translator('en');
    expect(tr('common.cancel')).toBe('Cancel');
    expect(tr('share.label.count', { count: 2, max: 4 })).toBe('2 / 4');
  });

  it('agrees with t for every key', () => {
    for (const lang of LANGUAGES) {
      const tr = translator(lang);
      for (const key of ['common.save', 'common.close', 'settings.title'] as const) {
        expect(tr(key)).toBe(tAny(key, lang));
      }
    }
  });
});

/**
 * Dictionary parity. The compiler already refuses a missing key and a
 * placeholder that drifted -- these assert the same facts at runtime so a
 * failure names the entry instead of pointing at a type alias, and so the
 * guarantee survives anyone who reaches for `as any`.
 */
describe('dictionary parity', () => {
  const vars = (s: string) => [...s.matchAll(/\{(\w+)\}/g)].map((m) => m[1]!).sort();

  it('both dictionaries hold exactly the same keys', () => {
    expect(Object.keys(en).sort()).toEqual(Object.keys(ja).sort());
  });

  it('every message declares the same placeholders in both languages', () => {
    for (const key of Object.keys(ja) as (keyof typeof ja)[]) {
      expect(vars(en[key]), `placeholders differ for ${key}`).toEqual(vars(ja[key]));
    }
  });

  it('no message is left untranslated by being identical', () => {
    // Identical strings are legal for a format like "{count} / {max}", which
    // carries no words. Anything with letters in it that matches exactly is a
    // translation that was never written.
    const suspicious = (Object.keys(ja) as (keyof typeof ja)[]).filter(
      (k) => ja[k] === en[k] && /[A-Za-z぀-ヿ一-龯]/.test(ja[k].replace(/\{\w+\}/g, '')),
    );
    expect(suspicious).toEqual([]);
  });

  it('exposes both languages through the registry', () => {
    expect(Object.keys(dictionaries).sort()).toEqual(['en', 'ja']);
  });
});

/**
 * The two entries whose MEANING is load-bearing. The existing share-page tests
 * assert what the Japanese does not say; these do the same for the English,
 * because a fluent rewrite is exactly how that meaning gets lost.
 */
describe('safety-critical wording survives translation', () => {
  it('indeterminate reports missing knowledge, not missing availability', () => {
    const s = en['share.available.indeterminate'];
    expect(s).toMatch(/could not be determined/i);
    expect(s).not.toMatch(/\bno (open time|availability)\b/i);
    expect(s).not.toMatch(/\b(unavailable|fully booked|busy)\b/i);
  });

  it('indeterminate names no reason', () => {
    // Expired, revoked, unexpandable recurrence -- the viewer is told none of
    // them, in either language.
    for (const s of [ja['share.available.indeterminate'], en['share.available.indeterminate']]) {
      expect(s).not.toMatch(/recurr|繰り返し|expired|期限|revoked|失効/i);
    }
  });

  it('the empty notice speaks of what is SHARED, not of what exists', () => {
    expect(en['share.available.empty']).toMatch(/shared/i);
    expect(ja['share.available.empty']).toContain('共有');
  });
});
