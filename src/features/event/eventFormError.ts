/**
 * What the event dialog is showing in its error line, and how it reads.
 *
 * THE LAST OF THE FOUR FROZEN-ERROR SITES, and the one with the most sources.
 * Before P6 step 8 the dialog kept `formError: string | null`, filled from
 * eleven places: four catches read `e.message`, six validation failures called
 * `tr(...)`, and one asked `contentLengthError` for a sentence. All eleven
 * decided their wording at the moment of the failure, so a language change
 * afterwards re-rendered every other string in the dialog and left this one
 * behind.
 *
 * THREE VARIANTS, because there are three genuinely different things to keep:
 *
 *   'caught'          something was thrown. The value is kept as-is and read
 *                     through caughtErrorText, shared with the calendar
 *                     banner, the share dialog and the settings dialog.
 *   'validation'      the form refused the input. The five keys involved take
 *                     no variables, so the key alone is the whole state.
 *   'contentTooLong'  also a refusal, but one whose sentence quotes a number
 *                     and differs per field, so it keeps the violation
 *                     contentLimits produced rather than a key.
 *
 * WHY 'contentTooLong' IS NOT FOLDED INTO 'validation'. It would need the key
 * AND the number AND the pairing between them, and `t` demands exactly the
 * variables a key declares -- so one variant covering both would either widen
 * the key type (and owe `t` the widest variable set in the dictionary) or carry
 * an optional `max` that four of the five keys must not have. Keeping the
 * violation lets contentLimits stay the only place that knows which field maps
 * to which message.
 *
 * A module rather than a ternary in JSX because the project has no
 * component-test environment (vitest runs with `environment: 'node'`), so a
 * decision that lives here is a decision that can be tested.
 */

import { caughtErrorText } from '../../i18n/errorText';
import { t } from '../../i18n/t';
import { DEFAULT_LANGUAGE, type Language } from '../../i18n/types';
import { contentLengthMessage, type ContentLengthViolation } from '../../services/contentLimits';
import { dateTimeIssueText } from './datetimeInput/dateTimeIssueText';

/**
 * The validation refusals the dialog raises by key alone.
 *
 * A union of literals, not MessageKey: `t` reads a message's placeholders off
 * the key's literal type, so a widened key would make the render site owe it
 * the widest variable set in the dictionary. All five of these take none,
 * which is exactly why they can share one variant.
 *
 * `event.tz.unresolved` is raised from two different places -- the series
 * panel and the save path -- and is one member here, because what the owner
 * reads is the same sentence either way.
 */
export type EventValidationKey =
  | 'event.title.required'
  | 'event.error.dateRequired'
  | 'event.error.endDateBeforeStart'
  | 'event.error.endBeforeStart'
  /** K18: outside the dates/instants the database stores (eventDateBounds.ts). */
  | 'event.error.allDayOutOfRange'
  | 'event.error.timedOutOfRange'
  | 'event.tz.unresolved';

/** An error the event dialog is showing. */
/**
 * A date/time the form cannot save (P8-b5.6b-2). Its own kind rather than
 * more validation keys: these are decided by the date/time inputs and by the
 * DST check in formInstant, and the draft case carries which part refused.
 *   draft        -- a field holds text that did not parse; the committed
 *                   value behind it is no longer what the owner sees
 *   gap          -- a time that does not exist (clocks jumped forward)
 *   foldUnchosen -- a time that happens twice, with neither chosen
 */
export type DateTimeIssue =
  | { readonly problem: 'draft'; readonly part: 'date' | 'time'; readonly empty: boolean }
  | { readonly problem: 'gap' }
  | { readonly problem: 'foldUnchosen' };

export type EventFormError =
  | { readonly kind: 'caught'; readonly cause: unknown }
  | { readonly kind: 'datetime'; readonly issue: DateTimeIssue }
  | { readonly kind: 'validation'; readonly key: EventValidationKey }
  | { readonly kind: 'contentTooLong'; readonly violation: ContentLengthViolation };

/**
 * The error line's text, resolved at render.
 *
 * `lang` defaults to the default language so a call with no argument answers in
 * the Japanese this dialog has always shown.
 */
export function eventFormErrorText(
  error: EventFormError,
  lang: Language = DEFAULT_LANGUAGE,
): string {
  switch (error.kind) {
    case 'caught':
      return caughtErrorText(error.cause, lang);
    case 'validation':
      // The key is already narrowed to five literals that take no variables,
      // so this call needs no variable argument and the compiler agrees.
      return t(error.key, lang);
    case 'contentTooLong':
      return contentLengthMessage(error.violation, lang);
    case 'datetime':
      return dateTimeIssueText(error.issue, lang);
  }
}
