import { afterAll, describe, expect, it } from 'vitest';
import { stepAnchor } from './useCalendarView';

/*
  P8-mobile-1: the calendar's prev/next step, pulled out of the hook so it can
  be tested. The swipe (M4) calls the same step as the arrows.

  BUG FOUND (month mode, every layout): the step was `d.setMonth(m + dir)` on
  the anchor, so from the 31st it overflowed: Jan 31 -> "next" -> Mar 3 (no
  February), Mar 31 -> "prev" -> Mar 3 (did not move), May 31 -> Jul 1. The
  day is now clamped to the target month. Weeks and days were never affected.
  Runs under several OS zones: the anchor is a local Date.
*/

const env = (globalThis as unknown as { process: { env: Record<string, string | undefined> } }).process.env;
const ORIGINAL_TZ = env.TZ;
afterAll(() => {
  if (ORIGINAL_TZ === undefined) delete env.TZ;
  else env.TZ = ORIGINAL_TZ;
});
const ymd = (d: Date) => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;

for (const os of ['UTC', 'Asia/Tokyo', 'America/New_York', 'America/Havana', 'Pacific/Apia']) {
  describe(`stepAnchor (OS ${os})`, () => {
    const at = (y: number, m: number, d: number) => { env.TZ = os; return new Date(y, m - 1, d, 12); };

    it('month: from the 31st it lands in the NEXT / PREVIOUS month, clamped', () => {
      expect(ymd(stepAnchor(at(2026, 1, 31), 'month', 1))).toBe('2026-02-28');
      expect(ymd(stepAnchor(at(2024, 1, 31), 'month', 1))).toBe('2024-02-29'); // leap year
      expect(ymd(stepAnchor(at(2026, 3, 31), 'month', -1))).toBe('2026-02-28');
      expect(ymd(stepAnchor(at(2026, 5, 31), 'month', 1))).toBe('2026-06-30');
      expect(ymd(stepAnchor(at(2026, 12, 31), 'month', 1))).toBe('2027-01-31'); // year end
      expect(ymd(stepAnchor(at(2026, 1, 15), 'month', -1))).toBe('2025-12-15'); // year start
    });

    it('month: twelve steps forward from any day of 2026 visit twelve different months, in order', () => {
      for (let d = 1; d <= 31; d++) {
        let a = at(2026, 1, d);
        const months: string[] = [];
        for (let i = 0; i < 12; i++) { a = stepAnchor(a, 'month', 1); months.push(ymd(a).slice(0, 7)); }
        expect(months, `from 2026-01-${d}`).toEqual(['2026-02', '2026-03', '2026-04', '2026-05', '2026-06', '2026-07',
          '2026-08', '2026-09', '2026-10', '2026-11', '2026-12', '2027-01']);
      }
    });

    it('agenda and week step by seven days, day by one (unchanged)', () => {
      expect(ymd(stepAnchor(at(2026, 3, 5), 'agenda', 1))).toBe('2026-03-12');
      expect(ymd(stepAnchor(at(2026, 3, 5), 'week', -1))).toBe('2026-02-26');
      expect(ymd(stepAnchor(at(2026, 2, 28), 'day', 1))).toBe('2026-03-01');
      expect(ymd(stepAnchor(at(2024, 2, 28), 'day', 1))).toBe('2024-02-29');
    });

    it('a DST switch does not move the date (the anchor is noon)', () => {
      expect(ymd(stepAnchor(at(2026, 3, 7), 'day', 1))).toBe('2026-03-08');
      expect(ymd(stepAnchor(at(2026, 10, 31), 'day', 1))).toBe('2026-11-01');
      expect(ymd(stepAnchor(at(2026, 2, 8), 'month', 1))).toBe('2026-03-08');
    });
  });
}
