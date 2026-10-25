/**
 * Pure conversions between the recurrence UI form model and RecurrenceRule, plus
 * scope-based form seeding. Kept UI-free so it is unit-testable.
 */

import { t } from '../../i18n/t';
import { DEFAULT_LANGUAGE, type Language } from '../../i18n/types';
import type { MessageKey } from '../../i18n/ja';
import type { DomainError } from '../../errors';
import type { EventOccurrence, EditScope, EventRow } from '../../types/event';
import type { RecurrenceRule, Weekday } from '../../types/recurrence';
import { WEEKDAYS } from '../../types/recurrence';
import { MAX_COUNT, MAX_INTERVAL } from '../../services/recurrence';
import { addDaysToDateString, isoFromDateString } from '../../utils/datetime';
import { dayStartInstantIso, weekdayOfDayKey, zonedDayKey } from '../../utils/timezone';

/**
 * Which of the form's three rules was broken.
 *
 * A discriminator rather than three classes, matching
 * FreeBusyRateLimitedError and InvalidTimezoneError: these are one failure --
 * "the recurrence form does not describe a rule" -- with three wordings, and
 * every call site that cares about them cares about all three at once.
 */
export type RecurrenceFormErrorReason =
  /** interval < 1 (0, a fraction below 1, a negative). */
  | 'intervalTooSmall'
  /** interval not a whole number from 1 to MAX_INTERVAL: a fraction, NaN, Infinity, 10000+ (K13). */
  | 'intervalInvalid'
  /** endMode 'count' with count < 1 (0, a fraction below 1, a negative). */
  | 'countTooSmall'
  /** endMode 'count' with a count not a whole number from 1 to MAX_COUNT (K14). */
  | 'countInvalid'
  /** endMode 'until' with no date chosen. */
  | 'untilRequired'
  /** a timed series ending after LAST_TIMED_UNTIL_DATE (K17). */
  | 'untilOutOfRange';

/** The last end date a TIMED series can carry (K17): its end is computed via the next day, and year 10000 is not representable. */
export const LAST_TIMED_UNTIL_DATE = '9999-12-30';

/**
 * The message key each reason renders.
 *
 * Carried as data because `messageKey` is part of the DomainError contract.
 * It is NOT what renders the sentence -- see below.
 */
const REASON_KEY: Record<RecurrenceFormErrorReason, MessageKey> = {
  intervalTooSmall: 'recurrence.intervalTooSmall',
  intervalInvalid: 'recurrence.intervalInvalid',
  countTooSmall: 'recurrence.countTooSmall',
  countInvalid: 'recurrence.countInvalid',
  untilRequired: 'recurrence.untilRequired',
  untilOutOfRange: 'recurrence.untilOutOfRange',
};

/**
 * Render one reason in one language.
 *
 * A SWITCH RATHER THAN `t(REASON_KEY[reason], lang)`, which does not compile.
 * `t` reads the placeholder names off the key's literal type to decide what
 * variables the call must supply; indexing REASON_KEY yields the whole
 * MessageKey union, so the compiler demands the widest variable set any
 * message in the dictionary declares. Writing the three keys out keeps each
 * call literal and checked -- the same reason the errors.ts classes re-derive
 * their key in localize() instead of reading their own messageKey field.
 *
 * Shared by the constructor and localize() so the Japanese `.message` and
 * `localize('ja')` cannot drift apart: they are the same call.
 */
function renderReason(reason: RecurrenceFormErrorReason, lang: Language): string {
  switch (reason) {
    case 'intervalTooSmall':
      return t('recurrence.intervalTooSmall', lang);
    case 'intervalInvalid':
      return t('recurrence.intervalInvalid', lang);
    case 'countTooSmall':
      return t('recurrence.countTooSmall', lang);
    case 'countInvalid':
      return t('recurrence.countInvalid', lang);
    case 'untilRequired':
      return t('recurrence.untilRequired', lang);
    case 'untilOutOfRange':
      return t('recurrence.untilOutOfRange', lang);
  }
}

/**
 * A recurrence form that cannot be turned into a rule.
 *
 * WHY THIS EXISTS. The three refusals were `throw new Error(t(key,
 * DEFAULT_LANGUAGE))`: the wording was decided at the moment of failure, in
 * Japanese, and nothing downstream could tell the three apart or ask for them
 * in another language. EventDialog renders whatever `.message` holds, so the
 * sentence an English owner saw was fixed before the dialog ever opened.
 *
 * WHY IT IS HERE AND NOT IN errors.ts. That module says which errors belong to
 * it: the ones that cross layers, raised in a repository or a hook and caught
 * in the UI. This one is raised by formToRule and caught six lines later in
 * the same feature folder -- it has exactly one owner, which is the case
 * errors.ts explicitly leaves co-located (see UnsupportedRRuleError). What it
 * takes from errors.ts is the CONTRACT, not a base class: `DomainError` is
 * declared as an interface precisely so a class elsewhere can satisfy it, and
 * satisfying it means isDomainError() recognises this error and the display
 * sites P6's next step wires up need no special case for it.
 *
 * WHY NOT A `lang` PARAMETER ON formToRule. Validation and display are
 * different concerns, and threading a language through a pure converter would
 * tie the two together: the rule a form describes does not depend on the
 * language the owner reads. The error carries the FACT; the screen decides the
 * words, at the moment it draws them.
 */
export class RecurrenceFormError extends Error implements DomainError {
  readonly code = 'RECURRENCE_FORM' as const;
  readonly reason: RecurrenceFormErrorReason;
  /**
   * Typed as the whole union, like FreeBusyRateLimitedError's. A narrower
   * literal would be better for `t`, but the DomainError contract declares
   * MessageKey -- which is also why localize() re-derives the key from
   * `reason` instead of reading this field.
   */
  readonly messageKey: MessageKey;
  readonly hasCustomMessage: boolean;

  /**
   * `reason` comes first because it is required; the classes in errors.ts put
   * `message` first only to keep their pre-existing `new X(message)` call
   * sites meaning what they did. This class has no such history -- its three
   * throw sites are the only ones -- so the required argument leads.
   */
  constructor(reason: RecurrenceFormErrorReason, message?: string) {
    super(message ?? renderReason(reason, DEFAULT_LANGUAGE));
    this.name = 'RecurrenceFormError';
    this.reason = reason;
    this.messageKey = REASON_KEY[reason];
    this.hasCustomMessage = message !== undefined;
  }

  localize(lang: Language): string {
    // An explicit message is returned unchanged: an arbitrary string cannot be
    // translated, and replacing it with the generic sentence for the reason
    // would discard what the thrower chose to say. The same contract the
    // errors.ts classes keep.
    if (this.hasCustomMessage) return this.message;
    return renderReason(this.reason, lang);
  }
}

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

/**
 * Read the INTERVAL field (K13, P8-finish-3a.1). Stricter than
 * parsePositiveIntInput, which the count field still uses:
 *
 * - only plain digits are a number. "1e21", "1.5", "12abc" were read by
 *   parseInt as 1, 1 and 12 -- the field then showed and saved a value the
 *   owner never typed;
 * - anything else that is not empty is COMMITTED, as the number it is (0,
 *   10000, 1e23) or NaN, so formToRule refuses the save with its message.
 *   Keeping the previous value instead would save something other than what
 *   is on screen;
 * - `badInput` is the browser saying the text is not a number at all (it then
 *   reports the value as ""), which is invalid, not empty;
 * - an empty field keeps the previous value while typing, as before.
 *
 * `display` is the text to show: normalised only when valid ("05" -> "5"),
 * otherwise exactly as typed.
 */
export function parseIntervalInput(raw: string, badInput = false): { display: string; commit: number | null } {
  return parseBoundedIntInput(raw, MAX_INTERVAL, badInput);
}

/** The COUNT field, read the same way (K14, P8-finish-3a.2), up to MAX_COUNT. */
export function parseCountInput(raw: string, badInput = false): { display: string; commit: number | null } {
  return parseBoundedIntInput(raw, MAX_COUNT, badInput);
}

function parseBoundedIntInput(raw: string, max: number, badInput: boolean): { display: string; commit: number | null } {
  const text = raw.trim();
  if (text === '') return badInput ? { display: raw, commit: Number.NaN } : { display: '', commit: null };
  if (!/^[0-9]+$/.test(text)) return { display: raw, commit: Number.NaN };
  const n = Number(text);
  if (n >= 1 && n <= max) return { display: String(n), commit: n };
  return { display: raw, commit: n };
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
 *
 * Throws `RecurrenceFormError` on invalid input -- still an `Error` with the
 * same Japanese `.message`, so `e instanceof Error ? e.message : String(e)`
 * at the call site is unaffected, but now carrying a `reason` and a
 * `localize(lang)`. The signature takes no language, because which rule a
 * form describes does not depend on what language it is read in.
 *
 * K13 (P8-finish-3a.1): the interval must be a whole number from 1 to
 * MAX_INTERVAL. It used to be floored and had no upper bound, so 1.5 was saved
 * as 1 and 1e23 as "INTERVAL=1e+23". Below 1 keeps its old reason; anything
 * else out of range is refused as 'intervalInvalid' -- never rounded or clamped.
 *
 * `dtstartIso` and `timeZone` are used to derive a default weekday and to
 * build a timed UNTIL.
 */
export function formToRule(
  form: RecurrenceForm,
  dtstartIso: string,
  timeZone: string,
  allDay: boolean,
): RecurrenceRule | null {
  if (form.freq === 'none') return null;

  const interval = form.interval;
  if (interval < 1) {
    throw new RecurrenceFormError('intervalTooSmall');
  }
  if (!Number.isInteger(interval) || interval > MAX_INTERVAL) {
    throw new RecurrenceFormError('intervalInvalid');
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
    // K14: same shape as the interval -- below 1 keeps its old reason, any other
    // value outside 1..MAX_COUNT is refused, never rounded or clamped.
    if (form.count < 1) {
      throw new RecurrenceFormError('countTooSmall');
    }
    if (!Number.isInteger(form.count) || form.count > MAX_COUNT) {
      throw new RecurrenceFormError('countInvalid');
    }
    rule.count = form.count;
  } else if (form.endMode === 'until') {
    if (!form.untilDate) {
      throw new RecurrenceFormError('untilRequired');
    }
    // K17: a timed series ends at the end of that day in its zone, computed via
    // the NEXT day; after 9999-12-30 that is year 10000, which the date code
    // cannot represent (the save used to fail with a raw "Invalid time value").
    // The date field accepts years 1000..9999, so this is the one date to refuse.
    if (!allDay && form.untilDate > LAST_TIMED_UNTIL_DATE) {
      throw new RecurrenceFormError('untilOutOfRange');
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
