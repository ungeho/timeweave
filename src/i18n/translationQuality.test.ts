import { describe, expect, it } from 'vitest';
import { t } from './t';
import { ja } from './ja';
import { en } from './en';
import { retryAdvice } from '../errors';

/**
 * P5 step 1: the English translation-quality audit, as tests.
 *
 * Each finding the audit acted on is pinned here, so it cannot regress; each
 * finding it DECIDED NOT to act on is pinned too, so the decision is a record
 * rather than an omission someone rediscovers.
 *
 * This file checks the English as English. The safety MEANINGS it must carry
 * are already covered per-surface (shareUi, eventUi, calendarUi, settingsUi,
 * pureModules, auditFix); the few restated here are the ones a wording fix in
 * this step came close to.
 */

const KEYS = Object.keys(ja) as (keyof typeof ja)[];
const JP = /[ぁ-んァ-ン一-龯]/;

describe('dictionary integrity', () => {
  it('the key sets match, both ways', () => {
    expect(Object.keys(en).sort()).toEqual(Object.keys(ja).sort());
  });

  it('every placeholder set matches, per key', () => {
    const vars = (s: string) =>
      [...s.matchAll(/\{(\w+)\}/g)].map((m) => m[1]).sort().join(',');
    for (const k of KEYS) expect(vars(en[k]), String(k)).toBe(vars(ja[k]));
  });

  it('no English value is empty, padded by accident, or still Japanese', () => {
    for (const k of KEYS) {
      expect(en[k], String(k)).not.toBe('');
      expect(en[k], String(k)).not.toMatch(JP);
      // Four keys are sentence FRAGMENTS joined around a <strong> or after a
      // separator, so they legitimately start or end with one space. Nothing
      // else may, and none may carry two.
      expect(en[k], String(k)).not.toMatch(/^\s\s|\s\s$|\s\s/);
    }
  });

  it('the fragments that may carry a leading or trailing space are these four', () => {
    const padded = KEYS.filter((k) => /^\s|\s$/.test(en[k])).sort();
    expect(padded).toEqual([
      'share.error.notFreeNote',
      'shareDialog.created.warnBefore',
      'shareDialog.note.deleteBody',
      'shareDialog.note.revokeBody',
      'shareDialog.toggleUpdating',
    ]);
  });

  it('no English value is left identical to the Japanese except pure patterns', () => {
    // The implementation plan's P5 condition was "zero identical keys". Three
    // are identical and correctly so: they contain no words at all, only
    // placeholders and punctuation. The condition is really "zero identical
    // keys that contain translatable TEXT", and this is that condition.
    const identical = KEYS.filter((k) => en[k] === ja[k]).sort();
    expect(identical).toEqual([
      'calendar.chip.ariaLabel', // "{title}, {visibility}" -- the comma is
      // deliberate in both languages: a screen reader pauses on it.
      'share.label.count', // "{count} / {max}"
      'share.link.status', // "{label} — {status}"
    ]);
    for (const k of identical) {
      expect(en[k].replace(/\{\w+\}/g, '').trim(), String(k)).toMatch(/^[\s,/—-]*$/);
    }
  });
});

/**
 * THE PLURAL FINDING, which was the audit's most concrete defect.
 *
 * `retryAdvice` does `Math.ceil(seconds / 60)`, so ANY window of 60 seconds or
 * less renders `{minutes}` as 1 -- which made "about 1 minutes" the ordinary
 * output rather than an edge case. English has no invariant plural noun and
 * this layer has no plural rules, so the fix is an abbreviated unit.
 */
describe('the retry advice is grammatical at every count', () => {
  it('one second and one minute read correctly', () => {
    expect(retryAdvice(1, 'en')).toBe('Please try again in about 1 sec');
    expect(retryAdvice(60, 'en')).toBe('Please try again in about 1 min');
  });

  it('many read correctly too, with the same unit', () => {
    expect(retryAdvice(45, 'en')).toBe('Please try again in about 45 sec');
    expect(retryAdvice(180, 'en')).toBe('Please try again in about 3 min');
  });

  it('no count is ever followed by a plural noun in English', () => {
    // The shape that would break: a digit, a space, a word ending in s.
    for (const n of [1, 2, 30, 59, 60, 61, 120, 3600]) {
      expect(retryAdvice(n, 'en'), String(n)).not.toMatch(/\b\d+ \w+s\b/);
    }
  });

  it('the boundaries did not move', () => {
    // The wording changed; the arithmetic did not.
    expect(retryAdvice(null, 'en')).toBe('Please wait a moment and try again');
    expect(retryAdvice(0, 'en')).toBe('Please wait a moment and try again');
    expect(retryAdvice(59, 'en')).toMatch(/59 sec$/);
    expect(retryAdvice(61, 'en')).toMatch(/2 min$/);
  });

  it('the Japanese is untouched, where the plural was never a problem', () => {
    expect(retryAdvice(1)).toBe('約1秒後にもう一度お試しください');
    expect(retryAdvice(60)).toBe('約1分後にもう一度お試しください');
  });

  it('the advice is carried into every message that embeds it', () => {
    for (const k of [
      'error.writeRateLimited',
      'error.freeBusyRateLimited',
      'error.freeBusyBusy',
      'error.shareLinkRateLimited',
    ] as const) {
      const s = t(k, 'en', { advice: retryAdvice(60, 'en') });
      expect(s, k).not.toMatch(/\{advice\}/);
      expect(s, k).toContain('1 min');
      expect(s, k).not.toMatch(/\b\d+ \w+s\b/);
    }
  });
});

describe('no remaining count sits next to a plural noun', () => {
  it('not where the count is a RUNTIME value', () => {
    // These three come from the server or from the data, so 1 is reachable and
    // the noun after them has to be invariant -- which is why the retry keys
    // abbreviate their unit and the overflow keys omit theirs.
    const runtime = KEYS.filter((k) => /\{(count|seconds|minutes)\}/.test(ja[k]));
    expect(runtime.length).toBeGreaterThan(3);
    for (const k of runtime) {
      expect(en[k], String(k)).not.toMatch(/\{(count|seconds|minutes)\} \w+s\b/);
    }
  });

  it('`{max}` is exempt, because every ceiling it carries is a constant far above 1', () => {
    // "must be {max} characters or fewer" would be wrong at max = 1. The four
    // ceilings are TITLE_MAX 200, CATEGORY_MAX 50, DESCRIPTION_MAX 2000 and
    // SHARE_LABEL_MAX 50 -- compile-time constants, none of them 1. Recorded
    // as an exemption rather than left as an unexplained pass: a future limit
    // of 1 would need the noun handled.
    const maxKeys = KEYS.filter((k) => /\{max\}/.test(ja[k])).sort();
    expect(maxKeys).toEqual([
      'content.categoryTooLong',
      'content.descriptionTooLong',
      'content.titleTooLong',
      'share.label.count',
      'share.label.tooLong',
    ]);
    for (const k of maxKeys) {
      if (k === 'share.label.count') continue; // pure pattern, no nouns
      expect(en[k], String(k)).toMatch(/\{max\} characters or fewer$/);
    }
  });
});

/**
 * TERMINOLOGY. The same thing must be called the same thing in a button, in
 * the label above it and in the sentence explaining it.
 */
describe('terminology is consistent across surfaces', () => {
  it('the availability control is named for what it decides', () => {
    // "Status: Busy" reads as the status of the save. The column is called
    // `availability`, the options are Busy and Available, and this is the one
    // control where that distinction has to be unmistakable.
    expect(en['event.field.availability']).toBe('Availability');
    expect(en['event.field.availability']).not.toMatch(/^Status$/);
  });

  it('"open time" is the phrase for Available everywhere it is spelled out', () => {
    for (const k of [
      'share.available.empty',
      'sharePage.footer.withAvailable',
      'calendar.availableTitle',
      'shareDialog.sub.availableShared',
      'shareDialog.sub.availableHidden',
    ] as const) {
      expect(en[k], k).toMatch(/open time/i);
    }
  });

  it('the three visibility options keep their stored value in the label', () => {
    expect(en['event.visibility.private']).toBe('Private (private)');
    expect(en['event.visibility.busyOnly']).toBe('Busy only (busy_only)');
    expect(en['event.visibility.public']).toBe('Public (public)');
  });

  it('revoke and delete are never each other, in button or in prose', () => {
    expect(en['shareDialog.revoke']).toBe('Revoke');
    expect(en['shareDialog.delete']).toBe('Delete');
    expect(en['shareDialog.note.revokeTerm']).toBe('Revoking');
    expect(en['shareDialog.note.deleteTerm']).toBe('Deleting');
    // The status word matches the verb that produces it.
    expect(en['shareDialog.status.revoked']).toBe('Revoked');
    expect(en['shareDialog.status.expired']).toBe('Expired');
  });

  it('expiry is "expired", never "revoked", and the hint keeps them apart', () => {
    const hint = en['shareDialog.expiredHint'];
    expect(hint).toMatch(/expired/i);
    expect(hint).toMatch(/revoke it first/i);
  });

  it('the two edit scopes are the only two, and each names itself', () => {
    // EditScope is 'only' | 'all'. There is no "this and following" option in
    // this app, so there is no third wording to audit.
    expect(en['event.scope.only']).toBe('This occurrence only');
    expect(en['event.scope.all']).toBe('All occurrences');
    const scopeKeys = (Object.keys(ja) as string[])
      .filter((k) => k.startsWith('event.scope.') && k !== 'event.scope.label')
      .sort();
    expect(scopeKeys).toEqual(['event.scope.all', 'event.scope.only']);
  });

  it('a label and the heading it opens use one key, not two spellings', () => {
    // The header button and the dialog title are the same destination.
    expect(en['settings.title']).toBe('Settings');
  });
});

/**
 * ENGLISH AS ENGLISH. The findings this step fixed, and the shapes that would
 * reintroduce them.
 */
describe('the English reads as English', () => {
  it('nothing says "busy" about the server, where Busy means availability', () => {
    expect(en['error.freeBusyBusy']).toMatch(/already being calculated/i);
    expect(en['error.freeBusyBusy']).not.toMatch(/is busy/i);
  });

  it('no message tells the user to "try the operation again"', () => {
    // A translation-ism: English just says "try again".
    for (const k of KEYS) expect(en[k], String(k)).not.toMatch(/try the operation/i);
  });

  it('the anonymous page uses no recurrence jargon', () => {
    // "cannot be expanded" meant RRULE expansion to a reader who has never
    // heard of it. It still has to say the picture is incomplete.
    const s = en['sharePage.incompleteWarning'];
    expect(s).not.toMatch(/expand/i);
    expect(s).toMatch(/could not be included/i);
    expect(s).toMatch(/not necessarily free/i);
  });

  it('the unset time zone is described the same way in both places', () => {
    expect(en['settings.timezone.hint']).toMatch(/no time zone/i);
    expect(en['settings.timezone.unsetNotice']).toMatch(/no time zone is set/i);
    expect(en['settings.timezone.hint']).not.toMatch(/go back to not set/i);
  });

  it('the URL warning is idiomatic and still emphasises the right span', () => {
    const joined =
      en['shareDialog.created.warnBefore'] +
      en['shareDialog.created.warnEmphasis'] +
      en['shareDialog.created.warnAfter'];
    expect(joined).toBe(
      'This URL is shown only once. Once you close this it cannot be shown again ' +
        '(the token is not stored), so copy it now if you need it.',
    );
    expect(en['shareDialog.created.warnEmphasis']).toBe('only once');
    // The promise that made the split necessary.
    expect(joined).toMatch(/cannot be shown again/i);
    expect(joined).toMatch(/not stored/i);
  });

  it('quotation marks are typographic, matching the apostrophes', () => {
    // This file already uses ’ in "browser’s". A straight " beside it is the
    // kind of inconsistency nobody reports and everybody notices.
    expect(en['share.error.notFreeNote']).toContain('“no events”');
    for (const k of KEYS) expect(en[k], String(k)).not.toContain('"');
  });

  it('"e.g." is followed by lower case', () => {
    expect(en['shareDialog.labelPlaceholder']).toBe('e.g. for client A');
  });

  it('the language setting is described in the right word order', () => {
    // Was the pending notice, removed at the end of P6 when its claim became
    // false. The remaining language sentence leads with its subject too.
    expect(en['settings.language.notInCalculation']).toMatch(/^The language setting /);
  });

  it('no English value is long enough to break a narrow control', () => {
    // Buttons, option labels and field labels only. Sentences are exempt --
    // they wrap. 40 characters is roughly the widest the 460px modal takes.
    const shortKeys = KEYS.filter((k) =>
      /^(common\.\w+|calendar\.(view\.\w+|today|prev|next)|shareDialog\.(status\.\w+|revoke|delete|deleteConfirm|create)|event\.(field|scope)\.\w+|recurrence\.(freq|end)\.\w+|settings\.timezone\.confirmApply)$/.test(
        String(k),
      ),
    );
    expect(shortKeys.length).toBeGreaterThan(20);
    for (const k of shortKeys) expect(en[k].length, `${k}: ${en[k]}`).toBeLessThanOrEqual(40);
  });

  it('every English sentence that ends a thought ends it the same way as the Japanese', () => {
    // Not a style rule: a key whose Japanese ends in 。 and whose English has
    // no full stop is usually a fragment that lost its other half.
    //
    // Trimmed first, because a trailing space here is a LAYOUT separator, not
    // a missing full stop: shareDialog.note.revokeBody ends a sentence and is
    // followed immediately by the next <strong>, with the newline between them
    // dropped by JSX. The previous test pins which keys may carry such a space.
    for (const k of KEYS) {
      if (!/。$/.test(ja[k])) continue;
      expect(en[k].trimEnd(), String(k)).toMatch(/[.!?)]$/);
    }
  });
});

/**
 * THE AUDIT'S DECISIONS NOT TO ACT. Recorded so they read as choices.
 */
describe('what the audit left alone, and why', () => {
  it('the three unused keys are still present and still three', () => {
    // Not deleted: the brief says to confirm their purpose first. Two are
    // composition patterns the dialogs never needed; one duplicates
    // calendar.untitled. (The four legend keys were here until P8-mobile-2
    // put the legend on the share page.)
    const MODULES = import.meta.glob('/src/**/*.{ts,tsx}', {
      query: '?raw',
      import: 'default',
      eager: true,
    }) as Record<string, string>;
    const blob = Object.entries(MODULES)
      .filter(([p]) => !p.includes('.test.'))
      .filter(([p]) => !/\/i18n\/(ja|en|dictionaries)\.ts$/.test(p))
      .map(([, text]) => text)
      .join('\n');
    const unused = (Object.keys(ja) as string[]).filter((k) => !blob.includes(`'${k}'`)).sort();
    expect(unused).toEqual([
      'event.untitled',
      'share.label.count',
      'share.link.status',
    ]);
  });

  it('weekday and month names are still absent from the dictionary', () => {
    const dateKeys = (Object.keys(ja) as string[]).filter((k) =>
      /^(weekday|month|date|time)\./.test(k),
    );
    expect(dateKeys).toEqual([]);
  });

  it('the Japanese dictionary was not touched by this step', () => {
    // The audit's licence covered the English. Two spot checks on strings the
    // English fixes sat next to.
    expect(ja['error.retry.minutes']).toBe('約{minutes}分後にもう一度お試しください');
    expect(ja['event.field.availability']).toBe('状態');
    expect(ja['calendar.timed']).toBe('時刻あり');
    expect(ja['error.freeBusyBusy']).toBe('空き時間の計算が混み合っています。{advice}');
  });

  it('the 24-hour clock decision from P4 is untouched', () => {
    // No key names a clock format, and none may: the format lives in
    // utils/datetime.ts as CLOCK_24H.
    for (const k of KEYS) expect(en[k], String(k)).not.toMatch(/\bAM\b|\bPM\b|am\/pm/);
  });
});
