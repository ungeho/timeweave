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
  getFreeBusy,
  listShareLinks,
  revokeShareLink,
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
      expires_at: null, created_at: '2026-08-30T00:00:00Z',
    }];
    const link = await createShareLink({ label: 'v', includePrivate: true });
    expect(h.calls[0]).toEqual({
      name: 'create_share_link',
      params: { p_label: 'v', p_include_private: true, p_expires_at: null },
    });
    expect(link).toEqual({
      id: 'l1', token: 'secret-token', label: 'v', includePrivate: true,
      expiresAt: null, revokedAt: null, createdAt: '2026-08-30T00:00:00Z',
    });
  });

  it('defaults include_private to true when omitted', async () => {
    h.state.data = [{ id: 'l', token: 't', label: null, include_private: true, expires_at: null, created_at: 'c' }];
    await createShareLink();
    expect((h.calls[0]!.params as Record<string, unknown>).p_include_private).toBe(true);
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
    }];
    const links = await listShareLinks();
    expect(links).toEqual([{
      id: 'l1', label: 'a', includePrivate: false,
      expiresAt: '2026-12-31T00:00:00Z', revokedAt: null, createdAt: 'c',
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
    expect(res).toEqual({ complete: false, slots: [] });
  });

  it('propagates the 22023 over-range error', async () => {
    h.state.error = { message: 'requested range exceeds 92 days' };
    await expect(getFreeBusy('t', 'a', 'b', 'c', 'd')).rejects.toThrow(/exceeds 92 days/);
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
    await expect(getFreeBusy('t', 'a', 'b', 'c', 'd')).resolves.toEqual({ complete: true, slots: [] });
  });
});
