import { describe, expect, it } from 'vitest';
import type { FreeBusySlot } from '../../types/share';
import { dayStartInstantIso } from '../../utils/timezone';
import { busyForDay } from './freeBusyLayout';

const TZ = 'Asia/Tokyo';

// 2026-09-01 in Tokyo: [00:00, next 00:00) as UTC instants.
const day0 = dayStartInstantIso('2026-09-01', TZ);
const day1 = dayStartInstantIso('2026-09-02', TZ);

describe('busyForDay — timed', () => {
  it('includes a timed slot inside the day, clipped to itself', () => {
    const slots: FreeBusySlot[] = [
      { allDay: false, start: addHours(day0, 9), end: addHours(day0, 10) },
    ];
    const { timed, allDayCount } = busyForDay('2026-09-01', TZ, slots);
    expect(allDayCount).toBe(0);
    expect(timed).toEqual([{ start: addHours(day0, 9), end: addHours(day0, 10) }]);
  });

  it('clips a slot that spans midnight to the day boundary', () => {
    // 23:00 day0 -> 01:00 day1.
    const slots: FreeBusySlot[] = [
      { allDay: false, start: addHours(day0, 23), end: addHours(day1, 1) },
    ];
    const d0 = busyForDay('2026-09-01', TZ, slots);
    expect(d0.timed).toEqual([{ start: addHours(day0, 23), end: day1 }]);
    const d1 = busyForDay('2026-09-02', TZ, slots);
    expect(d1.timed).toEqual([{ start: day1, end: addHours(day1, 1) }]);
  });

  it('excludes a slot on another day', () => {
    const slots: FreeBusySlot[] = [
      { allDay: false, start: addHours(day1, 9), end: addHours(day1, 10) },
    ];
    expect(busyForDay('2026-09-01', TZ, slots).timed).toEqual([]);
  });

  it('sorts multiple timed slots ascending', () => {
    const slots: FreeBusySlot[] = [
      { allDay: false, start: addHours(day0, 14), end: addHours(day0, 15) },
      { allDay: false, start: addHours(day0, 9), end: addHours(day0, 10) },
    ];
    const { timed } = busyForDay('2026-09-01', TZ, slots);
    expect(timed.map((t) => t.start)).toEqual([addHours(day0, 9), addHours(day0, 14)]);
  });
});

describe('busyForDay — all-day', () => {
  it('counts an all-day slot covering the day (half-open)', () => {
    const slots: FreeBusySlot[] = [{ allDay: true, startDate: '2026-09-01', endDate: '2026-09-02' }];
    expect(busyForDay('2026-09-01', TZ, slots).allDayCount).toBe(1);
    // end is exclusive -> not counted on 09-02.
    expect(busyForDay('2026-09-02', TZ, slots).allDayCount).toBe(0);
  });

  it('counts a multi-day all-day slot on each covered day', () => {
    const slots: FreeBusySlot[] = [{ allDay: true, startDate: '2026-09-01', endDate: '2026-09-04' }];
    expect(busyForDay('2026-09-01', TZ, slots).allDayCount).toBe(1);
    expect(busyForDay('2026-09-03', TZ, slots).allDayCount).toBe(1);
    expect(busyForDay('2026-09-04', TZ, slots).allDayCount).toBe(0);
  });
});

/** Add whole hours to a UTC ISO instant. */
function addHours(iso: string, hours: number): string {
  return new Date(Date.parse(iso) + hours * 3_600_000).toISOString();
}
