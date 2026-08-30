import type { CSSProperties } from 'react';
import type { EventOccurrence } from '../../types/event';
import { categoryColor } from '../../utils/categoryColor';
import { buildAllDayBands, MAX_ALL_DAY_LANES } from './allDayBands';
import { visibilityMeta } from './visibilityMeta';
import { VisibilityIcon } from './EventChip';

interface Props {
  /** Consecutive day keys forming the columns (a week row, 7 days, or 1). */
  dayKeys: string[];
  occurrences: EventOccurrence[];
  onOccurrenceClick: (occ: EventOccurrence) => void;
  maxLanes?: number;
}

/**
 * Horizontal all-day / multi-day band strip laid over `dayKeys` columns.
 * Layout (band positions, lane stacking, overflow) comes from the pure
 * `buildAllDayBands`; this component only renders it. Reused by the month view
 * (per week row) and the week/day time-grid header.
 */
export function AllDayLane({ dayKeys, occurrences, onOccurrenceClick, maxLanes = MAX_ALL_DAY_LANES }: Props) {
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

      {hasOverflow &&
        overflow.map((n, i) =>
          n > 0 ? (
            <span
              key={`ov-${i}`}
              className="allday-overflow"
              style={{ gridColumn: `${i + 1}`, gridRow: rows }}
            >
              +{n}
            </span>
          ) : null,
        )}
    </div>
  );
}
