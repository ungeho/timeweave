/**
 * Which timezone control the dialog shows, case by case. The interesting part is
 * what stays HIDDEN: an exception snapshot, an all-day series and a per-occurrence
 * edit must offer no series-timezone control at all, because none of them owns a
 * zone.
 */

import { describe, expect, it } from 'vitest';
import { timezoneFieldView, type TimezoneFieldInput } from './timezoneField';

const TZ = 'Asia/Tokyo';

const timedMaster = (timezone: string | null) => ({
  allDay: false,
  rrule: 'FREQ=WEEKLY;BYDAY=MO',
  timezone,
});
const timedOneOff = { allDay: false, rrule: null, timezone: null };
const allDaySeries = { allDay: true, rrule: 'FREQ=WEEKLY;BYDAY=MO', timezone: null };

/**
 * Mirrors how EventDialog derives `formIsTimedRecurrence`, so a test can say
 * "the user ticked 終日" rather than passing a bare boolean.
 */
const dialogFormIsTimedRecurrence = (form: {
  allDay: boolean;
  freq: 'none' | 'daily' | 'weekly' | 'monthly';
}) => !form.allDay && form.freq !== 'none';

/** Defaults describe creating a plain timed one-off: nothing to show. */
const view = (over: Partial<TimezoneFieldInput> = {}) =>
  timezoneFieldView({
    target: null,
    isRecurring: false,
    scope: 'only',
    formIsTimedRecurrence: false,
    browserTimeZone: TZ,
    ...over,
  });

describe('timezoneFieldView — a zone the save will adopt', () => {
  it('shows the browser zone when creating a timed recurrence', () => {
    expect(view({ formIsTimedRecurrence: true })).toEqual({ kind: 'adopting', timezone: TZ });
  });

  it('reports null rather than a fallback when the browser gave no zone', () => {
    expect(view({ formIsTimedRecurrence: true, browserTimeZone: null })).toEqual({
      kind: 'adopting',
      timezone: null,
    });
  });

  it('shows it when a one-off is gaining a rule', () => {
    expect(view({ target: timedOneOff, formIsTimedRecurrence: true })).toEqual({
      kind: 'adopting',
      timezone: TZ,
    });
  });

  it('shows it when an all-day series is turned timed (not the series control)', () => {
    expect(
      view({ target: allDaySeries, isRecurring: true, scope: 'all', formIsTimedRecurrence: true }),
    ).toEqual({ kind: 'adopting', timezone: TZ });
  });

  it('shows nothing when the form describes no recurrence', () => {
    expect(view({ target: timedOneOff })).toEqual({ kind: 'none' });
  });
});

describe('timezoneFieldView — an existing series (scope "all")', () => {
  const seriesView = (timezone: string | null, browserTimeZone: string | null = TZ) =>
    view({
      target: timedMaster(timezone),
      isRecurring: true,
      scope: 'all',
      formIsTimedRecurrence: true,
      browserTimeZone,
    });

  it('reports a legacy master as unset, with the set action available', () => {
    expect(seriesView(null)).toEqual({ kind: 'series-unset', canSet: true });
  });

  it('withholds the set action when the browser has no storable zone', () => {
    expect(seriesView(null, null)).toEqual({ kind: 'series-unset', canSet: false });
  });

  it('shows the stored zone, with no change offered when it already matches', () => {
    expect(seriesView(TZ)).toEqual({ kind: 'series-set', timezone: TZ, canChange: false });
  });

  it('offers the change only when the browser zone differs', () => {
    expect(seriesView('Europe/Paris')).toEqual({
      kind: 'series-set',
      timezone: 'Europe/Paris',
      canChange: true,
    });
  });

  it('compares names verbatim: an alias reads as a difference, and is never rewritten', () => {
    // Same rules, different spelling. Neither this code nor the database
    // canonicalises, so the stored string is shown and compared as-is.
    const v = timezoneFieldView({
      target: timedMaster('Asia/Calcutta'),
      isRecurring: true,
      scope: 'all',
      formIsTimedRecurrence: true,
      browserTimeZone: 'Asia/Kolkata',
    });
    expect(v).toEqual({ kind: 'series-set', timezone: 'Asia/Calcutta', canChange: true });
  });

  /**
   * The control depends on the form as well as the stored row. Once the form
   * stops describing a timed recurrence the save will clear the zone in the same
   * patch, so a series zone must no longer be shown or offered — even though the
   * stored row is still a master until that save happens.
   */
  it('hides the series control once the form no longer describes a recurrence', () => {
    expect(
      view({
        target: timedMaster(TZ),
        isRecurring: true,
        scope: 'all',
        formIsTimedRecurrence: false,
      }),
    ).toEqual({ kind: 'none' });
  });

  it('hides it when the form turns the series all-day', () => {
    // Both causes — no rule, and all-day — reach the view as the same `false`,
    // so this goes through the dialog's own derivation to keep the all-day case
    // legible, and pins that it does not fall through to 'adopting' either: an
    // all-day row carries no zone at all.
    expect(
      view({
        target: timedMaster(TZ),
        isRecurring: true,
        scope: 'all',
        formIsTimedRecurrence: dialogFormIsTimedRecurrence({ allDay: true, freq: 'weekly' }),
      }),
    ).toEqual({ kind: 'none' });
  });

  it('hides the set action of a legacy master when the form drops the rule', () => {
    expect(
      view({
        target: timedMaster(null),
        isRecurring: true,
        scope: 'all',
        formIsTimedRecurrence: false,
      }),
    ).toEqual({ kind: 'none' });
  });

  it('brings the control back when the recurrence is restored', () => {
    const params = { target: timedMaster(TZ), isRecurring: true, scope: 'all' as const };
    expect(view({ ...params, formIsTimedRecurrence: false })).toEqual({ kind: 'none' });
    expect(view({ ...params, formIsTimedRecurrence: true })).toEqual({
      kind: 'series-set',
      timezone: TZ,
      canChange: false,
    });
  });

  it('brings the set action back for a legacy master too', () => {
    const params = { target: timedMaster(null), isRecurring: true, scope: 'all' as const };
    expect(view({ ...params, formIsTimedRecurrence: false })).toEqual({ kind: 'none' });
    expect(view({ ...params, formIsTimedRecurrence: true })).toEqual({
      kind: 'series-unset',
      canSet: true,
    });
  });
});

describe('timezoneFieldView — where the series control must not appear', () => {
  it('is hidden for a per-occurrence edit of a timed series', () => {
    expect(
      view({ target: timedMaster(TZ), isRecurring: true, scope: 'only' }),
    ).toEqual({ kind: 'none' });
  });

  it('is hidden for an all-day series edited as a whole', () => {
    expect(view({ target: allDaySeries, isRecurring: true, scope: 'all' })).toEqual({
      kind: 'none',
    });
  });

  it('is hidden for an exception row (it carries no zone of its own)', () => {
    const exception = { allDay: false, rrule: null, timezone: null };
    expect(view({ target: exception, isRecurring: true, scope: 'only' })).toEqual({ kind: 'none' });
  });

  it('is hidden when editing a plain one-off', () => {
    expect(view({ target: timedOneOff })).toEqual({ kind: 'none' });
  });
});
