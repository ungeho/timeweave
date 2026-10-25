import { describe, expect, it } from 'vitest';
import { ja } from './ja';
import { en } from './en';
import {
  LANGUAGES,
  languageNotInCalculationNotice,
  timezoneChangeNeedsWarning,
  timezoneChangeNotice,
  timezoneUnsetNotice,
} from '../features/settings/timezoneSetting';

// P6 step 3 turned the four notices into functions of the display language.
// These guards are about the JAPANESE, so they call with NO ARGUMENT -- which
// is also the assertion that the default still answers exactly as the module
// constants did. The English side lives in i18n/settingsNotices.i18n.test.ts.
const TIMEZONE_CHANGE_NOTICE = timezoneChangeNotice();
const TIMEZONE_UNSET_NOTICE = timezoneUnsetNotice();
const LANGUAGE_NOT_IN_CALCULATION_NOTICE = languageNotInCalculationNotice();

/**
 * P3-b step 3 moved the wording of the SETTINGS DIALOG and the CALENDAR
 * TOOLBAR into the dictionary.
 *
 * As in every earlier step the claim is that NOTHING THE USER SEES CHANGED, so
 * the Japanese below is written out literally rather than read back from `ja`.
 *
 * Neither component can be rendered here -- vitest runs `environment: 'node'`
 * and jsdom is deliberately not added -- so what is checked is the dictionary
 * they now read, the notices they still render from timezoneSetting.ts, the
 * option lists' coverage of their unions, and the source structure of the
 * save/load path.
 */

const JP = /[ぁ-んァ-ヶ一-龯]/;

const MODULES = import.meta.glob('/src/**/*.{ts,tsx}', {
  query: '?raw',
  import: 'default',
  eager: true,
}) as Record<string, string>;

const source = (path: string) => (MODULES['/src/' + path] ?? '') as string;

describe('the settings dialog renders the same Japanese as before', () => {
  it('the title, the loading line and the buttons', () => {
    expect(ja['settings.title']).toBe('設定');
    expect(ja['common.loading']).toBe('読み込み中…');
    expect(ja['common.saving']).toBe('保存中…');
    expect(ja['common.save']).toBe('保存');
    expect(ja['common.cancel']).toBe('キャンセル');
    expect(ja['common.close']).toBe('閉じる');
  });

  it('the time zone field and its hint', () => {
    expect(ja['settings.timezone.label']).toBe('タイムゾーン');
    expect(ja['settings.timezone.hint']).toBe(
      '終日の予定をどの暦日として扱うかを決めます。空欄にすると未設定に戻ります。',
    );
  });

  it('the language field and its empty option', () => {
    expect(ja['settings.language.label']).toBe('表示言語');
    expect(ja['settings.language.followBrowser']).toBe('ブラウザの設定に従う');
  });

  it('the confirmation step', () => {
    expect(ja['settings.timezone.confirmTitle']).toBe('タイムゾーンを変更します。');
    expect(ja['settings.timezone.confirmApply']).toBe('変更する');
  });

  it('the save notice', () => {
    expect(ja['settings.saved']).toBe('設定を保存しました。');
  });
});

describe('the calendar toolbar renders the same Japanese as before', () => {
  it('the navigation controls, including the two accessible names', () => {
    expect(ja['calendar.today']).toBe('今日');
    expect(ja['calendar.prev']).toBe('前へ');
    expect(ja['calendar.next']).toBe('次へ');
  });

  it('the three view buttons', () => {
    expect(ja['calendar.view.month']).toBe('月');
    expect(ja['calendar.view.week']).toBe('週');
    expect(ja['calendar.view.day']).toBe('日');
  });
});

describe('the English settings and toolbar copy is complete and clean', () => {
  it('every settings and calendar key has a non-empty English value', () => {
    const keys = (Object.keys(ja) as (keyof typeof ja)[]).filter(
      (k) =>
        String(k).startsWith('settings.') ||
        String(k).startsWith('calendar.') ||
        String(k).startsWith('common.'),
    );
    expect(keys.length).toBeGreaterThan(25);
    for (const k of keys) {
      expect(en[k].trim(), String(k)).not.toBe('');
      expect(en[k], String(k)).not.toMatch(JP);
    }
  });

  it('no English string in this scope leaks an uninterpolated placeholder', () => {
    const keys = (Object.keys(ja) as (keyof typeof ja)[]).filter(
      (k) =>
        String(k).startsWith('settings.') ||
        String(k).startsWith('calendar.') ||
        String(k).startsWith('common.'),
    );
    for (const k of keys) {
      if (/\{\w+\}/.test(ja[k])) continue; // intentionally interpolated
      expect(en[k], String(k)).not.toMatch(/\{\w+\}/);
    }
  });

  it('the three view labels are distinct, and so are the nav controls', () => {
    for (const d of [ja, en]) {
      const views = [d['calendar.view.month'], d['calendar.view.week'], d['calendar.view.day']];
      expect(new Set(views).size).toBe(3);
      const nav = [d['calendar.today'], d['calendar.prev'], d['calendar.next']];
      expect(new Set(nav).size).toBe(3);
    }
  });

  it('the confirm action is distinct from Cancel and from Save', () => {
    // Three buttons can be on screen at once in the confirming state. Two of
    // them reading the same word is how an owner confirms a zone change they
    // meant to abandon.
    for (const d of [ja, en]) {
      const three = [d['settings.timezone.confirmApply'], d['common.cancel'], d['common.save']];
      expect(new Set(three).size).toBe(3);
    }
  });
});

/**
 * THE NOTICES ARE STILL PINNED TO JAPANESE, ON PURPOSE.
 *
 * timezoneSetting.ts holds them as module constants resolved with
 * DEFAULT_LANGUAGE -- the same shape freeBusyPresentation.ts uses for the
 * share page's messages, and the same reason: they are pure-module exports
 * that components render as-is, so they cannot read a React context.
 *
 * Converting them is not part of this step. What IS part of this step is that
 * their MEANING is intact, because the dialog's whole job is to tell the owner
 * what a zone change will do before they confirm it.
 */
describe('the time zone notices still say exactly what a change does', () => {
  it('all three lines are present, in order', () => {
    expect(TIMEZONE_CHANGE_NOTICE).toHaveLength(3);
    expect(TIMEZONE_CHANGE_NOTICE[0]).toBe(
      '終日の予定は、このタイムゾーンの暦日として解釈されます。',
    );
    expect(TIMEZONE_CHANGE_NOTICE[1]).toBe(
      '匿名共有ページに表示される空き時間が変わることがあります。',
    );
    expect(TIMEZONE_CHANGE_NOTICE[2]).toBe(
      '時刻を指定した予定（開始・終了時刻のある予定）は変わりません。',
    );
  });

  it('it names the all-day reinterpretation, the share effect and the timed exemption', () => {
    const all = TIMEZONE_CHANGE_NOTICE.join('');
    expect(all).toContain('終日の予定');
    expect(all).toContain('匿名共有ページ');
    expect(all).toContain('変わりません');
  });

  it('the English of all three keeps those same three claims', () => {
    expect(en['settings.timezone.changeAllDay']).toMatch(/all-day/i);
    expect(en['settings.timezone.changeAllDay']).toMatch(/calendar days?/i);
    expect(en['settings.timezone.changeShare']).toMatch(/anonymous share page/i);
    // The one an owner is most likely to get wrong: a zone change does NOT
    // move a 09:00 meeting, because start_at is an absolute instant.
    expect(en['settings.timezone.changeTimedUnaffected']).toMatch(/unaffected/i);
    expect(en['settings.timezone.changeTimedUnaffected']).not.toMatch(/\bmove|shift|change/i);
  });

  it('the unset notice still frames hiding as the SAFE outcome, not a failure', () => {
    expect(TIMEZONE_UNSET_NOTICE).toContain('タイムゾーンが未設定のため');
    expect(TIMEZONE_UNSET_NOTICE).toContain('空き時間を表示できません');
    expect(TIMEZONE_UNSET_NOTICE).toContain('安全のため非表示');
    expect(en['settings.timezone.unsetNotice']).toMatch(/safe/i);
  });

  it('the unset notice still names the exact shape that triggers it', () => {
    // "it sometimes does not work" is what sent this project on a long hunt
    // once already: the combination is an all-day event plus timed open time
    // in the same period.
    expect(TIMEZONE_UNSET_NOTICE).toContain('終日の予定と時刻指定の空き時間');
    const s = en['settings.timezone.unsetNotice'];
    expect(s).toMatch(/all-day/i);
    expect(s).toMatch(/timed open time/i);
  });

  it('warning on a zone change is still decided by timezoneChangeNeedsWarning', () => {
    // Setting one for the first time warns, because that is the moment all-day
    // events start being disclosed. Clearing one warns too. An unchanged value
    // does not.
    expect(timezoneChangeNeedsWarning(null, 'Asia/Tokyo')).toBe(true);
    expect(timezoneChangeNeedsWarning('Asia/Tokyo', null)).toBe(true);
    expect(timezoneChangeNeedsWarning('Asia/Tokyo', 'Asia/Tokyo')).toBe(false);
    expect(timezoneChangeNeedsWarning(null, null)).toBe(false);
    const src = source('features/settings/SettingsDialog.tsx');
    expect(src).toMatch(/timezoneChangeNeedsWarning\(saved\.timezone, nextTz\)/);
    expect(src).toMatch(/if \(needsWarning && !confirming\)/);
  });
});

/**
 * THE PENDING NOTICE IS GONE, and this is the guard that keeps it gone.
 *
 * For four phases the dialog said the language control stored a value but did
 * not change the screen. That was true, and saying anything else would have
 * taught the owner that saving was broken. It is now false: the switch is on,
 * a saved preference is applied, and a notice claiming otherwise would be the
 * mirror of the same failure -- an owner told their choice has not taken
 * effect while the page around the notice is already in their language.
 *
 * So these tests assert the ABSENCE, and that the one statement which is still
 * true survived the removal.
 */
describe('the language control no longer claims switching is inactive', () => {
  it('the pending notice is not rendered, and its key is gone', () => {
    const src = source('features/settings/SettingsDialog.tsx');
    expect(src).not.toContain('languagePendingNotice');
    expect(ja).not.toHaveProperty('settings.language.pending');
    expect(en).not.toHaveProperty('settings.language.pending');
  });

  it('the one statement that is still true is still rendered', () => {
    const src = source('features/settings/SettingsDialog.tsx');
    expect(src).toContain('languageNotInCalculationNotice(language)');
  });

  it('the Free/Busy independence is still its own separate statement', () => {
    expect(LANGUAGE_NOT_IN_CALCULATION_NOTICE).toContain('空き時間の計算には影響しません');
    expect(en['settings.language.notInCalculation']).toMatch(/does not affect/i);
    expect(en['settings.language.notInCalculation']).toMatch(/calculat/i);
  });

  it('the language options keep their autonyms, untranslated in both directions', () => {
    // 日本語 and English name THEMSELVES. A viewer reading an English UI who
    // wants Japanese looks for 日本語, not for "Japanese" -- so these are the
    // one place in the app where the label must NOT follow the display
    // language, and they stay out of the dictionary for that reason.
    expect(LANGUAGES.map((l) => l.value)).toEqual(['ja', 'en']);
    expect(LANGUAGES.map((l) => l.label)).toEqual(['日本語', 'English']);
    const languageKeys = (Object.keys(ja) as string[]).filter((k) =>
      /^settings\.language\.(ja|en|japanese|english)$/i.test(k),
    );
    expect(languageKeys).toEqual([]);
  });

  it('the options still say nothing about time zones', () => {
    for (const l of LANGUAGES) expect(l.label).not.toMatch(/UTC|GMT|\//);
  });
});

/**
 * The save and load path. This step changed wording only, and these are the
 * properties the wording sits on top of.
 */
describe('the settings save and load flow is unchanged', () => {
  it('the empty option still means NULL, which is what falls back to the browser', () => {
    // The select's value stays '' in the form and is converted on save. A
    // stored null is what resolveLanguage then reads as "ask the browser".
    const src = source('features/settings/SettingsDialog.tsx');
    expect(src).toMatch(/<option value="">/);
    expect(src).toMatch(/language: lang === '' \? null : lang/);
    expect(src).toMatch(/setLang\(s\.language \?\? ''\)/);
  });

  it('an empty time zone field still stores null rather than an empty string', () => {
    const src = source('features/settings/SettingsDialog.tsx');
    expect(src).toMatch(/const nextTz = tz\.trim\(\) === '' \? null : tz\.trim\(\)/);
  });

  it('nothing is written optimistically: the form takes the SERVER value back', () => {
    const src = source('features/settings/SettingsDialog.tsx');
    expect(src).toMatch(/const s = await saveOwnerSettings\(/);
    expect(src).toMatch(/setSaved\(s\)/);
    expect(src).toMatch(/setTz\(s\.timezone \?\? ''\)/);
  });

  it('the saved language is still pushed into the provider from the server value', () => {
    // setStoredLanguage(s.language), not setStoredLanguage(lang): the save
    // already reported what was stored, so the form's value is the wrong
    // source and a re-fetch would be a second round trip for the same answer.
    const src = source('features/settings/SettingsDialog.tsx');
    expect(src).toMatch(/setStoredLanguage\(s\.language\)/);
    expect(src).not.toMatch(/setStoredLanguage\(lang\)/);
  });

  it('the double-save guard is still a ref, not just the disabled attribute', () => {
    const src = source('features/settings/SettingsDialog.tsx');
    expect(src).toMatch(/if \(savingRef\.current\) return/);
  });

  it('saving, success and failure are still three separate states', () => {
    // `saving` swaps the button label, `notice` reports success with
    // role="status", `error` reports failure. Collapsing any two would leave
    // a failed save looking like a successful one.
    const src = source('features/settings/SettingsDialog.tsx');
    expect(src).toMatch(/saving \? tr\('common\.saving'\) : tr\('common\.save'\)/);
    expect(src).toMatch(/saving \? tr\('common\.saving'\) : tr\('settings\.timezone\.confirmApply'\)/);
    expect(src).toMatch(/role="status"/);
    // P6 step 7 stopped storing the sentence: the error line reads its cause
    // through caughtErrorText at render. The three states are still three.
    expect(src).toContain('className="form-error">{caughtErrorText(error.cause, language)}');
    expect(src).toContain('role="status">{tr(notice)}');
  });

  it('the dialog is still the only non-provider caller of getOwnerSettings', () => {
    const src = source('features/settings/SettingsDialog.tsx');
    expect(src).toMatch(/await getOwnerSettings\(\)/);
  });
});

describe('the calendar toolbar still does the same things', () => {
  it('today, prev and next are still wired to the view', () => {
    const src = source('features/calendar/CalendarToolbar.tsx');
    expect(src).toMatch(/onClick=\{view\.today\}/);
    expect(src).toMatch(/onClick=\{view\.prev\}/);
    expect(src).toMatch(/onClick=\{view\.next\}/);
  });

  it('the view buttons still offer exactly month, week and day, in order', () => {
    const src = source('features/calendar/CalendarToolbar.tsx');
    const modes = [...src.matchAll(/\{ value: '(\w+)', key: 'calendar\.view\./g)].map((m) => m[1]);
    expect(modes).toEqual(['month', 'week', 'day']);
    expect(src).toMatch(/onClick=\{\(\) => view\.setMode\(m\.value\)\}/);
    expect(src).toMatch(/view\.mode === m\.value \? 'active' : ''/);
  });

  it('the list carries a compile-time coverage assertion', () => {
    expect(source('features/calendar/CalendarToolbar.tsx')).toMatch(/_modeParity/);
  });

  it('the two glyph buttons get their name from an aria-label that is translated', () => {
    // ‹ and › announce nothing on their own. These labels ARE the buttons'
    // accessible names, which is why they had to move with the visible copy
    // rather than be left behind as literals.
    const src = source('features/calendar/CalendarToolbar.tsx');
    expect(src).toMatch(/aria-label=\{tr\('calendar\.prev'\)\}/);
    expect(src).toMatch(/aria-label=\{tr\('calendar\.next'\)\}/);
    expect(src).not.toMatch(/aria-label="/);
  });

  it('no button in either component is left with a hardcoded title attribute', () => {
    for (const p of [
      'features/calendar/CalendarToolbar.tsx',
      'features/settings/SettingsDialog.tsx',
    ]) {
      expect(source(p), p).not.toMatch(/title="/);
    }
  });

  it('the period title still comes from the date formatters, now with a locale', () => {
    // monthTitle / weekTitle / dayTitle are date FORMATS, not copy, and they
    // stayed that way: this step left them alone and P4 step 2 gave all three
    // the SAME locale, so switching view cannot switch date convention.
    const src = source('features/calendar/CalendarToolbar.tsx');
    expect(src).toMatch(/monthTitle\(view\.anchor, locale\)/);
    expect(src).toMatch(/weekTitle\(view\.anchor, timeZone, locale\)/);
    expect(src).toMatch(/dayTitle\(view\.anchor, timeZone, locale\)/);
    expect(src).toMatch(/const locale = intlLocale\(language\)/);
    // The titles are still not built out of dictionary keys.
    expect(src).not.toMatch(/tr\('calendar\.(today|prev|next)'\).*monthTitle/);
  });
});

describe('what this step deliberately did not do', () => {
  it('no weekday or month-name keys were added', () => {
    const dateKeys = (Object.keys(ja) as string[]).filter(
      (k) => k.startsWith('weekday.') || k.startsWith('month.') || k.startsWith('date.'),
    );
    expect(dateKeys).toEqual([]);
  });

  it('the view labels are the VIEWS, not the weekdays they share a character with', () => {
    // 月 is both "month" and "Monday". The English proves which one this is.
    expect(en['calendar.view.month']).toBe('Month');
    expect(en['calendar.view.week']).toBe('Week');
    expect(en['calendar.view.day']).toBe('Day');
  });

  it('the notices are still module constants pinned to the default language', () => {
    // The step-1 precedent, kept: a pure module cannot read a React context,
    // so these resolve with DEFAULT_LANGUAGE and the dialog renders them as-is.
    const mod = source('features/settings/timezoneSetting.ts');
    expect(mod).toMatch(/DEFAULT_LANGUAGE/);
    expect(mod).not.toMatch(/useTranslate|useLanguage|resolvedLanguage/);
  });

  it('both components read the language but still render the default', () => {
    // LANGUAGE_SWITCH_ENABLED pins what the provider hands out until P6, so a
    // migrated component still shows Japanese for everyone. The flag itself is
    // asserted in wiring.test.ts.
    for (const p of [
      'features/settings/SettingsDialog.tsx',
      'features/calendar/CalendarToolbar.tsx',
    ]) {
      expect(source(p)).toMatch(/useTranslate\(\)/);
    }
  });
});
