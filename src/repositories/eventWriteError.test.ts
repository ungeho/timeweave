import { describe, expect, it } from 'vitest';
import {
  DuplicateExceptionError,
  EventQuotaExceededError,
  ExceptionQuotaExceededError,
  InvalidTimezoneError,
  TimezoneClearedError,
  TimezoneRequiredError,
  WriteRateLimitedError,
} from '../errors';
import { mapEventWriteError, parseRetryAfterSeconds } from './eventWriteError';

/**
 * The database's write-error contract, pinned from the TypeScript side.
 *
 * mapEventWriteError is pure, so it is exercised directly rather than through a
 * repository. supabaseEventRepository.test.ts keeps its own 23505 case: that one
 * proves the repository CALLS this mapping, and is left alone on purpose.
 *
 * The discriminator is the DETAIL token and nothing else. These tests therefore
 * pass a `code` that does not match any token's SQLSTATE wherever the token is
 * what should decide, so a mapping that quietly started branching on SQLSTATE
 * would fail here.
 */

describe('mapEventWriteError: existing branches', () => {
  it('maps 23505 to DuplicateExceptionError', () => {
    expect(mapEventWriteError({ code: '23505', message: 'duplicate key' }))
      .toBeInstanceOf(DuplicateExceptionError);
  });

  it('lets 23505 win over any DETAIL token', () => {
    // Order matters: the unique index has no token of its own, so the SQLSTATE
    // check has to run before the switch. If it ever moves below, this fails.
    const e = mapEventWriteError({
      code: '23505',
      details: 'TIMEWEAVE_RATE_EVENTS',
      message: 'duplicate key',
    });
    expect(e).toBeInstanceOf(DuplicateExceptionError);
  });

  it.each([
    ['TIMEWEAVE_TZ_INVALID', InvalidTimezoneError],
    ['TIMEWEAVE_TZ_REQUIRED', TimezoneRequiredError],
    ['TIMEWEAVE_TZ_CLEARED', TimezoneClearedError],
  ] as const)('maps %s to its domain error', (details, ctor) => {
    expect(mapEventWriteError({ code: '23514', details })).toBeInstanceOf(ctor);
  });

  it('passes an unrecognised failure through with the server message', () => {
    const e = mapEventWriteError({ code: '42501', message: 'permission denied for table events' });
    expect(e.constructor).toBe(Error);
    expect(e.message).toBe('permission denied for table events');
  });

  it('names the failure even when the server said nothing', () => {
    expect(mapEventWriteError({ code: '42501' }).message).toBe('Unknown database error');
    expect(mapEventWriteError({ message: null }).message).toBe('Unknown database error');
  });
});

describe('mapEventWriteError: quota tokens (0011)', () => {
  it('maps TIMEWEAVE_QUOTA_EVENTS to EventQuotaExceededError', () => {
    const e = mapEventWriteError({ code: '23514', details: 'TIMEWEAVE_QUOTA_EVENTS' });
    expect(e).toBeInstanceOf(EventQuotaExceededError);
    expect(e.message).toContain('上限に達しました');
  });

  it('maps TIMEWEAVE_QUOTA_EXCEPTIONS to ExceptionQuotaExceededError', () => {
    const e = mapEventWriteError({ code: '23514', details: 'TIMEWEAVE_QUOTA_EXCEPTIONS' });
    expect(e).toBeInstanceOf(ExceptionQuotaExceededError);
    expect(e.message).toContain('個別変更');
  });

  it('does not name a number in either message', () => {
    // The limits live in the database (events_max_per_owner / _exceptions_per_master,
    // granted to authenticated for exactly this reason). A copy here could drift.
    for (const details of ['TIMEWEAVE_QUOTA_EVENTS', 'TIMEWEAVE_QUOTA_EXCEPTIONS']) {
      expect(mapEventWriteError({ code: '23514', details }).message).not.toMatch(/\d/);
    }
  });
});

describe('mapEventWriteError: rate token (0012)', () => {
  const rate = (hint?: string | null) =>
    mapEventWriteError({ code: 'PT429', details: 'TIMEWEAVE_RATE_EVENTS', hint });

  it('maps TIMEWEAVE_RATE_EVENTS to WriteRateLimitedError', () => {
    expect(rate('retry_after_seconds=7')).toBeInstanceOf(WriteRateLimitedError);
  });

  it('carries the wait as a field and in the message', () => {
    const e = rate('retry_after_seconds=7') as WriteRateLimitedError;
    expect(e.retryAfterSeconds).toBe(7);
    expect(e.message).toContain('約7秒後');
  });

  it('says minutes, rounded up, once the wait passes a minute', () => {
    const e = rate('retry_after_seconds=61') as WriteRateLimitedError;
    expect(e.retryAfterSeconds).toBe(61);
    expect(e.message).toContain('約2分後');
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
    const e = rate(hint) as WriteRateLimitedError;
    // The class is never in doubt -- only the precision of the advice is.
    expect(e).toBeInstanceOf(WriteRateLimitedError);
    expect(e.retryAfterSeconds).toBeNull();
    expect(e.message).toContain('しばらく待ってから');
    expect(e.message).not.toMatch(/約\d/);
  });

  it('falls back to generic advice if constructed with a zero wait directly', () => {
    // The parser never yields 0 (see its tests), but the constructor is public.
    // "約0秒後" would read as a bug, so retryAdvice keeps its own guard.
    const e = new WriteRateLimitedError(0);
    expect(e.message).toContain('しばらく待ってから');
    expect(e.message).not.toMatch(/約\d/);
  });
});

describe('parseRetryAfterSeconds', () => {
  it.each([
    ['retry_after_seconds=7', 7],
    ['retry_after_seconds=1', 1],
    ['retry_after_seconds=3600', 3600],
    ['retry_after_seconds=007', 7],
    ['retry_after_seconds=7;next=1', 7],
    ['retry_after_seconds=7, next=1', 7],
    ['foo; retry_after_seconds=7', 7],
    ['foo;retry_after_seconds=7', 7],
    ['foo,retry_after_seconds=7', 7],
    ['wait (retry_after_seconds=7)', 7],
    ['owner is 00:00:59 ahead; retry_after_seconds=60 from now', 60],
  ] as const)('accepts %s', (hint, want) => {
    expect(parseRetryAfterSeconds(hint)).toBe(want);
  });

  it.each([
    ['null', null],
    ['undefined', undefined],
    ['empty', ''],
    ['no token', 'wait a while'],
    ['no value', 'retry_after_seconds='],
    ['not a number', 'retry_after_seconds=soon'],
    ['negative', 'retry_after_seconds=-5'],
    ['fractional', 'retry_after_seconds=7.5'],
    ['fractional, zero part', 'retry_after_seconds=0.5'],
    ['a key with a letter prefix', 'xretry_after_seconds=7'],
    ['a key with an underscore prefix', 'max_retry_after_seconds=7'],
    ['a key with a digit prefix', '2retry_after_seconds=7'],
    ['a dotted key', 'hint.retry_after_seconds=7'],
    ['trailing letters', 'retry_after_seconds=7abc'],
    ['a unit suffix', 'retry_after_seconds=7s'],
    ['trailing underscore', 'retry_after_seconds=7_'],
    ['zero', 'retry_after_seconds=0'],
    ['zero, padded', 'retry_after_seconds=000'],
    ['past the hour', 'retry_after_seconds=3601'],
    ['absurd', 'retry_after_seconds=999999999999999999999'],
  ] as const)('rejects %s', (_label, hint) => {
    expect(parseRetryAfterSeconds(hint)).toBeNull();
  });

  it('rejects a fractional value rather than truncating it', () => {
    // The contract emits ceil(...)::text. A fraction means the contract is not
    // what this parser believes, and a truncated guess would be a wrong number
    // presented as a right one.
    expect(parseRetryAfterSeconds('retry_after_seconds=7.5')).not.toBe(7);
    expect(parseRetryAfterSeconds('retry_after_seconds=7.5')).toBeNull();
  });

  it('rejects trailing garbage rather than reading the leading digits', () => {
    // Same reasoning as the fraction: `7abc` is not a value the contract emits,
    // and backtracking to a shorter digit run must not turn `77abc` into 7.
    expect(parseRetryAfterSeconds('retry_after_seconds=7abc')).toBeNull();
    expect(parseRetryAfterSeconds('retry_after_seconds=77abc')).toBeNull();
  });

  it('recognises the key only as a token of its own', () => {
    expect(parseRetryAfterSeconds('retry_after_seconds=7')).toBe(7);
    expect(parseRetryAfterSeconds('foo; retry_after_seconds=7')).toBe(7);
    expect(parseRetryAfterSeconds('xretry_after_seconds=7')).toBeNull();
  });

  it('skips an embedded key and still finds a standalone one later', () => {
    // The left boundary rejects the embedded occurrence; it must not stop the
    // search from reaching the real token further along.
    expect(parseRetryAfterSeconds('xretry_after_seconds=99 retry_after_seconds=7')).toBe(7);
  });
});
