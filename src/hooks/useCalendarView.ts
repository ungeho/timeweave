/**
 * View state for the calendar: which mode (month/week/day for now just month)
 * and which period is anchored. Navigation logic lives here, not in the UI.
 */

import { useCallback, useMemo, useState } from 'react';

export type ViewMode = 'month' | 'week' | 'day';

export interface CalendarView {
  mode: ViewMode;
  /** The date the current period is anchored on (local time). */
  anchor: Date;
  setMode: (mode: ViewMode) => void;
  next: () => void;
  prev: () => void;
  today: () => void;
}

export function useCalendarView(initialMode: ViewMode = 'month'): CalendarView {
  const [mode, setMode] = useState<ViewMode>(initialMode);
  const [anchor, setAnchor] = useState<Date>(() => new Date());

  const step = useCallback(
    (dir: 1 | -1) => {
      setAnchor((cur) => {
        const d = new Date(cur);
        if (mode === 'month') d.setMonth(d.getMonth() + dir);
        else if (mode === 'week') d.setDate(d.getDate() + dir * 7);
        else d.setDate(d.getDate() + dir);
        return d;
      });
    },
    [mode],
  );

  const next = useCallback(() => step(1), [step]);
  const prev = useCallback(() => step(-1), [step]);
  const today = useCallback(() => setAnchor(new Date()), []);

  return useMemo(
    () => ({ mode, anchor, setMode, next, prev, today }),
    [mode, anchor, next, prev, today],
  );
}
