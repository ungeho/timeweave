/**
 * mapShareLinkError is pure, so it is exercised directly, the way
 * eventWriteError.test.ts and freeBusyError.test.ts treat their mappings.
 * shareRepository.test.ts covers the wiring from the RPC to here.
 *
 * The UUID checks are the point of the whole module: 0016 formats the owner's
 * id and the configured ceilings into its message, so a mapped error must never
 * carry them.
 */

import { describe, expect, it } from 'vitest';
import {
  ShareLinkActiveQuotaExceededError,
  ShareLinkRateLimitedError,
  ShareLinkTotalQuotaExceededError,
} from '../errors';
import { mapShareLinkError } from './shareLinkError';

// Shaped exactly like what 0016 raises, including the owner id and the limits.
const OWNER = 'aa39f01f-e076-47a1-915c-e92a963c2efb';
const ACTIVE_MSG = `share link quota exceeded: owner ${OWNER} would hold 26 active links, limit is 25`;
const TOTAL_MSG = `share link quota exceeded: owner ${OWNER} would hold 101 share links, limit is 100`;
const RATE_MSG = `share link create rate exceeded: owner ${OWNER} is 00:00:07 beyond an allowance of 00:02:00 at 00:00:10 per link`;

describe('mapShareLinkError: active quota (0016)', () => {
  const err = () => mapShareLinkError({
    code: '23514',
    details: 'TIMEWEAVE_QUOTA_SHARE_LINKS_ACTIVE',
    hint: 'Revoke an existing share link to free an active slot.',
    message: ACTIVE_MSG,
  });

  it('maps to ShareLinkActiveQuotaExceededError', () => {
    expect(err()).toBeInstanceOf(ShareLinkActiveQuotaExceededError);
    expect(err().name).toBe('ShareLinkActiveQuotaExceededError');
  });

  it('names revoking, which the UI can actually do', () => {
    expect(err().message).toContain('失効');
  });

  it('carries neither the owner id nor the ceiling', () => {
    expect(err().message).not.toContain(OWNER);
    expect(err().message).not.toMatch(/\d/);
  });
});

describe('mapShareLinkError: total quota (0016)', () => {
  const err = () => mapShareLinkError({
    code: '23514',
    details: 'TIMEWEAVE_QUOTA_SHARE_LINKS_TOTAL',
    hint: 'Delete revoked share links to free capacity; revoking alone does not.',
    message: TOTAL_MSG,
  });

  it('maps to ShareLinkTotalQuotaExceededError', () => {
    expect(err()).toBeInstanceOf(ShareLinkTotalQuotaExceededError);
  });

  it('is worded differently from the active quota', () => {
    const active = mapShareLinkError({ details: 'TIMEWEAVE_QUOTA_SHARE_LINKS_ACTIVE' });
    expect(err().message).not.toBe(active.message);
  });

  // The dialog has no delete action, so the message must not ask for one --
  // and it must not let the user think revoking will help.
  it('asks for no operation this app does not offer', () => {
    expect(err().message).not.toMatch(/削除/);
    expect(err().message).toContain('失効させても総数は減りません');
  });

  it('carries neither the owner id nor the ceiling', () => {
    expect(err().message).not.toContain(OWNER);
    expect(err().message).not.toMatch(/\d/);
  });
});

describe('mapShareLinkError: create rate (0016)', () => {
  const rate = (hint?: string | null) =>
    mapShareLinkError({ code: 'PT429', details: 'TIMEWEAVE_RATE_SHARE_LINKS', hint, message: RATE_MSG });

  it('maps to ShareLinkRateLimitedError and carries the wait', () => {
    const e = rate('retry_after_seconds=7') as ShareLinkRateLimitedError;
    expect(e).toBeInstanceOf(ShareLinkRateLimitedError);
    expect(e.retryAfterSeconds).toBe(7);
    expect(e.message).toContain('約7秒後');
  });

  it('says minutes, rounded up, once the wait passes a minute', () => {
    const e = rate('retry_after_seconds=61') as ShareLinkRateLimitedError;
    expect(e.retryAfterSeconds).toBe(61);
    expect(e.message).toContain('約2分後');
  });

  it('carries neither the owner id nor the raw intervals', () => {
    const e = rate('retry_after_seconds=7');
    expect(e.message).not.toContain(OWNER);
    expect(e.message).not.toContain('00:02:00');
  });

  it.each([
    ['a missing hint', undefined],
    ['a null hint', null],
    ['an empty hint', ''],
    ['a hint with no token', 'try again later'],
    ['a non-numeric value', 'retry_after_seconds=abc'],
    ['an empty value', 'retry_after_seconds='],
    ['a negative value', 'retry_after_seconds=-1'],
    ['a fractional value', 'retry_after_seconds=7.5'],
    ['a value with trailing garbage', 'retry_after_seconds=7abc'],
    ['a zero wait', 'retry_after_seconds=0'],
    ['a value beyond an hour', 'retry_after_seconds=3601'],
  ] as const)('still refuses correctly with %s', (_label, hint) => {
    const e = rate(hint) as ShareLinkRateLimitedError;
    expect(e).toBeInstanceOf(ShareLinkRateLimitedError);
    expect(e.retryAfterSeconds).toBeNull();
    expect(e.message).toContain('しばらく待ってから');
    expect(e.message).not.toMatch(/約\d/);
  });
});

describe('mapShareLinkError: everything else', () => {
  // SQLSTATE is not the discriminator: 23514 is shared with every other CHECK
  // and PT429 with every other limiter.
  it.each([
    ['23514 with an unknown token', '23514', 'TIMEWEAVE_QUOTA_SOMETHING_NEW'],
    ['PT429 with an unknown token', 'PT429', 'TIMEWEAVE_RATE_SOMETHING_NEW'],
    ['the events quota token', '23514', 'TIMEWEAVE_QUOTA_EVENTS'],
    ['a near-miss token', '23514', 'TIMEWEAVE_QUOTA_SHARE_LINKS'],
    ['an empty detail', '23514', ''],
  ] as const)('leaves %s unmapped', (_label, code, details) => {
    const e = mapShareLinkError({ code, details, message: 'server said so' });
    expect(e).not.toBeInstanceOf(ShareLinkActiveQuotaExceededError);
    expect(e).not.toBeInstanceOf(ShareLinkTotalQuotaExceededError);
    expect(e).not.toBeInstanceOf(ShareLinkRateLimitedError);
    expect(e.message).toBe('server said so');
  });

  it('passes an ordinary failure through with its own message', () => {
    expect(mapShareLinkError({ message: 'authentication required' }).message)
      .toBe('authentication required');
  });

  it('never swallows a failure with no message', () => {
    expect(mapShareLinkError({ code: '42501' }).message).toBe('Unknown database error');
    expect(mapShareLinkError({ message: null }).message).toBe('Unknown database error');
  });
});
