/**
 * Month-grid arithmetic for the date picker. Calendar dates only
 * ("YYYY-MM-DD"), in UTC fields so no zone or DST can move a day. Weeks start
 * on MONDAY, like the app's week view (utils/timezone weekdayOfDayKey).
 */
import { addDaysToDateString } from '../../../utils/datetime';
import { weekdayOfDayKey } from '../../../utils/timezone';

const pad = (n: number, w = 2) => String(n).padStart(w, '0');

export function dayKeyOf(y: number, m: number, d: number): string {
  return `${pad(y, 4)}-${pad(m)}-${pad(d)}`;
}

export function parseDayKey(key: string): { y: number; m: number; d: number } | null {
  const match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(key);
  if (!match) return null;
  return { y: Number(match[1]), m: Number(match[2]), d: Number(match[3]) };
}

export function daysInMonth(y: number, m: number): number {
  return new Date(Date.UTC(y, m, 0)).getUTCDate();
}

/** Month arithmetic that CLAMPS the day (Jan 31 + 1 month = Feb 28/29), never rolls over. */
export function addMonthsClamped(key: string, n: number): string {
  const p = parseDayKey(key)!;
  const total = p.y * 12 + (p.m - 1) + n;
  const y = Math.floor(total / 12);
  const m = (total % 12) + 1;
  return dayKeyOf(y, m, Math.min(p.d, daysInMonth(y, m)));
}

/** 6 weeks x 7 days, Monday first, including the neighbouring months' days. */
export function monthGrid(year: number, month: number): { key: string; inMonth: boolean }[] {
  const first = dayKeyOf(year, month, 1);
  const start = addDaysToDateString(first, -weekdayOfDayKey(first));
  return Array.from({ length: 42 }, (_, i) => {
    const key = addDaysToDateString(start, i);
    return { key, inMonth: parseDayKey(key)!.m === month };
  });
}

/** Today's calendar date on this device (a date, not an instant). */
export function todayDayKey(now = new Date()): string {
  return dayKeyOf(now.getFullYear(), now.getMonth() + 1, now.getDate());
}
