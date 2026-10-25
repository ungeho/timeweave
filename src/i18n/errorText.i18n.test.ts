/**
 * `caughtErrorText`: what a screen shows for a value a catch received.
 *
 * P6 step 5 introduced this as `features/calendar/loadErrorText`, for the
 * calendar's load banner. Step 6 moved it to `i18n/errorText` because
 * ShareDialog needs the identical decision, and reusing the calendar module
 * would have carried its name ("load" -- nothing is loaded when a revoke
 * fails) and its `calendar.*` fallback key into the share screen. The wording
 * did not change in either language; only where it is keyed did.
 *
 * `useEvents` used to do `setError(e instanceof Error ? e.message : String(e))`
 * -- the sentence decided at the moment of failure and kept in state as a
 * string. That is the same freezing defect P6 step 2 found on the share page,
 * and it was the worse instance of the two: a dialog's error dies when the
 * dialog closes, but this banner sits on the main screen for as long as the
 * failure lasts, so it is the one an owner would actually be looking at when
 * the language changed around it.
 *
 * The share dialog's own wiring is in sharePageError.i18n.test.ts; this file
 * owns the shared helper and the calendar's use of it.
 *
 * NEITHER THE HOOK NOR THE PAGE CAN BE RENDERED HERE -- vitest runs with
 * `environment: 'node'` and jsdom is not added -- so the decision was moved
 * into `loadErrorText`, which this file exercises directly, exactly as
 * `loadState.ts` was extracted from the same hook for the same reason. What is
 * left in the hook and the page is asserted structurally.
 */

import { describe, expect, it } from 'vitest';
import { caughtErrorText } from './errorText';
import {
  EventQuotaExceededError,
  FreeBusyRateLimitedError,
  SeriesEditBlockedError,
  WriteRateLimitedError,
} from '../errors';
import { RecurrenceFormError } from '../features/event/recurrenceForm';
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

/** The banner as CalendarPage composes it. */
const banner = (cause: unknown, lang: 'ja' | 'en') =>
  t('calendar.loadError', lang, { message: caughtErrorText(cause, lang) });

// ---------------------------------------------------------------------------

describe('a DomainError answers through localize', () => {
  it('renders in Japanese and in English', () => {
    const e = new EventQuotaExceededError();
    expect(caughtErrorText(e, 'ja')).toBe(e.localize('ja'));
    expect(caughtErrorText(e, 'en')).toBe(e.localize('en'));
    expect(caughtErrorText(e, 'ja')).toMatch(JAPANESE);
    expect(caughtErrorText(e, 'en')).not.toMatch(JAPANESE);
  });

  it('the Japanese equals what the banner showed before this step', () => {
    // The old code read `.message`, which for a default-constructed domain
    // error IS the Japanese rendering. Nothing on screen moves today.
    for (const e of [
      new EventQuotaExceededError(),
      new SeriesEditBlockedError(),
      new WriteRateLimitedError(30),
      new FreeBusyRateLimitedError('busy', 1),
    ]) {
      expect(caughtErrorText(e, 'ja'), e.name).toBe(e.message);
    }
  });

  it('English actually differs, including the interpolated retry advice', () => {
    for (const e of [
      new EventQuotaExceededError(),
      new SeriesEditBlockedError(),
      new WriteRateLimitedError(30),
    ]) {
      expect(caughtErrorText(e, 'en'), e.name).not.toBe(caughtErrorText(e, 'ja'));
      expect(caughtErrorText(e, 'en'), e.name).not.toMatch(JAPANESE);
    }
    // The advice travels as a variable, so it has to follow the language too
    // or the sentence would be half-translated.
    expect(caughtErrorText(new WriteRateLimitedError(30), 'en')).toMatch(/30 sec\b/);
    expect(caughtErrorText(new WriteRateLimitedError(120), 'en')).toMatch(/2 min\b/);
  });

  it('a domain error from outside errors.ts localizes too', () => {
    // P6 step 4's RecurrenceFormError satisfies DomainError from its own
    // module. isDomainError is structural, so this branch picks it up with no
    // special case -- which was the point of co-locating it.
    const e = new RecurrenceFormError('untilRequired');
    expect(caughtErrorText(e, 'ja')).toBe('終了日を入力してください');
    expect(caughtErrorText(e, 'en')).toBe('Please enter an end date');
  });

  it('a custom message is shown verbatim in both languages', () => {
    // The contract the error classes keep, unchanged by moving the decision
    // out here: an arbitrary string cannot be translated, and replacing it
    // with the generic sentence would discard what the thrower chose to say.
    const e = new EventQuotaExceededError('bespoke wording');
    expect(e.hasCustomMessage).toBe(true);
    for (const lang of LANGUAGES) {
      expect(caughtErrorText(e, lang), lang).toBe('bespoke wording');
    }
  });
});

describe('the wrapper and the detail speak the same language', () => {
  it('both halves are Japanese, or both English', () => {
    // THE MIXING FAILURE THIS PHASE KEEPS FINDING. Before, the wrapper came
    // from tr() and followed the language while the detail was a frozen
    // Japanese string, so an English calendar would have read
    // "Could not load: 予定の上限に達しました".
    const e = new EventQuotaExceededError();
    const ja = banner(e, 'ja');
    expect(ja).toContain('読み込みエラー');
    expect(ja).toMatch(JAPANESE);
    expect(ja).not.toMatch(/[A-Za-z]{4,}/);

    const en = banner(e, 'en');
    expect(en).toContain('Could not load');
    expect(en).not.toMatch(JAPANESE);
  });

  it('no placeholder survives into the rendered banner', () => {
    for (const lang of LANGUAGES) {
      for (const cause of [new EventQuotaExceededError(), new Error('x'), null]) {
        expect(banner(cause, lang), lang).not.toMatch(/\{\w+\}/);
      }
    }
  });

  it('changing the language changes only the words', () => {
    // Same cause in, two sentences out. This is the whole claim of the step:
    // the stored value did not move, its rendering did.
    const cause = new EventQuotaExceededError();
    expect(banner(cause, 'ja')).not.toBe(banner(cause, 'en'));
    // And re-rendering in the same language is stable.
    expect(banner(cause, 'ja')).toBe(banner(cause, 'ja'));
  });
});

describe('a plain Error keeps the message it always showed', () => {
  it('the message is passed through untranslated', () => {
    // Not a domain error, so there is no key to render -- and an arbitrary
    // message is a string somebody chose. Replacing it would lose information
    // the owner can act on.
    const e = new Error('column "foo" does not exist');
    for (const lang of LANGUAGES) {
      expect(caughtErrorText(e, lang), lang).toBe('column "foo" does not exist');
    }
  });

  it('a TypeError or a DOMException-shaped failure is handled the same way', () => {
    expect(caughtErrorText(new TypeError('Failed to fetch'), 'en')).toBe('Failed to fetch');
    expect(caughtErrorText(new RangeError('out of range'), 'ja')).toBe('out of range');
  });

  it('an Error with an empty message yields an empty detail, not a crash', () => {
    expect(caughtErrorText(new Error(''), 'ja')).toBe('');
  });
});

/**
 * The non-Error cases. These are the ones the step's gate asked to be looked
 * at rather than waved through, and the answer is a deliberate narrowing.
 */
describe('anything that is not an Error gets a generic sentence', () => {
  it.each([
    ['null', null],
    ['undefined', undefined],
    ['a string', 'TypeError: Failed to fetch'],
    ['a number', 42],
    ['a plain object', { code: 'PGRST301', hint: 'internal detail' }],
    ['an array', [1, 2, 3]],
    ['a symbol-free class instance', new (class Weird {})()],
  ])('%s', (_label, cause) => {
    for (const lang of LANGUAGES) {
      const got = caughtErrorText(cause, lang);
      expect(got, lang).toBe(t('error.unknownCause', lang));
      expect(got, lang).not.toBe('');
    }
  });

  it('the thrown value never reaches the screen', () => {
    // THE NARROWING. The old code did String(cause): "null", "[object
    // Object]", or -- for an object carrying its own toString -- whatever that
    // returns. None of it helps the owner, and the last is an unbounded
    // stringification of an arbitrary value into the DOM. A non-Error throw is
    // a bug path, not a diagnosis.
    const leaky = {
      secret: 'service_role_key_abc123',
      toString: () => 'service_role_key_abc123',
    };
    for (const lang of LANGUAGES) {
      const got = caughtErrorText(leaky, lang);
      expect(got, lang).not.toContain('service_role_key');
      expect(banner(leaky, lang), lang).not.toContain('service_role_key');
    }
    // And the generic sentence is not an accidental stringification either.
    expect(caughtErrorText({ a: 1 }, 'ja')).not.toContain('object');
  });

  it('the generic sentence exists in both languages and differs', () => {
    expect(t('error.unknownCause', 'ja')).toMatch(JAPANESE);
    expect(t('error.unknownCause', 'en')).not.toMatch(JAPANESE);
    expect(t('error.unknownCause', 'en')).not.toBe(t('error.unknownCause', 'ja'));
  });

  it('it reads sensibly inside the wrapper', () => {
    expect(banner(null, 'ja')).toBe('読み込みエラー: 原因を特定できませんでした');
    expect(banner(null, 'en')).toBe('Could not load: the cause could not be determined');
  });

  it('an unrecognised language still answers, in Japanese', () => {
    const bogus = 'de' as unknown as 'ja';
    expect(caughtErrorText(null, bogus)).toBe(caughtErrorText(null, 'ja'));
    expect(caughtErrorText(new EventQuotaExceededError(), bogus)).toBe(
      caughtErrorText(new EventQuotaExceededError(), 'ja'),
    );
  });

  it('called with no language at all, it answers in Japanese', () => {
    expect(caughtErrorText(null)).toBe(caughtErrorText(null, 'ja'));
    expect(caughtErrorText(new Error('plain'))).toBe('plain');
  });
});

/**
 * The hook. Not renderable here, so these read its source -- which is the same
 * bargain every structural guard in this suite makes.
 */
describe('useEvents holds the cause, and knows nothing about language', () => {
  const hook = code('hooks/useEvents.ts');

  it('the state is a tagged object, so a null cause is still an error', () => {
    // `unknown` includes null, and the consumer's test is `error !== null`.
    // A bare `unknown | null` would have made `throw null` indistinguishable
    // from success and the banner would simply not appear.
    expect(hook).toMatch(/interface EventsLoadError/);
    expect(hook).toMatch(/readonly kind: 'error'/);
    expect(hook).toMatch(/readonly cause: unknown/);
    expect(hook).toMatch(/error: EventsLoadError \| null/);
  });

  it('the catch stores the cause and resolves nothing', () => {
    expect(hook).toMatch(/setError\(\{ kind: 'error', cause: e \}\)/);
    expect(hook).not.toMatch(/instanceof Error \? e\.message : String\(e\)/);
    expect(hook).not.toMatch(/String\(e\)/);
  });

  it('the hook imports no dictionary and names no language', () => {
    // The strongest form of "a language change cannot re-run the fetch":
    // there is nothing in this file for a language to be a dependency of.
    expect(hook).not.toMatch(/i18n|useTranslate|useLanguage|DEFAULT_LANGUAGE|Language/);
    expect(hook).not.toMatch(/\bt\(/);
  });

  it('reload still clears the error before fetching, so a success removes it', () => {
    // Anchored FROM the declaration: 'useEffect' also appears in the import
    // line at the top, so searching the whole file for it slices backwards.
    const start = hook.indexOf('const reload');
    const reload = hook.slice(start, hook.indexOf('useEffect', start));
    expect(start).toBeGreaterThan(0);
    expect(reload).toContain('repo.list()');
    expect(reload.indexOf('setError(null)')).toBeGreaterThan(0);
    // Cleared BEFORE the await, as before -- so a retry that succeeds leaves
    // no banner, and one that fails replaces it.
    expect(reload.indexOf('setError(null)')).toBeLessThan(reload.indexOf('await repo.list()'));
  });

  it('the fetch, its dependencies and its retry conditions are untouched', () => {
    // reload depends on the repository alone, and the effect on reload. No
    // language, so no re-fetch when one changes.
    expect(hook).toMatch(/\}, \[repo\]\);/);
    expect(hook).toMatch(/useEffect\(\(\) => \{\s*void reload\(\);\s*\}, \[reload\]\);/);
    expect(hook).toMatch(/const repo = useMemo\(\(\) => getEventRepository\(\), \[\]\)/);
  });

  it('rows are still replaced only once the new list resolves', () => {
    // What keeps the grid up during a reload (loadState.ts relies on it) and
    // what keeps a failed load from blanking the calendar.
    expect(hook).toMatch(/setRows\(await repo\.list\(\)\)/);
    // The catch does not touch rows, so a failure keeps what was on screen.
    const katch = hook.slice(hook.indexOf('} catch (e) {'), hook.indexOf('} finally {'));
    expect(katch).not.toMatch(/setRows/);
  });

  it('nothing else about the hook changed', () => {
    // The mutation methods all still reload afterwards.
    for (const m of ['create', 'update', 'remove', 'editOccurrence', 'deleteOccurrence', 'setSeriesTimezone']) {
      expect(hook, m).toMatch(new RegExp(`const ${m} = useCallback\\(`));
    }
    expect(hook).toMatch(/expandEvents\(rows, rangeStartIso, rangeEndIso\)/);
  });
});

describe('CalendarPage renders it, and nothing else moved', () => {
  const page = code('features/calendar/CalendarPage.tsx');

  it('it reads the language and resolves at render', () => {
    expect(page).toContain('const { language } = useLanguage()');
    expect(page).toContain('caughtErrorText(events.error.cause, language)');
    expect(page).toContain("tr('calendar.loadError'");
  });

  it('it no longer renders the hook error as a string', () => {
    expect(page).not.toMatch(/\{ message: events\.error \}/);
  });

  it('the banner still appears exactly when there is an error', () => {
    // `error !== null` is still the test, and the tagged object makes it
    // correct for every cause including null.
    expect(page).toMatch(/\{events\.error && \(/);
  });

  it('the first-load placeholder rule is unchanged', () => {
    expect(page).toMatch(/isAwaitingRows\(\{ loading: events\.loading, rowCount: events\.rows\.length \}\)/);
  });

  it('no disclosure decision was touched', () => {
    // An error must not make the calendar show more than it did.
    expect(page).not.toMatch(/visibility|availability|include_private|shareAvailable/i);
  });
});

describe('the module stays pure and the switch stays off', () => {
  it('errorText holds no hook and no React import', () => {
    const mod = code('i18n/errorText.ts');
    expect(mod).not.toMatch(/useTranslate|useLanguage|from 'react'/);
    expect(mod).toMatch(/lang: Language = DEFAULT_LANGUAGE/);
  });

  it('it resolves nothing at import time', () => {
    const mod = code('i18n/errorText.ts');
    expect(mod).not.toMatch(/^(export )?const \w+ = t\(/m);
    expect(mod).not.toMatch(/t\('[\w.]+', DEFAULT_LANGUAGE\)/);
  });

  it('it renders exactly one key, and that key is not namespaced to a screen', () => {
    // `calendar.loadErrorUnknown` before step 6. A share dialog rendering a
    // calendar-namespaced string is correct today and wrong the first time
    // either message is reworded.
    const keys = [...code('i18n/errorText.ts').matchAll(/t\('([\w.]+)'/g)].flatMap((m) =>
      m[1] ? [m[1]] : [],
    );
    expect(keys).toEqual(['error.unknownCause']);
    expect(keys[0]).not.toMatch(/^(calendar|share|event|settings)\./);
  });

  it('the calendar-namespaced key is gone, not merely unused', () => {
    expect(source('i18n/ja.ts')).not.toContain('calendar.loadErrorUnknown');
    expect(source('i18n/en.ts')).not.toContain('calendar.loadErrorUnknown');
  });

  it('the switch is ON, so this helper now decides what a viewer reads', () => {
    // For four phases the provider pinned `language` to Japanese and these
    // branches were a rehearsal. They are live now.
    expect(LANGUAGE_SWITCH_ENABLED).toBe(true);
    expect(caughtErrorText(new EventQuotaExceededError(), 'en')).not.toMatch(JAPANESE);
  });
});
