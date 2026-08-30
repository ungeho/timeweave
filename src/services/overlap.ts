/**
 * Time-interval overlap checks. Pure, UI-free, unit-testable.
 * Intervals are half-open [start, end): touching edges do NOT overlap.
 */

import { fromIso } from '../utils/datetime';

export interface Interval {
  start: string; // UTC ISO
  end: string; // UTC ISO
}

/** True when two half-open intervals share any positive-length span. */
export function overlaps(a: Interval, b: Interval): boolean {
  const aStart = fromIso(a.start).getTime();
  const aEnd = fromIso(a.end).getTime();
  const bStart = fromIso(b.start).getTime();
  const bEnd = fromIso(b.end).getTime();
  return aStart < bEnd && bStart < aEnd;
}

/** All members of `others` that overlap `target`. */
export function findOverlaps<T extends Interval>(target: Interval, others: T[]): T[] {
  return others.filter((o) => overlaps(target, o));
}

/** True when any two intervals in the list overlap. */
export function hasAnyOverlap(intervals: Interval[]): boolean {
  const sorted = [...intervals].sort(
    (a, b) => fromIso(a.start).getTime() - fromIso(b.start).getTime(),
  );
  for (let i = 1; i < sorted.length; i++) {
    if (overlaps(sorted[i - 1]!, sorted[i]!)) return true;
  }
  return false;
}
