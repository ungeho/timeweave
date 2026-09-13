import { useMemo } from 'react';
import type { EventOccurrence } from '../../types/event';
import { zonedDayKey } from '../../utils/timezone';
import { buildMonthGrid, type MonthGridCell } from './monthGrid';
import { AllDayLane } from './AllDayLane';
import { EventChip } from './EventChip';
import { COMPACT_MONTH_QUERY, monthChipCap, splitMonthCellChips } from './dayAgenda';
import { useMediaQuery } from '../../hooks/useMediaQuery';

interface Props {
  anchor: Date;
  timeZone: string;
  occurrences: EventOccurrence[];
  /** Clicking an empty day starts a new event on that day. */
  onDayClick: (dayKey: string) => void;
  /** Clicking an occurrence opens it for editing. */
  onOccurrenceClick: (occ: EventOccurrence) => void;
  /**
   * Opens the full day listing. Reached from either overflow affordance -- the
   * all-day lane's "+N" and a cell's "+N" -- because a day truncated on one
   * side is usually busy on the other, and one list answers both.
   */
  onDayAgendaOpen: (dayKey: string) => void;
}

const WEEKDAY_LABELS = ['月', '火', '水', '木', '金', '土', '日'];

export function MonthView({
  anchor,
  timeZone,
  occurrences,
  onDayClick,
  onOccurrenceClick,
  onDayAgendaOpen,
}: Props) {
  // The cell's chip budget follows the row height, which the same breakpoint
  // lowers in CSS. Subscribed rather than read once, so rotating a phone or
  // dragging a desktop window across 640px re-lays the grid instead of leaving
  // it clipped at the old cap.
  const chipCap = monthChipCap(useMediaQuery(COMPACT_MONTH_QUERY));

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
              onOverflowClick={onDayAgendaOpen}
            />
            <div className="month-week-grid">
              {week.map((cell) => {
                const dayEvents = timedByDay.get(cell.dayKey) ?? [];
                // Capped so the cell cannot outgrow --month-row-h. Before this,
                // every timed occurrence was rendered and `.month-cell-events`
                // (overflow: hidden) simply clipped the surplus -- invisible and
                // uncountable.
                const { visible, hiddenCount } = splitMonthCellChips(dayEvents, chipCap);
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
                      {visible.map((occ) => (
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
                      {hiddenCount > 0 && (
                        <button
                          type="button"
                          className="month-more"
                          onClick={(e) => {
                            // Without this the cell's own handler fires too and
                            // opens the "new event" dialog behind the agenda.
                            e.stopPropagation();
                            onDayAgendaOpen(cell.dayKey);
                          }}
                          // The visible label matches the all-day lane's "+N",
                          // so one day's two truncations read as one idiom. The
                          // spoken and hover text stay descriptive: "+3" on its
                          // own says nothing about what it opens.
                          aria-label={`他 ${hiddenCount} 件の予定を表示`}
                          title={`他 ${hiddenCount} 件の予定を表示`}
                        >
                          +{hiddenCount}
                        </button>
                      )}
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
