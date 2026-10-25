import { describe, expect, it } from 'vitest';
import { t } from './t';
import {
  unavailableMessage,
  activeEmptyMessage,
} from '../features/share/freeBusyPresentation';
import {
  availableEmptyMessage,
  availableIndeterminateMessage,
} from '../features/share/availablePresentation';
import { freeBusyErrorBanner } from '../features/share/freeBusyBanner';
import { eventDisplayTitle } from '../features/calendar/eventTitle';
import { visibilityMeta } from '../features/calendar/visibilityMeta';
import { contentLengthError, TITLE_MAX, CATEGORY_MAX, DESCRIPTION_MAX } from '../services/contentLimits';
import { FreeBusyRateLimitedError } from '../errors';

/**
 * P3 step 2 moved these modules' wording into the dictionary. As in step 1,
 * the claim is that NOTHING THE USER SEES CHANGED, so the Japanese below is
 * written out rather than read back from the dictionary.
 */

describe('the Japanese is byte-identical to before P3 step 2', () => {
  it('share page presentation', () => {
    // P6 step 2 made these four functions of the display language. Called with
    // no argument they answer in Japanese, which is what keeps this step's
    // claim -- that nothing the user sees changed -- true through that change.
    expect(unavailableMessage()).toBe('この共有リンクは利用できません。');
    expect(activeEmptyMessage()).toBe('この期間に共有されている予定はありません。');
    expect(availableEmptyMessage()).toBe('この期間に共有されている空き時間はありません。');
    expect(availableIndeterminateMessage()).toBe(
      '空き時間を正確に判定できませんでした。この期間については、空いているかどうかを確認するには直接ご連絡ください。',
    );
  });

  it('the error banner, generic and rate-limited', () => {
    const NOTE = '（この画面は「予定なし」を意味しません）';
    expect(freeBusyErrorBanner(new Error('boom'))).toBe(
      `空き時間を取得できませんでした。時間をおいて再読み込みしてください。${NOTE}`,
    );
    expect(freeBusyErrorBanner(new FreeBusyRateLimitedError('busy', 1))).toBe(
      `空き時間の計算が混み合っています。約1秒後にもう一度お試しください${NOTE}`,
    );
  });

  it('event titles and visibility labels', () => {
    expect(eventDisplayTitle({ title: '', availability: 'busy' })).toBe('(無題)');
    expect(eventDisplayTitle({ title: '', availability: 'available' })).toBe('空き時間');
    // P6 step 1 made visibilityMeta a function; called with no language it
    // still answers in Japanese, which is what keeps this step true.
    expect(visibilityMeta('private').label).toBe('非公開');
    expect(visibilityMeta('busy_only').label).toBe('予定あり（詳細非公開）');
    expect(visibilityMeta('busy_only').short).toBe('予定あり');
    expect(visibilityMeta('public').label).toBe('公開');
  });

  it('content length errors, with the ceiling interpolated', () => {
    const long = (n: number) => 'あ'.repeat(n + 1);
    expect(contentLengthError({ title: long(TITLE_MAX), category: null, description: null }))
      .toBe(`タイトルは${TITLE_MAX}文字以内で入力してください`);
    expect(contentLengthError({ title: 'ok', category: long(CATEGORY_MAX), description: null }))
      .toBe(`カテゴリは${CATEGORY_MAX}文字以内で入力してください`);
    expect(contentLengthError({ title: 'ok', category: null, description: long(DESCRIPTION_MAX) }))
      .toBe(`メモは${DESCRIPTION_MAX}文字以内で入力してください`);
    expect(contentLengthError({ title: 'ok', category: null, description: null })).toBeNull();
  });
});

describe('English renders correctly', () => {
  it('content limits take the language and keep the number', () => {
    // The ceiling travels as a variable, so one wording serves both languages
    // and the number cannot drift from the constant it describes.
    const long = 'a'.repeat(TITLE_MAX + 1);
    const en = contentLengthError({ title: long, category: null, description: null }, 'en');
    expect(en).toBe(`Title must be ${TITLE_MAX} characters or fewer`);
    expect(en).not.toMatch(/\{max\}/);
  });

  it('defaults to Japanese when no language is passed', () => {
    // Every existing caller passes nothing, which is why the parameter has a
    // default rather than being required.
    const long = 'a'.repeat(TITLE_MAX + 1);
    expect(contentLengthError({ title: long, category: null, description: null }))
      .toMatch(/^タイトルは/);
  });

  it('share page copy exists in English with no stray placeholders', () => {
    for (const key of [
      'share.unavailable', 'share.activeEmpty', 'share.error.generic',
      'share.error.notFreeNote', 'share.available.empty', 'share.available.indeterminate',
    ] as const) {
      const s = t(key, 'en');
      expect(s).not.toBe('');
      expect(s).not.toMatch(/\{\w+\}/);
      expect(s).not.toMatch(/[ぁ-んァ-ヶ一-龯]/);
    }
  });
});

/**
 * The meanings that must survive translation. The Japanese versions of these
 * are already guarded elsewhere; this does the same for English, because a
 * fluent rewrite is exactly how such a meaning gets lost.
 */
describe('safety-critical meanings are preserved in English', () => {
  it('unavailable names no reason', () => {
    const s = t('share.unavailable', 'en');
    expect(s).not.toMatch(/expired|revoked|deleted|unknown|invalid|not found/i);
  });

  it('the empty notice says SHARED, not that the owner is free', () => {
    const s = t('share.activeEmpty', 'en');
    expect(s).toMatch(/shared/i);
    expect(s).not.toMatch(/\bfree\b|\bavailable\b/i);
  });

  it('the error banner still refuses to read as "no events"', () => {
    expect(t('share.error.notFreeNote', 'en')).toMatch(/does not mean/i);
  });

  it('available indeterminate still reports missing knowledge', () => {
    const s = t('share.available.indeterminate', 'en');
    expect(s).toMatch(/could not be determined/i);
    expect(s).not.toMatch(/\bno (open time|availability)\b/i);
  });

  it('busy_only still says details are hidden, not that the event is public', () => {
    const s = t('calendar.visibility.busyOnly', 'en');
    expect(s).toMatch(/hidden/i);
    expect(s).not.toMatch(/public/i);
  });

  it('the unset-timezone notice still frames hiding as the safe outcome', () => {
    expect(t('settings.timezone.unsetNotice', 'en')).toMatch(/safe/i);
  });

  it('the timezone change notice still says timed events do NOT move', () => {
    expect(t('settings.timezone.changeTimedUnaffected', 'en')).toMatch(/unaffected/i);
  });
});
