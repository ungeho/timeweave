/**
 * Pure helpers to build the 6x7 month grid. No React, no styling — just the
 * dates a month view needs, so it can be unit-tested independently of the UI.
 * Week starts on Monday.
 */

export interface MonthGridCell {
  date: Date; // local midnight of this day
  dayKey: string; // "YYYY-MM-DD" local
  inCurrentMonth: boolean;
  isToday: boolean;
}

/** Build the grid of days shown for the month containing `anchor`. */
export function buildMonthGrid(anchor: Date, today: Date = new Date()): MonthGridCell[] {
  const year = anchor.getFullYear();
  const month = anchor.getMonth();

  const first = new Date(year, month, 1);
  const offset = (first.getDay() + 6) % 7; // days from Monday to the 1st
  const gridStart = new Date(year, month, 1 - offset);

  const todayKey = dayKey(today);
  const cells: MonthGridCell[] = [];
  for (let i = 0; i < 42; i++) {
    const date = new Date(gridStart.getFullYear(), gridStart.getMonth(), gridStart.getDate() + i);
    cells.push({
      date,
      dayKey: dayKey(date),
      inCurrentMonth: date.getMonth() === month,
      isToday: dayKey(date) === todayKey,
    });
  }
  return cells;
}

/** Range [start, end) in UTC ISO covering the whole visible month grid. */
export function monthGridRange(anchor: Date): { startIso: string; endIso: string } {
  const cells = buildMonthGrid(anchor);
  const first = cells[0]!.date;
  const last = cells[cells.length - 1]!.date;
  const start = new Date(first.getFullYear(), first.getMonth(), first.getDate());
  const endExclusive = new Date(last.getFullYear(), last.getMonth(), last.getDate() + 1);
  return { startIso: start.toISOString(), endIso: endExclusive.toISOString() };
}

/** Title like "2026年8月" using the user's locale. */
export function monthTitle(anchor: Date, locale?: string): string {
  return new Intl.DateTimeFormat(locale, { year: 'numeric', month: 'long' }).format(anchor);
}

function dayKey(d: Date): string {
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
}

function pad(n: number): string {
  return String(n).padStart(2, '0');
}
