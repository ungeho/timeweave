/**
 * The share page's failure wording. The invariant under test is not the prose
 * but the promise: whatever went wrong, the banner still says that this is not
 * a claim of availability.
 */

import { describe, expect, it } from 'vitest';
import { FreeBusyRateLimitedError } from '../../errors';
import { freeBusyErrorBanner } from './freeBusyBanner';

const NOTE = '（この画面は「予定なし」を意味しません）';

describe('freeBusyErrorBanner', () => {
  it('keeps the generic wording for an unrecognised failure', () => {
    const text = freeBusyErrorBanner(new Error('requested range exceeds 92 days'));
    expect(text).toContain('空き時間を取得できませんでした');
    expect(text).toContain('時間をおいて再読み込みしてください');
  });

  it('never shows the database message to the viewer', () => {
    // English log prose, and for an unknown token the page must stay silent.
    expect(freeBusyErrorBanner(new Error('requested range exceeds 92 days')))
      .not.toContain('92 days');
  });

  it('uses the rate-limit message, with its wait, when the RPC refused', () => {
    const text = freeBusyErrorBanner(new FreeBusyRateLimitedError('rate', 7));
    expect(text).toContain('一時的に制限しています');
    expect(text).toContain('約7秒後');
  });

  it('uses the busy message when both slots were taken', () => {
    const text = freeBusyErrorBanner(new FreeBusyRateLimitedError('busy', 1));
    expect(text).toContain('混み合っています');
    expect(text).toContain('約1秒後');
  });

  it.each([
    ['an unrecognised error', new Error('boom')],
    ['a rate refusal with a wait', new FreeBusyRateLimitedError('rate', 30)],
    ['a rate refusal without a wait', new FreeBusyRateLimitedError('rate', null)],
    ['a busy refusal', new FreeBusyRateLimitedError('busy', 1)],
    ['a rejected string', 'TypeError: Failed to fetch'],
    ['a rejected null', null],
    ['a rejected undefined', undefined],
  ] as const)('always ends with the "not free" note: %s', (_label, cause) => {
    expect(freeBusyErrorBanner(cause).endsWith(NOTE)).toBe(true);
  });

  it('does not ask the viewer to reload twice over', () => {
    // The rate branch carries its own advice; the generic sentence must not be
    // glued onto it as well.
    const text = freeBusyErrorBanner(new FreeBusyRateLimitedError('rate', 7));
    expect(text).not.toContain('空き時間を取得できませんでした');
  });
});
