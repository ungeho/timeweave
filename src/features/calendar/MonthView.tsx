import { Fragment, useMemo, type CSSProperties } from 'react';
import type { EventOccurrence } from '../../types/event';
import { categoryColor } from '../../utils/categoryColor';
import { useMediaQuery } from '../../hooks/useMediaQuery';
import { buildMonthGrid, type MonthGridCell } from './monthGrid';
import type { AllDayBand } from './allDayBands';
import { EventChip, VisibilityIcon } from './EventChip';
import { visibilityMeta } from './visibilityMeta';
import { COMPACT_MONTH_QUERY } from './dayAgenda';
import { buildMonthWeekLayout, groupMonthOccurrences, monthSlotCount } from './monthWeekLayout';

interface Props {
  anchor: Date;
  timeZone: string;
  occurrences: EventOccurrence[];
  /** Clicking an empty day starts a new event on that day. */
  onDayClick: (dayKey: string) => void;
  /** Clicking an occurrence opens it for editing. */
  onOccurrenceClick: (occ: EventOccurrence) => void;
  /** Opens the full day listing, from a day's single "+N". */
  onDayAgendaOpen: (dayKey: string) => void;
}

const WEEKDAY_LABELS = ['月', '火', '水', '木', '金', '土', '日'];

/**
 * Item rows per day for the current viewport.
 *
 * The ONE place the month view decides compactness: the existing
 * COMPACT_MONTH_QUERY, subscribed, mapped through monthSlotCount. The grid and
 * the loading placeholder both call this, and the stylesheet only ever receives
 * the result as --month-slots, so the row count and the breakpoint that
 * switches it have no second definition in CSS.
 */
export function useMonthSlots(): number {
  return monthSlotCount(useMediaQuery(COMPACT_MONTH_QUERY));
}

/** Hands the row count to the stylesheet, which derives the week height from it. */
export function monthSlotsStyle(slots: number): CSSProperties {
  return { '--month-slots': String(slots) } as CSSProperties;
}

/**
 * Month grid. Each week is ONE CSS grid -- a date row plus `slots` item rows --
 * and `buildMonthWeekLayout` decides what goes in every row: all-day bands on
 * top, timed chips below them, and at most one "+N" per day in its last row.
 * This component only places those results; it decides nothing about what fits.
 *
 * Grid lines: row 1 is the date label, so item row r is grid row r + 2.
 */
export function MonthView({
  anchor,
  timeZone,
  occurrences,
  onDayClick,
  onOccurrenceClick,
  onDayAgendaOpen,
}: Props) {
  const slots = useMonthSlots();

  const weeks = useMemo(() => {
    const cells = buildMonthGrid(anchor);
    const chunks: MonthGridCell[][] = [];
    for (let i = 0; i < cells.length; i += 7) chunks.push(cells.slice(i, i + 7));
    return chunks;
  }, [anchor]);

  const groups = useMemo(
    () => groupMonthOccurrences(occurrences, timeZone),
    [occurrences, timeZone],
  );

  // Once per week per change of data or viewport, not on every render.
  const layouts = useMemo(
    () => weeks.map((week) => buildMonthWeekLayout(week.map((c) => c.dayKey), groups, slots)),
    [weeks, groups, slots],
  );

  return (
    <div className="month" style={monthSlotsStyle(slots)}>
      <div className="month-weekdays">
        {WEEKDAY_LABELS.map((w) => (
          <div key={w} className="month-weekday">{w}</div>
        ))}
      </div>

      <div className="month-weeks">
        {weeks.map((week, wi) => {
          const layout = layouts[wi];
          if (!layout) return null;
          return (
            <div className="month-week" key={wi}>
              {/* Day backgrounds and click targets first, so every band, chip
                  and "+N" below is painted on top of them. */}
              {week.map((cell, ci) => (
                <div
                  key={`cell-${cell.dayKey}`}
                  className={[
                    'month-cell',
                    cell.inCurrentMonth ? '' : 'muted',
                    cell.isToday ? 'today' : '',
                  ].join(' ').trim()}
                  style={{ gridColumn: ci + 1 }}
                  onClick={() => onDayClick(cell.dayKey)}
                >
                  <div className="month-cell-date">{cell.date.getDate()}</div>
                </div>
              ))}

              {layout.bands.map((band) => (
                <MonthBand
                  key={`band-${band.occurrence.event.id}-${band.occurrence.start}`}
                  band={band}
                  onOccurrenceClick={onOccurrenceClick}
                />
              ))}

              {layout.days.map((day) => (
                <Fragment key={`day-${day.dayKey}`}>
                  {day.chips.map((occ, k) => (
                    <EventChip
                      key={`${occ.event.id}-${occ.start}`}
                      occurrence={occ}
                      variant="chip"
                      style={{ gridColumn: day.columnIndex + 1, gridRow: day.bandRows + k + 2 }}
                      onClick={(e) => {
                        e.stopPropagation();
                        onOccurrenceClick(occ);
                      }}
                    />
                  ))}
                  {day.moreRow !== null && (
                    <button
                      type="button"
                      className="month-more"
                      style={{ gridColumn: day.columnIndex + 1, gridRow: day.moreRow + 2 }}
                      onClick={(e) => {
                        e.stopPropagation();
                        onDayAgendaOpen(day.dayKey);
                      }}
                      // One "+N" per day, counting hidden all-day bands and hidden
                      // timed events together: both open the same agenda. The
                      // spoken and hover text stay descriptive, since "+3" on its
                      // own says nothing about what it opens.
                      aria-label={`他 ${day.hiddenCount} 件の予定を表示`}
                      title={`他 ${day.hiddenCount} 件の予定を表示`}
                    >
                      +{day.hiddenCount}
                    </button>
                  )}
                </Fragment>
              ))}
            </div>
          );
        })}
      </div>
    </div>
  );
}

/**
 * One all-day band placed in a week's grid. The same markup and classes the
 * week/day header's AllDayLane renders, so a band looks identical in every
 * view; only the placement differs (row = lane + 2, below the date label).
 */
function MonthBand({
  band,
  onOccurrenceClick,
}: {
  band: AllDayBand;
  onOccurrenceClick: (occ: EventOccurrence) => void;
}) {
  const { event } = band.occurrence;
  const color = categoryColor(event.category);
  const vis = visibilityMeta[event.visibility];
  const style = {
    gridColumn: `${band.startIndex + 1} / span ${band.span}`,
    gridRow: band.lane + 2,
    '--cat-bg': color.bg,
    '--cat-fg': color.fg,
  } as CSSProperties;

  return (
    <button
      type="button"
      className={[
        'allday-band',
        band.continuesLeft ? 'cont-left' : '',
        band.continuesRight ? 'cont-right' : '',
      ].join(' ').trim()}
      style={style}
      onClick={(e) => {
        e.stopPropagation();
        onOccurrenceClick(band.occurrence);
      }}
      title={`${event.title}（${vis.label}）`}
      aria-label={`${event.title}, ${vis.label}`}
    >
      {band.continuesLeft && <span className="cont-mark" aria-hidden>‹</span>}
      <VisibilityIcon visibility={event.visibility} />
      <span className="allday-band-title">{event.title || '(無題)'}</span>
      {band.continuesRight && <span className="cont-mark" aria-hidden>›</span>}
    </button>
  );
}
