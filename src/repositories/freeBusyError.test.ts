/**
 * mapFreeBusyError is pure, so it is exercised directly rather than through a
 * fake Supabase client -- the same way eventWriteError.test.ts treats its
 * mapping. shareRepository.test.ts covers the wiring from the RPC to here.
 */

import { describe, expect, it } from 'vitest';
import { FreeBusyRateLimitedError } from '../errors';
import { mapFreeBusyError } from './freeBusyError';

describe('mapFreeBusyError: rate token (0019)', () => {
  const rate = (hint?: string | null) =>
    mapFreeBusyError({ code: 'PT429', details: 'TIMEWEAVE_RATE_FREEBUSY', hint });

  it('maps TIMEWEAVE_RATE_FREEBUSY to a rate-kind FreeBusyRateLimitedError', () => {
    const e = rate('retry_after_seconds=7') as FreeBusyRateLimitedError;
    expect(e).toBeInstanceOf(FreeBusyRateLimitedError);
    expect(e.kind).toBe('rate');
    expect(e.name).toBe('FreeBusyRateLimitedError');
  });

  it('carries the wait as a field and in the message', () => {
    const e = rate('retry_after_seconds=7') as FreeBusyRateLimitedError;
    expect(e.retryAfterSeconds).toBe(7);
    expect(e.message).toContain('約7秒後');
  });

  it('says minutes, rounded up, once the wait passes a minute', () => {
    const e = rate('retry_after_seconds=61') as FreeBusyRateLimitedError;
    expect(e.retryAfterSeconds).toBe(61);
    expect(e.message).toContain('約2分後');
  });

  // 0019 raises the owner refusal and the link refusal with the SAME detail and
  // different MESSAGE prose. The mapping must not read the prose, so both have
  // to come out identical -- including the kind, which a viewer could otherwise
  // use to learn that another link of the same calendar is being hammered.
  it.each([
    ['owner', 'free/busy rate exceeded for this calendar'],
    ['link', 'free/busy rate exceeded for this share link'],
  ] as const)('ignores the %s message wording entirely', (_which, message) => {
    const e = mapFreeBusyError({
      code: 'PT429', details: 'TIMEWEAVE_RATE_FREEBUSY', hint: 'retry_after_seconds=4', message,
    }) as FreeBusyRateLimitedError;
    expect(e.kind).toBe('rate');
    expect(e.retryAfterSeconds).toBe(4);
    expect(e.message).not.toContain('calendar');
    expect(e.message).not.toContain('share link');
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
    const e = rate(hint) as FreeBusyRateLimitedError;
    // The classification is never in doubt -- only the precision of the advice.
    expect(e).toBeInstanceOf(FreeBusyRateLimitedError);
    expect(e.kind).toBe('rate');
    expect(e.retryAfterSeconds).toBeNull();
    expect(e.message).toContain('しばらく待ってから');
    expect(e.message).not.toMatch(/約\d/);
  });
});

describe('mapFreeBusyError: busy token (0019)', () => {
  it('maps TIMEWEAVE_RATE_FREEBUSY_BUSY to a busy-kind error with 0019\'s 1 s hint', () => {
    const e = mapFreeBusyError({
      code: 'PT429', details: 'TIMEWEAVE_RATE_FREEBUSY_BUSY', hint: 'retry_after_seconds=1',
      message: 'free/busy is busy for this calendar',
    }) as FreeBusyRateLimitedError;
    expect(e).toBeInstanceOf(FreeBusyRateLimitedError);
    expect(e.kind).toBe('busy');
    expect(e.retryAfterSeconds).toBe(1);
    expect(e.message).toContain('混み合っています');
    expect(e.message).toContain('約1秒後');
  });

  it('is worded differently from the rate kind', () => {
    const busy = mapFreeBusyError({ details: 'TIMEWEAVE_RATE_FREEBUSY_BUSY', hint: 'retry_after_seconds=1' });
    const rate = mapFreeBusyError({ details: 'TIMEWEAVE_RATE_FREEBUSY', hint: 'retry_after_seconds=1' });
    expect(busy.message).not.toBe(rate.message);
    expect(rate.message).toContain('一時的に制限しています');
  });

  it('keeps the kind when the hint is unusable', () => {
    const e = mapFreeBusyError({ details: 'TIMEWEAVE_RATE_FREEBUSY_BUSY' }) as FreeBusyRateLimitedError;
    expect(e.kind).toBe('busy');
    expect(e.retryAfterSeconds).toBeNull();
    expect(e.message).toContain('しばらく待ってから');
  });
});

describe('mapFreeBusyError: everything else', () => {
  it('passes the 92-day 22023 through with its own message', () => {
    const e = mapFreeBusyError({ code: '22023', message: 'requested range exceeds 92 days' });
    expect(e).not.toBeInstanceOf(FreeBusyRateLimitedError);
    expect(e.message).toBe('requested range exceeds 92 days');
  });

  // PT429 is not the discriminator: a future limiter could use the same code
  // with a marker this build has never heard of, and guessing "rate limit" for
  // it would put a wait time on screen that nobody promised.
  it('does not assume a rate limit from PT429 alone', () => {
    const e = mapFreeBusyError({ code: 'PT429', details: 'TIMEWEAVE_RATE_SOMETHING_NEW', hint: 'retry_after_seconds=5', message: 'nope' });
    expect(e).not.toBeInstanceOf(FreeBusyRateLimitedError);
    expect(e.message).toBe('nope');
  });

  it.each([
    ['a near-miss marker', 'TIMEWEAVE_RATE_FREEBUSY_'],
    ['the events marker', 'TIMEWEAVE_RATE_EVENTS'],
    ['an empty detail', ''],
  ] as const)('leaves %s unmapped', (_label, details) => {
    const e = mapFreeBusyError({ code: 'PT429', details, message: 'server said so' });
    expect(e).not.toBeInstanceOf(FreeBusyRateLimitedError);
    expect(e.message).toBe('server said so');
  });

  it('never swallows a failure with no message', () => {
    expect(mapFreeBusyError({ code: '42501' }).message).toBe('Unknown database error');
    expect(mapFreeBusyError({ message: null }).message).toBe('Unknown database error');
  });
});
