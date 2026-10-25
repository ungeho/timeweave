import { describe, expect, it } from 'vitest';
import { t } from './t';
import { ja } from './ja';
import { en } from './en';
import {
  AVAILABILITIES,
  availabilityLabel,
  isTitleRequired,
} from '../features/event/availabilityField';
import { VISIBILITIES } from '../features/calendar/visibilityMeta';

/**
 * P3-b step 2 moved the EVENT UI's wording into the dictionary: the create/edit
 * dialog (EventDialog) and the recurrence fieldset inside it (RecurrenceEditor).
 *
 * As in every earlier step the claim is that NOTHING THE USER SEES CHANGED, so
 * the Japanese below is written out literally rather than read back from `ja`.
 * Reading it back would pass against any value, including a wrong one.
 *
 * Neither component can be rendered here -- vitest runs `environment: 'node'`
 * and jsdom is deliberately not added -- so what is checked is the dictionary
 * they now read, the option lists' coverage of their unions, and the source
 * structure. The behaviour of the form itself (validation, seeding, scope,
 * rule building) lives in recurrenceForm.ts, availabilityField.ts,
 * timezoneField.ts and timezoneRules.ts, each with its own suite, and this
 * step touched none of them.
 */

const JP = /[ぁ-んァ-ヶ一-龯]/;

const MODULES = import.meta.glob('/src/**/*.{ts,tsx}', {
  query: '?raw',
  import: 'default',
  eager: true,
}) as Record<string, string>;

const source = (path: string) => (MODULES['/src/' + path] ?? '') as string;

describe('the event dialog renders the same Japanese as before P3-b step 2', () => {
  it('the two titles', () => {
    expect(ja['event.dialog.create']).toBe('予定を追加');
    expect(ja['event.dialog.edit']).toBe('予定を編集');
  });

  it('the edit scope', () => {
    expect(ja['event.scope.label']).toBe('対象');
    expect(ja['event.scope.only']).toBe('この回のみ');
    expect(ja['event.scope.all']).toBe('すべての回');
  });

  it('every field label', () => {
    expect(ja['event.field.title']).toBe('タイトル');
    expect(ja['event.field.allDay']).toBe('終日');
    expect(ja['event.field.startDate']).toBe('開始日');
    expect(ja['event.field.endDate']).toBe('終了日');
    expect(ja['event.field.start']).toBe('開始');
    expect(ja['event.field.end']).toBe('終了');
    expect(ja['event.field.description']).toBe('メモ');
    expect(ja['event.field.category']).toBe('カテゴリ');
    expect(ja['event.field.visibility']).toBe('公開範囲');
    expect(ja['event.field.availability']).toBe('状態');
  });

  it('the three visibility options, enum value included', () => {
    expect(ja['event.visibility.private']).toBe('非公開 (private)');
    expect(ja['event.visibility.busyOnly']).toBe('予定ありのみ (busy_only)');
    expect(ja['event.visibility.public']).toBe('公開 (public)');
  });

  it('the four validation messages', () => {
    // The title message is the key P1 added and nothing used until now; it has
    // to match the literal the dialog carried.
    expect(ja['event.title.required']).toBe('タイトルを入力してください');
    expect(ja['event.error.dateRequired']).toBe('日付を入力してください');
    expect(ja['event.error.endDateBeforeStart']).toBe('終了日は開始日以降にしてください');
    expect(ja['event.error.endBeforeStart']).toBe('終了日時は開始日時以降にしてください');
  });

  it('the time zone panel', () => {
    expect(ja['event.tz.label']).toBe('タイムゾーン');
    expect(ja['event.tz.unset']).toBe('未設定');
    expect(ja['event.tz.setCurrentUnknown']).toBe('現在のタイムゾーンを設定');
  });

  it('the two zone refusals, which end without a full stop as they did', () => {
    expect(ja['event.tz.unresolved']).toBe(
      'タイムゾーンを判定できないため、時刻ありの繰り返し予定は保存できません。ブラウザの日付と時刻の設定をご確認ください',
    );
    expect(ja['event.tz.unavailable']).toBe(
      'ブラウザからタイムゾーンを取得できないため、設定できません。ブラウザの日付と時刻の設定をご確認ください',
    );
  });

  it('the buttons come from common.*, unchanged', () => {
    expect(ja['common.delete']).toBe('削除');
    expect(ja['common.cancel']).toBe('キャンセル');
    expect(ja['common.save']).toBe('保存');
  });
});

describe('the recurrence editor renders the same Japanese as before', () => {
  it('the fieldset legend and the frequency control', () => {
    expect(ja['recurrence.legend']).toBe('繰り返し');
    expect(ja['recurrence.freq.label']).toBe('頻度');
    expect(ja['recurrence.freq.none']).toBe('繰り返さない');
    expect(ja['recurrence.freq.daily']).toBe('毎日');
    expect(ja['recurrence.freq.weekly']).toBe('毎週');
    expect(ja['recurrence.freq.monthly']).toBe('毎月');
  });

  it('the interval, weekday and end controls', () => {
    expect(ja['recurrence.interval.label']).toBe('間隔');
    expect(ja['recurrence.weekdays.label']).toBe('曜日');
    expect(ja['recurrence.end.label']).toBe('終了');
    expect(ja['recurrence.end.never']).toBe('終わりなし');
    expect(ja['recurrence.end.count']).toBe('回数');
    expect(ja['recurrence.end.until']).toBe('終了日');
    expect(ja['recurrence.count.label']).toBe('回数');
    expect(ja['recurrence.until.label']).toBe('終了日');
  });

  it('the option and the field it reveals share the Japanese but not the key', () => {
    // Identical in Japanese, which is why one key would have looked harmless.
    // English needs them apart: you pick "after a number of repeats" and are
    // then asked for the "number of repeats".
    expect(ja['recurrence.end.count']).toBe(ja['recurrence.count.label']);
    expect(ja['recurrence.end.until']).toBe(ja['recurrence.until.label']);
    expect(en['recurrence.end.count']).not.toBe(en['recurrence.count.label']);
    expect(en['recurrence.end.until']).not.toBe(en['recurrence.until.label']);
  });

  it('the existing rule-validation messages are untouched', () => {
    // P3 step 2 moved these; step 2 of P3-b must not have disturbed them.
    expect(ja['recurrence.intervalTooSmall']).toBe('繰り返し間隔は 1 以上にしてください');
    expect(ja['recurrence.countTooSmall']).toBe('繰り返し回数は 1 以上にしてください');
    expect(ja['recurrence.untilRequired']).toBe('終了日を入力してください');
  });
});

describe('the interpolated keys', () => {
  it('the adopting hint places the zone', () => {
    expect(t('event.tz.recurrence', 'ja', { timezone: 'Asia/Tokyo' })).toBe(
      '繰り返しのタイムゾーン: Asia/Tokyo',
    );
    expect(t('event.tz.recurrence', 'en', { timezone: 'Asia/Tokyo' })).toBe(
      'Time zone of the repeat: Asia/Tokyo',
    );
  });

  it('the two series buttons place the zone in parentheses, as the templates did', () => {
    expect(t('event.tz.setCurrent', 'ja', { timezone: 'Asia/Tokyo' })).toBe(
      '現在のタイムゾーン (Asia/Tokyo) を設定',
    );
    expect(t('event.tz.changeToCurrent', 'ja', { timezone: 'Asia/Tokyo' })).toBe(
      '現在のタイムゾーン (Asia/Tokyo) に変更',
    );
    expect(t('event.tz.setCurrent', 'en', { timezone: 'Europe/Berlin' })).toBe(
      'Set the current time zone (Europe/Berlin)',
    );
    expect(t('event.tz.changeToCurrent', 'en', { timezone: 'Europe/Berlin' })).toBe(
      'Change to the current time zone (Europe/Berlin)',
    );
  });

  it('an empty zone still renders empty parentheses, not the placeholder', () => {
    // `storableTimeZone` is `string | null`, and the template literal it
    // replaced rendered null as nothing. The call site passes '' so that the
    // output is identical rather than the word "null" or a stray {timezone}.
    expect(t('event.tz.changeToCurrent', 'ja', { timezone: '' })).toBe(
      '現在のタイムゾーン () に変更',
    );
  });

  it('no zone string hard-codes a zone name', () => {
    for (const k of ['event.tz.recurrence', 'event.tz.setCurrent', 'event.tz.changeToCurrent'] as const) {
      expect(ja[k]).toMatch(/\{timezone\}/);
      expect(en[k]).toMatch(/\{timezone\}/);
      expect(en[k]).not.toMatch(/UTC|GMT|Asia|Europe|America/);
    }
  });
});

describe('the English event UI is complete and clean', () => {
  it('every event and recurrence key has a non-empty English value', () => {
    const keys = (Object.keys(ja) as (keyof typeof ja)[]).filter(
      (k) => String(k).startsWith('event.') || String(k).startsWith('recurrence.'),
    );
    expect(keys.length).toBeGreaterThan(40);
    for (const k of keys) {
      expect(en[k].trim(), String(k)).not.toBe('');
      expect(en[k], String(k)).not.toMatch(JP);
    }
  });

  it('no English event string leaks an uninterpolated placeholder', () => {
    const keys = (Object.keys(ja) as (keyof typeof ja)[]).filter(
      (k) => String(k).startsWith('event.') || String(k).startsWith('recurrence.'),
    );
    for (const k of keys) {
      if (/\{\w+\}/.test(ja[k])) continue; // intentionally interpolated
      expect(en[k], String(k)).not.toMatch(/\{\w+\}/);
    }
  });

  it('every field label is distinct, so two controls cannot collapse into one', () => {
    const labels = [
      'event.field.title',
      'event.field.allDay',
      'event.field.startDate',
      'event.field.endDate',
      'event.field.start',
      'event.field.end',
      'event.field.description',
      'event.field.category',
      'event.field.visibility',
      'event.field.availability',
    ] as const;
    for (const d of [ja, en]) {
      expect(new Set(labels.map((k) => d[k])).size).toBe(labels.length);
    }
  });
});

/**
 * VISIBILITY IS THE DISCLOSURE CONTROL, and its three options are what an
 * owner reads before deciding how much of a row a share link may reveal. The
 * stored value is part of each label in both languages: translating the word
 * and dropping `(busy_only)` would leave the owner guessing which of two
 * similar-sounding options they actually picked.
 */
describe('the visibility options keep their meaning and their stored values', () => {
  it('each label still carries its stored enum value', () => {
    for (const d of [ja, en]) {
      expect(d['event.visibility.private']).toContain('(private)');
      expect(d['event.visibility.busyOnly']).toContain('(busy_only)');
      expect(d['event.visibility.public']).toContain('(public)');
    }
  });

  it('the three are distinct in both languages', () => {
    for (const d of [ja, en]) {
      const three = [
        d['event.visibility.private'],
        d['event.visibility.busyOnly'],
        d['event.visibility.public'],
      ];
      expect(new Set(three).size).toBe(3);
    }
  });

  it('busy_only reads as busy, never as public and never as private', () => {
    // It discloses that there IS an event and withholds everything else. A
    // label that read "public" would overstate it; "private" would understate
    // it, and the owner would hide a row they meant to show as busy.
    const s = en['event.visibility.busyOnly'];
    expect(s).toMatch(/busy/i);
    expect(s).not.toMatch(/\bpublic\b/i);
    expect(s).not.toMatch(/\bprivate\b(?!\))/i);
    expect(ja['event.visibility.busyOnly']).toContain('予定あり');
  });

  it('private names no exception for busy sharing', () => {
    // A private row IS still shared as busy by an include-private link. The
    // option label is deliberately the bare word, with that rule stated in the
    // share dialog where the link is configured, so this must not grow into a
    // promise the share dialog contradicts.
    expect(en['event.visibility.private']).toBe('Private (private)');
    expect(ja['event.visibility.private']).toBe('非公開 (private)');
  });

  it('the option list the dialog renders covers every Visibility', () => {
    // VISIBILITIES is the canonical ordered list of the union, exported by
    // visibilityMeta.ts. It replaced `Object.keys(visibilityMeta)` when P6
    // step 1 turned that Record into a function -- and key order was a weak
    // place to keep a contract anyway. The dialog builds its own option
    // array (it needs the enum value inside the label); this checks the two
    // still agree, in order.
    const inDialog = [...source('features/event/EventDialog.tsx').matchAll(
      /\{ value: '(\w+)', key: 'event\.visibility\./g,
    )].map((m) => m[1]);
    expect(inDialog).toEqual([...VISIBILITIES]);
  });
});

describe('Busy and Available now read in the display language', () => {
  it('the Japanese keeps the English term the rest of the product uses', () => {
    // This WAS deliberately not migrated, and the reason was sound: "Busy"
    // and "Available" are the terms the app uses in Japanese too -- the
    // share dialog says 空き時間(Available) -- so a free translation would
    // have broken the correspondence between this control and the checkbox
    // that decides whether the time is shared. What it cost was a Japanese
    // form with two English words in it and no Japanese name for either.
    //
    // Keeping the term in parentheses satisfies both.
    expect([...AVAILABILITIES]).toEqual(['busy', 'available']);
    expect(availabilityLabel('busy', 'ja')).toBe('予定あり (Busy)');
    expect(availabilityLabel('available', 'ja')).toBe('空き時間 (Available)');
    expect(availabilityLabel('busy', 'ja')).toContain('Busy');
    expect(availabilityLabel('available', 'ja')).toContain('Available');
  });

  it('the English is unchanged -- the label already IS the term', () => {
    expect(availabilityLabel('busy', 'en')).toBe('Busy');
    expect(availabilityLabel('available', 'en')).toBe('Available');
  });

  it('busy still requires a title and available still does not', () => {
    expect(isTitleRequired('busy')).toBe(true);
    expect(isTitleRequired('available')).toBe(false);
  });

  it('the dialog still asks for a title based on the availability being SAVED', () => {
    // Not the one the row arrived with: turning an untitled available event
    // back into a busy one has to demand the title a busy event needs.
    const src = source('features/event/EventDialog.tsx');
    expect(src).toMatch(/isTitleRequired\(availability\)\s*&&\s*!title\.trim\(\)/);
  });

  it('the dialog still defaults a new event to busy', () => {
    const src = source('features/event/EventDialog.tsx');
    expect(src).toMatch(/useState<Availability>\('busy'\)/);
    expect(src).toMatch(/setAvailability\('busy'\)/);
  });

  it('the dialog still defaults a new event to private', () => {
    // Changing this default is explicitly NOT part of this step.
    const src = source('features/event/EventDialog.tsx');
    expect(src).toMatch(/useState<Visibility>\('private'\)/);
    expect(src).toMatch(/setVisibility\('private'\)/);
  });
});

/**
 * THE RECURRENCE SAFETY PROPERTIES.
 *
 * A wrong word here does not render badly, it edits the wrong rows: "all
 * occurrences" applied to one, or a zone adopted by guesswork. The rules
 * themselves are tested in their own modules; what is checked here is that
 * this step left them in place and that neither language blurs them.
 */
describe('the edit scope stays unmistakable', () => {
  it('the two options are different in both languages', () => {
    for (const d of [ja, en]) {
      expect(d['event.scope.only']).not.toBe(d['event.scope.all']);
    }
  });

  it('"only" names a single occurrence and "all" names the series', () => {
    expect(ja['event.scope.only']).toContain('この回');
    expect(ja['event.scope.all']).toContain('すべて');
    expect(en['event.scope.only']).toMatch(/\bonly\b/i);
    expect(en['event.scope.only']).toMatch(/occurrence/i);
    expect(en['event.scope.all']).toMatch(/\ball\b/i);
  });

  it('neither option promises the other', () => {
    expect(en['event.scope.only']).not.toMatch(/\ball\b|series|every/i);
    expect(ja['event.scope.only']).not.toContain('すべて');
  });

  it('the scope still re-seeds the form and still starts at "only"', () => {
    const src = source('features/event/EventDialog.tsx');
    expect(src).toMatch(/useState<EditScope>\('only'\)/);
    expect(src).toMatch(/setScope\('only'\)/);
    expect(src).toMatch(/formSeedForScope\(occ, master, next\)/);
  });

  it('a per-occurrence edit still leaves the series rule alone', () => {
    // `rrule === undefined` means "omit the key"; the editor is read-only for
    // that scope. Both halves of the rule survive this step.
    const src = source('features/event/EventDialog.tsx');
    expect(src).toMatch(/recurrenceEditable = !isRecurring \|\| scope === 'all'/);
    expect(src).toMatch(/allDayLocked = isRecurring && scope === 'only'/);
  });
});

describe('the zone is still never guessed', () => {
  it('neither refusal offers a fallback zone in either language', () => {
    for (const k of ['event.tz.unresolved', 'event.tz.unavailable'] as const) {
      expect(en[k]).not.toMatch(/UTC|GMT|default|assume|instead/i);
      expect(ja[k]).not.toContain('UTC');
    }
  });

  it('both refusals point at the browser settings rather than at a retry', () => {
    for (const k of ['event.tz.unresolved', 'event.tz.unavailable'] as const) {
      expect(ja[k]).toContain('ブラウザの日付と時刻の設定');
      expect(en[k]).toMatch(/browser/i);
      expect(en[k]).toMatch(/date and time settings/i);
    }
  });

  it('the save refusal says a TIMED REPEAT cannot be saved, not that saving failed', () => {
    expect(ja['event.tz.unresolved']).toContain('時刻ありの繰り返し予定は保存できません');
    expect(en['event.tz.unresolved']).toMatch(/repeating event with a time cannot be saved/i);
  });

  it('the panel refusal says it cannot be SET, since nothing is being saved there', () => {
    expect(ja['event.tz.unavailable']).toContain('設定できません');
    expect(en['event.tz.unavailable']).toMatch(/cannot be set/i);
  });

  it('the zone is still resolved once on open and never re-read on save', () => {
    const src = source('features/event/EventDialog.tsx');
    // Passed as the lazy initialiser, so it runs once rather than on every
    // render -- and saving uses that value instead of re-reading the browser.
    expect(src).toMatch(/useState<string \| null>\(resolveStorableTimeZone\)/);
  });

  it('setting a series zone is still its own action, not part of onSave', () => {
    const src = source('features/event/EventDialog.tsx');
    expect(src).toMatch(/onSetSeriesTimezone\(master\.id, storableTimeZone\)/);
    // The save path builds its intent from editTimezoneIntent, which is what
    // refuses rather than inventing a zone.
    expect(src).toMatch(/editTimezoneIntent\(target, \{ allDay: time\.allDay, rrule \}, storableTimeZone\)/);
  });
});

/**
 * The option lists moved from `{ value, label }` to `{ value, key }`. The
 * values are the ones persisted and the ones the selects compare against, so
 * the move must not have dropped or renamed one.
 */
describe('the option lists still offer exactly their unions', () => {
  it('the recurrence editor offers four frequencies and three end modes', () => {
    const src = source('features/event/RecurrenceEditor.tsx');
    const freq = [...src.matchAll(/\{ value: '(\w+)', key: 'recurrence\.freq\./g)].map((m) => m[1]);
    const end = [...src.matchAll(/\{ value: '(\w+)', key: 'recurrence\.end\./g)].map((m) => m[1]);
    expect(freq).toEqual(['none', 'daily', 'weekly', 'monthly']);
    expect(end).toEqual(['never', 'count', 'until']);
  });

  it('each list carries a compile-time coverage assertion', () => {
    // These are what make a dropped option a build failure rather than a
    // control that silently lost a choice. If they are deleted, this fails.
    const dialog = source('features/event/EventDialog.tsx');
    const editor = source('features/event/RecurrenceEditor.tsx');
    expect(dialog).toMatch(/_visibilityParity/);
    expect(editor).toMatch(/_freqParity/);
    expect(editor).toMatch(/_endParity/);
  });
});

describe('what this step deliberately did not do', () => {
  it('weekday labels are NOT in the dictionary -- P4 step 1 gave them a formatter', () => {
    // This step left the Record keyed by RFC 5545 code in place; P4 step 1
    // replaced it, along with the three identical arrays elsewhere, with
    // i18n/dateNames.ts. What has not changed, and must not, is that the
    // seven names are a DATE FORMAT and so never became dictionary keys.
    const editor = source('features/event/RecurrenceEditor.tsx');
    expect(editor).toMatch(/weekdayNamesShort\(language\)/);
    expect(editor).not.toContain("MO: '月'");
    const weekdayKeys = (Object.keys(ja) as string[]).filter((k) => k.startsWith('weekday.'));
    expect(weekdayKeys).toEqual([]);
  });

  it('no category autocomplete was added', () => {
    const src = source('features/event/EventDialog.tsx');
    expect(src).not.toMatch(/datalist|autoComplete|suggest/i);
  });

  it('the two components read the language but still render the default', () => {
    // LANGUAGE_SWITCH_ENABLED pins what the provider hands out until P6, so a
    // component on the migrated list still shows Japanese for everyone. The
    // flag itself is asserted in wiring.test.ts.
    for (const p of ['features/event/EventDialog.tsx', 'features/event/RecurrenceEditor.tsx']) {
      expect(source(p)).toMatch(/useTranslate\(\)/);
    }
  });
});
