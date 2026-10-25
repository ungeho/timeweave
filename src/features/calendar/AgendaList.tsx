/**
 * Everything on one day, as a list.
 *
 * EXTRACTED FROM DayAgendaDialog so the phone and the dialog cannot drift
 * apart. They show the same thing for the same reason -- the full contents of
 * a date, including whatever a month cell truncated -- and before this they
 * would have been two copies of the same arrangement, free to disagree about
 * grouping, order, or what an empty day says.
 *
 * It renders only. `buildDayAgenda` decides what belongs here and in what
 * order; `EventChip` decides how one entry looks, which is where Busy and
 * Available get their fill and hatch, and where a recurring occurrence gets
 * its marker. Nothing about those rules is restated here.
 *
 * The occurrence objects are passed through BY IDENTITY: whatever reaches
 * `onOccurrenceClick` is the very object the caller supplied, so it routes
 * into the existing edit path with no adapter in between.
 */

import type { EventOccurrence } from '../../types/event';
import { useTranslate } from '../../i18n/useLanguage';
import { EventChip } from './EventChip';
import type { DayAgenda } from './dayAgenda';

export function AgendaList({
  agenda,
  onOccurrenceClick,
  /** Rendered under the list, for the phone's "add on this day" affordance. */
  footer,
}: {
  agenda: DayAgenda;
  onOccurrenceClick: (occ: EventOccurrence) => void;
  footer?: React.ReactNode;
}) {
  const tr = useTranslate();
  const total = agenda.allDay.length + agenda.timed.length;

  return (
    <>
      {total === 0 ? (
        <p className="day-agenda-empty">{tr('calendar.agenda.empty')}</p>
      ) : (
        <div className="day-agenda-list">
          {agenda.allDay.length > 0 && (
            <>
              <p className="day-agenda-group">{tr('calendar.allDay')}</p>
              {agenda.allDay.map((occ) => (
                <EventChip
                  key={`ad-${occ.event.id}-${occ.start}`}
                  occurrence={occ}
                  variant="chip"
                  onClick={() => onOccurrenceClick(occ)}
                />
              ))}
            </>
          )}

          {agenda.timed.length > 0 && (
            <>
              <p className="day-agenda-group">{tr('calendar.timed')}</p>
              {agenda.timed.map((occ) => (
                <EventChip
                  key={`t-${occ.event.id}-${occ.start}`}
                  occurrence={occ}
                  variant="chip"
                  onClick={() => onOccurrenceClick(occ)}
                />
              ))}
            </>
          )}
        </div>
      )}
      {footer}
    </>
  );
}
