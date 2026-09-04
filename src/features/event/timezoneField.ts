/**
 * What the dialog should show about `timezone`, decided in one pure place so the
 * rules are unit-testable without rendering the form.
 *
 * There are exactly two situations in which a zone is on screen, and they are
 * mutually exclusive:
 *
 *   'adopting'  — the save itself will write a zone, because the row being
 *                 created or edited is BECOMING a timed recurrence master. The
 *                 value comes from the browser and travels with the save.
 *   'series-*'  — the row is ALREADY a timed master AND the form still describes
 *                 one. Its zone is not part of an ordinary save at all; changing
 *                 it is a separate, explicit action (setSeriesTimezone), which is
 *                 why these carry a button instead of a value the form submits.
 *
 * The series controls therefore depend on BOTH the stored state and the form,
 * not on the stored row alone: the moment the form stops describing a timed
 * recurrence — the frequency set to none, or the event turned all-day — the row
 * is on its way to losing its zone (the save clears it in the same patch), so
 * offering to set or change that zone would be describing a series that is about
 * to stop existing. Switching the recurrence back brings the control back.
 *
 * They also appear only when the master itself is being edited (scope 'all').
 * For scope 'only' the edit produces an exception snapshot, which never carries
 * a zone, and all-day series have no zone to show either.
 *
 * Zone names are compared and shown VERBATIM. 'Asia/Calcutta' and 'Asia/Kolkata'
 * are the same rules under different spellings, but neither this code nor the
 * database canonicalises, so a differing string is reported as a difference.
 */

import type { EditScope } from '../../types/event';
import { isTimedMaster } from '../../services/timezoneRules';

export type TimezoneFieldView =
  /** Nothing to show: no zone is involved in this save. */
  | { kind: 'none' }
  /**
   * The save will store this zone alongside the new rrule. `timezone` is null
   * when the browser reported none — the save will be refused, not guessed.
   */
  | { kind: 'adopting'; timezone: string | null }
  /** A legacy master (M0): no zone, and it stays that way unless asked. */
  | { kind: 'series-unset'; canSet: boolean }
  /** A master with a zone (M1). `canChange` is false when it already matches. */
  | { kind: 'series-set'; timezone: string; canChange: boolean };

export interface TimezoneFieldInput {
  /** The row an edit would land on: the master for scope 'all', the occurrence's
   *  row otherwise. null while creating. */
  target: { allDay: boolean; rrule: string | null; timezone: string | null } | null;
  /** True when the dialog is editing an occurrence that belongs to a series. */
  isRecurring: boolean;
  scope: EditScope;
  /** True when the form currently describes a timed recurrence. */
  formIsTimedRecurrence: boolean;
  /** The zone resolved when the dialog opened, or null if none is storable. */
  browserTimeZone: string | null;
}

export function timezoneFieldView(input: TimezoneFieldInput): TimezoneFieldView {
  const { target, isRecurring, scope, formIsTimedRecurrence, browserTimeZone } = input;

  // An existing timed master, edited as a whole, that the form still describes
  // as one. This branch takes precedence — for such a row an ordinary save never
  // adopts anything, it leaves the column alone. The form condition matters: an
  // edit that drops the rule (or turns the event all-day) is on its way to
  // clearing the zone, so there is no series zone left to offer.
  if (
    target !== null &&
    isRecurring &&
    scope === 'all' &&
    isTimedMaster(target) &&
    formIsTimedRecurrence
  ) {
    if (target.timezone === null) return { kind: 'series-unset', canSet: browserTimeZone !== null };
    return {
      kind: 'series-set',
      timezone: target.timezone,
      canChange: browserTimeZone !== null && browserTimeZone !== target.timezone,
    };
  }

  // Otherwise a zone is only involved if this save creates a timed recurrence:
  // a new event, a one-off gaining a rule, or an all-day series turning timed.
  if (formIsTimedRecurrence) return { kind: 'adopting', timezone: browserTimeZone };
  return { kind: 'none' };
}
