import { describe, expect, it } from 'vitest';
import { buildMonthGrid, monthGridRange } from './monthGrid';

describe('buildMonthGrid', () => {
  it('always produces 42 cells (6 weeks)', () => {
    expect(buildMonthGrid(new Date(2026, 7, 15))).toHaveLength(42);
  });

  it('starts on a Monday', () => {
    const cells = buildMonthGrid(new Date(2026, 7, 15));
    expect(cells[0]!.date.getDay()).toBe(1);
  });

  it('marks in-month days correctly', () => {
    const cells = buildMonthGrid(new Date(2026, 7, 15)); // August
    const inMonth = cells.filter((c) => c.inCurrentMonth);
    expect(inMonth).toHaveLength(31); // August has 31 days
    expect(inMonth.every((c) => c.date.getMonth() === 7)).toBe(true);
  });

  it('flags today', () => {
    const today = new Date(2026, 7, 15);
    const cells = buildMonthGrid(today, today);
    const todays = cells.filter((c) => c.isToday);
    expect(todays).toHaveLength(1);
    expect(todays[0]!.date.getDate()).toBe(15);
  });
});

describe('monthGridRange', () => {
  it('covers the full visible grid', () => {
    const { startIso, endIso } = monthGridRange(new Date(2026, 7, 15));
    expect(new Date(startIso).getDay()).toBe(1); // Monday start
    expect(new Date(endIso).getTime()).toBeGreaterThan(new Date(startIso).getTime());
  });
});
