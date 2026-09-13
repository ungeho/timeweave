import type { EventOccurrence } from '../../types/event';
import { isoFromDateString } from '../../utils/datetime';
import { EventChip } from './EventChip';
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
 * order, and `EventChip` decides how one entry looks. This component only
 * arranges them and closes itself, so the list can be tested without a DOM.
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
  const total = agenda.allDay.length + agenda.timed.length;

  // dayKey is a plain calendar date; render it through the local-midnight
  // instant so the weekday is the one the grid showed.
  const heading = new Date(isoFromDateString(agenda.dayKey)).toLocaleDateString(undefined, {
    year: 'numeric',
    month: 'long',
    day: 'numeric',
    weekday: 'short',
  });

  const open = (occ: EventOccurrence) => {
    onOccurrenceClick(occ);
    onClose();
  };

  return (
    <div className="modal-backdrop" onClick={onClose}>
      <div className="modal" onClick={(e) => e.stopPropagation()} role="dialog" aria-modal="true">
        <h3 className="modal-title">{heading}</h3>

        {total === 0 ? (
          <p className="day-agenda-empty">この日の予定はありません。</p>
        ) : (
          <div className="day-agenda-list">
            {agenda.allDay.length > 0 && (
              <>
                <p className="day-agenda-group">終日</p>
                {agenda.allDay.map((occ) => (
                  <EventChip
                    key={`ad-${occ.event.id}-${occ.start}`}
                    occurrence={occ}
                    variant="chip"
                    onClick={() => open(occ)}
                  />
                ))}
              </>
            )}

            {agenda.timed.length > 0 && (
              <>
                <p className="day-agenda-group">時刻あり</p>
                {agenda.timed.map((occ) => (
                  <EventChip
                    key={`t-${occ.event.id}-${occ.start}`}
                    occurrence={occ}
                    variant="chip"
                    onClick={() => open(occ)}
                  />
                ))}
              </>
            )}
          </div>
        )}

        <div className="modal-actions">
          <span className="spacer" />
          <button className="btn" onClick={onClose}>閉じる</button>
        </div>
      </div>
    </div>
  );
}
