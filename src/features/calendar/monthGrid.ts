/**
 * Pure helpers to build the 6x7 month grid. No React, no styling — just the
 * dates a month view needs, so it can be unit-tested independently of the UI.
 * Week starts on Monday.
 */

export interface MonthGridCell {
  /**
   * The first local instant of this day (its local midnight). For a date the
   * local zone skipped entirely (Pacific/Apia 2011-12-30) that is the next
   * day's start, so read the date from dayKey / dayOfMonth, never from here.
   */
  date: Date;
  dayKey: string; // "YYYY-MM-DD" local
  /** The number the cell shows: dayKey's day of month. */
  dayOfMonth: number;
  inCurrentMonth: boolean;
  isToday: boolean;
}

/**
 * Build the grid of days shown for the month containing `anchor`.
 *
 * The dates are CALENDAR arithmetic (UTC fields, no zone), and only then
 * turned into local instants. Reading a cell's date back out of a local Date
 * (as this did) fails where the local zone skipped a whole date: with the OS on
 * Pacific/Apia, `new Date(2011, 11, 30)` is 12-31 00:00, so December 2011 had
 * two 31sts and no 30th (R1-M, docs/p8-datetime-contract.md §10).
 */
export function buildMonthGrid(anchor: Date, today: Date = new Date()): MonthGridCell[] {
  const year = anchor.getFullYear();
  const month = anchor.getMonth();

  const firstDow = new Date(Date.UTC(year, month, 1)).getUTCDay();
  const offset = (firstDow + 6) % 7; // days from Monday to the 1st

  const todayKey = dayKey(today);
  const cells: MonthGridCell[] = [];
  for (let i = 0; i < 42; i++) {
    const cal = new Date(Date.UTC(year, month, 1 - offset + i));
    const y = cal.getUTCFullYear();
    const m = cal.getUTCMonth();
    const d = cal.getUTCDate();
    const key = `${y}-${pad(m + 1)}-${pad(d)}`;
    cells.push({
      date: new Date(y, m, d),
      dayKey: key,
      dayOfMonth: d,
      inCurrentMonth: m === month,
      isToday: key === todayKey,
    });
  }
  return cells;
}

/** Range [start, end) in UTC ISO covering the whole visible month grid. */
export function monthGridRange(anchor: Date): { startIso: string; endIso: string } {
  const cells = buildMonthGrid(anchor);
  // From the calendar keys, not read back from cell.date (see buildMonthGrid).
  const [fy, fm, fd] = cells[0]!.dayKey.split('-').map(Number) as [number, number, number];
  const [ly, lm, ld] = cells[cells.length - 1]!.dayKey.split('-').map(Number) as [number, number, number];
  const start = new Date(fy, fm - 1, fd);
  const endExclusive = new Date(ly, lm - 1, ld + 1);
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
