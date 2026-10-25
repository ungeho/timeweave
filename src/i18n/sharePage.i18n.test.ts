/**
 * P6 step 2: the anonymous share page follows the VIEWER's language.
 *
 * This route is the one place in the app where the reader is a stranger. Every
 * other screen is behind AuthGate, so a pinned Japanese string there is at
 * worst wrong for the owner, who chose the setting. Here the reader never had
 * a setting to choose: their language comes from their own browser, so a
 * sentence resolved at import time was guaranteed to be the wrong language for
 * somebody.
 *
 * TWO CLASSES OF GUARD LIVE HERE, and they are not the same claim:
 *
 *   The Japanese is byte-identical. Called with no argument -- and with 'ja'
 *   explicitly -- every sentence is the string the page has always shown.
 *   This is what makes the step a no-op today.
 *
 *   The SAFETY MEANINGS hold in English too. These sentences are the only
 *   thing standing between a viewer and a wrong booking, and a fluent
 *   translation is exactly how "we could not determine this" quietly becomes
 *   "there is nothing here". Each Japanese guard elsewhere in the suite has an
 *   English twin below.
 *
 * What is NOT tested here is the state machine: which presentation each state
 * maps to is asserted in the two modules' own test files, and this step did not
 * touch it. The tests at the bottom assert that it did not.
 */

import { describe, expect, it } from 'vitest';
import {
  activeEmptyMessage,
  freeBusyPresentation,
  unavailableMessage,
} from '../features/share/freeBusyPresentation';
import {
  availableEmptyMessage,
  availableIndeterminateMessage,
  availablePresentation,
  availableSlots,
  hasDisclosedAvailable,
} from '../features/share/availablePresentation';
import { freeBusyErrorBanner } from '../features/share/freeBusyBanner';
import { hasNoDisclosedBusy } from '../features/share/freeBusyLayout';
import { FreeBusyRateLimitedError } from '../errors';
import { LANGUAGE_SWITCH_ENABLED, LANGUAGES } from './types';
import type { AvailableResult, FreeBusySlot } from '../types/share';

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

/** Any Japanese character: kana, or a CJK ideograph. */
const JAPANESE = /[ぁ-んァ-ヶ一-龯]/;

const SLOT: FreeBusySlot = {
  allDay: false,
  start: '2026-09-01T09:00:00.000Z',
  end: '2026-09-01T10:00:00.000Z',
};

// ---------------------------------------------------------------------------

describe('the Japanese is exactly what the page has always shown', () => {
  it('the four banners, called with no argument', () => {
    expect(unavailableMessage()).toBe('この共有リンクは利用できません。');
    expect(activeEmptyMessage()).toBe('この期間に共有されている予定はありません。');
    expect(availableEmptyMessage()).toBe('この期間に共有されている空き時間はありません。');
    expect(availableIndeterminateMessage()).toBe(
      '空き時間を正確に判定できませんでした。この期間については、空いているかどうかを確認するには直接ご連絡ください。',
    );
  });

  it("passing 'ja' explicitly is the same as passing nothing", () => {
    // The default is not a separate code path, and this is what says so.
    expect(unavailableMessage('ja')).toBe(unavailableMessage());
    expect(activeEmptyMessage('ja')).toBe(activeEmptyMessage());
    expect(availableEmptyMessage('ja')).toBe(availableEmptyMessage());
    expect(availableIndeterminateMessage('ja')).toBe(availableIndeterminateMessage());
  });

  it('the error banner, generic and both refusals', () => {
    const NOTE = '（この画面は「予定なし」を意味しません）';
    expect(freeBusyErrorBanner(new Error('boom'))).toBe(
      `空き時間を取得できませんでした。時間をおいて再読み込みしてください。${NOTE}`,
    );
    expect(freeBusyErrorBanner(new FreeBusyRateLimitedError('busy', 1))).toBe(
      `空き時間の計算が混み合っています。約1秒後にもう一度お試しください${NOTE}`,
    );
    expect(freeBusyErrorBanner(new FreeBusyRateLimitedError('rate', 7))).toBe(
      `空き時間の取得が短時間に集中したため、一時的に制限しています。約7秒後にもう一度お試しください${NOTE}`,
    );
  });

  it('reading the lead through localize() did not move the Japanese', () => {
    // The lead used to be `cause.message`, built at construction with the
    // default language. localize('ja') has to reproduce it exactly, including
    // the retry advice, or this step would have rewritten a live string.
    for (const err of [
      new FreeBusyRateLimitedError('rate', 7),
      new FreeBusyRateLimitedError('rate', 90),
      new FreeBusyRateLimitedError('rate', null),
      new FreeBusyRateLimitedError('busy', 1),
    ]) {
      expect(freeBusyErrorBanner(err)).toContain(err.message);
    }
  });

  it('an explicit custom message is still shown verbatim, in either language', () => {
    // hasCustomMessage short-circuits localize, so a caller that passed its own
    // wording keeps it. Translating it would discard information the caller
    // chose to supply.
    const err = new FreeBusyRateLimitedError('rate', 5, 'bespoke wording');
    expect(freeBusyErrorBanner(err, 'ja')).toContain('bespoke wording');
    expect(freeBusyErrorBanner(err, 'en')).toContain('bespoke wording');
  });
});

describe('English carries no Japanese', () => {
  it('no banner leaks a Japanese character', () => {
    for (const [name, text] of [
      ['unavailable', unavailableMessage('en')],
      ['activeEmpty', activeEmptyMessage('en')],
      ['availableEmpty', availableEmptyMessage('en')],
      ['availableIndeterminate', availableIndeterminateMessage('en')],
      ['error generic', freeBusyErrorBanner(new Error('boom'), 'en')],
      ['error rate', freeBusyErrorBanner(new FreeBusyRateLimitedError('rate', 7), 'en')],
      ['error busy', freeBusyErrorBanner(new FreeBusyRateLimitedError('busy', 1), 'en')],
      ['error rate, no wait', freeBusyErrorBanner(new FreeBusyRateLimitedError('rate', null), 'en')],
    ] as const) {
      expect(text, name).not.toMatch(JAPANESE);
      expect(text, name).not.toBe('');
    }
  });

  it('the error banner is a WHOLE sentence in one language, lead and note alike', () => {
    // THE REGRESSION THIS STEP EXISTS TO PREVENT. Translating the note while
    // the lead came from `cause.message` produced one banner in two languages,
    // which is worse than leaving it Japanese: it reads as a bug and it buries
    // the safety note in prose the viewer may not be reading carefully.
    const en = freeBusyErrorBanner(new FreeBusyRateLimitedError('rate', 7), 'en');
    expect(en).toMatch(/temporarily limited/i);
    expect(en).toMatch(/does not mean/i);
    expect(en).not.toMatch(JAPANESE);

    const ja = freeBusyErrorBanner(new FreeBusyRateLimitedError('rate', 7), 'ja');
    expect(ja).toMatch(/一時的に制限しています/);
    expect(ja).toMatch(/予定なし/);
    // The Japanese banner has no English prose glued into it either.
    expect(ja).not.toMatch(/[A-Za-z]{4,}/);
  });

  it('every banner differs between the two languages', () => {
    // A key that silently fell back to Japanese would pass the "no empty
    // string" check and nothing else. These sentences have no proper nouns, so
    // identical output in both languages means a lookup did not happen.
    for (const fn of [
      unavailableMessage,
      activeEmptyMessage,
      availableEmptyMessage,
      availableIndeterminateMessage,
    ]) {
      expect(fn('en')).not.toBe(fn('ja'));
    }
    expect(freeBusyErrorBanner(new Error('x'), 'en')).not.toBe(
      freeBusyErrorBanner(new Error('x'), 'ja'),
    );
  });

  it('an unrecognised language falls back to Japanese rather than blanking', () => {
    // The value reaches these functions from navigator.languages via
    // resolveLanguage. t() does the normalising, so there is none here to get
    // wrong -- this asserts the result, not the mechanism.
    const bogus = 'de' as unknown as 'ja';
    expect(unavailableMessage(bogus)).toBe(unavailableMessage('ja'));
    expect(availableIndeterminateMessage(bogus)).toBe(availableIndeterminateMessage('ja'));
    expect(freeBusyErrorBanner(new Error('x'), bogus)).toBe(
      freeBusyErrorBanner(new Error('x'), 'ja'),
    );
  });
});

/**
 * The safety meanings, asserted in BOTH languages.
 *
 * Each of these has a Japanese-only twin in the modules' own test files. The
 * point of repeating them per language is that the risk is not translation
 * failure but translation FLUENCY: "open time could not be determined" and "no
 * open time" are both natural English, and only one of them is true.
 */
describe('Available never reads as "the owner is free"', () => {
  it('indeterminate reports missing knowledge, never an empty calendar', () => {
    expect(availableIndeterminateMessage('ja')).toContain('判定できませんでした');
    expect(availableIndeterminateMessage('ja')).not.toContain('ありません');
    expect(availableIndeterminateMessage('ja')).not.toContain('空いていません');

    const en = availableIndeterminateMessage('en');
    expect(en).toMatch(/could not be determined/i);
    expect(en).not.toMatch(/\bno (open time|availability|free time)\b/i);
    expect(en).not.toMatch(/\b(is|are) (free|available)\b/i);
    expect(en).not.toMatch(/\bfully booked\b/i);
  });

  it('indeterminate names no reason, in either language', () => {
    // An unexpandable recurrence is a detail of the owner's calendar. 0023's
    // discipline -- never disclose WHY -- applies to this state too, and a
    // translator with no context is exactly who would helpfully add it.
    for (const leak of ['繰り返し', '定期', '予定']) {
      expect(availableIndeterminateMessage('ja')).not.toContain(leak);
    }
    for (const leak of [/recurr/i, /repeat/i, /rrule/i, /event/i, /calculat/i]) {
      expect(availableIndeterminateMessage('en'), String(leak)).not.toMatch(leak);
    }
  });

  it('indeterminate offers the viewer a way to find out', () => {
    // The state is a dead end otherwise: the page cannot answer, so the
    // sentence has to hand the question back to a human.
    expect(availableIndeterminateMessage('ja')).toContain('直接ご連絡');
    expect(availableIndeterminateMessage('en')).toMatch(/get in touch|contact/i);
  });

  it('the empty answer speaks of what is SHARED, not of what exists', () => {
    // The owner may have open time they simply did not mark available. This
    // page cannot tell, and must not say otherwise.
    expect(availableEmptyMessage('ja')).toContain('共有');
    const en = availableEmptyMessage('en');
    expect(en).toMatch(/shared/i);
    expect(en).not.toMatch(/\b(has|have|owner)\b/i);
  });

  it('the busy-empty notice says SHARED too, and never claims freedom', () => {
    expect(activeEmptyMessage('ja')).toContain('共有');
    const en = activeEmptyMessage('en');
    expect(en).toMatch(/shared/i);
    expect(en).not.toMatch(/\bfree\b|\bavailable\b|\bopen\b/i);
  });

  it('the two available sentences stay distinguishable in both languages', () => {
    // If a translation collapsed them, "we don't know" and "there is none"
    // would become the same screen -- the exact confusion the union prevents.
    for (const lang of LANGUAGES) {
      expect(availableIndeterminateMessage(lang), lang).not.toBe(availableEmptyMessage(lang));
    }
  });

  it('the unavailable sentence names no reason in either language', () => {
    for (const reason of ['期限', '失効', '削除', '無効', '不正', 'トークン']) {
      expect(unavailableMessage('ja')).not.toContain(reason);
    }
    const en = unavailableMessage('en');
    for (const reason of [/expired/i, /revoked/i, /deleted/i, /unknown/i, /invalid/i, /not found/i, /token/i]) {
      expect(en, String(reason)).not.toMatch(reason);
    }
  });

  it('no banner shows a raw API enum, in either language', () => {
    for (const lang of LANGUAGES) {
      for (const text of [
        unavailableMessage(lang),
        activeEmptyMessage(lang),
        availableEmptyMessage(lang),
        availableIndeterminateMessage(lang),
      ]) {
        for (const leak of [
          'active',
          'unavailable',
          'not_requested',
          'indeterminate',
          'complete',
          'link_state',
          'share_available',
          'include_private',
        ]) {
          expect(text, `${lang}:${leak}`).not.toContain(leak);
        }
      }
    }
  });

  it('an error is never readable as "no events", in either language', () => {
    // The note is appended on every branch, which is what makes this
    // structural rather than a rule to remember. Asserted per language because
    // the append is now two lookups rather than one constant.
    for (const lang of LANGUAGES) {
      for (const cause of [
        new Error('boom'),
        new FreeBusyRateLimitedError('rate', 30),
        new FreeBusyRateLimitedError('rate', null),
        new FreeBusyRateLimitedError('busy', 1),
        'TypeError: Failed to fetch',
        null,
        undefined,
      ]) {
        const text = freeBusyErrorBanner(cause, lang);
        expect(text.length, lang).toBeGreaterThan(0);
        expect(text, lang).toContain(
          lang === 'en' ? 'does not mean' : '「予定なし」を意味しません',
        );
      }
    }
  });

  it('the database message is still withheld, in either language', () => {
    // English log prose, and for a revoked-or-unknown token the page must stay
    // uninformative. Translating the banner must not have turned the cause into
    // something the viewer can read.
    for (const lang of LANGUAGES) {
      const text = freeBusyErrorBanner(new Error('requested range exceeds 92 days'), lang);
      expect(text, lang).not.toContain('92 days');
      expect(text, lang).not.toContain('requested range');
    }
  });

  it('the rate branch does not also ask the viewer to reload', () => {
    // It carries its own advice; the generic sentence must not be glued on.
    for (const lang of LANGUAGES) {
      const text = freeBusyErrorBanner(new FreeBusyRateLimitedError('rate', 7), lang);
      expect(text, lang).not.toContain(
        lang === 'en' ? 'could not be loaded' : '空き時間を取得できませんでした',
      );
    }
  });
});

/**
 * Busy and Available are different claims, and the words have to keep them
 * apart. The failure mode is not a mistranslation but a SYNONYM: English calls
 * both "free", so a translator smoothing the copy could make the busy-empty
 * notice and the available-empty notice say the same thing.
 */
describe('Busy and Available do not blur together', () => {
  it('the busy notice and the available notice are different sentences', () => {
    for (const lang of LANGUAGES) {
      expect(activeEmptyMessage(lang), lang).not.toBe(availableEmptyMessage(lang));
    }
  });

  it('each names the thing it is about', () => {
    expect(activeEmptyMessage('ja')).toContain('予定');
    expect(activeEmptyMessage('en')).toMatch(/events/i);
    expect(availableEmptyMessage('ja')).toContain('空き時間');
    expect(availableEmptyMessage('en')).toMatch(/open time/i);
  });

  it('the busy notice does not speak of open time, nor the reverse', () => {
    expect(activeEmptyMessage('ja')).not.toContain('空き時間');
    expect(activeEmptyMessage('en')).not.toMatch(/open time/i);
    expect(availableEmptyMessage('ja')).not.toContain('予定');
    expect(availableEmptyMessage('en')).not.toMatch(/\bevents\b/i);
  });
});

/**
 * The state machine. P6 step 2 changed WORDING ONLY, and these are the guards
 * that say so: every mapping below held before this step and holds after it,
 * for both languages, because none of it consults a language at all.
 */
describe('the three Available states still map as they did', () => {
  it('not_requested renders nothing', () => {
    // Never an empty strip: the link was not opted in, so the page was told
    // nothing about open time and must not imply it was asked.
    expect(availablePresentation({ status: 'not_requested' })).toBe('hidden');
    expect(availableSlots({ status: 'not_requested' })).toEqual([]);
    expect(hasDisclosedAvailable({ status: 'not_requested' })).toBe(false);
  });

  it('indeterminate renders the sentence and NO slots', () => {
    expect(availablePresentation({ status: 'indeterminate' })).toBe('indeterminate');
    expect(availableSlots({ status: 'indeterminate' })).toEqual([]);
    expect(hasDisclosedAvailable({ status: 'indeterminate' })).toBe(false);
  });

  it('complete renders its slots, and an empty set is a real answer', () => {
    const withSlots: AvailableResult = { status: 'complete', slots: [SLOT] };
    const empty: AvailableResult = { status: 'complete', slots: [] };
    expect(availablePresentation(withSlots)).toBe('slots');
    expect(availablePresentation(empty)).toBe('slots');
    expect(availableSlots(withSlots)).toEqual([SLOT]);
    expect(hasDisclosedAvailable(withSlots)).toBe(true);
    expect(hasDisclosedAvailable(empty)).toBe(false);
  });

  it('only the opted-in, exact, empty case gets the empty sentence', () => {
    // 'hidden' says nothing: "no open time is shared" would answer a question
    // nobody put. This is the pairing of state to copy, in one place.
    const shows = (a: AvailableResult) =>
      availablePresentation(a) === 'slots' && availableSlots(a).length === 0;
    expect(shows({ status: 'complete', slots: [] })).toBe(true);
    expect(shows({ status: 'complete', slots: [SLOT] })).toBe(false);
    expect(shows({ status: 'indeterminate' })).toBe(false);
    expect(shows({ status: 'not_requested' })).toBe(false);
  });

  it('the presentation of each state is identical whatever the language', () => {
    // The functions take no language, and that is the point: wording is a
    // separate concern from what is shown. A regression here would mean a
    // language had started deciding disclosure.
    for (const a of [
      { status: 'not_requested' },
      { status: 'indeterminate' },
      { status: 'complete', slots: [SLOT] },
      { status: 'complete', slots: [] },
    ] as AvailableResult[]) {
      expect(availablePresentation.length).toBe(1);
      expect(availableSlots(a)).toEqual(availableSlots(a));
    }
    expect(availableSlots.length).toBe(1);
    expect(hasDisclosedAvailable.length).toBe(1);
    expect(freeBusyPresentation.length).toBe(1);
  });

  it('busy stays the priority: its empty notice reads the BUSY set alone', () => {
    // hasNoDisclosedBusy is busy-only by construction, and the page suppresses
    // its notice when available blocks are drawn. Neither fact involves a
    // language, and this asserts the pairing the page relies on.
    const busyEmpty = { complete: true, slots: [] };
    expect(hasNoDisclosedBusy(busyEmpty)).toBe(true);
    expect(hasNoDisclosedBusy({ complete: true, slots: [SLOT] })).toBe(false);
    // Incomplete busy is NOT "nothing shared" -- unshown times are unknown.
    expect(hasNoDisclosedBusy({ complete: false, slots: [] })).toBe(false);

    // The page's actual condition: notice only when busy disclosed nothing AND
    // no open time is on screen.
    const notice = (a: AvailableResult) => hasNoDisclosedBusy(busyEmpty) && !hasDisclosedAvailable(a);
    expect(notice({ status: 'complete', slots: [SLOT] })).toBe(false);
    expect(notice({ status: 'complete', slots: [] })).toBe(true);
    expect(notice({ status: 'indeterminate' })).toBe(true);
    expect(notice({ status: 'not_requested' })).toBe(true);
  });

  it('the link-state mapping is unchanged and language-free', () => {
    expect(freeBusyPresentation({ status: 'loading' })).toBe('loading');
    expect(freeBusyPresentation({ status: 'error' })).toBe('error');
    expect(freeBusyPresentation({ status: 'ok', result: { linkState: 'active' } })).toBe('calendar');
    expect(freeBusyPresentation({ status: 'ok', result: { linkState: 'unavailable' } })).toBe(
      'unavailable',
    );
  });

  it('Available is never computed from the gaps between Busy blocks', () => {
    // The one invariant a display change could not break but a careless edit
    // could: available slots come only from the backend's subtraction. Nothing
    // in either module reads the busy set to synthesise open time.
    for (const p of [
      'features/share/availablePresentation.ts',
      'features/share/freeBusyPresentation.ts',
    ]) {
      const mod = code(p);
      expect(mod, p).not.toMatch(/invert|complement|gap|mergeFreeBusySlots/i);
    }
  });
});

/**
 * Privacy. The language change must not have given this route a new reason to
 * ask the database anything.
 */
describe('the anonymous route reads nothing it did not read before', () => {
  it('the page never names owner settings', () => {
    // anon holds no privilege on that table, so a read would raise 42501 and
    // take the share page down -- and it would be the wrong question anyway:
    // an anonymous viewer needs their OWN language, not the owner's.
    const page = code('features/share/FreeBusyPage.tsx');
    expect(page).not.toMatch(/owner_settings|ownerSettingsRepository|getOwnerSettings/);
  });

  it('nor do the three modules it renders', () => {
    for (const p of [
      'features/share/freeBusyPresentation.ts',
      'features/share/availablePresentation.ts',
      'features/share/freeBusyBanner.ts',
    ]) {
      const mod = code(p);
      expect(mod, p).not.toMatch(/owner_settings|getOwnerSettings|supabase|repositor/i);
    }
  });

  it('the share repository still knows nothing about language', () => {
    const repo = code('repositories/shareRepository.ts');
    expect(repo).not.toMatch(/i18n|Language|resolveLanguage|intlLocale/);
  });

  it('the RPC call has no language argument to change', () => {
    // The strongest available form of "changing language does not change the
    // request": there is no slot in the call for it. The five parameters are
    // the token and the window.
    const repo = code('repositories/shareRepository.ts');
    const call = repo.slice(repo.indexOf("rpc('get_free_busy'"), repo.indexOf('if (error) throw mapFreeBusyError'));
    expect(call).toContain('p_token');
    expect(call).toContain('p_from');
    expect(call).toContain('p_to');
    expect(call).toContain('p_from_date');
    expect(call).toContain('p_to_date');
    expect(call).not.toMatch(/lang|locale|p_language/i);
  });

  it('the page resolves the viewer\'s language and passes it, fetching nothing', () => {
    // useLanguage() on this route starts no request: the provider carries
    // isPublicRoute, which short-circuits the settings read. That is asserted in
    // wiring.test.ts; here the claim is only that the page uses the value.
    const page = code('features/share/FreeBusyPage.tsx');
    expect(page).toMatch(/const \{ language \} = useLanguage\(\)/);
    for (const call of [
      'unavailableMessage(language)',
      'activeEmptyMessage(language)',
      'availableIndeterminateMessage(language)',
      'availableEmptyMessage(language)',
      'freeBusyErrorBanner(load.cause, language)',
    ]) {
      expect(page, call).toContain(call);
    }
  });

  it('no pinned banner constant is rendered any more', () => {
    const page = code('features/share/FreeBusyPage.tsx');
    expect(page).not.toMatch(/\{(UNAVAILABLE|ACTIVE_EMPTY|AVAILABLE_EMPTY|AVAILABLE_INDETERMINATE)_MESSAGE\}/);
  });

  it('the error banner is resolved at RENDER, so a language change reaches it', () => {
    // It used to be resolved in the catch and stored as a string, which pinned
    // it to the language that happened to be current when the fetch failed --
    // every other string on the page would have re-rendered and that one would
    // not. The state now holds the cause.
    const page = code('features/share/FreeBusyPage.tsx');
    expect(page).toMatch(/status: 'error'; cause: unknown/);
    expect(page).toMatch(/setLoad\(\{ status: 'error', cause \}\)/);
    expect(page).not.toMatch(/status: 'error', message:/);
    expect(page).not.toMatch(/\{load\.message\}/);
  });

  it('the three modules stay pure, taking the language as an argument', () => {
    for (const p of [
      'features/share/freeBusyPresentation.ts',
      'features/share/availablePresentation.ts',
      'features/share/freeBusyBanner.ts',
    ]) {
      const mod = code(p);
      expect(mod, p).not.toMatch(/useTranslate|useLanguage|from 'react'/);
      expect(mod, p).toMatch(/lang: Language = DEFAULT_LANGUAGE/);
      // And no module-level resolved string is left behind.
      expect(mod, p).not.toMatch(/^(export )?const \w+ = t\(/m);
    }
  });

  it('no cache was added where a single lookup does', () => {
    // Deliberate asymmetry with visibilityMeta, which caches because a month
    // grid asks it a hundred times. These banners render once per page.
    for (const p of [
      'features/share/freeBusyPresentation.ts',
      'features/share/availablePresentation.ts',
      'features/share/freeBusyBanner.ts',
    ]) {
      expect(code(p), p).not.toMatch(/new Map|CACHE/);
    }
  });
});

describe('the opt-ins and the switch are untouched', () => {
  it('share_available and include_private remain independent in the type', () => {
    // Two separate booleans, all four combinations legal. A display change has
    // no business collapsing them, and the type is where that is stated.
    const types = source('types/share.ts');
    expect(types).toMatch(/includePrivate: boolean/);
    expect(types).toMatch(/shareAvailable: boolean/);
  });

  it('neither opt-in is read by anything this step touched', () => {
    for (const p of [
      'features/share/freeBusyPresentation.ts',
      'features/share/availablePresentation.ts',
      'features/share/freeBusyBanner.ts',
      'features/share/FreeBusyPage.tsx',
    ]) {
      const mod = code(p);
      expect(mod, p).not.toMatch(/shareAvailable|share_available/);
      expect(mod, p).not.toMatch(/includePrivate|include_private/);
    }
  });

  it('the anonymous page still discloses no event detail', () => {
    // No title, no category, no id, no visibility -- the page renders blocks.
    const page = code('features/share/FreeBusyPage.tsx');
    expect(page).not.toMatch(/\.title|\.category|\.description|visibilityMeta|eventDisplayTitle/);
  });

  it('the switch is ON, so an English viewer now reads this page in English', () => {
    // The highest-stakes case in the whole phase: this route's reader is an
    // anonymous stranger whose language comes from their own browser.
    expect(LANGUAGE_SWITCH_ENABLED).toBe(true);
    for (const text of [
      unavailableMessage('en'),
      activeEmptyMessage('en'),
      availableEmptyMessage('en'),
      availableIndeterminateMessage('en'),
    ]) {
      expect(text).not.toMatch(JAPANESE);
    }
  });

  it('these modules render only the share page own copy', () => {
    // P6 step 2's claim was "no key was added"; P6.7 added exactly one --
    // sharePage.block.timeRange, the accessible name of a timed block -- so
    // the claim becomes the durable one it was standing in for: nothing here
    // reaches into another screen's namespace, which is how copy starts being
    // shared by accident and then reworded for one screen only.
    for (const p of [
      'features/share/freeBusyPresentation.ts',
      'features/share/availablePresentation.ts',
      'features/share/freeBusyBanner.ts',
    ]) {
      const keys = [...code(p).matchAll(/t\('([\w.]+)'/g)].flatMap((m) => (m[1] ? [m[1]] : []));
      expect(keys.length, p).toBeGreaterThan(0);
      for (const k of keys) {
        expect(k, `${p}:${k}`).toMatch(/^(share|sharePage)\./);
        expect(k, `${p}:${k}`).not.toMatch(/^(calendar|event|settings|recurrence|auth|login)\./);
      }
    }
  });
});
