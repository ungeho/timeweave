import type { CSSProperties } from 'react';
import type { EventOccurrence } from '../../types/event';
import { categoryColor } from '../../utils/categoryColor';
import { buildAllDayBands, MAX_ALL_DAY_LANES } from './allDayBands';
import { overflowEntries } from './dayAgenda';
import { visibilityMeta } from './visibilityMeta';
import { VisibilityIcon } from './EventChip';

interface Props {
  /** Consecutive day keys forming the columns (a week row, 7 days, or 1). */
  dayKeys: string[];
  occurrences: EventOccurrence[];
  onOccurrenceClick: (occ: EventOccurrence) => void;
  maxLanes?: number;
  /**
   * Opens the day agenda for a column whose bands were cut by the lane cap.
   * Optional: without it the "+N" stays the inert label it has always been,
   * which is what the week/day header wants -- those views show every lane, so
   * their overflow is empty and there is nothing to open.
   */
  onOverflowClick?: (dayKey: string) => void;
}

/**
 * Horizontal all-day / multi-day band strip laid over `dayKeys` columns.
 * Layout (band positions, lane stacking, overflow) comes from the pure
 * `buildAllDayBands`; this component only renders it. Reused by the month view
 * (per week row) and the week/day time-grid header.
 */
export function AllDayLane({
  dayKeys,
  occurrences,
  onOccurrenceClick,
  maxLanes = MAX_ALL_DAY_LANES,
  onOverflowClick,
}: Props) {
  const { bands, laneCount, overflow } = buildAllDayBands(occurrences, dayKeys, maxLanes);
  const hasOverflow = overflow.some((n) => n > 0);
  const rows = laneCount + (hasOverflow ? 1 : 0);
  if (rows === 0) return null;

  const gridStyle: CSSProperties = {
    gridTemplateColumns: `repeat(${dayKeys.length}, 1fr)`,
    gridTemplateRows: `repeat(${rows}, var(--band-h))`,
  };

  return (
    <div className="allday-lane" style={gridStyle}>
      {bands.map((band) => {
        const color = categoryColor(band.occurrence.event.category);
        const vis = visibilityMeta[band.occurrence.event.visibility];
        const style = {
          gridColumn: `${band.startIndex + 1} / span ${band.span}`,
          gridRow: band.lane + 1,
          '--cat-bg': color.bg,
          '--cat-fg': color.fg,
        } as CSSProperties;
        return (
          <button
            key={`${band.occurrence.event.id}-${band.occurrence.start}`}
            type="button"
            className={[
              'allday-band',
              band.continuesLeft ? 'cont-left' : '',
              band.continuesRight ? 'cont-right' : '',
            ].join(' ').trim()}
            style={style}
            onClick={() => onOccurrenceClick(band.occurrence)}
            title={`${band.occurrence.event.title}（${vis.label}）`}
            aria-label={`${band.occurrence.event.title}, ${vis.label}`}
          >
            {band.continuesLeft && <span className="cont-mark" aria-hidden>‹</span>}
            <VisibilityIcon visibility={band.occurrence.event.visibility} />
            <span className="allday-band-title">{band.occurrence.event.title || '(無題)'}</span>
            {band.continuesRight && <span className="cont-mark" aria-hidden>›</span>}
          </button>
        );
      })}

      {/* The column -> date join lives in `overflowEntries`, not here: getting it
          wrong opens the wrong day while still showing the right number, which
          no screenshot would catch. */}
      {overflowEntries(dayKeys, overflow).map(({ columnIndex, dayKey, count }) =>
        onOverflowClick ? (
          <button
            key={`ov-${columnIndex}`}
            type="button"
            className="allday-overflow is-button"
            style={{ gridColumn: `${columnIndex + 1}`, gridRow: rows }}
            onClick={(e) => {
              e.stopPropagation();
              onOverflowClick(dayKey);
            }}
            aria-label={`他 ${count} 件の終日予定を表示`}
            title={`他 ${count} 件の終日予定を表示`}
          >
            +{count}
          </button>
        ) : (
          <span
            key={`ov-${columnIndex}`}
            className="allday-overflow"
            style={{ gridColumn: `${columnIndex + 1}`, gridRow: rows }}
          >
            +{count}
          </span>
        ),
      )}
    </div>
  );
}
