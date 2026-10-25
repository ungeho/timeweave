/**
 * P6 step 8: the event dialog's error line is resolved at render.
 *
 * The last of the four frozen-error screens and the one with the most sources.
 * `formError` was filled from eleven places: four catches read `e.message`,
 * six validation failures called `tr(...)`, and one asked `contentLengthError`
 * for a sentence. Every one of them decided the wording at the moment of the
 * failure, so a language change afterwards re-rendered the whole dialog and
 * left the error line in the old language.
 *
 * THREE VARIANTS, and the reason there are three rather than two is worth
 * stating: the five `tr()` keys take NO variables, so a key is the whole
 * state, while the three content-length messages each quote a number and
 * differ per field. One variant covering both would have to widen the key type
 * -- and `t` demands exactly the variables a key declares, so a widened key
 * owes it the widest variable set in the dictionary.
 *
 * The dialog cannot be rendered here (vitest runs `environment: 'node'` with
 * no jsdom), so the decision is exercised directly and the wiring is asserted
 * structurally.
 */

import { describe, expect, it } from 'vitest';
import {
  eventFormErrorText,
  type EventFormError,
  type EventValidationKey,
} from '../features/event/eventFormError';
import {
  CATEGORY_MAX,
  DESCRIPTION_MAX,
  TITLE_MAX,
  contentLengthError,
  contentLengthMessage,
  contentLengthViolation,
  type ContentLengths,
} from '../services/contentLimits';
import { RecurrenceFormError } from '../features/event/recurrenceForm';
import {
  DuplicateExceptionError,
  EventQuotaExceededError,
  ExceptionQuotaExceededError,
  SeriesEditBlockedError,
  WriteRateLimitedError,
} from '../errors';
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
const DLG = 'features/event/EventDialog.tsx';

const caught = (cause: unknown): EventFormError => ({ kind: 'caught', cause });
const validation = (key: EventValidationKey): EventFormError => ({ kind: 'validation', key });

/** The five validation keys and the Japanese each has always shown. */
const VALIDATION: { key: EventValidationKey; ja: string }[] = [
  { key: 'event.title.required', ja: 'タイトルを入力してください' },
  { key: 'event.error.dateRequired', ja: '日付を入力してください' },
  { key: 'event.error.endDateBeforeStart', ja: '終了日は開始日以降にしてください' },
  { key: 'event.error.endBeforeStart', ja: '終了日時は開始日時以降にしてください' },
  {
    key: 'event.tz.unresolved',
    ja: 'タイムゾーンを判定できないため、時刻ありの繰り返し予定は保存できません。ブラウザの日付と時刻の設定をご確認ください',
  },
  // K18 (P8-finish-3b): the database's own date bounds, refused before saving.
  { key: 'event.error.allDayOutOfRange', ja: '終日の予定は 9999年12月30日 までの日付にしてください' },
  {
    key: 'event.error.timedOutOfRange',
    ja: 'この日時は保存できる範囲を超えています。協定世界時（UTC）で 9999年12月31日 のうちに終わる日時にしてください',
  },
];

// ---------------------------------------------------------------------------

describe('every assignment path keeps a cause or a key', () => {
  it('the five catches store the cause', () => {
    /*
      Five since P8-b5. The new one wraps buildSaveResult inside handleSave:
      it used to be called outside the try, so a throw escaped the handler
      as an unhandled rejection and the save button appeared to do nothing.
      The count is the point of this test -- a catch added without routing
      its cause through EventFormError would be the thing it misses.
    */
    const dlg = code(DLG);
    expect(dlg.split("setFormError({ kind: 'caught', cause: e })").length - 1).toBe(5);
    expect(dlg).not.toMatch(/instanceof Error \? e\.message : String\(e\)/);
    expect(dlg).not.toMatch(/errorMessage/);
  });

  it('the seven validation failures store a key', () => {
    /*
      Seven since P8-b5. The new one is the empty-datetime check in the timed
      branch -- the all-day branch had always had its equivalent, and without
      it an emptied start threw instead of reporting.
    */
    //   Nine since P8-finish-3b (K18): the all-day and the timed branch each
    // refuse a date the database cannot store (eventDateBounds.ts).
    const dlg = code(DLG);
    expect(dlg.split("setFormError({ kind: 'validation', key: ").length - 1).toBe(9);
    expect(dlg).not.toMatch(/setFormError\(tr\(/);
  });

  it('every key stored by the dialog is one the type admits', () => {
    // A key that drifted out of the union would be a compile error at the
    // assignment; this catches the reverse -- a member nobody uses, which
    // means a path was removed without its key.
    const used = new Set(
      [...code(DLG).matchAll(/kind: 'validation', key: '([\w.]+)'/g)].flatMap((m) =>
        m[1] ? [m[1]] : [],
      ),
    );
    expect([...used].sort()).toEqual(VALIDATION.map((v) => v.key).sort());
  });

  it('the length refusal stores the violation, not the sentence', () => {
    const dlg = code(DLG);
    expect(dlg).toContain("setFormError({ kind: 'contentTooLong', violation: tooLong })");
    expect(dlg).toContain('contentLengthViolation(content)');
    expect(dlg).not.toContain('contentLengthError(');
  });

  it('the three clear points are unchanged', () => {
    // Two at the start of a read/save and one before a delete. Changing the
    // count would change when an error disappears.
    expect(code(DLG).split('setFormError(null)').length - 1).toBe(3);
  });

  it('formError is the only state holding wording', () => {
    // The other two `string | null` slots hold IANA zone names, which are
    // values rather than copy.
    const dlg = code(DLG);
    expect(dlg).toMatch(/useState<EventFormError \| null>/);
    expect(dlg).not.toMatch(/\[formError, setFormError\] = useState<string \| null>/);
    for (const other of ['storableTimeZone', 'seriesTimeZone']) {
      expect(dlg, other).toMatch(new RegExp(`${other}[^=]*=[^;]*useState<string \\| null>`));
    }
  });
});

describe('the six validation errors read exactly as before in Japanese', () => {
  it.each(VALIDATION)('$key', ({ key, ja }) => {
    expect(eventFormErrorText(validation(key), 'ja')).toBe(ja);
    // Called with no language at all, the same.
    expect(eventFormErrorText(validation(key))).toBe(ja);
  });

  it('the two tz.unresolved call sites share one sentence', () => {
    // The series panel and the save path both raise it, and the owner reads
    // the same thing either way -- which is why it is one union member.
    const dlg = code(DLG);
    expect(dlg.split("key: 'event.tz.unresolved'").length - 1).toBe(2);
  });
});

describe('the six validation errors read correctly in English', () => {
  it.each(VALIDATION)('$key', ({ key }) => {
    const en = eventFormErrorText(validation(key), 'en');
    expect(en).not.toMatch(JAPANESE);
    expect(en).not.toBe('');
    expect(en).not.toMatch(/\{\w+\}/);
    expect(en).not.toBe(eventFormErrorText(validation(key), 'ja'));
  });

  it('each still says what it is about', () => {
    const en = (k: EventValidationKey) => eventFormErrorText(validation(k), 'en');
    expect(en('event.title.required')).toMatch(/title/i);
    expect(en('event.error.dateRequired')).toMatch(/date/i);
    expect(en('event.error.endDateBeforeStart')).toMatch(/end date/i);
    expect(en('event.error.endBeforeStart')).toMatch(/end/i);
    expect(en('event.tz.unresolved')).toMatch(/time zone/i);
  });

  it('the two end-ordering messages stay distinguishable', () => {
    // One is about all-day dates, the other about timed instants. A fluent
    // rewrite that merged them would leave an owner unable to tell which field
    // is wrong.
    for (const lang of LANGUAGES) {
      expect(
        eventFormErrorText(validation('event.error.endDateBeforeStart'), lang),
        lang,
      ).not.toBe(eventFormErrorText(validation('event.error.endBeforeStart'), lang));
    }
  });

  it('the tz refusal still says the save is refused, not merely degraded', () => {
    // It is the one validation message that stops a SAVE for a reason outside
    // the form. Saying less would leave the owner retrying.
    expect(eventFormErrorText(validation('event.tz.unresolved'), 'ja')).toContain('保存できません');
    expect(eventFormErrorText(validation('event.tz.unresolved'), 'en')).toMatch(
      /cannot be saved|can't be saved/i,
    );
  });

  it('an unrecognised language falls back to Japanese', () => {
    const bogus = 'de' as unknown as 'ja';
    for (const { key, ja } of VALIDATION) {
      expect(eventFormErrorText(validation(key), bogus), key).toBe(ja);
    }
  });
});

describe('the length refusal names its field and quotes its ceiling', () => {
  // Typed as ContentLengths, not inferred: `category: null` would otherwise
  // narrow to the `null` type and the sibling cases would not assign.
  const longTitle: ContentLengths = {
    title: 'a'.repeat(TITLE_MAX + 1),
    category: null,
    description: null,
  };
  const longCategory: ContentLengths = {
    title: 'ok',
    category: 'a'.repeat(CATEGORY_MAX + 1),
    description: null,
  };
  const longDescription: ContentLengths = {
    title: 'ok',
    category: null,
    description: 'a'.repeat(DESCRIPTION_MAX + 1),
  };

  it('the Japanese equals what contentLengthError produced', () => {
    for (const content of [longTitle, longCategory, longDescription]) {
      const violation = contentLengthViolation(content);
      expect(violation).not.toBeNull();
      expect(eventFormErrorText({ kind: 'contentTooLong', violation: violation! }, 'ja')).toBe(
        contentLengthError(content),
      );
    }
  });

  it('each field has its own sentence and its own number, in both languages', () => {
    const cases: [ContentLengths, number, RegExp, RegExp][] = [
      [longTitle, TITLE_MAX, /タイトル/, /title/i],
      [longCategory, CATEGORY_MAX, /カテゴリ/, /category/i],
      [longDescription, DESCRIPTION_MAX, /メモ/, /description|note/i],
    ];
    for (const [content, max, jaRe, enRe] of cases) {
      const violation = contentLengthViolation(content)!;
      const e: EventFormError = { kind: 'contentTooLong', violation };
      expect(eventFormErrorText(e, 'ja')).toMatch(jaRe);
      expect(eventFormErrorText(e, 'ja')).toContain(String(max));
      expect(eventFormErrorText(e, 'en')).toMatch(enRe);
      expect(eventFormErrorText(e, 'en')).toContain(String(max));
      expect(eventFormErrorText(e, 'en')).not.toMatch(JAPANESE);
    }
  });

  it('the ceiling comes from the state, so it cannot drift from the rule', () => {
    const e: EventFormError = { kind: 'contentTooLong', violation: { field: 'title', max: 9 } };
    expect(eventFormErrorText(e, 'ja')).toContain('9');
    expect(eventFormErrorText(e, 'en')).toContain('9');
  });

  it('the checking order is still title, category, description', () => {
    // A form with two over-long fields names the first, and which one that is
    // has always been this order.
    const both = {
      title: 'a'.repeat(TITLE_MAX + 1),
      category: 'a'.repeat(CATEGORY_MAX + 1),
      description: 'a'.repeat(DESCRIPTION_MAX + 1),
    };
    expect(contentLengthViolation(both)?.field).toBe('title');
    expect(contentLengthViolation({ ...both, title: 'ok' })?.field).toBe('category');
    expect(contentLengthViolation({ ...both, title: 'ok', category: null })?.field).toBe(
      'description',
    );
  });

  it('contentLengthError keeps its old contract for its other callers', () => {
    // Asserted directly in contentLimits.test.ts and the i18n suites, so
    // delegating internally must not have changed what it returns.
    expect(contentLengthError({ title: 'ok', category: null, description: null })).toBeNull();
    expect(contentLengthError(longTitle)).toBe(
      contentLengthMessage({ field: 'title', max: TITLE_MAX }),
    );
    expect(contentLengthError(longTitle, 'en')).toBe(
      contentLengthMessage({ field: 'title', max: TITLE_MAX }, 'en'),
    );
  });

  it('a value that fits is still accepted at the boundary', () => {
    expect(
      contentLengthViolation({ title: 'a'.repeat(TITLE_MAX), category: null, description: null }),
    ).toBeNull();
  });
});

describe('caught errors localize, including the recurrence form', () => {
  it('a RecurrenceFormError reads in both languages', () => {
    // It reaches the dialog as the 'caught' variant: caughtErrorText sees a
    // DomainError (isDomainError is structural, so step 4's co-located class
    // qualifies) and calls localize.
    const e = new RecurrenceFormError('untilRequired');
    expect(eventFormErrorText(caught(e), 'ja')).toBe('終了日を入力してください');
    expect(eventFormErrorText(caught(e), 'en')).toBe('Please enter an end date');
    for (const reason of ['intervalTooSmall', 'countTooSmall', 'untilRequired'] as const) {
      const err = new RecurrenceFormError(reason);
      // Japanese is byte-identical to the `.message` the old helper showed.
      expect(eventFormErrorText(caught(err), 'ja'), reason).toBe(err.message);
      expect(eventFormErrorText(caught(err), 'en'), reason).not.toMatch(JAPANESE);
    }
  });

  it('the domain errors this dialog actually raises localize', () => {
    for (const e of [
      new DuplicateExceptionError(),
      new SeriesEditBlockedError(),
      SeriesEditBlockedError.timezoneChange(),
      new EventQuotaExceededError(),
      new ExceptionQuotaExceededError(),
      new WriteRateLimitedError(15),
    ]) {
      expect(eventFormErrorText(caught(e), 'ja'), e.name).toBe(e.message);
      expect(eventFormErrorText(caught(e), 'en'), e.name).not.toMatch(JAPANESE);
      expect(eventFormErrorText(caught(e), 'en'), e.name).not.toBe(
        eventFormErrorText(caught(e), 'ja'),
      );
    }
  });

  it('a rate-limited write keeps its interpolated wait', () => {
    expect(eventFormErrorText(caught(new WriteRateLimitedError(15)), 'en')).toMatch(/15 sec\b/);
    expect(eventFormErrorText(caught(new WriteRateLimitedError(15)), 'ja')).toMatch(/15秒/);
  });

  it('a custom message is shown verbatim, never translated', () => {
    for (const e of [
      new SeriesEditBlockedError('bespoke wording'),
      new RecurrenceFormError('countTooSmall', 'bespoke wording'),
    ]) {
      expect(e.hasCustomMessage).toBe(true);
      for (const lang of LANGUAGES) {
        expect(eventFormErrorText(caught(e), lang), e.name).toBe('bespoke wording');
      }
    }
  });

  it('a plain Error keeps its message', () => {
    const e = new Error('23505: duplicate key');
    for (const lang of LANGUAGES) {
      expect(eventFormErrorText(caught(e), lang), lang).toBe('23505: duplicate key');
    }
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
      const got = eventFormErrorText(caught(cause), lang);
      expect(got, lang).toBe(t('error.unknownCause', lang));
      expect(got, lang).not.toBe('');
    }
  });

  it('the tagged state is why a null cause is still an error', () => {
    const mod = code('features/event/eventFormError.ts');
    expect(mod).toMatch(/readonly kind: 'caught'/);
    expect(mod).toMatch(/readonly cause: unknown/);
    expect(code(DLG)).toMatch(/\{formError && \(/);
  });

  it('the thrown value never reaches the screen', () => {
    const leaky = { detail: 'row id 7f3a-secret', toString: () => 'row id 7f3a-secret' };
    for (const lang of LANGUAGES) {
      expect(eventFormErrorText(caught(leaky), lang), lang).not.toContain('7f3a-secret');
    }
  });

  it('no event content is interpolated into any error wording', () => {
    // A title, a category or a description must not arrive via an error line
    // -- an untitled-but-private event's contents least of all.
    for (const lang of LANGUAGES) {
      for (const e of [
        caught(new Error('boom')),
        caught(null),
        validation('event.title.required'),
        { kind: 'contentTooLong', violation: { field: 'title', max: TITLE_MAX } } as EventFormError,
      ]) {
        const got = eventFormErrorText(e, lang);
        expect(got).not.toMatch(/private|busy_only|public/);
      }
    }
  });
});

describe('a language change updates the display and nothing else', () => {
  it('the same stored error reads differently per language, stably within one', () => {
    for (const e of [
      caught(new EventQuotaExceededError()),
      validation('event.title.required'),
      { kind: 'contentTooLong', violation: { field: 'category', max: CATEGORY_MAX } } as EventFormError,
    ]) {
      expect(eventFormErrorText(e, 'ja')).not.toBe(eventFormErrorText(e, 'en'));
      expect(eventFormErrorText(e, 'ja')).toBe(eventFormErrorText(e, 'ja'));
    }
  });

  it('no event API is reachable from the display path', () => {
    for (const p of ['features/event/eventFormError.ts', 'services/contentLimits.ts']) {
      const mod = code(p);
      expect(mod, p).not.toMatch(/repositor|supabase|useEvents|formToRule/i);
    }
  });

  it('the helper is pure: no hook, no React, no import-time resolution', () => {
    const mod = code('features/event/eventFormError.ts');
    expect(mod).not.toMatch(/useTranslate|useLanguage|from 'react'/);
    expect(mod).toMatch(/lang: Language = DEFAULT_LANGUAGE/);
    expect(mod).not.toMatch(/^(export )?const \w+ = t\(/m);
  });

  it('the dialog reads the DISPLAYED language', () => {
    const dlg = code(DLG);
    expect(dlg).toContain('const { language } = useLanguage()');
    expect(dlg).toContain('eventFormErrorText(formError, language)');
  });
});

/**
 * The event-operation invariants. All negatives: an error line is wording.
 */
describe('the event operations are untouched', () => {
  const dlg = code(DLG);

  it('the save conditions are unchanged', () => {
    expect(dlg).toMatch(/isTitleRequired\(availability\) && !title\.trim\(\)/);
    expect(dlg).toMatch(/endDateInclusive < startDate/);
    expect(dlg).toMatch(/new Date\(endAt\)\.getTime\(\) < new Date\(startAt\)\.getTime\(\)/);
    // Each refusal still abandons the read with null.
    expect(dlg.split('return null;').length - 1).toBeGreaterThanOrEqual(6);
  });

  it('the recurrence rule is still built and validated the same way', () => {
    expect(dlg).toMatch(/formToRule\(recurrenceForm, dtstartIso, timeZone, allDay\)/);
    expect(dlg).toMatch(/rrule = rule \? formatRRule\(rule\) : null/);
    // Only an editable rule contributes; a per-occurrence edit leaves it alone.
    expect(dlg).toMatch(/if \(recurrenceEditable\) \{/);
  });

  it('availability and visibility stay independent, with no new default', () => {
    expect(dlg).toMatch(/useState<Visibility>\('private'\)/);
    expect(dlg).toMatch(/setVisibility\('private'\)/);
    // The content object carries both, separately.
    expect(dlg).toMatch(/visibility,\s*availability,/);
  });

  it('the all-day end date is still stored exclusive', () => {
    expect(dlg).toMatch(/endDate: addDaysToDateString\(endDateInclusive, 1\)/);
  });

  it('the timezone guard still refuses a timed recurrence with no zone', () => {
    expect(dlg).toMatch(/storableTimeZone/);
    expect(dlg).toContain("key: 'event.tz.unresolved'");
  });

  it('the scope of an edit is still decided by formSeedForScope', () => {
    expect(dlg).toMatch(/formSeedForScope/);
    expect(code('features/event/recurrenceForm.ts')).toMatch(/export function formSeedForScope/);
  });

  it('the switch is ON, so these refusals now reach an English owner', () => {
    expect(LANGUAGE_SWITCH_ENABLED).toBe(true);
    for (const { key } of VALIDATION) {
      expect(eventFormErrorText(validation(key), 'en'), key).not.toMatch(JAPANESE);
    }
  });

  it('no dictionary key was added for this step', () => {
    // All eight keys involved already existed. Only who holds them changed.
    const keys = [
      ...code('features/event/eventFormError.ts').matchAll(/'(event\.[\w.]+)'/g),
    ].flatMap((m) => (m[1] ? [m[1]] : []));
    // P8-finish-3b (K18) added exactly two: event.error.allDayOutOfRange and
    // event.error.timedOutOfRange. The count is still exact.
    expect(new Set(keys).size).toBe(7);
    for (const k of keys) {
      expect(t(k as 'event.title.required', 'ja'), k).not.toBe(k);
      expect(t(k as 'event.title.required', 'en'), k).not.toBe(k);
    }
  });
});
