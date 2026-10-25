import type { EventOccurrence } from '../../types/event';
import { useLanguage, useTranslate } from '../../i18n/useLanguage';
import { intlLocale } from '../../i18n/resolveLanguage';
import { dayKeyTitle } from './weekGrid';
import { AgendaList } from './AgendaList';
import type { DayAgenda } from './dayAgenda';

interface Props {
  agenda: DayAgenda;
  /** Clicking an entry opens it for editing, exactly as clicking a chip does. */
  onOccurrenceClick: (occ: EventOccurrence) => void;
  onClose: () => void;
}

/**
 * Everything scheduled on one day, opened from a month cell's "+N".
 *
 * Deliberately thin: `buildDayAgenda` decides what belongs here and in what
 * order, `AgendaList` draws them, and `EventChip` decides how one entry
 * looks. This component contributes a heading, a close button and the modal
 * around them.
 *
 * THE LIST MOVED OUT in P8-b2, when the phone needed the same one. Two copies
 * of "everything on this day" would have been free to disagree about grouping,
 * order, or what an empty day says -- and the two are meant to show the same
 * thing for the same reason.
 *
 * The entries are the SAME occurrence objects the month grid was given, so
 * `onOccurrenceClick` is the existing edit handler with no adapter in between --
 * clicking a row here and clicking the chip it was hidden behind reach
 * `openEdit` by the same route with the same argument.
 *
 * Reuses `.modal-backdrop` / `.modal` from EventDialog and ShareDialog, down to
 * the backdrop-click-to-close and the inner `stopPropagation`, so a third modal
 * behaves like the two that already exist.
 */
export function DayAgendaDialog({ agenda, onOccurrenceClick, onClose }: Props) {
  const tr = useTranslate();
  const { language } = useLanguage();

  // The same words the day-view title uses, from the same helper, so the
  // heading and the toolbar cannot disagree about a date. It used to inline
  // `toLocaleDateString(undefined, ...)` -- a second copy of the option set
  // and the last place in the app that read the browser's locale instead of
  // the resolved language.
  const heading = dayKeyTitle(agenda.dayKey, intlLocale(language));

  const open = (occ: EventOccurrence) => {
    onOccurrenceClick(occ);
    onClose();
  };

  return (
    <div className="modal-backdrop" onClick={onClose}>
      <div className="modal" onClick={(e) => e.stopPropagation()} role="dialog" aria-modal="true">
        <h3 className="modal-title">{heading}</h3>

        <AgendaList agenda={agenda} onOccurrenceClick={open} />

        <div className="modal-actions">
          <span className="spacer" />
          <button className="btn" onClick={onClose}>{tr('common.close')}</button>
        </div>
      </div>
    </div>
  );
}
