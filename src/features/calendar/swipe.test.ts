import { describe, expect, it } from 'vitest';
import { classifySwipe, SWIPE_MAX_MS, SWIPE_MIN_DX } from './mobile/swipe';
import { addDaysToDateString } from '../../utils/datetime';

/*
  P8-mobile-1 (M4): when a touch gesture is a swipe. The handler itself needs a
  browser (checked with real touch input in the browser run); the DECISION is
  pure and pinned here.
*/

describe('classifySwipe', () => {
  it('a clear horizontal flick is a swipe, by direction', () => {
    expect(classifySwipe(-120, 10, 200)).toBe('left');
    expect(classifySwipe(120, -10, 200)).toBe('right');
  });

  it('too short is a tap, not a swipe', () => {
    expect(classifySwipe(-(SWIPE_MIN_DX - 1), 0, 100)).toBeNull();
    expect(classifySwipe(-SWIPE_MIN_DX, 0, 100)).toBe('left');
    expect(classifySwipe(0, 0, 80)).toBeNull();
  });

  it('vertical or diagonal movement is a scroll, never a page change', () => {
    expect(classifySwipe(10, 300, 300)).toBeNull();
    expect(classifySwipe(-100, 60, 200)).toBeNull(); // diagonal: |dx| < 2|dy|
    expect(classifySwipe(-120, 60, 200)).toBe('left'); // exactly 2:1
  });

  it('a slow drag is not a swipe', () => {
    expect(classifySwipe(-200, 0, SWIPE_MAX_MS + 1)).toBeNull();
    expect(classifySwipe(-200, 0, SWIPE_MAX_MS)).toBe('left');
    expect(classifySwipe(-200, 0, Number.NaN)).toBeNull();
  });
});

describe('the list swipe steps one CALENDAR day', () => {
  it('month ends, year ends, leap days and DST days', () => {
    expect(addDaysToDateString('2026-01-31', 1)).toBe('2026-02-01');
    expect(addDaysToDateString('2026-03-01', -1)).toBe('2026-02-28');
    expect(addDaysToDateString('2024-03-01', -1)).toBe('2024-02-29');
    expect(addDaysToDateString('2026-12-31', 1)).toBe('2027-01-01');
    expect(addDaysToDateString('2026-03-07', 1)).toBe('2026-03-08'); // NY / Havana switch
    expect(addDaysToDateString('2026-11-01', -1)).toBe('2026-10-31');
  });
});

const SRC = (import.meta.glob('/src/features/calendar/mobile/MobileCalendar.tsx', { query: '?raw', import: 'default', eager: true }) as Record<string, string>)[
  '/src/features/calendar/mobile/MobileCalendar.tsx'
]!;

describe('MobileCalendar wiring', () => {
  it('list: a day by calendar date via the same selection a strip tap makes; month: the arrows\' own step', () => {
    expect(SRC).toMatch(/onSelectDay\(addDaysToDateString\(selectedDayKey, d\)\)/);
    expect(SRC).toMatch(/if \(d === 1\) view\.next\(\);\s*else view\.prev\(\);/);
    expect(SRC).toMatch(/<div ref=\{swipeRef\} className="mobile-swipe-area">/);
  });

  it('the arrow buttons are still there', () => {
    expect(SRC).toMatch(/aria-label=\{tr\('calendar\.prev'\)\}/);
    expect(SRC).toMatch(/aria-label=\{tr\('calendar\.next'\)\}/);
  });
});
