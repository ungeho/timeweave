/**
 * P6 step 7: the settings dialog's error line is resolved at render.
 *
 * The smallest of the four frozen-error sites and the last before EventDialog.
 * Two catches filled `error` from `e.message`; a third path filled `notice`
 * from `tr('settings.saved')`. All three froze their wording at the moment they
 * were set, which was particularly visible here: step 3 had already made the
 * four timezone/language notices in this same dialog follow the language, so a
 * language change updated the paragraphs and left the error line beside them
 * in the old one.
 *
 * NO NEW DECISION WAS INTRODUCED. The three cases -- DomainError localizes, a
 * plain Error keeps its message, anything else gets the generic sentence --
 * are `caughtErrorText`'s, shared with the calendar banner and the share
 * dialog and tested in errorText.i18n.test.ts. What this file checks is that
 * this dialog reaches them, and that the save flow it sits inside did not
 * move: the dialog cannot be rendered here (vitest runs `environment: 'node'`
 * with no jsdom), so the flow is asserted structurally.
 */

import { describe, expect, it } from 'vitest';
import { caughtErrorText } from './errorText';
import {
  InvalidTimezoneError,
  TimezoneClearedError,
  TimezoneRequiredError,
  WriteRateLimitedError,
} from '../errors';
import {
  languageNotInCalculationNotice,
  timezoneChangeNeedsWarning,
  timezoneChangeNotice,
  timezoneUnsetNotice,
} from '../features/settings/timezoneSetting';
import { t } from './t';
import { LANGUAGE_SWITCH_ENABLED, LANGUAGES } from './types';

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
const DLG = 'features/settings/SettingsDialog.tsx';

// ---------------------------------------------------------------------------

describe('both catch paths keep the cause', () => {
  it('the load and the save each store a wrapper, not a sentence', () => {
    // The two are getOwnerSettings (the mount effect) and saveOwnerSettings
    // (persist). Both become the same thing, because the error line does not
    // care which call failed.
    const dlg = code(DLG);
    expect(dlg.split('setError({ cause: e })').length - 1).toBe(2);
    expect(dlg).not.toMatch(/instanceof Error \? e\.message : String\(e\)/);
    expect(dlg).not.toMatch(/String\(e\)/);
  });

  it('the load path still respects its cancelled guard', () => {
    // An unmounted dialog must still set nothing -- the one thing the effect's
    // cleanup exists for, and it would be easy to drop while editing the line.
    const dlg = code(DLG);
    expect(dlg).toContain('if (!cancelled) setError({ cause: e })');
    expect(dlg).toMatch(/return \(\) => \{ cancelled = true; \};/);
  });

  it('the save path stores only the error', () => {
    // What keeps the form's selection and the server's value from being
    // confused after a failure: neither `saved` nor the form fields is touched
    // in the catch, so the owner keeps what they chose and `saved` keeps what
    // is stored.
    const dlg = code(DLG);
    const start = dlg.indexOf('const persist');
    const katch = dlg.slice(dlg.indexOf('} catch (e) {', start), dlg.indexOf('} finally {', start));
    expect(katch).toContain('setError({ cause: e })');
    expect(katch).not.toMatch(/setSaved|setTz|setLang|setStoredLanguage|setNotice|setConfirming/);
  });

  it('the state is a wrapper, so a null cause is still an error', () => {
    // The render test is `error && ...`, and `unknown` includes null.
    const dlg = code(DLG);
    expect(dlg).toMatch(/type SettingsError = \{ readonly cause: unknown \}/);
    expect(dlg).toMatch(/useState<SettingsError \| null>/);
    expect(dlg).toMatch(/\{error && <p className="form-error">/);
  });

  it('no discriminated union was added where one variant does', () => {
    // Unlike ShareDialog, nothing in this dialog validates input into a
    // message -- the zone field is free text and the database has the final
    // word -- so there is no second variant and no tag to carry.
    const dlg = code(DLG);
    expect(dlg).not.toMatch(/kind: 'caught'/);
    expect(dlg).not.toMatch(/SettingsDialogError|shareDialogErrorText/);
  });
});

describe('the error renders in both languages', () => {
  it('a DomainError localizes, and the Japanese is what it showed before', () => {
    for (const e of [
      new InvalidTimezoneError(),
      new TimezoneRequiredError(),
      new TimezoneClearedError(),
      new WriteRateLimitedError(20),
    ]) {
      // `.message` IS the Japanese rendering for a default-constructed one.
      expect(caughtErrorText(e, 'ja'), e.name).toBe(e.message);
      expect(caughtErrorText(e, 'en'), e.name).not.toMatch(JAPANESE);
      expect(caughtErrorText(e, 'en'), e.name).not.toBe(caughtErrorText(e, 'ja'));
    }
  });

  it('the zone refusals are the ones this dialog actually raises', () => {
    // 0025's trigger raises TIMEWEAVE_TZ_INVALID for a zone the database does
    // not know; the dialog deliberately does not pre-validate. So this is the
    // error an owner is most likely to see here, and it has to read in their
    // language.
    const e = new InvalidTimezoneError();
    expect(caughtErrorText(e, 'ja')).toMatch(JAPANESE);
    expect(caughtErrorText(e, 'en')).toMatch(/time zone/i);
  });

  it('a rate-limited write keeps its interpolated wait in both languages', () => {
    expect(caughtErrorText(new WriteRateLimitedError(20), 'en')).toMatch(/20 sec\b/);
    expect(caughtErrorText(new WriteRateLimitedError(20), 'ja')).toMatch(/20秒/);
  });

  it('a custom message is shown verbatim, never translated', () => {
    const e = new InvalidTimezoneError('bespoke wording');
    expect(e.hasCustomMessage).toBe(true);
    for (const lang of LANGUAGES) {
      expect(caughtErrorText(e, lang), lang).toBe('bespoke wording');
    }
  });

  it('a plain Error keeps its message, as before', () => {
    const e = new Error('28000: JWT expired');
    for (const lang of LANGUAGES) {
      expect(caughtErrorText(e, lang), lang).toBe('28000: JWT expired');
    }
  });

  it('the same stored error reads differently per language, and stably within one', () => {
    const e = new TimezoneRequiredError();
    expect(caughtErrorText(e, 'ja')).not.toBe(caughtErrorText(e, 'en'));
    expect(caughtErrorText(e, 'ja')).toBe(caughtErrorText(e, 'ja'));
  });

  it('the dialog reads it with the DISPLAYED language', () => {
    // `language` is what the screen is written in; `lang` is the value this
    // dialog is about to store. Using the latter would translate the error the
    // moment the owner picked a language in the select, before saving.
    const dlg = code(DLG);
    expect(dlg).toContain('caughtErrorText(error.cause, language)');
    expect(dlg).not.toContain('caughtErrorText(error.cause, lang)');
  });
});

describe('null, undefined and unknown throws keep the line visible', () => {
  it.each([
    ['null', null],
    ['undefined', undefined],
    ['a string', 'TypeError: Failed to fetch'],
    ['a number', 0],
    ['an object', { code: 'PGRST301' }],
  ])('%s still produces a sentence', (_label, cause) => {
    for (const lang of LANGUAGES) {
      const got = caughtErrorText(cause, lang);
      expect(got, lang).toBe(t('error.unknownCause', lang));
      expect(got, lang).not.toBe('');
    }
  });

  it('the thrown value never reaches the screen', () => {
    // This dialog talks to owner_settings, so a stringified cause is the last
    // place a session detail should be able to surface.
    const leaky = { jwt: 'eyJhbGciOi.secret', toString: () => 'eyJhbGciOi.secret' };
    for (const lang of LANGUAGES) {
      expect(caughtErrorText(leaky, lang), lang).not.toContain('eyJhbGciOi');
    }
  });

  it('no setting value is interpolated into any error wording', () => {
    // The zone and the language are what this dialog stores. Neither should
    // arrive via an error line.
    for (const lang of LANGUAGES) {
      for (const cause of [new InvalidTimezoneError(), new Error('boom'), null]) {
        const got = caughtErrorText(cause, lang);
        expect(got).not.toMatch(/Asia\/|America\/|Europe\//);
      }
    }
  });
});

describe('the success notice follows the language too', () => {
  it('it is stored as a key, not as rendered text', () => {
    const dlg = code(DLG);
    expect(dlg).toContain("setNotice('settings.saved')");
    expect(dlg).not.toMatch(/setNotice\(tr\(/);
    expect(dlg).toMatch(/\{tr\(notice\)\}/);
    expect(dlg).toMatch(/type SettingsNotice = 'settings\.saved'/);
  });

  it('it renders in both languages and keeps its live-region role', () => {
    expect(t('settings.saved', 'ja')).toMatch(JAPANESE);
    expect(t('settings.saved', 'en')).not.toMatch(JAPANESE);
    expect(t('settings.saved', 'en')).not.toBe(t('settings.saved', 'ja'));
    expect(source(DLG)).toMatch(/className="share-notice" role="status"/);
  });

  it('success and failure stay two different states', () => {
    // Collapsing them would leave a failed save looking like a successful one.
    const dlg = code(DLG);
    expect(dlg).toMatch(/\{error && <p className="form-error">/);
    expect(dlg).toMatch(/\{notice && <p className="share-notice"/);
    // And the save clears both before acting, so neither outlives its attempt.
    const start = dlg.indexOf('const persist');
    const body = dlg.slice(start, dlg.indexOf('const onSave', start));
    expect(body.indexOf('setError(null)')).toBeGreaterThan(0);
    expect(body.indexOf('setNotice(null)')).toBeGreaterThan(0);
    expect(body.indexOf('setError(null)')).toBeLessThan(body.indexOf('await saveOwnerSettings'));
  });
});

/**
 * The save flow. All negatives: an error line is wording, and wording has no
 * business near what gets written or when the display language moves.
 */
describe('the settings save flow is untouched', () => {
  const dlg = code(DLG);

  it('owner_settings is read and written exactly as before', () => {
    expect(dlg).toMatch(/await getOwnerSettings\(\)/);
    expect(dlg).toMatch(/await saveOwnerSettings\(\{/);
    expect(dlg).toMatch(/timezone: nextTz/);
    expect(dlg).toMatch(/language: lang === '' \? null : lang/);
  });

  it('the dialog is still one of exactly three getOwnerSettings callers', () => {
    const callers = Object.keys(MODULES)
      .filter((p) => !p.includes('.test.'))
      .map((p) => p.replace(/^\/src\//, ''))
      .filter((p) => /getOwnerSettings\s*\(/.test(code(p)))
      .sort();
    expect(callers).toEqual([
      'features/settings/SettingsDialog.tsx',
      'i18n/LanguageProvider.tsx',
      'repositories/ownerSettingsRepository.ts',
    ]);
  });

  it('setStoredLanguage still runs after the save returns, with the SERVER value', () => {
    // The display language must not move for a save that did not land, and
    // must not move to the form's value when the server stored something else.
    const start = dlg.indexOf('const persist');
    const persist = dlg.slice(start, dlg.indexOf('} catch (e)', start));
    expect(start).toBeGreaterThan(0);
    expect(persist).toMatch(/const s = await saveOwnerSettings/);
    expect(persist.indexOf('setStoredLanguage(s.language)')).toBeGreaterThan(
      persist.indexOf('await saveOwnerSettings'),
    );
    expect(persist).not.toMatch(/setStoredLanguage\(lang\)/);
    // And it is unreachable from the catch.
    const katch = dlg.slice(dlg.indexOf('} catch (e) {', start), dlg.indexOf('} finally {', start));
    expect(katch).not.toContain('setStoredLanguage');
  });

  it('nothing is written optimistically', () => {
    // The form keeps showing the server's value until the round trip returns.
    const start = dlg.indexOf('const persist');
    const persist = dlg.slice(start, dlg.indexOf('} catch (e)', start));
    expect(persist.indexOf('setSaved(s)')).toBeGreaterThan(persist.indexOf('await saveOwnerSettings'));
  });

  it('the double-submit guard is intact', () => {
    expect(dlg).toMatch(/if \(savingRef\.current\) return/);
    expect(dlg).toMatch(/savingRef\.current = true/);
    expect(dlg).toMatch(/savingRef\.current = false/);
  });

  it('the zone confirmation flow is unchanged', () => {
    // A zone change is confirmed before it is applied, and the trigger reads
    // the stored value against the one about to be stored.
    expect(dlg).toMatch(/const needsWarning = timezoneChangeNeedsWarning\(saved\.timezone, nextTz\)/);
    expect(dlg).toMatch(/if \(needsWarning && !confirming\) \{/);
    expect(dlg).toMatch(/setConfirming\(true\)/);
    expect(dlg).toMatch(/timezoneChangeNotice\(language\)\.map/);
    // And the trigger itself takes no language.
    expect(timezoneChangeNeedsWarning.length).toBe(2);
    expect(timezoneChangeNeedsWarning(null, 'Asia/Tokyo')).toBe(true);
    expect(timezoneChangeNeedsWarning('Asia/Tokyo', 'Asia/Tokyo')).toBe(false);
    expect(timezoneChangeNeedsWarning('Asia/Tokyo', null)).toBe(true);
  });

  it('the unset-zone behaviour is unchanged', () => {
    expect(dlg).toMatch(/saved\.timezone === null &&/);
    expect(dlg).toContain('timezoneUnsetNotice(language)');
  });

  it("step 3's four notices were not touched", () => {
    // They already follow the language; this step must not have disturbed
    // them, and the pending notice in particular must still be rendered.
    for (const call of [
      'timezoneUnsetNotice(language)',
      'languageNotInCalculationNotice(language)',
      'timezoneChangeNotice(language)',
    ]) {
      expect(dlg, call).toContain(call);
    }
    // And they still answer in Japanese by default, unchanged.
    expect(timezoneUnsetNotice()).toMatch(JAPANESE);
    expect(languageNotInCalculationNotice()).toContain('空き時間の計算には影響しません');
    expect(timezoneChangeNotice()).toHaveLength(3);
  });

  it('no language reaches what gets stored', () => {
    // `nextTz` is derived from the form field alone, and the language written
    // is the form's own select value -- never the displayed language.
    expect(dlg).toMatch(/const nextTz = tz\.trim\(\) === '' \? null : tz\.trim\(\)/);
    expect(dlg).not.toMatch(/timezone: language|language: language\b/);
  });

  it('the switch is ON, so a saved preference now decides this dialog', () => {
    expect(LANGUAGE_SWITCH_ENABLED).toBe(true);
    expect(caughtErrorText(new InvalidTimezoneError(), 'en')).not.toMatch(JAPANESE);
  });

  it('no dictionary key was added for this step', () => {
    // `settings.saved` already existed; only who holds it changed.
    const keys = [...code(DLG).matchAll(/tr\('([\w.]+)'/g)].flatMap((m) => (m[1] ? [m[1]] : []));
    expect(keys.length).toBeGreaterThan(0);
    for (const k of keys) {
      expect(k, k).toMatch(/^(settings|common)\./);
    }
    expect(source('i18n/ja.ts')).toContain("'settings.saved'");
  });
});
