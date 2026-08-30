import type { CalendarView, ViewMode } from '../../hooks/useCalendarView';
import { monthTitle } from './monthGrid';
import { dayTitle, weekTitle } from './weekGrid';

interface Props {
  view: CalendarView;
  timeZone: string;
}

const MODES: { value: ViewMode; label: string }[] = [
  { value: 'month', label: '月' },
  { value: 'week', label: '週' },
  { value: 'day', label: '日' },
];

/** Prev / next / today, period title, and view-mode switch. */
export function CalendarToolbar({ view, timeZone }: Props) {
  const title =
    view.mode === 'month'
      ? monthTitle(view.anchor)
      : view.mode === 'week'
        ? weekTitle(view.anchor, timeZone)
        : dayTitle(view.anchor, timeZone);

  return (
    <div className="toolbar">
      <div className="toolbar-nav">
        <button className="btn" onClick={view.today}>今日</button>
        <button className="btn icon" aria-label="前へ" onClick={view.prev}>‹</button>
        <button className="btn icon" aria-label="次へ" onClick={view.next}>›</button>
        <h2 className="toolbar-title">{title}</h2>
      </div>
      <div className="toolbar-modes">
        {MODES.map((m) => (
          <button
            key={m.value}
            className={`btn ${view.mode === m.value ? 'active' : ''}`}
            onClick={() => view.setMode(m.value)}
          >
            {m.label}
          </button>
        ))}
      </div>
    </div>
  );
}
