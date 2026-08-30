import type { CSSProperties, MouseEvent } from 'react';
import type { EventOccurrence, Visibility } from '../../types/event';
import { formatTime } from '../../utils/datetime';
import { categoryColor } from '../../utils/categoryColor';
import { visibilityMeta } from './visibilityMeta';

type Variant = 'chip' | 'block';

interface Props {
  occurrence: EventOccurrence;
  variant?: Variant;
  /** Extra positioning styles (used by the time-grid block variant). */
  style?: CSSProperties;
  onClick?: (e: MouseEvent) => void;
}

/** Tiny inline-SVG visibility marker — no emoji (consistent across OSes). */
export function VisibilityIcon({ visibility }: { visibility: Visibility }) {
  const common = { width: 11, height: 11, viewBox: '0 0 16 16', 'aria-hidden': true } as const;
  if (visibility === 'private') {
    return (
      <svg {...common} className="vis-icon">
        <path
          fill="currentColor"
          d="M8 1a3 3 0 0 0-3 3v2H4a1 1 0 0 0-1 1v6a1 1 0 0 0 1 1h8a1 1 0 0 0 1-1V7a1 1 0 0 0-1-1h-1V4a3 3 0 0 0-3-3Zm-1.5 5V4a1.5 1.5 0 0 1 3 0v2h-3Z"
        />
      </svg>
    );
  }
  if (visibility === 'busy_only') {
    return (
      <svg {...common} className="vis-icon">
        <circle cx="8" cy="8" r="6" fill="currentColor" />
      </svg>
    );
  }
  return (
    <svg {...common} className="vis-icon">
      <path
        fill="none"
        stroke="currentColor"
        strokeWidth="1.3"
        d="M8 2a6 6 0 1 0 0 12A6 6 0 0 0 8 2Zm0 0c2 2 2 10 0 12M8 2C6 4 6 12 8 14M2.3 6h11.4M2.3 10h11.4"
      />
    </svg>
  );
}

/**
 * Shared event pill used by month cells (`chip`) and the week/day time grid
 * (`block`). Category color is applied via CSS custom properties (no CSS-in-JS);
 * visibility is shown with an icon + accessible label, never color alone.
 */
export function EventChip({ occurrence, variant = 'chip', style, onClick }: Props) {
  const { event } = occurrence;
  const color = categoryColor(event.category);
  const vis = visibilityMeta[event.visibility];

  const colorVars = {
    '--cat-bg': color.bg,
    '--cat-fg': color.fg,
    '--cat-border': color.border,
    ...style,
  } as CSSProperties;

  return (
    <button
      type="button"
      className={`event-chip variant-${variant}`}
      style={colorVars}
      onClick={onClick}
      title={`${event.title}（${vis.label}）`}
      aria-label={`${event.title}, ${vis.label}`}
    >
      {!occurrence.allDay && <span className="event-chip-time">{formatTime(occurrence.start)}</span>}
      <VisibilityIcon visibility={event.visibility} />
      <span className="event-chip-title">{event.title || '(無題)'}</span>
    </button>
  );
}
