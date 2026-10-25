/**
 * P6 step 4: the recurrence form's three refusals became a typed error.
 *
 * They were `throw new Error(t(key, DEFAULT_LANGUAGE))` -- the wording decided
 * at the moment of failure, in Japanese, by a pure converter that has no
 * business knowing what language anyone reads. Nothing downstream could tell
 * the three apart, and EventDialog renders whatever `.message` holds, so the
 * sentence an English owner would see was fixed before the dialog opened.
 *
 * THE CLAIM OF THIS STEP IS NARROW, and most of the file is spent holding it
 * to that: only the IDENTITY of the errors changed. The same three inputs are
 * refused, the same three Japanese sentences come out of `.message`, and every
 * valid form still converts to exactly the rule it did before. What is new is
 * that each refusal carries a `reason` and can be asked for its wording in a
 * language, which is what the next step needs in order to wire the display.
 */

import { describe, expect, it } from 'vitest';
import {
  EMPTY_RECURRENCE_FORM,
  RecurrenceFormError,
  formToRule,
  ruleToForm,
  type RecurrenceForm,
  type RecurrenceFormErrorReason,
} from '../features/event/recurrenceForm';
import { isDomainError } from '../errors';
import { eventFormErrorText } from '../features/event/eventFormError';
import { dayStartInstantIso } from '../utils/timezone';
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

const TZ = 'Asia/Tokyo';
const form = (over: Partial<RecurrenceForm>): RecurrenceForm => ({
  ...EMPTY_RECURRENCE_FORM,
  ...over,
});
/** An instant whose Tokyo calendar day is Monday 2026-08-24. */
const MON = dayStartInstantIso('2026-08-24', TZ);

/** The three refusals, each with the input that still produces it. */
const CASES: {
  reason: RecurrenceFormErrorReason;
  input: RecurrenceForm;
  ja: string;
  en: string;
}[] = [
  {
    reason: 'intervalTooSmall',
    input: form({ freq: 'daily', interval: 0 }),
    ja: '繰り返し間隔は 1 以上にしてください',
    en: 'The repeat interval must be 1 or more',
  },
  {
    reason: 'countTooSmall',
    input: form({ freq: 'daily', endMode: 'count', count: 0 }),
    ja: '繰り返し回数は 1 以上にしてください',
    en: 'The number of repeats must be 1 or more',
  },
  {
    reason: 'untilRequired',
    input: form({ freq: 'daily', endMode: 'until', untilDate: '' }),
    ja: '終了日を入力してください',
    en: 'Please enter an end date',
  },
];

const thrown = (f: RecurrenceForm, allDay = false): unknown => {
  try {
    formToRule(f, MON, TZ, allDay);
  } catch (e) {
    return e;
  }
  throw new Error('expected formToRule to throw');
};

// ---------------------------------------------------------------------------

describe('the same three inputs are refused, for the same three reasons', () => {
  it.each(CASES)('$reason still throws', ({ input }) => {
    expect(() => formToRule(input, MON, TZ, false)).toThrow();
  });

  it.each(CASES)('$reason is carried on the error', ({ reason, input }) => {
    const e = thrown(input);
    expect(e).toBeInstanceOf(RecurrenceFormError);
    expect((e as RecurrenceFormError).reason).toBe(reason);
  });

  it('the three reasons are distinguishable from one another', () => {
    // The whole point of the discriminator: a caller can act on WHICH rule was
    // broken without matching on a sentence.
    const reasons = CASES.map((c) => (thrown(c.input) as RecurrenceFormError).reason);
    expect(new Set(reasons).size).toBe(3);
    expect(reasons).toEqual(['intervalTooSmall', 'countTooSmall', 'untilRequired']);
  });

  it('a non-integer interval is still refused, by the interval rule', () => {
    // Math.floor runs first, so 0.5 floors to 0 and fails the same check.
    const e = thrown(form({ freq: 'daily', interval: 0.5 }));
    expect((e as RecurrenceFormError).reason).toBe('intervalTooSmall');
  });

  it('a negative count is still refused, by the count rule', () => {
    const e = thrown(form({ freq: 'daily', endMode: 'count', count: -3 }));
    expect((e as RecurrenceFormError).reason).toBe('countTooSmall');
  });

  it('the interval rule is checked before the end rule, as before', () => {
    // Both broken at once: the order decides which sentence the owner sees,
    // and it has not changed.
    const e = thrown(form({ freq: 'daily', interval: 0, endMode: 'until', untilDate: '' }));
    expect((e as RecurrenceFormError).reason).toBe('intervalTooSmall');
  });

  it("'none' still returns null without validating anything", () => {
    // An interval of 0 is irrelevant when there is no rule to build.
    expect(formToRule(form({ freq: 'none', interval: 0 }), MON, TZ, false)).toBeNull();
  });
});

describe('.message is byte-identical to the Japanese it always threw', () => {
  it.each(CASES)('$reason', ({ input, ja }) => {
    expect((thrown(input) as Error).message).toBe(ja);
  });

  it('constructing one directly gives the same sentence', () => {
    for (const { reason, ja } of CASES) {
      expect(new RecurrenceFormError(reason).message).toBe(ja);
    }
  });

  it('the dialog renders exactly that, so the screen has not moved', () => {
    // EventDialog's `errorMessage` helper is `e instanceof Error ? e.message
    // : String(e)`. A RecurrenceFormError IS an Error, so it takes the first
    // branch and shows `.message` -- the Japanese above.
    for (const { input, ja } of CASES) {
      const e = thrown(input);
      expect(e instanceof Error ? e.message : String(e)).toBe(ja);
    }
  });
});

describe('localize answers in both languages', () => {
  it.each(CASES)('$reason in Japanese equals .message', ({ reason, ja }) => {
    const e = new RecurrenceFormError(reason);
    expect(e.localize('ja')).toBe(ja);
    expect(e.localize('ja')).toBe(e.message);
  });

  it.each(CASES)('$reason in English', ({ reason, en }) => {
    const e = new RecurrenceFormError(reason);
    expect(e.localize('en')).toBe(en);
    expect(e.localize('en')).not.toMatch(JAPANESE);
  });

  it('English actually differs from Japanese for all three', () => {
    // A localize that ignored `lang` would pass every assertion above except
    // this one.
    for (const { reason } of CASES) {
      const e = new RecurrenceFormError(reason);
      expect(e.localize('en'), reason).not.toBe(e.localize('ja'));
    }
  });

  it('the three English sentences are distinct', () => {
    const en = CASES.map((c) => new RecurrenceFormError(c.reason).localize('en'));
    expect(new Set(en).size).toBe(3);
  });

  it('each English sentence still says what the rule is', () => {
    // Translation must not drop the number or the field it is about.
    const e = (r: RecurrenceFormErrorReason) => new RecurrenceFormError(r).localize('en');
    expect(e('intervalTooSmall')).toMatch(/interval/i);
    expect(e('intervalTooSmall')).toMatch(/\b1\b/);
    expect(e('countTooSmall')).toMatch(/repeats/i);
    expect(e('countTooSmall')).toMatch(/\b1\b/);
    expect(e('untilRequired')).toMatch(/end date/i);
  });

  it('an unrecognised language falls back to Japanese', () => {
    const bogus = 'de' as unknown as 'ja';
    for (const { reason, ja } of CASES) {
      expect(new RecurrenceFormError(reason).localize(bogus)).toBe(ja);
    }
  });

  it('an explicit custom message survives in both languages', () => {
    // The contract every errors.ts class keeps: an arbitrary string cannot be
    // translated, so it is returned unchanged rather than replaced by the
    // generic sentence for the reason.
    const e = new RecurrenceFormError('countTooSmall', 'bespoke wording');
    expect(e.hasCustomMessage).toBe(true);
    expect(e.message).toBe('bespoke wording');
    expect(e.localize('ja')).toBe('bespoke wording');
    expect(e.localize('en')).toBe('bespoke wording');
  });

  it('the thrown errors carry no custom message', () => {
    for (const { input } of CASES) {
      expect((thrown(input) as RecurrenceFormError).hasCustomMessage).toBe(false);
    }
  });
});

describe('the existing error contracts are intact', () => {
  it.each(CASES)('$reason is still an Error', ({ input }) => {
    const e = thrown(input);
    expect(e).toBeInstanceOf(Error);
    expect(e instanceof Error).toBe(true);
  });

  it('the name is set, as every other error class in this app sets it', () => {
    for (const { input } of CASES) {
      expect((thrown(input) as Error).name).toBe('RecurrenceFormError');
    }
  });

  it('one stable code identifies the failure, independent of wording', () => {
    // One code with three reasons, the arrangement FreeBusyRateLimitedError
    // uses: for anything that IDENTIFIES an error these are one failure --
    // "the form does not describe a rule" -- with three wordings.
    for (const { input } of CASES) {
      expect((thrown(input) as RecurrenceFormError).code).toBe('RECURRENCE_FORM');
    }
  });

  it('messageKey follows the reason', () => {
    expect(new RecurrenceFormError('intervalTooSmall').messageKey).toBe(
      'recurrence.intervalTooSmall',
    );
    expect(new RecurrenceFormError('countTooSmall').messageKey).toBe('recurrence.countTooSmall');
    expect(new RecurrenceFormError('untilRequired').messageKey).toBe('recurrence.untilRequired');
  });

  it('isDomainError recognises it, which is what the next step needs', () => {
    // The display sites will branch on this one predicate rather than naming
    // each class. Satisfying the interface from outside errors.ts is exactly
    // what that module made it an interface for.
    for (const { input } of CASES) {
      expect(isDomainError(thrown(input))).toBe(true);
    }
    expect(isDomainError(new Error('plain'))).toBe(false);
  });

  it('the code is registered in the shared ErrorCode union', () => {
    // The class is co-located, the code is not: ErrorCode is the registry of
    // everything that can name an error, and a code that lived outside it
    // could collide with a later one.
    expect(code('errors.ts')).toContain("| 'RECURRENCE_FORM'");
  });
});

describe('nothing about the conversion itself changed', () => {
  it('a weekly rule still sorts its weekdays and keeps RFC 5545 codes', () => {
    const rule = formToRule(form({ freq: 'weekly', weekdays: ['FR', 'MO'] }), MON, TZ, false);
    expect(rule).toEqual({ freq: 'WEEKLY', interval: 1, byDay: ['MO', 'FR'] });
  });

  it('an empty weekday list still defaults to the dtstart weekday', () => {
    const rule = formToRule(form({ freq: 'weekly', weekdays: [] }), MON, TZ, false);
    expect(rule?.byDay).toEqual(['MO']);
  });

  it('count and until still produce the same shapes', () => {
    expect(formToRule(form({ freq: 'daily', endMode: 'count', count: 5 }), MON, TZ, false)).toEqual(
      { freq: 'DAILY', interval: 1, byDay: undefined, count: 5 },
    );
    const allDay = formToRule(
      form({ freq: 'daily', endMode: 'until', untilDate: '2026-09-02' }),
      MON,
      TZ,
      true,
    );
    expect(allDay?.until).toEqual({ kind: 'date', date: '2026-09-02' });
    const timed = formToRule(
      form({ freq: 'daily', endMode: 'until', untilDate: '2026-09-02' }),
      MON,
      TZ,
      false,
    );
    expect(timed?.until?.kind).toBe('instant');
  });

  it('a rule still round-trips through ruleToForm', () => {
    const rule = formToRule(form({ freq: 'weekly', weekdays: ['WE'], endMode: 'count', count: 4 }), MON, TZ, false);
    expect(ruleToForm(rule!, TZ)).toMatchObject({
      freq: 'weekly',
      weekdays: ['WE'],
      endMode: 'count',
      count: 4,
    });
  });

  it('formToRule still takes four arguments, none of them a language', () => {
    // The design decision this step turned on. Threading a language through a
    // pure converter would tie validation to display: which rule a form
    // describes does not depend on what language it is read in.
    expect(formToRule.length).toBe(4);
    const mod = code('features/event/recurrenceForm.ts');
    expect(mod).not.toMatch(/export function formToRule\([^)]*lang/s);
  });

  it('the module still holds no hook and no React import', () => {
    const mod = code('features/event/recurrenceForm.ts');
    expect(mod).not.toMatch(/useTranslate|useLanguage|from 'react'/);
  });
});

describe('language cannot reach validation or storage', () => {
  it('the refusal decisions read no language', () => {
    // The three conditions are arithmetic and emptiness checks on the form.
    // None of them consults a dictionary, and the error is constructed only
    // after the decision is made.
    const mod = code('features/event/recurrenceForm.ts');
    const fn = mod.slice(mod.indexOf('export function formToRule'), mod.indexOf('export function ruleToForm'));
    expect(fn.length).toBeGreaterThan(0);
    expect(fn).not.toMatch(/\bt\(/);
    expect(fn).not.toMatch(/DEFAULT_LANGUAGE|Language/);
  });

  it('the same form yields the same rule regardless of display language', () => {
    // There is no language to vary -- which is the strongest form of this
    // claim. Asserted by converting twice and deep-comparing.
    const f = form({ freq: 'weekly', weekdays: ['TU'], endMode: 'count', count: 3 });
    expect(formToRule(f, MON, TZ, false)).toEqual(formToRule(f, MON, TZ, false));
  });

  it('the error carries no rule data that could reach a row', () => {
    // It is a sentence and a reason. Nothing about it is persisted: the save
    // is abandoned when it is thrown.
    const e = thrown(CASES[0]!.input) as RecurrenceFormError;
    // `name` is an own property because the constructor assigns it, which is
    // what every error class in this app does; `message` stays on Error.
    expect(Object.keys({ ...e }).sort()).toEqual(
      ['code', 'hasCustomMessage', 'messageKey', 'name', 'reason'].sort(),
    );
    // Nothing from the form travelled with it.
    for (const field of ['freq', 'interval', 'weekdays', 'endMode', 'count', 'untilDate']) {
      expect(e, field).not.toHaveProperty(field);
    }
  });

  it('the save is abandoned on a refusal, not persisted with a default', () => {
    // EventDialog returns null from readForm, so buildSaveResult yields null
    // and nothing is written.
    const dlg = code('features/event/EventDialog.tsx');
    const block = dlg.slice(dlg.indexOf('const rule = formToRule'), dlg.indexOf('return { content, time, rrule }'));
    expect(block).toMatch(/catch \(e\) \{/);
    // P6 step 8: the cause is kept and read at render instead of being
    // flattened to a sentence here. The save is still abandoned the same way.
    expect(block).toContain("setFormError({ kind: 'caught', cause: e })");
    expect(block).toMatch(/return null/);
  });
});

describe('the two components still show what they showed', () => {
  it('EventDialog now localizes it, and the Japanese is unchanged', () => {
    // P6 step 8 replaced the `errorMessage` helper with a stored cause read
    // through eventFormErrorText at render. A RecurrenceFormError reaches it
    // as the 'caught' variant, so caughtErrorText sees a DomainError and calls
    // localize(language) -- which in Japanese is byte-identical to the
    // `.message` the helper used to show.
    const dlg = code('features/event/EventDialog.tsx');
    expect(dlg).not.toMatch(/errorMessage/);
    expect(dlg).toContain('eventFormErrorText(formError, language)');
    for (const { reason, ja } of CASES) {
      const e = new RecurrenceFormError(reason);
      expect(eventFormErrorText({ kind: 'caught', cause: e }, 'ja'), reason).toBe(ja);
      expect(eventFormErrorText({ kind: 'caught', cause: e }, 'ja'), reason).toBe(e.message);
    }
  });

  it('RecurrenceEditor has no error path of its own to change', () => {
    // It is an input component; the form is validated on save, in the dialog.
    // Worth pinning, because "the editor shows the error" is the intuitive
    // assumption and it is wrong.
    const ed = code('features/event/RecurrenceEditor.tsx');
    expect(ed).not.toMatch(/formToRule|RecurrenceFormError|catch/);
  });

  it('the switch is ON, so an English owner now sees these in English', () => {
    expect(LANGUAGE_SWITCH_ENABLED).toBe(true);
    for (const { reason, en } of CASES) {
      expect(new RecurrenceFormError(reason).localize('en'), reason).toBe(en);
    }
  });

  it('no dictionary key was added for this step', () => {
    // The three sentences already existed and were audited in P5. Only who
    // decides when to render them changed.
    //   P8-finish-3a.1 (K13) added exactly one, 'recurrence.intervalInvalid',
    // for an interval outside 1..9999 (recurrenceInterval.test.ts). The set is
    // still pinned exactly, so any other addition fails here as before.
    //   P8-finish-3a.2 (K14) added exactly one more, 'recurrence.countInvalid'
    // (recurrenceCount.test.ts), and K17 one more, 'recurrence.untilOutOfRange'
    // (a timed series cannot end after 9999-12-30; recurrenceCount.test.ts).
    const keys = [...code('features/event/recurrenceForm.ts').matchAll(/t\('([\w.]+)'/g)].flatMap(
      (m) => (m[1] ? [m[1]] : []),
    );
    expect(new Set(keys)).toEqual(
      new Set([
        'recurrence.intervalTooSmall',
        'recurrence.intervalInvalid',
        'recurrence.countTooSmall',
        'recurrence.countInvalid',
        'recurrence.untilRequired',
        'recurrence.untilOutOfRange',
      ]),
    );
  });

  it('both languages render all three keys non-empty', () => {
    for (const lang of LANGUAGES) {
      for (const { reason } of CASES) {
        const s = new RecurrenceFormError(reason).localize(lang);
        expect(s, `${lang}:${reason}`).not.toBe('');
        expect(s, `${lang}:${reason}`).not.toMatch(/\{\w+\}/);
      }
    }
  });
});
