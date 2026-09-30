import { describe, expect, it } from 'vitest';

import {
  ACTIVE_EMPTY_MESSAGE,
  UNAVAILABLE_MESSAGE,
  freeBusyPresentation,
} from './freeBusyPresentation';

describe('freeBusyPresentation', () => {
  it('maps loading and error straight through', () => {
    expect(freeBusyPresentation({ status: 'loading' })).toBe('loading');
    expect(freeBusyPresentation({ status: 'error' })).toBe('error');
  });

  it('shows the calendar for an active link', () => {
    expect(freeBusyPresentation({ status: 'ok', result: { linkState: 'active' } }))
      .toBe('calendar');
  });

  it('shows the unavailable state for an unavailable link', () => {
    expect(freeBusyPresentation({ status: 'ok', result: { linkState: 'unavailable' } }))
      .toBe('unavailable');
  });

  // An active link that disclosed nothing is still the calendar: the empty-period
  // message belongs inside it. Collapsing the two would tell a viewer the link is
  // broken when the owner is simply free.
  it('never treats an active link as unavailable', () => {
    expect(freeBusyPresentation({ status: 'ok', result: { linkState: 'active' } }))
      .not.toBe('unavailable');
  });
});

describe('link-state copy', () => {
  it('is exactly the adopted wording', () => {
    expect(UNAVAILABLE_MESSAGE).toBe('この共有リンクは利用できません。');
    expect(ACTIVE_EMPTY_MESSAGE).toBe('この期間に共有されている予定はありません。');
  });

  // The backend collapses expired/revoked/deleted/unknown/malformed into one
  // state precisely so none of them can be inferred. Naming any of them here
  // would hand back the reason the API withholds.
  it('names no reason in the unavailable message', () => {
    for (const reason of ['期限', '失効', '削除', '無効', '不正', 'token', 'トークン']) {
      expect(UNAVAILABLE_MESSAGE).not.toContain(reason);
    }
  });

  it('shows no raw API enum to the viewer', () => {
    for (const enumValue of ['active', 'unavailable', 'link_state', 'linkState']) {
      expect(UNAVAILABLE_MESSAGE).not.toContain(enumValue);
      expect(ACTIVE_EMPTY_MESSAGE).not.toContain(enumValue);
    }
  });

  // 0023 removed the clause that said a revoked or expired link produced this
  // same screen. It used to be true; it is not any more.
  it('no longer claims revoked and expired links look the same', () => {
    expect(ACTIVE_EMPTY_MESSAGE).not.toContain('失効');
    expect(ACTIVE_EMPTY_MESSAGE).not.toContain('期限切れ');
  });
});
