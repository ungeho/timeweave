/**
 * Differential tests for the events.timezone state machine.
 *
 * The case numbering follows supabase/tests/0008_events_timezone_test.sql
 * section 3 one for one, so the SQL function and this TypeScript twin can be
 * reviewed side by side. Same inputs, same expected tokens.
 */

import { describe, expect, it } from 'vitest';
import {
  editTimezoneIntent,
  isTimedMaster,
  timezonePlacementOk,
  timezoneTransitionError,
  type TimezoneShape,
} from './timezoneRules';

const F = 'FREQ=DAILY';
const TZ = 'Asia/Tokyo';

/** Build a shape; defaults describe a timed one-off with no zone (state N). */
const shape = (over: Partial<TimezoneShape> = {}): TimezoneShape => ({
  allDay: false,
  rrule: null,
  recurrenceId: null,
  timezone: null,
  ...over,
});

const N = shape();
const allDayMaster = shape({ allDay: true, rrule: F });
const M0 = shape({ rrule: F });
const M1 = shape({ rrule: F, timezone: TZ });

describe('isTimedMaster', () => {
  it('is true only for a timed row carrying an rrule', () => {
    expect(isTimedMaster({ allDay: false, rrule: F })).toBe(true);
    expect(isTimedMaster({ allDay: false, rrule: null })).toBe(false);
    expect(isTimedMaster({ allDay: true, rrule: F })).toBe(false);
    expect(isTimedMaster({ allDay: true, rrule: null })).toBe(false);
  });
});

describe('timezonePlacementOk — only a timed master may carry a zone', () => {
  it('accepts every shape with no zone', () => {
    expect(timezonePlacementOk(N)).toBe(true);
    expect(timezonePlacementOk(M0)).toBe(true);
    expect(timezonePlacementOk(allDayMaster)).toBe(true);
    expect(timezonePlacementOk(shape({ recurrenceId: 'm1' }))).toBe(true);
  });

  it('accepts a timed master with a zone', () => {
    expect(timezonePlacementOk(M1)).toBe(true);
  });

  it('rejects a zone on an all-day master', () => {
    expect(timezonePlacementOk(shape({ allDay: true, rrule: F, timezone: TZ }))).toBe(false);
  });

  it('rejects a zone on an all-day one-off', () => {
    expect(timezonePlacementOk(shape({ allDay: true, timezone: TZ }))).toBe(false);
  });

  it('rejects a zone on a timed one-off', () => {
    expect(timezonePlacementOk(shape({ timezone: TZ }))).toBe(false);
  });

  it('rejects a zone on an exception snapshot', () => {
    expect(timezonePlacementOk(shape({ recurrenceId: 'm1', timezone: TZ }))).toBe(false);
  });
});

describe('timezoneTransitionError — every transition', () => {
  // INSERT
  it('3.1  INSERT -> N (timed one-off)', () => {
    expect(timezoneTransitionError(true, null, N)).toBeNull();
  });

  it('3.2  INSERT -> N (all-day one-off)', () => {
    expect(timezoneTransitionError(true, null, shape({ allDay: true }))).toBeNull();
  });

  it('3.3  INSERT -> N (all-day master)', () => {
    expect(timezoneTransitionError(true, null, allDayMaster)).toBeNull();
  });

  it('3.4  INSERT -> M0 REJECTED', () => {
    expect(timezoneTransitionError(true, null, M0)).toBe('TIMEWEAVE_TZ_REQUIRED');
  });

  it('3.5  INSERT -> M1', () => {
    expect(timezoneTransitionError(true, null, M1)).toBeNull();
  });

  // UPDATE from N
  it('3.6  N -> N', () => {
    expect(timezoneTransitionError(false, N, N)).toBeNull();
  });

  it('3.7  N -> M0 REJECTED', () => {
    expect(timezoneTransitionError(false, N, M0)).toBe('TIMEWEAVE_TZ_REQUIRED');
  });

  it('3.8  N -> M1', () => {
    expect(timezoneTransitionError(false, N, M1)).toBeNull();
  });

  it('3.9  all-day master -> M0 REJECTED', () => {
    expect(timezoneTransitionError(false, allDayMaster, M0)).toBe('TIMEWEAVE_TZ_REQUIRED');
  });

  // UPDATE from M0
  it('3.10 M0 -> N', () => {
    expect(timezoneTransitionError(false, M0, N)).toBeNull();
  });

  it('3.11 M0 -> M0 GRANDFATHERED', () => {
    expect(timezoneTransitionError(false, M0, M0)).toBeNull();
  });

  it('3.12 M0 -> M0 with a new rrule', () => {
    expect(timezoneTransitionError(false, M0, shape({ rrule: 'FREQ=WEEKLY' }))).toBeNull();
  });

  it('3.13 M0 -> M1', () => {
    expect(timezoneTransitionError(false, M0, M1)).toBeNull();
  });

  // UPDATE from M1
  it('3.14 M1 -> N', () => {
    expect(timezoneTransitionError(false, M1, N)).toBeNull();
  });

  it('3.15 M1 -> M0 REJECTED', () => {
    expect(timezoneTransitionError(false, M1, M0)).toBe('TIMEWEAVE_TZ_CLEARED');
  });

  it('3.16 M1 -> M1 unchanged', () => {
    expect(timezoneTransitionError(false, M1, M1)).toBeNull();
  });

  it("3.17 M1 -> M1' rezoned", () => {
    expect(
      timezoneTransitionError(false, M1, shape({ rrule: F, timezone: 'Europe/London' })),
    ).toBeNull();
  });

  it('an exception row promoted to a zone-less master is rejected', () => {
    const exception = shape({ recurrenceId: 'm1' });
    expect(timezoneTransitionError(false, exception, M0)).toBe('TIMEWEAVE_TZ_REQUIRED');
  });
});

/**
 * The UI-facing half of the same state machine: which intent an ordinary edit
 * carries. 'adopt' must mean ACQUISITION and nothing else, so it appears only
 * on the N -> M1 transition; M0/M1 stay 'keep' (their zone is setSeriesTimezone's
 * business), and anything that does not end as a timed master stays 'keep' too.
 */
describe('editTimezoneIntent', () => {
  const oneOff = { allDay: false, rrule: null };
  const legacyMaster = { allDay: false, rrule: F };
  const allDaySeries = { allDay: true, rrule: F };
  const TIMED_SERIES = { allDay: false, rrule: F };

  it('adopts when a timed one-off becomes a series (N -> M1)', () => {
    expect(editTimezoneIntent(oneOff, TIMED_SERIES, TZ)).toEqual({ kind: 'adopt', timezone: TZ });
  });

  it('adopts when an all-day series turns timed (N -> M1)', () => {
    expect(editTimezoneIntent(allDaySeries, TIMED_SERIES, TZ)).toEqual({ kind: 'adopt', timezone: TZ });
  });

  it('keeps when the row is already a timed master', () => {
    expect(editTimezoneIntent(legacyMaster, TIMED_SERIES, TZ)).toEqual({ kind: 'keep' });
  });

  it('keeps when the edit does not end as a timed master', () => {
    expect(editTimezoneIntent(oneOff, { allDay: false, rrule: null }, TZ)).toEqual({ kind: 'keep' });
    expect(editTimezoneIntent(oneOff, { allDay: true, rrule: F }, TZ)).toEqual({ kind: 'keep' });
    expect(editTimezoneIntent(legacyMaster, { allDay: true, rrule: F }, TZ)).toEqual({ kind: 'keep' });
  });

  it("keeps when the scope must not touch the rule at all (rrule undefined)", () => {
    expect(editTimezoneIntent(oneOff, { allDay: false, rrule: undefined }, TZ)).toEqual({ kind: 'keep' });
  });

  it('returns null — never a guessed UTC — when no zone could be resolved', () => {
    expect(editTimezoneIntent(oneOff, TIMED_SERIES, null)).toBeNull();
  });

  it('still keeps (not null) without a zone when none is needed', () => {
    expect(editTimezoneIntent(legacyMaster, TIMED_SERIES, null)).toEqual({ kind: 'keep' });
  });
});
