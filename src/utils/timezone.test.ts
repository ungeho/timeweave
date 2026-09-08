/**
 * Persistence-side timezone helpers.
 *
 * The accept/reject lists mirror supabase/tests/0008_events_timezone_test.sql
 * section 2, minus the two rules only the database can apply: exact
 * pg_timezone_names membership, and case sensitivity. Those divergences are
 * asserted explicitly below so that the split of responsibility stays visible.
 */

import { afterEach, describe, expect, it, vi } from 'vitest';
import type { ZonedWallClock } from './timezone';
import {
  getUserTimeZone,
  isStorableTimeZone,
  resolveStorableTimeZone,
  resolveZonedWallClock,
  zonedWallClockOf,
} from './timezone';

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

/**
 * Phase 5b-4 -- PostgreSQL-compatible wall-clock resolution.
 *
 * Every expected instant below is a MEASURED PostgreSQL value, not a derivation:
 *   America/New_York -- supabase/tests/0009_timed_recurrence_freebusy_preflight.sql
 *                       section B (assertions B.1-B.6), which has passed on the
 *                       target server.
 *   Europe/Dublin    -- the Phase 5b-4 probe, hand-run against the same server.
 *
 * The rule under test is "the LATER of the two candidate instants". It is NOT
 * "the standard-time offset": those two agree in every positive-DST zone, and
 * Europe/Dublin is here precisely because tzdata models it with NEGATIVE DST,
 * so its standard offset (IST, UTC+1) would give the EARLIER instant. The
 * measurement says PostgreSQL returns the later one, and so must we.
 *
 * These tests build wall clocks explicitly and compare explicit UTC instants,
 * so they do not depend on the zone the test runner happens to be in.
 */
describe('resolveZonedWallClock — PostgreSQL AT TIME ZONE semantics', () => {
  const at = (
    year: number, month: number, day: number, hour: number, minute: number,
  ): ZonedWallClock => ({ year, month, day, hour, minute, second: 0, ms: 0 });
  const resolvedIso = (w: ZonedWallClock, tz: string): string =>
    new Date(resolveZonedWallClock(w, tz)).toISOString();

  const NY = 'America/New_York';
  const DUB = 'Europe/Dublin';

  // -- A1/A2: New York spring-forward gap (02:00-02:59 does not exist) --------
  it('A1 resolves the New York spring gap forward, matching preflight B.1', () => {
    expect(resolvedIso(at(2026, 3, 8, 2, 30), NY)).toBe('2026-03-08T07:30:00.000Z');
  });

  it('A2 leaves the times on either side of the New York gap alone', () => {
    expect(resolvedIso(at(2026, 3, 8, 1, 30), NY)).toBe('2026-03-08T06:30:00.000Z');
    // preflight B.3: the gap and 03:30 land on the SAME instant.
    expect(resolvedIso(at(2026, 3, 8, 3, 30), NY)).toBe('2026-03-08T07:30:00.000Z');
  });

  // -- A3/A4: New York fall-back fold (01:00-01:59 happens twice) -------------
  it('A3 resolves the New York autumn fold to the LATER instant, matching preflight B.4', () => {
    // 01:30 EDT = 05:30Z (earlier) and 01:30 EST = 06:30Z (later).
    expect(resolvedIso(at(2026, 11, 1, 1, 30), NY)).toBe('2026-11-01T06:30:00.000Z');
  });

  it('A4 leaves the times on either side of the New York fold alone', () => {
    expect(resolvedIso(at(2026, 11, 1, 0, 30), NY)).toBe('2026-11-01T04:30:00.000Z');
    expect(resolvedIso(at(2026, 11, 1, 2, 30), NY)).toBe('2026-11-01T07:30:00.000Z'); // preflight B.6
  });

  // -- A5/A6: Europe/Dublin, where LATER and "standard offset" disagree -------
  it('A5 resolves the Dublin negative-DST gap to the LATER candidate', () => {
    // Candidates 00:30Z (IST +1, the STANDARD offset) and 01:30Z (GMT +0).
    // The probe measured 01:30Z: later wins, standard loses.
    expect(resolvedIso(at(2026, 3, 29, 1, 30), DUB)).toBe('2026-03-29T01:30:00.000Z');
  });

  it('A6 resolves the Dublin negative-DST fold to the LATER candidate', () => {
    // Same two candidates, both valid here. Again 01:30Z, the later one --
    // NOT 00:30Z, which is what the standard-time offset would have produced.
    expect(resolvedIso(at(2026, 10, 25, 1, 30), DUB)).toBe('2026-10-25T01:30:00.000Z');
  });

  it('A7 handles ordinary Dublin days on both sides of the year', () => {
    expect(resolvedIso(at(2026, 7, 15, 12, 0), DUB)).toBe('2026-07-15T11:00:00.000Z'); // IST +1
    expect(resolvedIso(at(2026, 1, 15, 12, 0), DUB)).toBe('2026-01-15T12:00:00.000Z'); // GMT +0
  });

  it('A8 handles zones with no transitions at all', () => {
    expect(resolvedIso(at(2026, 3, 8, 2, 30), 'Asia/Tokyo')).toBe('2026-03-07T17:30:00.000Z');
    expect(resolvedIso(at(2026, 11, 1, 1, 30), 'UTC')).toBe('2026-11-01T01:30:00.000Z');
  });

  it('A9 round-trips ordinary wall clocks, and reports the gap as shifted', () => {
    const normal = at(2026, 6, 1, 9, 30);
    expect(zonedWallClockOf(resolveZonedWallClock(normal, NY), NY)).toEqual(normal);

    // A fold round-trips to the same wall clock (both candidates render back).
    const fold = at(2026, 11, 1, 1, 30);
    expect(zonedWallClockOf(resolveZonedWallClock(fold, NY), NY)).toEqual(fold);

    // A gap cannot: preflight B.2 pins that 02:30 comes back as 03:30.
    const gap = at(2026, 3, 8, 2, 30);
    expect(zonedWallClockOf(resolveZonedWallClock(gap, NY), NY)).toEqual(at(2026, 3, 8, 3, 30));
  });

  it('A10 keeps sub-second precision through the conversion', () => {
    const w: ZonedWallClock = {
      year: 2026, month: 6, day: 1, hour: 9, minute: 30, second: 15, ms: 250,
    };
    expect(new Date(resolveZonedWallClock(w, NY)).toISOString()).toBe('2026-06-01T13:30:15.250Z');
    expect(zonedWallClockOf(resolveZonedWallClock(w, NY), NY)).toEqual(w);
  });
});
