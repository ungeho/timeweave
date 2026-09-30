import { beforeEach, describe, expect, it, vi } from 'vitest';

// A recording fake for requireSupabase().rpc(name, params) -> { data, error }.
const h = vi.hoisted(() => {
  const calls: { name: string; params: unknown }[] = [];
  const state: { data: unknown; error: unknown } = { data: null, error: null };
  const client = {
    rpc: (name: string, params: unknown) => {
      calls.push({ name, params });
      return Promise.resolve({ data: state.data, error: state.error });
    },
  };
  return { calls, state, client };
});

vi.mock('../lib/supabase', () => ({ requireSupabase: () => h.client }));

import {
  FreeBusyRateLimitedError,
  ShareLinkActiveQuotaExceededError,
  ShareLinkRateLimitedError,
  ShareLinkTotalQuotaExceededError,
} from '../errors';
import {
  createShareLink,
  deleteShareLink,
  getFreeBusy,
  listShareLinks,
  revokeShareLink,
  setShareAvailable,
} from './shareRepository';

beforeEach(() => {
  h.calls.length = 0;
  h.state.data = null;
  h.state.error = null;
});

describe('createShareLink', () => {
  it('passes params and maps the single returned row (with token)', async () => {
    h.state.data = [{
      id: 'l1', token: 'secret-token', label: 'v', include_private: true,
      expires_at: null, created_at: '2026-08-30T00:00:00Z', share_available: false,
    }];
    const link = await createShareLink({ label: 'v', includePrivate: true });
    expect(h.calls[0]).toEqual({
      name: 'create_share_link',
      params: {
        p_label: 'v', p_include_private: true, p_expires_at: null,
        p_share_available: false,
      },
    });
    expect(link).toEqual({
      id: 'l1', token: 'secret-token', label: 'v', includePrivate: true,
      expiresAt: null, revokedAt: null, createdAt: '2026-08-30T00:00:00Z',
      shareAvailable: false,
    });
  });

  it('defaults include_private to true when omitted', async () => {
    h.state.data = [{ id: 'l', token: 't', label: null, include_private: true, expires_at: null, created_at: 'c', share_available: false }];
    await createShareLink();
    expect((h.calls[0]!.params as Record<string, unknown>).p_include_private).toBe(true);
  });

  // 0022. The RPC parameter has its own DEFAULT of false, but the call still
  // sends the argument explicitly: a caller that omits shareAvailable must get
  // an opted-OUT link, and that has to be true of the wire call, not only of
  // the database.
  it('sends p_share_available false when omitted', async () => {
    h.state.data = [{ id: 'l', token: 't', label: null, include_private: true, expires_at: null, created_at: 'c', share_available: false }];
    await createShareLink();
    expect((h.calls[0]!.params as Record<string, unknown>).p_share_available).toBe(false);
  });

  it('passes and maps an explicit opt-in', async () => {
    h.state.data = [{ id: 'l', token: 't', label: null, include_private: false, expires_at: null, created_at: 'c', share_available: true }];
    const link = await createShareLink({ includePrivate: false, shareAvailable: true });
    expect((h.calls[0]!.params as Record<string, unknown>).p_share_available).toBe(true);
    // Independent settings: opting in to available time does not require, and
    // does not silently turn on, private-event inclusion.
    expect(link.shareAvailable).toBe(true);
    expect(link.includePrivate).toBe(false);
  });

  // An unapplied 0022 makes the RPC return a row with no share_available at all.
  // "Unknown" must read as not opted in, never as opted in.
  it('reads a missing share_available as false', async () => {
    h.state.data = [{ id: 'l', token: 't', label: null, include_private: true, expires_at: null, created_at: 'c' }];
    expect((await createShareLink()).shareAvailable).toBe(false);
  });

  it('throws on RPC error', async () => {
    h.state.error = { message: 'authentication required' };
    await expect(createShareLink()).rejects.toThrow(/authentication required/);
  });

  // 0016. The mapping itself is covered in shareLinkError.test.ts; what matters
  // here is that createShareLink routes the PostgrestError through it -- details
  // and hint included -- instead of keeping only the message, which carries the
  // owner's UUID.
  it('maps the active-quota marker and drops the owner id from the message', async () => {
    const owner = 'aa39f01f-e076-47a1-915c-e92a963c2efb';
    h.state.error = {
      code: '23514',
      details: 'TIMEWEAVE_QUOTA_SHARE_LINKS_ACTIVE',
      hint: 'Revoke an existing share link to free an active slot.',
      message: `share link quota exceeded: owner ${owner} would hold 26 active links, limit is 25`,
    };
    const e = await createShareLink().catch((x: unknown) => x);
    expect(e).toBeInstanceOf(ShareLinkActiveQuotaExceededError);
    expect((e as Error).message).not.toContain(owner);
  });

  it('maps the total-quota marker', async () => {
    h.state.error = { code: '23514', details: 'TIMEWEAVE_QUOTA_SHARE_LINKS_TOTAL', message: 'quota' };
    const e = await createShareLink().catch((x: unknown) => x);
    expect(e).toBeInstanceOf(ShareLinkTotalQuotaExceededError);
  });

  it('maps the create-rate marker and carries the hint', async () => {
    h.state.error = {
      code: 'PT429',
      details: 'TIMEWEAVE_RATE_SHARE_LINKS',
      hint: 'retry_after_seconds=9',
      message: 'share link create rate exceeded: owner x is ... per link',
    };
    const e = await createShareLink().catch((x: unknown) => x);
    expect(e).toBeInstanceOf(ShareLinkRateLimitedError);
    expect((e as ShareLinkRateLimitedError).retryAfterSeconds).toBe(9);
  });

  it('leaves an unknown 23514 as a plain Error with the server message', async () => {
    h.state.error = { code: '23514', details: 'TIMEWEAVE_SOMETHING_NEW', message: 'refused' };
    const e = await createShareLink().catch((x: unknown) => x);
    expect(e).not.toBeInstanceOf(ShareLinkActiveQuotaExceededError);
    expect((e as Error).message).toBe('refused');
  });
});

describe('listShareLinks', () => {
  it('maps rows to camelCase without a token field', async () => {
    h.state.data = [{
      id: 'l1', label: 'a', include_private: false,
      expires_at: '2026-12-31T00:00:00Z', revoked_at: null, created_at: 'c',
      share_available: true,
    }];
    const links = await listShareLinks();
    expect(links).toEqual([{
      id: 'l1', label: 'a', includePrivate: false,
      expiresAt: '2026-12-31T00:00:00Z', revokedAt: null, createdAt: 'c',
      shareAvailable: true,
    }]);
    expect('token' in (links[0] as object)).toBe(false);
  });

  it('returns [] when the RPC returns null', async () => {
    h.state.data = null;
    expect(await listShareLinks()).toEqual([]);
  });
});

describe('revokeShareLink', () => {
  it('sends the id and returns the boolean result', async () => {
    h.state.data = true;
    expect(await revokeShareLink('l1')).toBe(true);
    expect(h.calls[0]).toEqual({ name: 'revoke_share_link', params: { p_id: 'l1' } });
  });
});

// 0022. Same shape of contract as deleteShareLink below: `false` is a VALUE, not
// a failure. The RPC returns it for an absent id, another owner's id, a revoked
// link and an expired one, so a client cannot use it to probe for rows -- and
// because the RPC is idempotent, it never means "the value was already that".
describe('setShareAvailable', () => {
  it('sends the id and the flag, and returns the boolean result', async () => {
    h.state.data = true;
    expect(await setShareAvailable('l1', true)).toBe(true);
    expect(h.calls[0]).toEqual({
      name: 'set_share_available',
      params: { p_id: 'l1', p_enabled: true },
    });
  });

  it('sends false as false, not as an omission', async () => {
    h.state.data = true;
    await setShareAvailable('l1', false);
    expect((h.calls[0]!.params as Record<string, unknown>).p_enabled).toBe(false);
  });

  it('resolves false for a refusal instead of throwing', async () => {
    h.state.data = false;
    await expect(setShareAvailable('nope', true)).resolves.toBe(false);
  });

  it('throws only on an RPC error', async () => {
    h.state.error = { message: 'authentication required' };
    await expect(setShareAvailable('l1', true)).rejects.toThrow(/authentication required/);
  });

  // 0016's quota trigger selects only owners whose count RISES and this UPDATE
  // moves no count, so its markers cannot reach here. If one somehow does, it
  // must stay a plain Error rather than be dressed up as a quota refusal the
  // owner cannot act on.
  it('does not route errors through mapShareLinkError', async () => {
    h.state.error = { code: '23514', details: 'TIMEWEAVE_QUOTA_SHARE_LINKS_ACTIVE', message: 'quota' };
    const e = await setShareAvailable('l1', true).catch((x: unknown) => x);
    expect(e).not.toBeInstanceOf(ShareLinkActiveQuotaExceededError);
    expect((e as Error).message).toBe('quota');
  });
});

// 0015. The contract this pins is that `false` is a VALUE, not a failure: the
// RPC returns it uniformly for an absent id, another owner's id, and one that
// is still active, so a client cannot use it to probe for rows. Turning any of
// those into a throw would be inventing information the database refused to
// give, so these tests assert the resolution, not a rejection.
describe('deleteShareLink', () => {
  it('calls delete_share_link with p_id', async () => {
    h.state.data = true;
    await deleteShareLink('l1');
    expect(h.calls).toHaveLength(1);
    expect(h.calls[0]).toEqual({ name: 'delete_share_link', params: { p_id: 'l1' } });
  });

  it('returns true when the row was deleted', async () => {
    h.state.data = true;
    await expect(deleteShareLink('l1')).resolves.toBe(true);
  });

  it('resolves false -- not throws -- when the RPC refuses', async () => {
    h.state.data = false;
    await expect(deleteShareLink('l1')).resolves.toBe(false);
  });

  it('resolves false when the RPC returns null', async () => {
    h.state.data = null;
    await expect(deleteShareLink('l1')).resolves.toBe(false);
  });

  it('propagates an RPC error with the server message, like revoke does', async () => {
    h.state.error = { message: 'authentication required' };
    await expect(deleteShareLink('l1')).rejects.toThrow(/authentication required/);
  });

  // DELETE fires no trigger in 0016, so none of mapShareLinkError's three
  // markers can arrive here. If this call ever started routing through that
  // mapping, a stray DETAIL would silently change the error's class.
  it('does not route failures through the create-only quota mapping', async () => {
    h.state.error = {
      code: '23514',
      details: 'TIMEWEAVE_QUOTA_SHARE_LINKS_TOTAL',
      message: 'refused',
    };
    const e = await deleteShareLink('l1').catch((x: unknown) => x);
    expect(e).not.toBeInstanceOf(ShareLinkTotalQuotaExceededError);
    expect((e as Error).constructor).toBe(Error);
    expect((e as Error).message).toBe('refused');
  });
});

describe('getFreeBusy', () => {
  it('passes the two windows and parses the discriminated slots', async () => {
    h.state.data = {
      complete: false,
      slots: [
        { all_day: true, start_date: '2026-09-01', end_date: '2026-09-02' },
        { all_day: false, start: '2026-09-01T09:00:00+00:00', end: '2026-09-01T10:00:00+00:00' },
      ],
    };
    const res = await getFreeBusy(
      't', '2026-09-01T00:00:00Z', '2026-09-08T00:00:00Z', '2026-09-01', '2026-09-08',
    );
    expect(h.calls[0]).toEqual({
      name: 'get_free_busy',
      params: {
        p_token: 't',
        p_from: '2026-09-01T00:00:00Z', p_to: '2026-09-08T00:00:00Z',
        p_from_date: '2026-09-01', p_to_date: '2026-09-08',
      },
    });
    expect(res).toEqual({
      // 0023 added linkState; this response predates it and so reads as active.
      linkState: 'active',
      complete: false,
      slots: [
        { allDay: true, startDate: '2026-09-01', endDate: '2026-09-02' },
        { allDay: false, start: '2026-09-01T09:00:00+00:00', end: '2026-09-01T10:00:00+00:00' },
      ],
    });
  });

  it('defaults to complete=false-safe empty when data is empty', async () => {
    h.state.data = {};
    const res = await getFreeBusy('t', 'a', 'b', 'c', 'd');
    expect(res).toEqual({ linkState: 'active', complete: false, slots: [] });
  });

  it('propagates the 22023 over-range error', async () => {
    h.state.error = { message: 'requested range exceeds 92 days' };
    await expect(getFreeBusy('t', 'a', 'b', 'c', 'd')).rejects.toThrow(/exceeds 92 days/);
  });

  // 0023. link_state is the ONLY thing that may hide a calendar, and only when
  // it is exactly 'unavailable'. Everything else -- a backend that predates the
  // migration, an explicit null, a value from some later phase this build has
  // never heard of -- must read as active, because the cost of the two mistakes
  // is not symmetric: calling an active link unavailable hides a real owner's
  // busy times behind what looks like a broken link, while calling an
  // unavailable link active merely reproduces the pre-0023 page, since such a
  // response carries complete=true and slots=[] anyway.
  it('reads link_state active and keeps the Busy payload', async () => {
    h.state.data = {
      link_state: 'active',
      complete: true,
      slots: [{ all_day: false, start: '2026-09-01T09:00:00+00:00', end: '2026-09-01T10:00:00+00:00' }],
    };
    const res = await getFreeBusy('t', 'a', 'b', 'c', 'd');
    expect(res.linkState).toBe('active');
    expect(res.complete).toBe(true);
    expect(res.slots).toEqual([
      { allDay: false, start: '2026-09-01T09:00:00+00:00', end: '2026-09-01T10:00:00+00:00' },
    ]);
  });

  it('reads link_state unavailable', async () => {
    h.state.data = { link_state: 'unavailable', complete: true, slots: [] };
    const res = await getFreeBusy('t', 'a', 'b', 'c', 'd');
    expect(res).toEqual({ linkState: 'unavailable', complete: true, slots: [] });
  });

  it('treats a legacy response with no link_state as active', async () => {
    h.state.data = { complete: true, slots: [] };
    expect((await getFreeBusy('t', 'a', 'b', 'c', 'd')).linkState).toBe('active');
  });

  it('treats a null link_state as active', async () => {
    h.state.data = { link_state: null, complete: true, slots: [] };
    expect((await getFreeBusy('t', 'a', 'b', 'c', 'd')).linkState).toBe('active');
  });

  it('treats an unrecognised link_state as active, not unavailable', async () => {
    h.state.data = { link_state: 'suspended', complete: true, slots: [] };
    expect((await getFreeBusy('t', 'a', 'b', 'c', 'd')).linkState).toBe('active');
  });

  it('keeps complete=false alongside a link_state', async () => {
    h.state.data = { link_state: 'active', complete: false, slots: [] };
    const res = await getFreeBusy('t', 'a', 'b', 'c', 'd');
    expect(res).toEqual({ linkState: 'active', complete: false, slots: [] });
  });
});

// 0019. The mapping itself is covered in freeBusyError.test.ts; what matters
// here is that getFreeBusy routes the PostgrestError through it -- details and
// hint included -- instead of keeping only the message.
describe('getFreeBusy: 0019 rate-limit refusals', () => {
  it('turns the rate marker into FreeBusyRateLimitedError, carrying the hint', async () => {
    h.state.error = {
      code: 'PT429',
      details: 'TIMEWEAVE_RATE_FREEBUSY',
      hint: 'retry_after_seconds=9',
      message: 'free/busy rate exceeded for this share link',
    };
    const e = await getFreeBusy('t', 'a', 'b', 'c', 'd').catch((x: unknown) => x);
    expect(e).toBeInstanceOf(FreeBusyRateLimitedError);
    expect((e as FreeBusyRateLimitedError).kind).toBe('rate');
    expect((e as FreeBusyRateLimitedError).retryAfterSeconds).toBe(9);
  });

  it('turns the busy marker into the busy kind', async () => {
    h.state.error = {
      code: 'PT429',
      details: 'TIMEWEAVE_RATE_FREEBUSY_BUSY',
      hint: 'retry_after_seconds=1',
      message: 'free/busy is busy for this calendar',
    };
    const e = await getFreeBusy('t', 'a', 'b', 'c', 'd').catch((x: unknown) => x);
    expect(e).toBeInstanceOf(FreeBusyRateLimitedError);
    expect((e as FreeBusyRateLimitedError).kind).toBe('busy');
  });

  it('leaves an unknown PT429 as a plain Error with the server message', async () => {
    h.state.error = { code: 'PT429', details: 'TIMEWEAVE_RATE_SOMETHING_NEW', message: 'refused' };
    const e = await getFreeBusy('t', 'a', 'b', 'c', 'd').catch((x: unknown) => x);
    expect(e).not.toBeInstanceOf(FreeBusyRateLimitedError);
    expect((e as Error).message).toBe('refused');
  });

  it('still returns data when there is no error', async () => {
    h.state.data = { complete: true, slots: [] };
    // linkState is 0023's addition; this fixture carries no link_state, so the
    // legacy fallback applies. The point of the test -- that a successful call
    // is not routed through the rate-limit mapping -- is unchanged.
    await expect(getFreeBusy('t', 'a', 'b', 'c', 'd'))
      .resolves.toEqual({ linkState: 'active', complete: true, slots: [] });
  });
});
