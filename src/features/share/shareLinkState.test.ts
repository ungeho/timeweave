import { describe, expect, it } from 'vitest';
import type { ShareLink } from '../../types/share';
import { canDeleteShareLink, shareLinkStatus, visibleShareLinks } from './shareLinkState';

/**
 * These pin migration 0015's delete predicate on the client side. The case that
 * matters most is EXPIRED BUT NOT REVOKED: it looks finished, and the RPC would
 * still refuse to delete it while returning the same `false` it returns for an
 * id that does not exist. If canDeleteShareLink ever starts saying true for it,
 * the dialog grows a button that silently does nothing.
 */

const NOW = Date.parse('2026-09-21T12:00:00Z');

const link = (over: Partial<ShareLink> = {}): ShareLink => ({
  id: 'l1',
  label: null,
  includePrivate: true,
  expiresAt: null,
  revokedAt: null,
  createdAt: '2026-09-01T00:00:00Z',
  // 0022's opt-in. None of the three functions under test reads it: a link's
  // status and deletability come from revokedAt and expiresAt alone, and that is
  // the point -- sharing available time is a setting, not a lifecycle state.
  shareAvailable: false,
  ...over,
});

describe('shareLinkStatus', () => {
  it('is active with no expiry and no revocation', () => {
    expect(shareLinkStatus(link(), NOW)).toBe('active');
  });

  it('is active while the expiry is still in the future', () => {
    expect(shareLinkStatus(link({ expiresAt: '2026-09-21T12:00:01Z' }), NOW)).toBe('active');
  });

  it('is expired once the expiry has passed', () => {
    expect(shareLinkStatus(link({ expiresAt: '2026-09-21T11:59:59Z' }), NOW)).toBe('expired');
  });

  it('treats the expiry instant itself as expired', () => {
    // `<=`, the comparison this list has always used.
    expect(shareLinkStatus(link({ expiresAt: '2026-09-21T12:00:00Z' }), NOW)).toBe('expired');
  });

  it('is revoked whether or not an expiry is set', () => {
    const revokedAt = '2026-09-10T00:00:00Z';
    expect(shareLinkStatus(link({ revokedAt }), NOW)).toBe('revoked');
    expect(shareLinkStatus(link({ revokedAt, expiresAt: '2026-01-01T00:00:00Z' }), NOW)).toBe('revoked');
    expect(shareLinkStatus(link({ revokedAt, expiresAt: '2099-01-01T00:00:00Z' }), NOW)).toBe('revoked');
  });

  it('reads an unparseable expiry as active rather than hiding the link', () => {
    expect(shareLinkStatus(link({ expiresAt: 'not a date' }), NOW)).toBe('active');
  });
});

describe('canDeleteShareLink', () => {
  it('is true only for a revoked link', () => {
    expect(canDeleteShareLink(link({ revokedAt: '2026-09-10T00:00:00Z' }))).toBe(true);
  });

  it('is false for an active link', () => {
    expect(canDeleteShareLink(link())).toBe(false);
  });

  // The whole reason this function exists.
  it('is false for an expired link that was never revoked', () => {
    const expired = link({ expiresAt: '2026-01-01T00:00:00Z' });
    expect(shareLinkStatus(expired, NOW)).toBe('expired');
    expect(canDeleteShareLink(expired)).toBe(false);
  });

  it('ignores expiry entirely, in both directions', () => {
    expect(canDeleteShareLink(link({ revokedAt: '2026-09-10T00:00:00Z', expiresAt: '2099-01-01T00:00:00Z' }))).toBe(true);
    expect(canDeleteShareLink(link({ expiresAt: '2000-01-01T00:00:00Z' }))).toBe(false);
  });
});

// 0022. shareAvailable is a SETTING; revokedAt and expiresAt are the lifecycle.
// Nothing here may consult it -- a link that shares available time must still be
// revocable and deletable on exactly the same terms as one that does not, or an
// owner could find the opt-in has quietly made a link harder to take back.
describe('shareAvailable does not affect status or deletability', () => {
  it('leaves shareLinkStatus alone in every state', () => {
    for (const on of [false, true]) {
      expect(shareLinkStatus(link({ shareAvailable: on }), NOW)).toBe('active');
      expect(shareLinkStatus(link({ shareAvailable: on, expiresAt: '2026-01-01T00:00:00Z' }), NOW)).toBe('expired');
      expect(shareLinkStatus(link({ shareAvailable: on, revokedAt: '2026-09-10T00:00:00Z' }), NOW)).toBe('revoked');
    }
  });

  it('leaves canDeleteShareLink alone', () => {
    for (const on of [false, true]) {
      expect(canDeleteShareLink(link({ shareAvailable: on }))).toBe(false);
      expect(canDeleteShareLink(link({ shareAvailable: on, revokedAt: '2026-09-10T00:00:00Z' }))).toBe(true);
    }
  });
});

describe('visibleShareLinks', () => {
  const active = link({ id: 'a' });
  const expired = link({ id: 'e', expiresAt: '2026-01-01T00:00:00Z' });
  const revoked = link({ id: 'r', revokedAt: '2026-09-10T00:00:00Z' });
  const all = [active, expired, revoked];

  it('returns everything, in order, when the filter is off', () => {
    expect(visibleShareLinks(all, false).map((l) => l.id)).toEqual(['a', 'e', 'r']);
  });

  it('does not copy the array when the filter is off', () => {
    expect(visibleShareLinks(all, true)).not.toBe(all);
    expect(visibleShareLinks(all, false)).toBe(all);
  });

  it('keeps only the rows that can actually be deleted', () => {
    expect(visibleShareLinks(all, true).map((l) => l.id)).toEqual(['r']);
  });

  it('agrees with canDeleteShareLink on every row it keeps', () => {
    expect(visibleShareLinks(all, true).every(canDeleteShareLink)).toBe(true);
  });

  it('can end up empty, which is what a filtered list with nothing revoked means', () => {
    expect(visibleShareLinks([active, expired], true)).toEqual([]);
    expect(visibleShareLinks([], true)).toEqual([]);
  });
});
