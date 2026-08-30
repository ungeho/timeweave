import { useLayoutEffect, useRef, type CSSProperties, type MouseEvent } from 'react';
import type { EventOccurrence } from '../../types/event';
import type { DayCell } from './weekGrid';
import {
  initialScrollMinutes,
  layoutDayColumn,
  MINUTES_PER_DAY,
} from './timeGrid';
import { AllDayLane } from './AllDayLane';
import { EventChip } from './EventChip';

const HOUR_PX = 48;
const TOTAL_PX = 24 * HOUR_PX;
const WEEKDAY_LABELS = ['月', '火', '水', '木', '金', '土', '日'];

interface Props {
  days: DayCell[];
  occurrences: EventOccurrence[];
  timeZone: string;
  onSlotClick: (dayKey: string, minutes: number) => void;
  onOccurrenceClick: (occ: EventOccurrence) => void;
}

/**
 * Shared week/day view: a fixed 0–24h time grid with an all-day header.
 * Used for the week (7 days) and day (1 day) modes. All time math comes from the
 * timezone-explicit pure helpers in `timeGrid`.
 */
export function TimeGridView({ days, occurrences, timeZone, onSlotClick, onOccurrenceClick }: Props) {
  const scrollRef = useRef<HTMLDivElement>(null);
  const anchorKey = days[0]?.dayKey ?? '';

  // Scroll to the initial position when the visible day(s) change (08:00, or an
  // earlier event). useLayoutEffect avoids a visible jump.
  useLayoutEffect(() => {
    const el = scrollRef.current;
    if (!el) return;
    const minutes = initialScrollMinutes(occurrences, timeZone);
    el.scrollTop = Math.max(0, (minutes / MINUTES_PER_DAY) * TOTAL_PX - 12);
    // Intentionally keyed on the day range, not on every occurrence change.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [anchorKey, timeZone]);

  const dayKeys = days.map((d) => d.dayKey);
  const colStyle: CSSProperties = { gridTemplateColumns: `repeat(${days.length}, 1fr)` };

  const handleColClick = (dayKey: string, e: MouseEvent<HTMLDivElement>) => {
    const rect = e.currentTarget.getBoundingClientRect();
    const y = e.clientY - rect.top;
    const raw = (y / rect.height) * MINUTES_PER_DAY;
    const snapped = Math.min(MINUTES_PER_DAY - 30, Math.max(0, Math.round(raw / 30) * 30));
    onSlotClick(dayKey, snapped);
  };

  return (
    <div className="timegrid">
      <div className="timegrid-head">
        <div className="timegrid-gutter-head" />
        <div className="timegrid-dayheads" style={colStyle}>
          {days.map((d) => (
            <div key={d.dayKey} className={`timegrid-dayhead ${d.isToday ? 'today' : ''}`}>
              <span className="dh-weekday">{WEEKDAY_LABELS[d.weekdayIndex]}</span>
              <span className="dh-day">{d.dayOfMonth}</span>
            </div>
          ))}
        </div>
      </div>

      <div className="timegrid-alldayrow">
        <div className="timegrid-gutter-label">終日</div>
        <div className="timegrid-allday">
          <AllDayLane dayKeys={dayKeys} occurrences={occurrences} onOccurrenceClick={onOccurrenceClick} />
        </div>
      </div>

      <div className="timegrid-scroll" ref={scrollRef}>
        <div className="timegrid-body" style={{ height: TOTAL_PX }}>
          <div className="timegrid-gutter">
            {Array.from({ length: 24 }, (_, h) => (
              <div key={h} className="timegrid-hour" style={{ height: HOUR_PX }}>
                <span className="timegrid-hour-label">{String(h).padStart(2, '0')}:00</span>
              </div>
            ))}
          </div>

          <div className="timegrid-cols" style={colStyle}>
            {days.map((day) => {
              const positioned = layoutDayColumn(occurrences, day.dayKey, timeZone);
              return (
                <div
                  key={day.dayKey}
                  className="timegrid-col"
                  onClick={(e) => handleColClick(day.dayKey, e)}
                >
                  {positioned.map((p) => {
                    const style: CSSProperties = {
                      position: 'absolute',
                      top: `${p.topFraction * 100}%`,
                      height: `${p.heightFraction * 100}%`,
                      left: `${(p.colIndex / p.colCount) * 100}%`,
                      width: `${(1 / p.colCount) * 100}%`,
                    };
                    return (
                      <EventChip
                        key={`${p.occurrence.event.id}-${p.occurrence.start}`}
                        occurrence={p.occurrence}
                        variant="block"
                        style={style}
                        onClick={(e) => {
                          e.stopPropagation();
                          onOccurrenceClick(p.occurrence);
                        }}
                      />
                    );
                  })}
                </div>
              );
            })}
          </div>
        </div>
      </div>
    </div>
  );
}
