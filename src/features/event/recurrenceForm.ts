/**
 * Pure conversions between the recurrence UI form model and RecurrenceRule, plus
 * scope-based form seeding. Kept UI-free so it is unit-testable.
 */

import type { EventOccurrence, EditScope, EventRow } from '../../types/event';
import type { RecurrenceRule, Weekday } from '../../types/recurrence';
import { WEEKDAYS } from '../../types/recurrence';
import { addDaysToDateString, isoFromDateString } from '../../utils/datetime';
import { dayStartInstantIso, weekdayOfDayKey, zonedDayKey } from '../../utils/timezone';

export type FormFreq = 'none' | 'daily' | 'weekly' | 'monthly';
export type EndMode = 'never' | 'count' | 'until';

export interface RecurrenceForm {
  freq: FormFreq;
  interval: number;
  weekdays: Weekday[];
  endMode: EndMode;
  count: number;
  untilDate: string; // "YYYY-MM-DD"
}

export const EMPTY_RECURRENCE_FORM: RecurrenceForm = {
  freq: 'none',
  interval: 1,
  weekdays: [],
  endMode: 'never',
  count: 10,
  untilDate: '',
};

/**
 * Interpret an in-progress positive-integer input (interval / count).
 * Separates the DISPLAY string from the COMMITTED value so typing stays smooth:
 * - `display` is what the field should show (leading zeros stripped once valid);
 * - `value` is the number to commit, or null to keep the previous valid value
 *   (empty field, or not yet a positive integer — e.g. "" or "0").
 * The field's own validation on save still runs through formToRule.
 */
export function parsePositiveIntInput(raw: string): { display: string; value: number | null } {
  if (raw.trim() === '') return { display: '', value: null };
  const n = Number.parseInt(raw, 10);
  if (Number.isInteger(n) && n >= 1) return { display: String(n), value: n };
  return { display: raw, value: null };
}

const FREQ_TO_FORM: Record<Exclude<FormFreq, 'none'>, RecurrenceRule['freq']> = {
  daily: 'DAILY',
  weekly: 'WEEKLY',
  monthly: 'MONTHLY',
};
const FORM_FROM_FREQ: Record<RecurrenceRule['freq'], Exclude<FormFreq, 'none'>> = {
  DAILY: 'daily',
  WEEKLY: 'weekly',
  MONTHLY: 'monthly',
};

/**
 * Build a RecurrenceRule from the form. Returns null when freq is 'none'.
 * Throws Error with a user-facing message on invalid input. `dtstartIso` and
 * `timeZone` are used to derive a default weekday and to build a timed UNTIL.
 */
export function formToRule(
  form: RecurrenceForm,
  dtstartIso: string,
  timeZone: string,
  allDay: boolean,
): RecurrenceRule | null {
  if (form.freq === 'none') return null;

  const interval = Math.floor(form.interval);
  if (!Number.isInteger(interval) || interval < 1) {
    throw new Error('繰り返し間隔は 1 以上にしてください');
  }

  const freq = FREQ_TO_FORM[form.freq];
  let byDay: Weekday[] | undefined;
  if (freq === 'WEEKLY') {
    byDay =
      form.weekdays.length > 0
        ? [...form.weekdays].sort((a, b) => WEEKDAYS.indexOf(a) - WEEKDAYS.indexOf(b))
        : [defaultWeekday(dtstartIso, timeZone)];
  }

  const rule: RecurrenceRule = { freq, interval, byDay };

  if (form.endMode === 'count') {
    if (!Number.isInteger(form.count) || form.count < 1) {
      throw new Error('繰り返し回数は 1 以上にしてください');
    }
    rule.count = form.count;
  } else if (form.endMode === 'until') {
    if (!form.untilDate) {
      throw new Error('終了日を入力してください');
    }
    rule.until = allDay
      ? { kind: 'date', date: form.untilDate }
      : { kind: 'instant', instant: endOfZonedDayIso(form.untilDate, timeZone) };
  }

  return rule;
}

/** Rebuild the form from an existing rule (for editing a master). */
export function ruleToForm(rule: RecurrenceRule, timeZone: string): RecurrenceForm {
  const form: RecurrenceForm = {
    ...EMPTY_RECURRENCE_FORM,
    freq: FORM_FROM_FREQ[rule.freq],
    interval: rule.interval,
    weekdays: rule.byDay ? [...rule.byDay] : [],
  };
  if (rule.count !== undefined) {
    form.endMode = 'count';
    form.count = rule.count;
  } else if (rule.until) {
    form.endMode = 'until';
    form.untilDate =
      rule.until.kind === 'date' ? rule.until.date : zonedDayKey(rule.until.instant, timeZone);
  }
  return form;
}

/** Build a synthetic occurrence representing a master row (its own base slot). */
export function masterOccurrence(master: EventRow): EventOccurrence {
  const start = master.allDay ? isoFromDateString(master.startDate!) : master.startAt!;
  const end = master.allDay ? isoFromDateString(master.endDate!) : master.endAt!;
  return {
    event: master,
    start,
    end,
    allDay: master.allDay,
    occurrenceKey: master.allDay ? master.startDate! : master.startAt!,
    isException: false,
  };
}

/**
 * Which occurrence to seed the dialog from, given the chosen scope.
 * - 'only': the occurrence itself (its real, possibly-overridden content).
 * - 'all': the MASTER's content (so editing all resets to the base event, not
 *   the exception's values), and the recurrence editor becomes editable.
 */
export function formSeedForScope(
  occ: EventOccurrence,
  master: EventRow,
  scope: EditScope,
): { occurrence: EventOccurrence; recurrenceEditable: boolean } {
  if (scope === 'all') {
    return { occurrence: masterOccurrence(master), recurrenceEditable: true };
  }
  return { occurrence: occ, recurrenceEditable: false };
}

function defaultWeekday(dtstartIso: string, timeZone: string): Weekday {
  return WEEKDAYS[weekdayOfDayKey(zonedDayKey(dtstartIso, timeZone))]!;
}

/** Inclusive end-of-day instant for a calendar date in the zone (23:59:59.999). */
function endOfZonedDayIso(dateStr: string, timeZone: string): string {
  const nextMidnight = dayStartInstantIso(addDaysToDateString(dateStr, 1), timeZone);
  return new Date(Date.parse(nextMidnight) - 1).toISOString();
}
