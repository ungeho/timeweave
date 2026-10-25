/**
 * View state for the calendar: which mode (month/week/day for now just month)
 * and which period is anchored. Navigation logic lives here, not in the UI.
 */

import { useCallback, useMemo, useState } from 'react';

/**
 * `agenda` IS MOBILE-ONLY. The desktop toolbar never offers it -- CalendarToolbar
 * lists month, week and day, and a compile-time parity check there fails if that
 * list and this type stop agreeing about those three. Adding a fourth value the
 * toolbar deliberately omits is the one case that parity check has to tolerate,
 * so it compares against the three it names rather than against the whole union.
 */
export type ViewMode = 'month' | 'week' | 'day' | 'agenda';

export interface CalendarView {
  mode: ViewMode;
  /** The date the current period is anchored on (local time). */
  anchor: Date;
  setMode: (mode: ViewMode) => void;
  next: () => void;
  prev: () => void;
  today: () => void;
  /**
   * Move the anchor to a specific date, keeping the mode.
   *
   * For the mobile date strip, where picking a day IS the navigation. The
   * anchor doubles as "the selected day" there, so there is no second piece of
   * state to keep in step with it -- and a width change carries the date
   * across because the anchor is what both layouts read.
   */
  goTo: (date: Date) => void;
}

export function useCalendarView(initialMode: ViewMode = 'month'): CalendarView {
  const [mode, setMode] = useState<ViewMode>(initialMode);
  const [anchor, setAnchor] = useState<Date>(() => new Date());

  const step = useCallback(
    (dir: 1 | -1) => {
      setAnchor((cur) => stepAnchor(cur, mode, dir));
    },
    [mode],
  );

  const next = useCallback(() => step(1), [step]);
  const prev = useCallback(() => step(-1), [step]);
  const today = useCallback(() => setAnchor(new Date()), []);
  const goTo = useCallback((date: Date) => setAnchor(new Date(date)), []);

  return useMemo(
    () => ({ mode, anchor, setMode, next, prev, today, goTo }),
    [mode, anchor, next, prev, today, goTo],
  );
}

/**
 * One press of prev/next (or one swipe): the new anchor. Pure, so it is testable.
 *
 * MONTH IS CLAMPED (P8-mobile-1). It was `d.setMonth(m + dir)`, which from the
 * 31st overflows into the month after: Jan 31 -> Mar 3, Mar 31 -> prev -> Mar 3,
 * May 31 -> Jul 1 -- a month skipped, or no move at all. The day now becomes
 * the last day of the target month when that month is shorter.
 */
export function stepAnchor(cur: Date, mode: ViewMode, dir: 1 | -1): Date {
  const d = new Date(cur);
  if (mode === 'month') {
    const target = new Date(cur.getFullYear(), cur.getMonth() + dir, 1);
    const last = new Date(target.getFullYear(), target.getMonth() + 1, 0).getDate();
    d.setFullYear(target.getFullYear(), target.getMonth(), Math.min(cur.getDate(), last));
  }
  // `agenda` steps by a WEEK, not a day: the arrows sit beside a strip
  // showing seven days, so they move the strip. Picking a day within it
  // is `goTo`, which is a different gesture with a different control.
  else if (mode === 'week' || mode === 'agenda') d.setDate(d.getDate() + dir * 7);
  else d.setDate(d.getDate() + dir);
  return d;
}
