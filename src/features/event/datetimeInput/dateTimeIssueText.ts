/**
 * The sentence for a date/time the event form refuses to save (P8-b5.6b-2).
 * Kept beside the inputs rather than in eventFormError.ts: these keys belong
 * to the date/time inputs and the DST check, and eventFormError.ts stays the
 * module of the five original validation keys (its own test pins that).
 */
import { t } from '../../../i18n/t';
import type { Language } from '../../../i18n/types';
import type { DateTimeIssue } from '../eventFormError';

export function dateTimeIssueText(issue: DateTimeIssue, lang: Language): string {
  switch (issue.problem) {
    case 'draft':
      // An emptied date reads exactly as it did before P8-b5.6b-2.
      if (issue.empty) return t(issue.part === 'date' ? 'event.error.dateRequired' : 'event.dt.time.empty', lang);
      return t('event.dt.draftInvalid', lang);
    case 'gap':
      return t('event.dt.dst.gapSave', lang);
    case 'foldUnchosen':
      return t('event.dt.dst.foldSave', lang);
  }
}
