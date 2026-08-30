import { describe, expect, it } from 'vitest';
import { hasAnyOverlap, overlaps } from './overlap';

const iv = (startH: number, endH: number) => ({
  start: new Date(2026, 0, 1, startH).toISOString(),
  end: new Date(2026, 0, 1, endH).toISOString(),
});

describe('overlaps', () => {
  it('detects overlapping intervals', () => {
    expect(overlaps(iv(9, 11), iv(10, 12))).toBe(true);
  });

  it('treats touching edges as non-overlapping', () => {
    expect(overlaps(iv(9, 10), iv(10, 11))).toBe(false);
  });

  it('detects containment', () => {
    expect(overlaps(iv(9, 17), iv(12, 13))).toBe(true);
  });

  it('returns false for disjoint intervals', () => {
    expect(overlaps(iv(9, 10), iv(11, 12))).toBe(false);
  });
});

describe('hasAnyOverlap', () => {
  it('finds an overlap in a list', () => {
    expect(hasAnyOverlap([iv(9, 10), iv(13, 14), iv(9, 15)])).toBe(true);
  });
  it('returns false when all disjoint', () => {
    expect(hasAnyOverlap([iv(9, 10), iv(10, 11), iv(11, 12)])).toBe(false);
  });
});
