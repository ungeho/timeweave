import { describe, expect, it } from 'vitest';
import { buildWeekDays, dayRange, weekRange, weekStartDayKey } from './weekGrid';

const TZ = 'Asia/Tokyo'; // UTC+9, no DST

describe('weekGrid (timezone-explicit)', () => {
  // 2026-08-27T03:00Z => 2026-08-27 12:00 in Tokyo (Thursday)
  const anchor = new Date('2026-08-27T03:00:00Z');

  it('weekStartDayKey returns the Monday of the zoned week', () => {
    expect(weekStartDayKey(anchor, TZ)).toBe('2026-08-24');
  });

  it('buildWeekDays returns 7 Monday-first consecutive days', () => {
    const now = new Date('2026-08-25T01:00:00Z'); // Tokyo 2026-08-25
    const days = buildWeekDays(anchor, TZ, now);
    expect(days.map((d) => d.dayKey)).toEqual([
      '2026-08-24', '2026-08-25', '2026-08-26', '2026-08-27',
      '2026-08-28', '2026-08-29', '2026-08-30',
    ]);
    expect(days[0]!.weekdayIndex).toBe(0); // Monday
    expect(days[0]!.dayOfMonth).toBe(24);
    expect(days.filter((d) => d.isToday).map((d) => d.dayKey)).toEqual(['2026-08-25']);
  });

  it('weekRange is the half-open UTC span of the zoned week', () => {
    const { startIso, endIso } = weekRange(anchor, TZ);
    expect(startIso).toBe('2026-08-23T15:00:00.000Z'); // Tokyo 08-24 00:00
    expect(endIso).toBe('2026-08-30T15:00:00.000Z'); // Tokyo 08-31 00:00
  });

  it('dayRange is the half-open UTC span of the zoned day', () => {
    const { startIso, endIso } = dayRange(anchor, TZ);
    expect(startIso).toBe('2026-08-26T15:00:00.000Z'); // Tokyo 08-27 00:00
    expect(endIso).toBe('2026-08-27T15:00:00.000Z'); // Tokyo 08-28 00:00
  });

  it('does not depend on the runtime local zone (UTC zone differs)', () => {
    // Same instant, zone = UTC => the day is 08-27, week Monday still 08-24.
    expect(weekStartDayKey(anchor, 'UTC')).toBe('2026-08-24');
    expect(weekRange(anchor, 'UTC').startIso).toBe('2026-08-24T00:00:00.000Z');
  });
});
