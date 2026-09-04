/**
 * Persistence-side timezone helpers.
 *
 * The accept/reject lists mirror supabase/tests/0008_events_timezone_test.sql
 * section 2, minus the two rules only the database can apply: exact
 * pg_timezone_names membership, and case sensitivity. Those divergences are
 * asserted explicitly below so that the split of responsibility stays visible.
 */

import { afterEach, describe, expect, it, vi } from 'vitest';
import { getUserTimeZone, isStorableTimeZone, resolveStorableTimeZone } from './timezone';

/** Replace what Intl.DateTimeFormat().resolvedOptions().timeZone reports. */
function stubResolvedTimeZone(value: unknown): void {
  const real = Intl.DateTimeFormat;
  vi.spyOn(Intl, 'DateTimeFormat').mockImplementation(((...args: unknown[]) => {
    // Only the zero-argument call reads the environment; validation calls
    // (which pass a locale and options) must keep the real behaviour.
    if (args.length === 0) {
      return { resolvedOptions: () => ({ timeZone: value }) } as unknown as Intl.DateTimeFormat;
    }
    return new (real as unknown as new (...a: unknown[]) => Intl.DateTimeFormat)(...args);
  }) as unknown as typeof Intl.DateTimeFormat);
}

afterEach(() => {
  vi.restoreAllMocks();
});

describe('isStorableTimeZone — accepted', () => {
  it.each([
    'Asia/Tokyo',
    'America/New_York',
    'Europe/London',
    'Pacific/Auckland',
    'UTC',
    'Etc/GMT-9',
    'America/Argentina/Buenos_Aires',
  ])('accepts %s', (tz) => {
    expect(isStorableTimeZone(tz)).toBe(true);
  });

  it('accepts an alias — neither side canonicalises', () => {
    expect(isStorableTimeZone('Asia/Calcutta')).toBe(true);
  });

  it('accepts a deliberately fixed offset — DST-free is a valid choice', () => {
    expect(isStorableTimeZone('Etc/GMT-9')).toBe(true);
    expect(isStorableTimeZone('UTC')).toBe(true);
  });
});

describe('isStorableTimeZone — refused', () => {
  it.each([
    ['Mars/Phobos', 'not a real zone'],
    ['', 'empty'],
    ['localtime', 'server-configuration dependent'],
    ['posix/Asia/Tokyo', 'duplicate spelling'],
    ['right/UTC', 'leap-second counting'],
    ['<+09>-9', 'raw POSIX specification'],
    ['Asia/Tokyo ', 'trailing space'],
    ['/Asia/Tokyo', 'leading separator'],
    ['Asia Tokyo', 'space instead of a separator'],
    ['Asia/Tokyo/Extra/Deep', 'too many segments'],
  ])('refuses %s (%s)', (tz) => {
    expect(isStorableTimeZone(tz)).toBe(false);
  });

  it('refuses a name over the 64 character cap', () => {
    expect(isStorableTimeZone('A'.repeat(65))).toBe(false);
  });
});

describe('isStorableTimeZone — deliberate divergence from the database', () => {
  it('accepts abbreviations that Intl knows but pg_timezone_names does not', () => {
    // ICU resolves legacy abbreviations such as JST; the catalog has no row for
    // them, so the DB refuses them with TIMEWEAVE_TZ_INVALID. Letting them past
    // here costs nothing: resolveStorableTimeZone never produces one, because
    // Intl reports a region zone for the environment.
    expect(isStorableTimeZone('JST')).toBe(true);
  });

  it('does not check case; the DB compares against pg_timezone_names exactly', () => {
    // 'asia/tokyo' resolves in Intl but has no pg_timezone_names row, so the DB
    // refuses it with TIMEWEAVE_TZ_INVALID. Being laxer here is the safe
    // direction: this function fails early, it never decides.
    expect(isStorableTimeZone('asia/tokyo')).toBe(true);
  });
});

describe('resolveStorableTimeZone', () => {
  it('returns the runtime zone verbatim, without canonicalising', () => {
    stubResolvedTimeZone('Asia/Calcutta');
    expect(resolveStorableTimeZone()).toBe('Asia/Calcutta');
  });

  it('returns null when the runtime reports an empty zone', () => {
    stubResolvedTimeZone('');
    expect(resolveStorableTimeZone()).toBeNull();
  });

  it('returns null when the runtime reports no zone at all', () => {
    stubResolvedTimeZone(undefined);
    expect(resolveStorableTimeZone()).toBeNull();
  });

  it('returns null for a zone that would not be storable', () => {
    stubResolvedTimeZone('localtime');
    expect(resolveStorableTimeZone()).toBeNull();
  });

  it('never falls back to UTC — that is the whole point', () => {
    stubResolvedTimeZone('');
    expect(resolveStorableTimeZone()).not.toBe('UTC');
  });
});

describe('getUserTimeZone — unchanged layout helper', () => {
  it('still falls back to UTC, because a layout must draw something', () => {
    stubResolvedTimeZone('');
    expect(getUserTimeZone()).toBe('UTC');
  });

  it('returns the runtime zone when there is one', () => {
    stubResolvedTimeZone('Asia/Tokyo');
    expect(getUserTimeZone()).toBe('Asia/Tokyo');
  });
});
