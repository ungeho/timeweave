import { describe, expect, it } from 'vitest';
import { intlLocale, resolveLanguage } from './resolveLanguage';
import { DEFAULT_LANGUAGE, LANGUAGES, isLanguage } from './types';

describe('resolveLanguage: an explicit choice wins', () => {
  it('uses the stored language whatever the browser says', () => {
    expect(resolveLanguage({ stored: 'en', browser: ['ja-JP'] })).toBe('en');
    expect(resolveLanguage({ stored: 'ja', browser: ['en-US'] })).toBe('ja');
  });
});

describe('resolveLanguage: unset follows the browser', () => {
  it('reads the primary subtag, ignoring the region', () => {
    expect(resolveLanguage({ stored: null, browser: ['en-GB'] })).toBe('en');
    expect(resolveLanguage({ stored: null, browser: ['ja-JP'] })).toBe('ja');
  });

  it('ignores case', () => {
    expect(resolveLanguage({ stored: null, browser: ['EN-us'] })).toBe('en');
  });

  it('accepts a bare tag with no region', () => {
    expect(resolveLanguage({ stored: null, browser: ['en'] })).toBe('en');
  });

  it('scans PAST unsupported preferences instead of stopping at the first', () => {
    // A viewer whose first choice is French and second is English should get
    // English. Looking only at browser[0] would hand them Japanese.
    expect(resolveLanguage({ stored: null, browser: ['fr-FR', 'en-US'] })).toBe('en');
    expect(resolveLanguage({ stored: null, browser: ['de', 'ko', 'ja'] })).toBe('ja');
  });

  it('takes the FIRST supported match when several are present', () => {
    expect(resolveLanguage({ stored: null, browser: ['en-US', 'ja-JP'] })).toBe('en');
    expect(resolveLanguage({ stored: null, browser: ['ja-JP', 'en-US'] })).toBe('ja');
  });
});

describe('resolveLanguage: fallback', () => {
  it('falls back to Japanese for an unsupported browser language', () => {
    expect(resolveLanguage({ stored: null, browser: ['fr-FR'] })).toBe('ja');
  });

  it('falls back when the browser list is empty', () => {
    expect(resolveLanguage({ stored: null, browser: [] })).toBe('ja');
  });

  it('falls back on junk entries rather than throwing', () => {
    // navigator.languages is supposed to be string[], but this value crosses a
    // runtime boundary and a blank or malformed tag must not take the page down.
    expect(resolveLanguage({ stored: null, browser: ['', '-', 'x'] })).toBe('ja');
    expect(resolveLanguage({ stored: null, browser: ['', 'en'] })).toBe('en');
  });

  it('falls back to Japanese, not English', () => {
    // Every string in the app is Japanese today, so an unplaceable viewer gets
    // a complete UI rather than a half-translated one.
    expect(DEFAULT_LANGUAGE).toBe('ja');
    expect(resolveLanguage({ stored: null, browser: ['zz'] })).toBe('ja');
  });
});

describe('resolveLanguage: the anonymous case', () => {
  it('an anonymous viewer always follows their own browser', () => {
    // An anonymous caller has no stored preference, and that is the correct
    // input rather than a gap: rendering the OWNER's language would hand a
    // stranger a page they cannot read. The mirror of the time zone rule,
    // where the owner's value is the right one.
    expect(resolveLanguage({ stored: null, browser: ['en-US'] })).toBe('en');
    expect(resolveLanguage({ stored: null, browser: ['ja-JP'] })).toBe('ja');
  });
});

describe('isLanguage', () => {
  it('accepts the supported pair and nothing else', () => {
    expect(isLanguage('ja')).toBe(true);
    expect(isLanguage('en')).toBe(true);
    for (const v of ['fr', 'JA', 'en-US', '', null, undefined, 0, {}]) {
      expect(isLanguage(v)).toBe(false);
    }
  });
});

describe('LANGUAGES', () => {
  it('lists both, default first', () => {
    expect(LANGUAGES).toEqual(['ja', 'en']);
    expect(LANGUAGES[0]).toBe(DEFAULT_LANGUAGE);
  });
});

describe('intlLocale', () => {
  it('maps to a tag with a region, not a bare language', () => {
    // A bare 'ja' leaves region conventions unspecified; Intl should be told.
    expect(intlLocale('ja')).toBe('ja-JP');
    expect(intlLocale('en')).toBe('en-US');
  });

  it('produces a tag Intl actually accepts', () => {
    for (const lang of LANGUAGES) {
      expect(() => new Intl.DateTimeFormat(intlLocale(lang))).not.toThrow();
    }
  });
});
