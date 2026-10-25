/**
 * P6 step 3: the four settings notices follow the display language.
 *
 * These four sentences are the only place the app explains what a TIME ZONE
 * change does, and a zone change is the one owner action that retroactively
 * reinterprets data already stored -- every all-day event is re-read against
 * the new zone, which can change what a live anonymous share link discloses.
 * An owner reading that warning in a language they do not read is being asked
 * to confirm something they were not told.
 *
 * TWO KINDS OF CLAIM LIVE HERE, as in step 2:
 *
 *   The Japanese is byte-identical, so today nothing moved.
 *
 *   The MEANINGS survive translation. For the zone notices the meaning is a
 *   three-part warning in a fixed order, and the third part -- timed events do
 *   NOT move -- is the one a fluent rewrite is most likely to soften, because
 *   it reads like a reassurance rather than a fact.
 *
 * AND ONE NEGATIVE CLAIM, which is the reason the step is safe: the display
 * language is not an input to anything the zone decides. The confirmation
 * trigger, the stored value and the all-day interpretation are all asserted
 * below to be language-free.
 */

import { describe, expect, it } from 'vitest';
import {
  LANGUAGES,
  browserTimezone,
  languageNotInCalculationNotice,
  timezoneChangeNeedsWarning,
  timezoneChangeNotice,
  timezoneOptions,
  timezoneUnsetNotice,
} from '../features/settings/timezoneSetting';
import { LANGUAGE_SWITCH_ENABLED, LANGUAGES as LANGUAGE_CODES } from './types';

const MODULES = import.meta.glob('/src/**/*.{ts,tsx}', {
  query: '?raw',
  import: 'default',
  eager: true,
}) as Record<string, string>;

const source = (p: string) => MODULES[`/src/${p}`] ?? '';

/** Source with comments stripped, so prose explaining a rule cannot satisfy it. */
const code = (p: string) =>
  source(p)
    .replace(/\/\*[\s\S]*?\*\//g, '')
    .replace(/(^|[^:])\/\/.*$/gm, '$1');

const JAPANESE = /[ぁ-んァ-ヶ一-龯]/;

// ---------------------------------------------------------------------------

describe('the Japanese is exactly what the dialog has always shown', () => {
  it('the three zone-change lines, in order, called with no argument', () => {
    expect(timezoneChangeNotice()).toEqual([
      '終日の予定は、このタイムゾーンの暦日として解釈されます。',
      '匿名共有ページに表示される空き時間が変わることがあります。',
      '時刻を指定した予定（開始・終了時刻のある予定）は変わりません。',
    ]);
  });

  it('the unset notice', () => {
    expect(timezoneUnsetNotice()).toBe(
      'タイムゾーンが未設定のため、終日の予定と時刻指定の空き時間が同じ期間に含まれる場合、匿名共有ページでは空き時間を表示できません（安全のため非表示になります）。',
    );
  });

  it('the language notice', () => {
    // The pending notice that used to sit beside this one was removed at the
    // end of P6, when its claim became false.
    expect(languageNotInCalculationNotice()).toBe(
      '言語設定は、共有される空き時間の計算には影響しません。',
    );
  });

  it("passing 'ja' explicitly is the same as passing nothing", () => {
    // The default is not a separate code path.
    expect(timezoneChangeNotice('ja')).toEqual(timezoneChangeNotice());
    expect(timezoneUnsetNotice('ja')).toBe(timezoneUnsetNotice());
    expect(languageNotInCalculationNotice('ja')).toBe(languageNotInCalculationNotice());
  });

  it('an unrecognised language falls back to Japanese rather than blanking', () => {
    const bogus = 'de' as unknown as 'ja';
    expect(timezoneUnsetNotice(bogus)).toBe(timezoneUnsetNotice('ja'));
    expect(timezoneChangeNotice(bogus)).toEqual(timezoneChangeNotice('ja'));
  });
});

describe('all four notices render in English', () => {
  it('no notice leaks a Japanese character', () => {
    const texts: [string, string][] = [
      ['changeAllDay', timezoneChangeNotice('en')[0]],
      ['changeShare', timezoneChangeNotice('en')[1]],
      ['changeTimedUnaffected', timezoneChangeNotice('en')[2]],
      ['unsetNotice', timezoneUnsetNotice('en')],
      ['languageNotInCalculation', languageNotInCalculationNotice('en')],
    ];
    for (const [name, text] of texts) {
      expect(text, name).not.toMatch(JAPANESE);
      expect(text, name).not.toBe('');
      expect(text, name).not.toMatch(/\{\w+\}/);
    }
  });

  it('every notice differs between the two languages', () => {
    // A key that silently fell back would pass a non-empty check and nothing
    // else. None of these sentences contains a proper noun, so identical
    // output in both languages means a lookup did not happen.
    expect(timezoneUnsetNotice('en')).not.toBe(timezoneUnsetNotice('ja'));
    expect(languageNotInCalculationNotice('en')).not.toBe(languageNotInCalculationNotice('ja'));
    for (const i of [0, 1, 2] as const) {
      expect(timezoneChangeNotice('en')[i], String(i)).not.toBe(timezoneChangeNotice('ja')[i]);
    }
  });
});

/**
 * The zone-change warning. Its job is to be read BEFORE a confirmation that
 * cannot be undone by re-saving (the data is reinterpreted, not moved), so the
 * three parts and their order are the contract.
 */
describe('the zone-change warning keeps its three parts and their order', () => {
  it('exactly three lines, in both languages', () => {
    for (const lang of LANGUAGE_CODES) {
      expect(timezoneChangeNotice(lang), lang).toHaveLength(3);
    }
  });

  it('the order is all-day, then share, then the timed exemption', () => {
    // Asserted per language because the order is carried by the call, not by
    // the dictionary: a reordering here would be invisible to key parity.
    const ja = timezoneChangeNotice('ja');
    expect(ja[0]).toContain('終日');
    expect(ja[1]).toContain('匿名共有');
    expect(ja[2]).toContain('変わりません');

    const en = timezoneChangeNotice('en');
    expect(en[0]).toMatch(/all-day/i);
    expect(en[1]).toMatch(/share page/i);
    expect(en[2]).toMatch(/unaffected/i);
  });

  it('the third line still says timed events do NOT move', () => {
    // THE LINE MOST AT RISK FROM A FLUENT REWRITE. `start_at` is an absolute
    // instant, so a 09:00 meeting stays at that instant whatever the zone. An
    // owner who believes otherwise will not change their zone at all.
    const en = timezoneChangeNotice('en')[2];
    expect(en).toMatch(/unaffected/i);
    expect(en).not.toMatch(/\b(will|may) (change|move|shift)\b/i);
    expect(timezoneChangeNotice('ja')[2]).toContain('変わりません');
  });

  it('the first line says all-day events are REINTERPRETED, not moved', () => {
    // The distinction the whole notice turns on: all-day events are stored as
    // calendar days and re-read, timed ones are instants and are not.
    expect(timezoneChangeNotice('ja')[0]).toContain('暦日');
    expect(timezoneChangeNotice('en')[0]).toMatch(/calendar days/i);
  });

  it('the second line warns that the ANONYMOUS page may change', () => {
    // The consequence an owner cannot see from their own calendar.
    expect(timezoneChangeNotice('ja')[1]).toContain('匿名共有ページ');
    expect(timezoneChangeNotice('en')[1]).toMatch(/anonymous share page/i);
    // "may change", never a promise either way.
    expect(timezoneChangeNotice('en')[1]).toMatch(/\bmay\b/i);
  });

  it('a fresh call returns a fresh triple, so nothing can mutate the warning', () => {
    const a = timezoneChangeNotice('ja');
    const b = timezoneChangeNotice('ja');
    expect(a).toEqual(b);
    expect(a).not.toBe(b);
  });
});

describe('the unset notice still names the exact shape that triggers it', () => {
  it('says what is hidden and that hiding is the SAFE outcome', () => {
    // "Sometimes it does not work" is what sent this project on a long hunt
    // once already. Both languages have to name the combination.
    const ja = timezoneUnsetNotice('ja');
    expect(ja).toContain('タイムゾーンが未設定のため');
    expect(ja).toContain('終日の予定と時刻指定の空き時間');
    expect(ja).toContain('空き時間を表示できません');
    expect(ja).toContain('安全のため非表示');

    const en = timezoneUnsetNotice('en');
    expect(en).toMatch(/no time zone is set/i);
    expect(en).toMatch(/all-day/i);
    expect(en).toMatch(/timed open time/i);
    expect(en).toMatch(/cannot show open time/i);
    expect(en).toMatch(/safe/i);
  });

  it('does not read as a bug report, in either language', () => {
    for (const lang of LANGUAGE_CODES) {
      const s = timezoneUnsetNotice(lang);
      expect(s, lang).not.toMatch(/error|エラー|失敗|bug|不具合/i);
    }
  });
});

describe('the language notices say what is true today', () => {
  it('the switch is ON, and nothing claims otherwise any more', () => {
    // The inverse of what this block asserted for four phases. The pending
    // notice was true while the switch was off; it is false now, so it is
    // gone, and the guard is that nothing says it again.
    expect(LANGUAGE_SWITCH_ENABLED).toBe(true);
    const mod = code('features/settings/timezoneSetting.ts');
    expect(mod).not.toMatch(/languagePendingNotice/);
    expect(mod).not.toContain('settings.language.pending');
    const dlg = code('features/settings/SettingsDialog.tsx');
    expect(dlg).not.toMatch(/languagePendingNotice/);
  });

  it('no remaining notice claims the language does not apply', () => {
    // A sentence saying the choice is not in effect would now be false in
    // either language.
    for (const lang of LANGUAGE_CODES) {
      const n = languageNotInCalculationNotice(lang);
      expect(n, lang).not.toMatch(/まだ有効になっていません|not in effect/i);
    }
  });

  it('the remaining notice does not revive the claim that only wording changes', () => {
    // The original false sentence: the language setting does more than change
    // wording (it is stored) and this notice is about neither -- it is about
    // the Free/Busy calculation.
    for (const lang of LANGUAGE_CODES) {
      expect(languageNotInCalculationNotice(lang), lang).not.toContain('文言だけが変わります');
    }
  });

  it('the calculation notice still says the language is not an input', () => {
    expect(languageNotInCalculationNotice('ja')).toContain('空き時間の計算には影響しません');
    const en = languageNotInCalculationNotice('en');
    expect(en).toMatch(/does not affect/i);
    expect(en).toMatch(/calculat/i);
  });

  it('the one remaining language notice is non-empty in both languages', () => {
    // There were two; the pending one is gone. What is left must still render.
    for (const lang of LANGUAGE_CODES) {
      expect(languageNotInCalculationNotice(lang), lang).not.toBe('');
      expect(languageNotInCalculationNotice(lang), lang).not.toMatch(/\{\w+\}/);
    }
    expect(languageNotInCalculationNotice('en')).not.toBe(
      languageNotInCalculationNotice('ja'),
    );
  });

  it('the calculation claim is backed by the code, not just asserted', () => {
    // The notice promises that the display language never reaches the
    // Free/Busy computation. P6 step 2 is what makes that checkable: the RPC
    // takes no language argument and the repository names no i18n symbol.
    const repo = code('repositories/shareRepository.ts');
    expect(repo).not.toMatch(/i18n|Language|resolveLanguage|intlLocale/);
    expect(repo).not.toMatch(/p_lang|p_locale|p_language/);
  });
});

/**
 * The negative claims. A display-language change must not reach anything the
 * zone decides, and the strongest form of that is structural: the functions
 * that decide take no language at all.
 */
describe('the display language is not an input to any zone decision', () => {
  it('the confirmation trigger takes no language', () => {
    expect(timezoneChangeNeedsWarning.length).toBe(2);
  });

  it('every confirmation case is unchanged and language-free', () => {
    // The full truth table, which this step must not have touched.
    expect(timezoneChangeNeedsWarning(null, 'Asia/Tokyo')).toBe(true); // first set
    expect(timezoneChangeNeedsWarning('Asia/Tokyo', 'Europe/Paris')).toBe(true); // moved
    expect(timezoneChangeNeedsWarning('Asia/Tokyo', 'Asia/Tokyo')).toBe(false); // no change
    expect(timezoneChangeNeedsWarning('Asia/Tokyo', null)).toBe(true); // cleared
    expect(timezoneChangeNeedsWarning(null, null)).toBe(false); // still unset
  });

  it('the zone list and the browser default take no language either', () => {
    expect(timezoneOptions.length).toBe(0);
    expect(browserTimezone.length).toBe(0);
    // Zone identifiers are IANA names, never localised: they are the value
    // that gets stored.
    const opts = timezoneOptions();
    expect(opts.length).toBeGreaterThan(0);
    for (const z of opts.slice(0, 40)) {
      expect(z, z).not.toMatch(JAPANESE);
    }
  });

  it('the module reads no zone catalog and no clock', () => {
    // Unchanged from before: the database owns zone validity (0008/0025), and
    // this module neither validates nor converts. A language change could not
    // affect a computation that is not here.
    const mod = code('features/settings/timezoneSetting.ts');
    expect(mod).not.toMatch(/new Date|Date\.now|toISOString|getTimezoneOffset/);
    expect(mod).not.toMatch(/pg_timezone|timezone_is_supported/);
  });

  it("the zone-validity probe still pins 'en-US'", () => {
    // utils/timezone.ts asks whether a zone NAME is usable. That call is not a
    // display concern, and localising it would change what it tests.
    expect(source('utils/timezone.ts')).toMatch(/Intl\.DateTimeFormat\('en-US'/);
    expect(code('utils/timezone.ts')).not.toMatch(/i18n|resolveLanguage|intlLocale/);
  });

  it('no stored value is touched by this step', () => {
    // The two writes this dialog makes are the zone and the language, and both
    // still carry the FORM's values. A notice cannot reach them.
    const dlg = code('features/settings/SettingsDialog.tsx');
    expect(dlg).toMatch(/timezone: nextTz/);
    expect(dlg).toMatch(/language: lang === '' \? null : lang/);
    // The notices are rendered, never written.
    expect(dlg).not.toMatch(/(timezone|language): (timezoneUnsetNotice|languageNotInCalculationNotice)/);
  });

  it('setStoredLanguage still runs after the save returns, with the SERVER value', () => {
    // Timing matters: pushing the form's value before the round trip would
    // show a language the server may have rejected. Unchanged by this step.
    const dlg = code('features/settings/SettingsDialog.tsx');
    // Anchored FROM the function: the load effect above it has a catch of
    // its own, so searching the whole file for one finds the wrong block.
    const start = dlg.indexOf('const persist');
    const persist = dlg.slice(start, dlg.indexOf('} catch (e)', start));
    expect(start).toBeGreaterThan(0);
    expect(persist.length).toBeGreaterThan(0);
    expect(persist).toMatch(/const s = await saveOwnerSettings/);
    expect(persist.indexOf('setStoredLanguage(s.language)')).toBeGreaterThan(
      persist.indexOf('await saveOwnerSettings'),
    );
    expect(persist).not.toMatch(/setStoredLanguage\(lang\)/);
  });

  it('owner_settings is still read by exactly the provider and this dialog', () => {
    const callers = Object.keys(MODULES)
      .filter((p) => !p.includes('.test.'))
      .filter((p) => /getOwnerSettings\s*\(/.test(code(p.replace(/^\/src\//, ''))))
      .map((p) => p.replace(/^\/src\//, ''))
      .sort();
    expect(callers).toEqual([
      'features/settings/SettingsDialog.tsx',
      'i18n/LanguageProvider.tsx',
      'repositories/ownerSettingsRepository.ts',
    ]);
  });
});

describe('the module stays pure and the dialog does the reading', () => {
  it('no hook crossed into the module', () => {
    const mod = code('features/settings/timezoneSetting.ts');
    expect(mod).not.toMatch(/useTranslate|useLanguage|from 'react'/);
    expect(mod).not.toMatch(/^(export )?const [A-Z_]+ = t\(/m);
  });

  it('the dialog resolves the DISPLAYED language and passes it to all four', () => {
    const dlg = code('features/settings/SettingsDialog.tsx');
    expect(dlg).toContain('const { language, setStoredLanguage } = useLanguage()');
    for (const call of [
      'timezoneUnsetNotice(language)',
      'languageNotInCalculationNotice(language)',
      'timezoneChangeNotice(language)',
    ]) {
      expect(dlg, call).toContain(call);
    }
  });

  it("the displayed language is not confused with the form's pending value", () => {
    // `language` is what the screen is written in; `lang` is the value this
    // control is about to store. They are different things that happen to hold
    // the same kind of value, and the notices must use the former -- otherwise
    // selecting English would translate the dialog before anything was saved.
    const dlg = code('features/settings/SettingsDialog.tsx');
    for (const wrong of [
      'timezoneUnsetNotice(lang)',
      'languageNotInCalculationNotice(lang)',
      'timezoneChangeNotice(lang)',
    ]) {
      expect(dlg, wrong).not.toContain(wrong);
    }
  });

  it('the notices are called at render, so a language change updates them', () => {
    // Inline in JSX, not hoisted into a useMemo keyed on something else. A
    // re-render is all it takes.
    const dlg = source('features/settings/SettingsDialog.tsx');
    expect(dlg).toMatch(/\{timezoneUnsetNotice\(language\)\}/);
    expect(dlg).toMatch(/\{languageNotInCalculationNotice\(language\)\}/);
    expect(dlg).toMatch(/timezoneChangeNotice\(language\)\.map/);
    expect(dlg).not.toMatch(/useMemo\([^)]*(Notice|notice)/);
  });

  it('the language picker still names each language in its own language', () => {
    // Deliberately NOT translated: a picker that renamed 日本語 to "Japanese"
    // for an English reader would be unreadable to the person looking for it.
    expect(LANGUAGES).toEqual([
      { value: 'ja', label: '日本語' },
      { value: 'en', label: 'English' },
    ]);
  });

  it('no dictionary key was added for this step', () => {
    // The six sentences already existed and were audited in P5. This step
    // changed only WHEN they are resolved.
    const keys = [
      ...code('features/settings/timezoneSetting.ts').matchAll(/t\('([\w.]+)'/g),
    ].flatMap((m) => (m[1] ? [m[1]] : []));
    expect(keys).toEqual([
      'settings.timezone.changeAllDay',
      'settings.timezone.changeShare',
      'settings.timezone.changeTimedUnaffected',
      'settings.timezone.unsetNotice',
      'settings.language.notInCalculation',
    ]);
  });
});
