/**
 * The language switch is live: the end-to-end display-language contract.
 *
 * Every piece of this was tested in isolation long before the flip --
 * resolveLanguage.test.ts for the fallback chain, languageState.test.ts for
 * the fetch, the race and the leak guard. What none of them could assert is
 * the COMPOSITION, because that lived in LanguageProvider.tsx and this project
 * runs vitest with `environment: 'node'` and no jsdom.
 *
 * So this file reproduces the provider's three lines exactly:
 *
 *     const effectiveStored = retainStored({ stored, loadedFor, userId });
 *     const resolvedLanguage = resolveLanguage({ stored: effectiveStored, browser });
 *     const language = LANGUAGE_SWITCH_ENABLED ? resolvedLanguage : DEFAULT_LANGUAGE;
 *
 * and asserts the contract a user actually experiences. The duplication is the
 * point: if someone changes the provider's composition, `providerLanguage`
 * below stops matching it and the structural guard at the bottom -- which
 * reads the real file -- fails.
 */

import { describe, expect, it } from 'vitest';
import {
  needsFetch,
  retainStored,
  shouldApplyFetchResult,
  shouldLoadStoredLanguage,
} from './languageState';
import { resolveLanguage } from './resolveLanguage';
import { DEFAULT_LANGUAGE, LANGUAGE_SWITCH_ENABLED, LANGUAGES, type Language } from './types';
import { t } from './t';
import { ja } from './ja';
import { en } from './en';

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

/** The provider's composition, line for line. */
function providerLanguage(input: {
  stored: Language | null;
  loadedFor: string | null;
  userId: string | null;
  browser: readonly string[];
}): Language {
  const effectiveStored = retainStored(input);
  const resolved = resolveLanguage({ stored: effectiveStored, browser: input.browser });
  return LANGUAGE_SWITCH_ENABLED ? resolved : DEFAULT_LANGUAGE;
}

/** A signed-in owner whose settings have loaded. */
const owner = (stored: Language | null, browser: readonly string[] = []) =>
  providerLanguage({ stored, loadedFor: 'u1', userId: 'u1', browser });

/** An anonymous viewer on /s/:token: no session, so never any stored value. */
const anon = (browser: readonly string[]) =>
  providerLanguage({ stored: null, loadedFor: null, userId: null, browser });

// ---------------------------------------------------------------------------

describe('the switch is on', () => {
  it('the flag is true and the provider hands out the resolved language', () => {
    expect(LANGUAGE_SWITCH_ENABLED).toBe(true);
    expect(code('i18n/types.ts')).toMatch(/LANGUAGE_SWITCH_ENABLED = true/);
  });

  it('the provider composition is still the three lines modelled here', () => {
    // If this fails, `providerLanguage` above has drifted from the real thing
    // and every assertion in this file is measuring the wrong model.
    const p = code('i18n/LanguageProvider.tsx');
    expect(p).toContain('const effectiveStored = retainStored({ stored, loadedFor, userId })');
    expect(p).toContain('const resolvedLanguage = resolveLanguage({ stored: effectiveStored, browser })');
    expect(p).toContain(
      'const language = LANGUAGE_SWITCH_ENABLED ? resolvedLanguage : DEFAULT_LANGUAGE',
    );
  });
});

describe('a signed-in owner', () => {
  it("language='ja' renders Japanese, whatever the browser says", () => {
    expect(owner('ja')).toBe('ja');
    expect(owner('ja', ['en-US', 'en'])).toBe('ja');
  });

  it("language='en' renders English, whatever the browser says", () => {
    expect(owner('en')).toBe('en');
    expect(owner('en', ['ja-JP', 'ja'])).toBe('en');
  });

  it('language=NULL falls back to the browser', () => {
    expect(owner(null, ['en-GB', 'en'])).toBe('en');
    expect(owner(null, ['ja-JP'])).toBe('ja');
  });

  it('an unsupported browser language falls back to Japanese', () => {
    expect(owner(null, ['de-DE', 'fr-FR'])).toBe('ja');
    expect(owner(null, [])).toBe('ja');
    expect(owner(null, ['xx'])).toBe('ja');
  });

  it('a region subtag does not defeat the match', () => {
    // Browsers almost always send a region; matching the whole tag would send
    // most English and Japanese speakers to the default for no reason.
    for (const tag of ['en', 'en-US', 'en-GB', 'EN-AU']) {
      expect(owner(null, [tag]), tag).toBe('en');
    }
  });

  it('a later preference is used when the first is unsupported', () => {
    expect(owner(null, ['fr-FR', 'en-US'])).toBe('en');
    expect(owner(null, ['de', 'ja'])).toBe('ja');
  });

  it('a stored value that is not a known language is ignored', () => {
    // The column can hold anything a newer build wrote.
    const bogus = 'de' as unknown as Language;
    expect(owner(bogus, ['en-US'])).toBe('en');
    expect(owner(bogus, [])).toBe('ja');
  });
});

describe('selecting a language does not change the display until it is saved', () => {
  it('the dialog writes the form value and pushes only the SERVER value', () => {
    // The form's `lang` is what gets stored; `setStoredLanguage` receives
    // `s.language`, the value the save confirmed. Nothing reads the form's
    // pending value for display.
    const dlg = code('features/settings/SettingsDialog.tsx');
    expect(dlg).toContain("language: lang === '' ? null : lang");
    expect(dlg).toContain('setStoredLanguage(s.language)');
    expect(dlg).not.toMatch(/setStoredLanguage\(lang\)/);
  });

  it('setStoredLanguage runs after the round trip, never before', () => {
    const dlg = code('features/settings/SettingsDialog.tsx');
    const start = dlg.indexOf('const persist');
    const persist = dlg.slice(start, dlg.indexOf('} catch (e)', start));
    expect(start).toBeGreaterThan(0);
    expect(persist.indexOf('setStoredLanguage(s.language)')).toBeGreaterThan(
      persist.indexOf('await saveOwnerSettings'),
    );
  });

  it('a failed save leaves the display language alone', () => {
    // The catch is unreachable from setStoredLanguage, so the provider keeps
    // the value it had. Modelled: a save that threw leaves `stored` unchanged.
    const dlg = code('features/settings/SettingsDialog.tsx');
    const start = dlg.indexOf('const persist');
    const katch = dlg.slice(dlg.indexOf('} catch (e) {', start), dlg.indexOf('} finally {', start));
    expect(katch).not.toContain('setStoredLanguage');
    expect(owner('ja', ['en-US'])).toBe('ja');
  });

  it('a successful save is reflected without a refetch', () => {
    // setStoredLanguage takes the value rather than re-reading the row, so the
    // next render resolves from it.
    expect(owner('ja')).toBe('ja');
    expect(owner('en')).toBe('en');
    const provider = code('i18n/LanguageProvider.tsx');
    expect(provider).toMatch(/setStoredLanguage = useCallback\(\(lang: Language \| null\) => \{/);
    expect(provider).toMatch(/writeSeq\.current \+= 1/);
  });
});

describe('the anonymous share page uses the viewer, never the owner', () => {
  it("the viewer's own browser decides", () => {
    expect(anon(['en-US', 'en'])).toBe('en');
    expect(anon(['ja-JP'])).toBe('ja');
  });

  it('an unsupported browser language falls back to Japanese', () => {
    expect(anon(['de-DE'])).toBe('ja');
    expect(anon([])).toBe('ja');
  });

  it("the owner's preference cannot reach this route", () => {
    // Two independent reasons, and both are asserted. First: the route never
    // fetches, so `stored` is null by construction.
    expect(shouldLoadStoredLanguage({ isPublicRoute: true, authEnabled: true, userId: 'u1' })).toBe(
      false,
    );
    expect(needsFetch({ shouldLoad: false, userId: 'u1', loadedFor: null })).toBe(false);
    // Second: even a stray value would be dropped, because no user is signed
    // in on this route.
    expect(retainStored({ stored: 'en', loadedFor: 'u1', userId: null })).toBeNull();
    // So an English-browser viewer of a Japanese owner's link reads English.
    expect(anon(['en-US'])).toBe('en');
  });

  it('nothing on the route reads owner_settings', () => {
    const page = code('features/share/FreeBusyPage.tsx');
    expect(page).not.toMatch(/owner_settings|ownerSettingsRepository|getOwnerSettings/);
    const app = source('App.tsx');
    const shareBranch = app.slice(app.indexOf("if (route.kind === 'share')"), app.indexOf('</LanguageProvider>'));
    expect(shareBranch).toMatch(/<LanguageProvider isPublicRoute>/);
  });

  it('no language is saved while viewing anonymously', () => {
    // setStoredLanguage is called from exactly one place, and it is the
    // owner's settings dialog.
    const callers = Object.keys(MODULES)
      .filter((p) => !p.includes('.test.'))
      .map((p) => p.replace(/^\/src\//, ''))
      .filter((p) => /setStoredLanguage\s*\(/.test(code(p)))
      .sort();
    // Exactly one INVOCATION site. The provider defines it; nobody else
    // calls it, so no anonymous path can push a language into the context.
    expect(callers).toEqual(['features/settings/SettingsDialog.tsx']);
    expect(code('features/share/FreeBusyPage.tsx')).not.toMatch(/setStoredLanguage/);
  });
});

describe('loading, races, user switches and unmount', () => {
  it('a preference is never shown to the wrong account', () => {
    // THE LEAK GUARD, at read time rather than in an effect: a value belonging
    // to another id is never handed out, not even for the render between
    // sign-out and the effect that would have cleared it.
    expect(providerLanguage({ stored: 'en', loadedFor: 'u1', userId: 'u2', browser: ['ja'] })).toBe(
      'ja',
    );
    expect(providerLanguage({ stored: 'en', loadedFor: 'u1', userId: null, browser: ['ja'] })).toBe(
      'ja',
    );
  });

  it('while the fetch is in flight the browser answer is used, not a blank', () => {
    // `stored` is null until the response lands, and null means "follow the
    // browser" -- which is also the right answer for an owner who set nothing.
    expect(providerLanguage({ stored: null, loadedFor: null, userId: 'u1', browser: ['en'] })).toBe(
      'en',
    );
  });

  it('a response that a save overtook is discarded', () => {
    // The owner saves English while the fetch issued at sign-in is still out.
    // Applying its older value would silently undo the save.
    expect(
      shouldApplyFetchResult({
        cancelled: false,
        requestedFor: 'u1',
        currentUserId: 'u1',
        writeSeqAtRequest: 0,
        writeSeqNow: 1,
      }),
    ).toBe(false);
  });

  it('a response for a previous user is discarded', () => {
    expect(
      shouldApplyFetchResult({
        cancelled: false,
        requestedFor: 'u1',
        currentUserId: 'u2',
        writeSeqAtRequest: 0,
        writeSeqNow: 0,
      }),
    ).toBe(false);
  });

  it('a response after unmount is discarded', () => {
    expect(
      shouldApplyFetchResult({
        cancelled: true,
        requestedFor: 'u1',
        currentUserId: 'u1',
        writeSeqAtRequest: 0,
        writeSeqNow: 0,
      }),
    ).toBe(false);
  });

  it('one fetch per user, and again when the user changes', () => {
    expect(needsFetch({ shouldLoad: true, userId: 'u1', loadedFor: null })).toBe(true);
    expect(needsFetch({ shouldLoad: true, userId: 'u1', loadedFor: 'u1' })).toBe(false);
    expect(needsFetch({ shouldLoad: true, userId: 'u2', loadedFor: 'u1' })).toBe(true);
  });

  it('local mode needs no fetch at all', () => {
    expect(shouldLoadStoredLanguage({ isPublicRoute: false, authEnabled: false, userId: null })).toBe(
      false,
    );
    expect(providerLanguage({ stored: null, loadedFor: null, userId: null, browser: ['en'] })).toBe(
      'en',
    );
  });
});

describe('a language change re-renders and nothing more', () => {
  it('the events hook knows no language, so no refetch can follow one', () => {
    const hook = code('hooks/useEvents.ts');
    expect(hook).not.toMatch(/i18n|Language|useTranslate|useLanguage|DEFAULT_LANGUAGE/);
    expect(hook).toMatch(/\}, \[repo\]\);/);
  });

  it('the share dialog fetches on mount only', () => {
    const dlg = code('features/share/ShareDialog.tsx');
    expect(dlg).toMatch(/useEffect\(\(\) => \{\s*void refresh\(\);\s*\}, \[\]\);/);
    expect(dlg).not.toMatch(/\[language\]/);
  });

  it('the settings dialog loads on mount only', () => {
    const dlg = code('features/settings/SettingsDialog.tsx');
    expect(dlg).toMatch(/\}, \[\]\);/);
    expect(dlg).not.toMatch(/\[language\]/);
  });

  it('the anonymous page refetches on week and zone, never on language', () => {
    const page = code('features/share/FreeBusyPage.tsx');
    expect(page).toMatch(/\}, \[token, view\.anchor, timeZone, days\]\);/);
  });

  it('no repository or RPC call names a language', () => {
    for (const p of [
      'repositories/shareRepository.ts',
      'repositories/eventRepository.ts',
      'repositories/ownerSettingsRepository.ts',
    ]) {
      const repo = code(p);
      expect(repo, p).not.toMatch(/p_lang|p_locale|p_language/);
    }
    // The settings repository writes the language as DATA, which is its job --
    // it must not read it to decide anything.
    expect(code('repositories/ownerSettingsRepository.ts')).not.toMatch(
      /resolveLanguage|intlLocale|useLanguage/,
    );
  });

  it('time zone and date arithmetic never consult the language', () => {
    for (const p of ['utils/timezone.ts', 'services/occurrences.ts', 'services/recurrence.ts']) {
      expect(code(p), p).not.toMatch(/i18n|resolveLanguage|useLanguage|intlLocale/);
    }
  });
});

describe('both dictionaries are complete, so no screen can fall back', () => {
  it('every key renders non-empty in both languages with no stray placeholder', () => {
    const keys = Object.keys(ja) as (keyof typeof ja)[];
    expect(keys.length).toBeGreaterThan(150);
    for (const k of keys) {
      for (const lang of LANGUAGES) {
        const s = t(k as 'common.save', lang);
        expect(s, `${lang}:${k}`).not.toBe('');
        // A missing key returns the key itself -- searchable, and caught here.
        expect(s, `${lang}:${k}`).not.toBe(k);
      }
    }
  });

  it('no English value carries Japanese text', () => {
    // The one failure mode a complete-looking dictionary can still have: a key
    // copied across and left untranslated.
    for (const [k, v] of Object.entries(en)) {
      expect(v, k).not.toMatch(JAPANESE);
    }
  });

  it('the two dictionaries agree on their key sets', () => {
    expect(Object.keys(en).sort()).toEqual(Object.keys(ja).sort());
  });

  it('the removed pending-notice key is gone from both', () => {
    expect(ja).not.toHaveProperty('settings.language.pending');
    expect(en).not.toHaveProperty('settings.language.pending');
  });

  it('the language picker still names each language in its own language', () => {
    // Not translated, deliberately: a picker that renamed 日本語 to "Japanese"
    // for an English reader would be unreadable to the person looking for it.
    const mod = code('features/settings/timezoneSetting.ts');
    expect(mod).toContain("{ value: 'ja', label: '日本語' }");
    expect(mod).toContain("{ value: 'en', label: 'English' }");
  });
});

describe('the invariants the language must not have touched', () => {
  it('availability and visibility are still separate fields', () => {
    const types = source('types/event.ts');
    expect(types).toMatch(/availability/);
    expect(types).toMatch(/visibility/);
    const dlg = code('features/event/EventDialog.tsx');
    expect(dlg).toMatch(/visibility,\s*availability,/);
  });

  it('new events still default to private', () => {
    expect(code('features/event/EventDialog.tsx')).toMatch(/useState<Visibility>\('private'\)/);
  });

  it('the two share opt-ins are still independent', () => {
    const types = source('types/share.ts');
    expect(types).toMatch(/includePrivate: boolean/);
    expect(types).toMatch(/shareAvailable: boolean/);
  });

  it('the three Available states are still distinct, and none reads as free', () => {
    const types = source('types/share.ts');
    for (const s of ['not_requested', 'indeterminate', 'complete']) {
      expect(types, s).toContain(s);
    }
    // And the copy for the two that have no slots says so in both languages.
    expect(t('share.available.indeterminate', 'en')).toMatch(/could not be determined/i);
    expect(t('share.available.indeterminate', 'en')).not.toMatch(/\bno open time\b/i);
    expect(t('share.available.empty', 'en')).toMatch(/shared/i);
    expect(t('share.activeEmpty', 'en')).not.toMatch(/\bfree\b|\bavailable\b/i);
  });

  it('Available is still never derived from the gaps between Busy blocks', () => {
    for (const p of [
      'features/share/availablePresentation.ts',
      'features/share/freeBusyPresentation.ts',
    ]) {
      expect(code(p), p).not.toMatch(/invert|complement|mergeFreeBusySlots/i);
    }
  });

  it('busy_only still says details are hidden, in both languages', () => {
    expect(t('calendar.visibility.busyOnly', 'ja')).toContain('非公開');
    expect(t('calendar.visibility.busyOnly', 'en')).toMatch(/hidden/i);
    expect(t('calendar.visibility.busyOnly', 'en')).not.toMatch(/public/i);
  });

  it('the week still starts on Monday in both languages', () => {
    const names = code('i18n/dateNames.ts');
    expect(names).toMatch(/ja: \['月', '火', '水', '木', '金', '土', '日'\]/);
    expect(names).toMatch(/en: \['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'\]/);
  });

  it('the clock stays 24-hour in both languages', () => {
    // English does NOT switch to AM/PM: the pin is explicit.
    expect(code('utils/datetime.ts')).toMatch(/hourCycle: 'h23'/);
  });

  it("the zone-validity probe still pins 'en-US'", () => {
    expect(source('utils/timezone.ts')).toMatch(/Intl\.DateTimeFormat\('en-US'/);
  });

  it('the anonymous page still discloses no event detail', () => {
    const page = code('features/share/FreeBusyPage.tsx');
    expect(page).not.toMatch(/\.title|\.category|\.description|visibilityMeta|eventDisplayTitle/);
  });
});
