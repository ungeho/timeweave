import { useMemo } from 'react';
import type { EventOccurrence } from '../../types/event';
import { zonedDayKey } from '../../utils/timezone';
import { buildMonthGrid, type MonthGridCell } from './monthGrid';
import { AllDayLane } from './AllDayLane';
import { EventChip } from './EventChip';

interface Props {
  anchor: Date;
  timeZone: string;
  occurrences: EventOccurrence[];
  /** Clicking an empty day starts a new event on that day. */
  onDayClick: (dayKey: string) => void;
  /** Clicking an occurrence opens it for editing. */
  onOccurrenceClick: (occ: EventOccurrence) => void;
}

const WEEKDAY_LABELS = ['月', '火', '水', '木', '金', '土', '日'];

export function MonthView({ anchor, timeZone, occurrences, onDayClick, onOccurrenceClick }: Props) {
  const weeks = useMemo(() => {
    const cells = buildMonthGrid(anchor);
    const chunks: MonthGridCell[][] = [];
    for (let i = 0; i < cells.length; i += 7) chunks.push(cells.slice(i, i + 7));
    return chunks;
  }, [anchor]);

  // Multi-day/all-day events render as bands (per week); timed events as chips
  // placed on their start day (grouped in the user's zone).
  const { allDayOccs, timedByDay } = useMemo(() => {
    const allDay: EventOccurrence[] = [];
    const timed = new Map<string, EventOccurrence[]>();
    for (const occ of occurrences) {
      if (occ.allDay) {
        allDay.push(occ);
      } else {
        const key = zonedDayKey(occ.start, timeZone);
        const list = timed.get(key) ?? [];
        list.push(occ);
        timed.set(key, list);
      }
    }
    return { allDayOccs: allDay, timedByDay: timed };
  }, [occurrences, timeZone]);

  return (
    <div className="month">
      <div className="month-weekdays">
        {WEEKDAY_LABELS.map((w) => (
          <div key={w} className="month-weekday">{w}</div>
        ))}
      </div>

      <div className="month-weeks">
        {weeks.map((week, wi) => (
          <div className="month-week" key={wi}>
            <AllDayLane
              dayKeys={week.map((c) => c.dayKey)}
              occurrences={allDayOccs}
              onOccurrenceClick={onOccurrenceClick}
            />
            <div className="month-week-grid">
              {week.map((cell) => {
                const dayEvents = timedByDay.get(cell.dayKey) ?? [];
                return (
                  <div
                    key={cell.dayKey}
                    className={[
                      'month-cell',
                      cell.inCurrentMonth ? '' : 'muted',
                      cell.isToday ? 'today' : '',
                    ].join(' ').trim()}
                    onClick={() => onDayClick(cell.dayKey)}
                  >
                    <div className="month-cell-date">{cell.date.getDate()}</div>
                    <div className="month-cell-events">
                      {dayEvents.map((occ) => (
                        <EventChip
                          key={`${occ.event.id}-${occ.start}`}
                          occurrence={occ}
                          variant="chip"
                          onClick={(e) => {
                            e.stopPropagation();
                            onOccurrenceClick(occ);
                          }}
                        />
                      ))}
                    </div>
                  </div>
                );
              })}
            </div>
          </div>
        ))}
      </div>
    </div>
  );
}
