/**
 * P6 step 6: the share dialog's error line is resolved at render.
 *
 * This was the largest of the four frozen-error sites and the only one with
 * more than one SOURCE of wording. Five catches filled `error` from
 * `e.message`; a sixth path filled it from `labelLengthError`, a sentence with
 * a number interpolated into it; and two more paths filled a separate `notice`
 * slot from `tr(...)`. All eight froze their text at the moment they were set,
 * so a language change afterwards re-rendered every other string in the dialog
 * and left these behind.
 *
 * WHAT IS TESTED HERE is the decision, which lives in `features/share/
 * shareError.ts` -- vitest runs with `environment: 'node'` and jsdom is not
 * added, so the dialog itself cannot be rendered. The wiring in the component
 * is asserted structurally, and the share-safety invariants are asserted as
 * NEGATIVES: this step must not have touched anything that decides disclosure.
 */

import { describe, expect, it } from 'vitest';
import {
  shareDialogErrorText,
  type ShareDialogError,
  type ShareDialogNotice,
} from '../features/share/shareError';
import {
  SHARE_LABEL_MAX,
  labelLengthError,
  labelTooLongMessage,
} from '../features/share/shareLinkLabel';
import {
  EventQuotaExceededError,
  ShareLinkActiveQuotaExceededError,
  ShareLinkRateLimitedError,
  ShareLinkTotalQuotaExceededError,
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

const caught = (cause: unknown): ShareDialogError => ({ kind: 'caught', cause });
const tooLong: ShareDialogError = { kind: 'labelTooLong', max: SHARE_LABEL_MAX };

const NOTICES: ShareDialogNotice[] = [
  'shareDialog.deleteRefused',
  'shareDialog.availableRefused',
];

// ---------------------------------------------------------------------------

describe('all five catch paths render through one helper', () => {
  it('each repository failure is carried as a cause, not a sentence', () => {
    // The five are listShareLinks, createShareLink, revokeShareLink,
    // deleteShareLink and setShareAvailable. They are indistinguishable to the
    // error line -- which is the point: the dialog stores what was thrown and
    // the helper decides the words.
    const dlg = code('features/share/ShareDialog.tsx');
    const stores = dlg.split("setError({ kind: 'caught', cause: e })").length - 1;
    expect(stores).toBe(5);
    expect(dlg).not.toMatch(/instanceof Error \? e\.message : String\(e\)/);
    expect(dlg).not.toMatch(/String\(e\)/);
  });

  it('a DomainError from any share path localizes', () => {
    for (const e of [
      new ShareLinkRateLimitedError(10),
      new ShareLinkActiveQuotaExceededError(),
      new ShareLinkTotalQuotaExceededError(),
      new EventQuotaExceededError(),
    ]) {
      // Japanese is what the dialog showed before: `.message` IS the Japanese
      // rendering for a default-constructed domain error.
      expect(shareDialogErrorText(caught(e), 'ja'), e.name).toBe(e.message);
      expect(shareDialogErrorText(caught(e), 'en'), e.name).not.toMatch(JAPANESE);
      expect(shareDialogErrorText(caught(e), 'en'), e.name).not.toBe(
        shareDialogErrorText(caught(e), 'ja'),
      );
    }
  });

  it('a rate-limit refusal keeps its interpolated wait in both languages', () => {
    // The advice travels as a variable, so a half-translated sentence is the
    // specific failure to rule out here.
    expect(shareDialogErrorText(caught(new ShareLinkRateLimitedError(45)), 'en')).toMatch(
      /45 sec\b/,
    );
    expect(shareDialogErrorText(caught(new ShareLinkRateLimitedError(45)), 'ja')).toMatch(/45秒/);
  });

  it('a custom message is shown verbatim, never translated', () => {
    const e = new ShareLinkTotalQuotaExceededError('bespoke wording');
    expect(e.hasCustomMessage).toBe(true);
    for (const lang of LANGUAGES) {
      expect(shareDialogErrorText(caught(e), lang), lang).toBe('bespoke wording');
    }
  });

  it('a plain Error keeps its message, as before', () => {
    const e = new Error('28000: JWT expired');
    for (const lang of LANGUAGES) {
      expect(shareDialogErrorText(caught(e), lang), lang).toBe('28000: JWT expired');
    }
  });
});

describe('the validation path holds the fact, not the sentence', () => {
  it('the Japanese is exactly what labelLengthError produced', () => {
    // The rule did not move -- shareLinkLabel still owns it, and this is the
    // same sentence it returns. Only WHEN it is rendered changed.
    const before = labelLengthError('a'.repeat(SHARE_LABEL_MAX + 1));
    expect(before).not.toBeNull();
    expect(shareDialogErrorText(tooLong, 'ja')).toBe(before);
  });

  it('it renders in English with the ceiling intact', () => {
    const en = shareDialogErrorText(tooLong, 'en');
    expect(en).not.toMatch(JAPANESE);
    expect(en).toContain(String(SHARE_LABEL_MAX));
    expect(en).not.toMatch(/\{\w+\}/);
  });

  it('the number comes from the state, so it cannot drift from the rule', () => {
    // `max` travels with the error rather than being re-read at render, and
    // the helper quotes whatever it was handed.
    expect(shareDialogErrorText({ kind: 'labelTooLong', max: 7 }, 'ja')).toContain('7');
    expect(shareDialogErrorText({ kind: 'labelTooLong', max: 7 }, 'en')).toContain('7');
  });

  it('the key lives in exactly one place', () => {
    // labelTooLongMessage was extracted so the dialog did not have to repeat
    // `t('share.label.tooLong', lang, { max })` itself.
    expect(shareDialogErrorText(tooLong, 'en')).toBe(labelTooLongMessage(SHARE_LABEL_MAX, 'en'));
    expect(code('features/share/ShareDialog.tsx')).not.toMatch(/share\.label\.tooLong/);
    const labelKeys = [
      ...code('features/share/shareLinkLabel.ts').matchAll(/t\('([\w.]+)'/g),
    ].flatMap((m) => (m[1] ? [m[1]] : []));
    expect(labelKeys).toEqual(['share.label.tooLong']);
  });

  it('labelLengthError keeps its old contract for its other callers', () => {
    // It is asserted directly in shareLinkLabel.test.ts and auditFix, so
    // delegating internally must not have changed what it returns.
    expect(labelLengthError(null)).toBeNull();
    expect(labelLengthError('a'.repeat(SHARE_LABEL_MAX))).toBeNull();
    expect(labelLengthError('a'.repeat(SHARE_LABEL_MAX + 1))).toBe(
      labelTooLongMessage(SHARE_LABEL_MAX),
    );
    expect(labelLengthError('a'.repeat(SHARE_LABEL_MAX + 1), 'en')).toBe(
      labelTooLongMessage(SHARE_LABEL_MAX, 'en'),
    );
  });

  it('the dialog still asks the rule before storing anything', () => {
    const dlg = code('features/share/ShareDialog.tsx');
    expect(dlg).toContain('labelLengthError(label) !== null');
    expect(dlg).toContain("setError({ kind: 'labelTooLong', max: SHARE_LABEL_MAX })");
    // And it still returns without calling the RPC.
    const create = dlg.slice(dlg.indexOf('const handleCreate'), dlg.indexOf('const handleRevoke'));
    expect(create.indexOf('labelLengthError')).toBeLessThan(create.indexOf('createShareLink'));
    expect(create).toMatch(/return;/);
  });
});

describe('the two notices follow the language too', () => {
  it('they are stored as keys, not as rendered text', () => {
    const dlg = code('features/share/ShareDialog.tsx');
    expect(dlg).toContain("setNotice('shareDialog.deleteRefused')");
    expect(dlg).toContain("setNotice('shareDialog.availableRefused')");
    expect(dlg).not.toMatch(/setNotice\(tr\(/);
    expect(dlg).toMatch(/\{tr\(notice\)\}/);
  });

  it('both render in both languages, with no Japanese left in English', () => {
    for (const key of NOTICES) {
      expect(t(key, 'ja'), key).toMatch(JAPANESE);
      expect(t(key, 'en'), key).not.toMatch(JAPANESE);
      expect(t(key, 'en'), key).not.toBe(t(key, 'ja'));
    }
  });

  it('a refusal still reads as a RESOLVED state, not an action to retry', () => {
    // 0015 returning false means the row was already gone -- another tab, most
    // likely -- so it is not a failure and goes to `notice`. What makes both
    // sentences notices rather than errors is that each names a likely cause
    // AND says the list was refreshed: nothing is left for the owner to do.
    // That has to survive translation, which is the part a fluent rewrite
    // would drop as redundant.
    expect(t('shareDialog.deleteRefused', 'ja')).toContain('一覧を更新しました');
    expect(t('shareDialog.availableRefused', 'ja')).toContain('一覧を更新しました');
    expect(t('shareDialog.deleteRefused', 'en')).toMatch(/list has been refreshed/i);
    expect(t('shareDialog.availableRefused', 'en')).toMatch(/list has been refreshed/i);

    // And each still names its own likely cause.
    expect(t('shareDialog.deleteRefused', 'ja')).toContain('すでに削除された');
    expect(t('shareDialog.deleteRefused', 'en')).toMatch(/already been deleted/i);
    expect(t('shareDialog.availableRefused', 'ja')).toContain('失効');
    expect(t('shareDialog.availableRefused', 'en')).toMatch(/expired or revoked/i);

    const dlg = code('features/share/ShareDialog.tsx');
    expect(dlg).toMatch(/if \(!deleted\) setNotice\('shareDialog\.deleteRefused'\)/);
    expect(dlg).toMatch(/if \(!applied\) setNotice\('shareDialog\.availableRefused'\)/);
  });

  it('the notice line keeps its live-region role', () => {
    expect(source('features/share/ShareDialog.tsx')).toMatch(
      /className="share-notice" role="status"/,
    );
  });
});

describe('a language change updates the display and nothing else', () => {
  it('the same stored error reads differently in each language', () => {
    const e = caught(new ShareLinkActiveQuotaExceededError());
    expect(shareDialogErrorText(e, 'ja')).not.toBe(shareDialogErrorText(e, 'en'));
    // And is stable within a language.
    expect(shareDialogErrorText(e, 'ja')).toBe(shareDialogErrorText(e, 'ja'));
    // The validation variant too.
    expect(shareDialogErrorText(tooLong, 'ja')).not.toBe(shareDialogErrorText(tooLong, 'en'));
  });

  it('no share API is reachable from the display path', () => {
    // A language change re-renders; it must not create, revoke, delete or
    // toggle anything. The helper and its two dependencies touch no
    // repository, so a re-render cannot call one.
    for (const p of ['features/share/shareError.ts', 'i18n/errorText.ts']) {
      const mod = code(p);
      expect(mod, p).not.toMatch(/repositor|supabase|createShareLink|revokeShareLink/i);
      expect(mod, p).not.toMatch(/deleteShareLink|setShareAvailable|listShareLinks/);
    }
  });

  it('the dialog fetches on mount only, with no language dependency', () => {
    // The effect's dependency list is empty, as it was. `language` is read for
    // rendering and is not a dependency of anything that calls out.
    const dlg = code('features/share/ShareDialog.tsx');
    expect(dlg).toMatch(/useEffect\(\(\) => \{\s*void refresh\(\);\s*\}, \[\]\);/);
    expect(dlg).not.toMatch(/\[language\]/);
    expect(dlg).not.toMatch(/useEffect[\s\S]{0,200}language/);
  });

  it('the helper is pure: no hook, no React, no module-level resolution', () => {
    const mod = code('features/share/shareError.ts');
    expect(mod).not.toMatch(/useTranslate|useLanguage|from 'react'/);
    expect(mod).toMatch(/lang: Language = DEFAULT_LANGUAGE/);
    expect(mod).not.toMatch(/^(export )?const \w+ = t\(/m);
  });

  it('called with no language it answers in Japanese', () => {
    expect(shareDialogErrorText(tooLong)).toBe(shareDialogErrorText(tooLong, 'ja'));
    expect(shareDialogErrorText(caught(new Error('x')))).toBe('x');
  });
});

describe('null, undefined and unknown throws keep the error visible', () => {
  it.each([
    ['null', null],
    ['undefined', undefined],
    ['a string', 'TypeError: Failed to fetch'],
    ['a number', 0],
    ['an object', { code: 'PGRST301' }],
  ])('%s still produces a sentence', (_label, cause) => {
    for (const lang of LANGUAGES) {
      const got = shareDialogErrorText(caught(cause), lang);
      expect(got, lang).toBe(t('error.unknownCause', lang));
      expect(got, lang).not.toBe('');
    }
  });

  it('the tagged state is why a null cause is still an error', () => {
    // The dialog's test is `error && ...`. A bare `unknown | null` would have
    // made `throw null` indistinguishable from success and the line would
    // simply not appear for a failure that did happen.
    const mod = code('features/share/shareError.ts');
    expect(mod).toMatch(/readonly kind: 'caught'/);
    expect(mod).toMatch(/readonly cause: unknown/);
    const dlg = code('features/share/ShareDialog.tsx');
    expect(dlg).toMatch(/\{error && <p className="form-error">/);
  });

  it('the thrown value never reaches the screen', () => {
    // A share error line is the last place to stringify an arbitrary object:
    // a token or a session detail could be anywhere in it.
    const leaky = {
      token: 'tw_live_abc123',
      toString: () => 'tw_live_abc123',
    };
    for (const lang of LANGUAGES) {
      expect(shareDialogErrorText(caught(leaky), lang), lang).not.toContain('tw_live_');
    }
  });

  it('no share token or URL is interpolated into any error wording', () => {
    // The plaintext token is shown exactly once, in its own field, right after
    // creation. It must not also arrive via an error.
    const mod = code('features/share/shareError.ts');
    expect(mod).not.toMatch(/token|shareUrl|justCreated/i);
    for (const lang of LANGUAGES) {
      for (const e of [caught(new Error('boom')), tooLong, caught(null)]) {
        expect(shareDialogErrorText(e, lang)).not.toMatch(/\/s\/|https?:/);
      }
    }
  });
});

/**
 * The invariants this step must not have touched. All negatives: the error
 * line is wording, and wording has no business near disclosure.
 */
describe('the share semantics are untouched', () => {
  it('neither opt-in is named by anything this step added', () => {
    for (const p of ['features/share/shareError.ts', 'i18n/errorText.ts']) {
      const mod = code(p);
      expect(mod, p).not.toMatch(/shareAvailable|share_available/);
      expect(mod, p).not.toMatch(/includePrivate|include_private/);
    }
  });

  it('the dialog still keeps the two opt-ins independent', () => {
    // Two separate pieces of state, and create() passes both. All four
    // combinations remain legal.
    const dlg = code('features/share/ShareDialog.tsx');
    expect(dlg).toMatch(/const \[includePrivate, setIncludePrivate\] = useState\(true\)/);
    expect(dlg).toMatch(/shareAvailable: shareAvailableNew/);
    expect(dlg).toMatch(/includePrivate,/);
  });

  it('revoke, delete and the toggle still use their own repository calls', () => {
    const dlg = code('features/share/ShareDialog.tsx');
    expect(dlg).toMatch(/await revokeShareLink\(id\)/);
    expect(dlg).toMatch(/await deleteShareLink\(id\)/);
    expect(dlg).toMatch(/await setShareAvailable\(l\.id, next\)/);
    expect(dlg).toMatch(/await createShareLink\(\{/);
    expect(dlg).toMatch(/await listShareLinks\(\)/);
  });

  it('the in-flight guards and non-optimistic refresh are unchanged', () => {
    const dlg = code('features/share/ShareDialog.tsx');
    expect(dlg).toMatch(/if \(deletingRef\.current !== null\) return/);
    expect(dlg).toMatch(/if \(togglingRef\.current !== null \|\| deletingRef\.current !== null\) return/);
    // The list is refetched rather than patched in place.
    expect(dlg).toMatch(/setLinks\(await listShareLinks\(\)\)/);
  });

  it('the delete-eligibility and status rules still come from shareLinkState', () => {
    const dlg = code('features/share/ShareDialog.tsx');
    for (const fn of ['canDeleteShareLink', 'canSetShareAvailable', 'shareLinkStatus', 'visibleShareLinks']) {
      expect(dlg, fn).toContain(fn);
    }
    // And that module learned nothing about language.
    expect(code('features/share/shareLinkState.ts')).not.toMatch(/i18n|Language|\bt\(/);
  });

  it('the error clearing points are unchanged', () => {
    // Every handler clears the error before acting, and refresh clears it
    // before fetching -- so a retry that succeeds leaves no line behind.
    const dlg = code('features/share/ShareDialog.tsx');
    expect(dlg.split('setError(null)').length - 1).toBe(5);
    expect(dlg.split('setNotice(null)').length - 1).toBeGreaterThanOrEqual(5);
    // Anchored FROM the declaration: 'useEffect' also appears in the import
    // line at the top, so searching the whole file for it slices backwards.
    const start = dlg.indexOf('const refresh');
    const refresh = dlg.slice(start, dlg.indexOf('useEffect', start));
    expect(start).toBeGreaterThan(0);
    expect(refresh).toContain('listShareLinks');
    expect(refresh.indexOf('setError(null)')).toBeLessThan(refresh.indexOf('await listShareLinks'));
  });

  it('the anonymous disclosure modules were not touched', () => {
    // This step is the owner's dialog. The viewer's page has its own copy, and
    // its meaning is pinned in sharePage.i18n.test.ts.
    for (const p of [
      'features/share/freeBusyPresentation.ts',
      'features/share/availablePresentation.ts',
      'features/share/freeBusyBanner.ts',
    ]) {
      expect(code(p), p).not.toMatch(/ShareDialogError|shareDialogErrorText|caughtErrorText/);
    }
  });

  it('the switch is ON, so these errors now reach an English owner', () => {
    expect(LANGUAGE_SWITCH_ENABLED).toBe(true);
    expect(shareDialogErrorText(caught(new ShareLinkRateLimitedError(10)), 'en')).not.toMatch(
      JAPANESE,
    );
    expect(shareDialogErrorText(tooLong, 'en')).not.toMatch(JAPANESE);
  });

  it('no dictionary key was added for the share dialog', () => {
    // The sentences already existed. `error.unknownCause` is the one key this
    // pair of steps introduced, and it replaced calendar.loadErrorUnknown
    // rather than adding to it.
    expect(source('i18n/ja.ts')).toContain("'error.unknownCause'");
    expect(source('i18n/ja.ts')).not.toContain('calendar.loadErrorUnknown');
    // The dialog renders its own namespaces plus the shared ones. What would
    // be wrong is a key belonging to ANOTHER feature, which is how copy starts
    // being reused by accident and then reworded for one screen only.
    const dlgKeys = [...code('features/share/ShareDialog.tsx').matchAll(/tr\('([\w.]+)'/g)].flatMap(
      (m) => (m[1] ? [m[1]] : []),
    );
    expect(dlgKeys.length).toBeGreaterThan(0);
    for (const k of dlgKeys) {
      expect(k, k).toMatch(/^(shareDialog|sharePage|share|common)\./);
      expect(k, k).not.toMatch(/^(calendar|event|settings|recurrence|auth)\./);
    }
  });
});
