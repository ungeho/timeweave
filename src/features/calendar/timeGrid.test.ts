import { describe, expect, it } from 'vitest';
import type { EventOccurrence, EventRow } from '../../types/event';
import { initialScrollMinutes, layoutDayColumn } from './timeGrid';

const TZ = 'Asia/Tokyo';

function timed(startIso: string, endIso: string, id = startIso): EventOccurrence {
  const event = { id, allDay: false } as unknown as EventRow;
  return { event, start: startIso, end: endIso, allDay: false, occurrenceKey: startIso, isException: false };
}

// Helper: Tokyo wall-clock time -> UTC instant (Tokyo is UTC+9).
const tokyo = (day: string, h: number, m = 0) => {
  const utcH = h - 9;
  const d = new Date(`${day}T00:00:00Z`);
  d.setUTCHours(utcH, m, 0, 0);
  return d.toISOString();
};

describe('layoutDayColumn — collision groups', () => {
  const DAY = '2026-08-24';

  it('non-overlapping events are full width (colCount 1)', () => {
    const occ = [timed(tokyo(DAY, 9), tokyo(DAY, 10)), timed(tokyo(DAY, 15), tokyo(DAY, 16))];
    const pos = layoutDayColumn(occ, DAY, TZ);
    expect(pos.every((p) => p.colCount === 1 && p.colIndex === 0)).toBe(true);
  });

  it('computes colCount per collision group, not per day', () => {
    // A/B overlap (2 cols); C is isolated (1 col).
    const A = timed(tokyo(DAY, 9), tokyo(DAY, 10), 'A');
    const B = timed(tokyo(DAY, 9, 30), tokyo(DAY, 10, 30), 'B');
    const C = timed(tokyo(DAY, 15), tokyo(DAY, 16), 'C');
    const pos = layoutDayColumn([A, B, C], DAY, TZ);
    const byId = Object.fromEntries(pos.map((p) => [p.occurrence.event.id, p]));
    expect(byId.A!.colCount).toBe(2);
    expect(byId.B!.colCount).toBe(2);
    expect(new Set([byId.A!.colIndex, byId.B!.colIndex])).toEqual(new Set([0, 1]));
    expect(byId.C!.colCount).toBe(1);
  });

  it('touching edges do not overlap', () => {
    const pos = layoutDayColumn(
      [timed(tokyo(DAY, 9), tokyo(DAY, 10)), timed(tokyo(DAY, 10), tokyo(DAY, 11))],
      DAY, TZ,
    );
    expect(pos.every((p) => p.colCount === 1)).toBe(true);
  });

  it('containment counts as overlap', () => {
    const pos = layoutDayColumn(
      [timed(tokyo(DAY, 9), tokyo(DAY, 17), 'big'), timed(tokyo(DAY, 12), tokyo(DAY, 13), 'small')],
      DAY, TZ,
    );
    expect(pos.every((p) => p.colCount === 2)).toBe(true);
  });

  it('positions by wall-clock fractions', () => {
    const [p] = layoutDayColumn([timed(tokyo(DAY, 9), tokyo(DAY, 10))], DAY, TZ);
    expect(p!.topFraction).toBeCloseTo(540 / 1440, 6);
    expect(p!.heightFraction).toBeCloseTo(60 / 1440, 6);
  });

  it('clips events crossing midnight to each day', () => {
    // Tokyo 23:00 (08-24) -> 01:00 (08-25).
    const occ = timed(tokyo('2026-08-24', 23), tokyo('2026-08-25', 1));
    const d1 = layoutDayColumn([occ], '2026-08-24', TZ)[0]!;
    expect(d1.topFraction).toBeCloseTo(1380 / 1440, 6);
    expect(d1.heightFraction).toBeCloseTo(60 / 1440, 6); // 23:00 -> 24:00
    const d2 = layoutDayColumn([occ], '2026-08-25', TZ)[0]!;
    expect(d2.topFraction).toBeCloseTo(0, 6);
    expect(d2.heightFraction).toBeCloseTo(60 / 1440, 6); // 00:00 -> 01:00
  });

  it('ignores all-day occurrences', () => {
    const allDay = { ...timed(tokyo(DAY, 9), tokyo(DAY, 10)), allDay: true };
    expect(layoutDayColumn([allDay], DAY, TZ)).toHaveLength(0);
  });
});

describe('layoutDayColumn — day intersection guard', () => {
  it('excludes an event dated after the target day (future)', () => {
    // 08-29 event laid out against 08-24 must not appear.
    const occ = timed(tokyo('2026-08-29', 9), tokyo('2026-08-29', 10));
    expect(layoutDayColumn([occ], '2026-08-24', TZ)).toHaveLength(0);
  });

  it('excludes an event dated before the target day (past)', () => {
    const occ = timed(tokyo('2026-08-24', 9), tokyo('2026-08-24', 10));
    expect(layoutDayColumn([occ], '2026-08-29', TZ)).toHaveLength(0);
  });

  it('shows an event spanning from the previous day into the target day', () => {
    // 08-23 22:00 -> 08-24 02:00 ; on 08-24 it is 00:00 -> 02:00.
    const occ = timed(tokyo('2026-08-23', 22), tokyo('2026-08-24', 2));
    const [p] = layoutDayColumn([occ], '2026-08-24', TZ);
    expect(p!.topFraction).toBeCloseTo(0, 6);
    expect(p!.heightFraction).toBeCloseTo(120 / 1440, 6);
  });

  it('shows an event spanning from the target day into the next day', () => {
    // 08-24 22:00 -> 08-25 02:00 ; on 08-24 it is 22:00 -> 24:00.
    const occ = timed(tokyo('2026-08-24', 22), tokyo('2026-08-25', 2));
    const [p] = layoutDayColumn([occ], '2026-08-24', TZ);
    expect(p!.topFraction).toBeCloseTo(1320 / 1440, 6);
    expect(p!.heightFraction).toBeCloseTo(120 / 1440, 6);
  });

  it('excludes an event ending exactly at the target day 00:00 (half-open)', () => {
    // 08-23 22:00 -> 08-24 00:00 : ends at the very start of 08-24 -> not shown.
    const occ = timed(tokyo('2026-08-23', 22), tokyo('2026-08-24', 0));
    expect(layoutDayColumn([occ], '2026-08-24', TZ)).toHaveLength(0);
  });

  it('clips a 23:00 -> next-day 01:00 event to 23:00–24:00 on the target day', () => {
    const occ = timed(tokyo('2026-08-24', 23), tokyo('2026-08-25', 1));
    const [p] = layoutDayColumn([occ], '2026-08-24', TZ);
    expect(p!.topFraction).toBeCloseTo(1380 / 1440, 6);
    expect(p!.heightFraction).toBeCloseTo(60 / 1440, 6);
  });

  it('treats end === start touching boundary as non-overlapping', () => {
    const pos = layoutDayColumn(
      [timed(tokyo('2026-08-24', 9), tokyo('2026-08-24', 10)),
       timed(tokyo('2026-08-24', 10), tokyo('2026-08-24', 11))],
      '2026-08-24', TZ,
    );
    expect(pos).toHaveLength(2);
    expect(pos.every((p) => p.colCount === 1)).toBe(true);
  });
});

describe('layoutDayColumn — DST safety', () => {
  it('places 09:00 at 540 minutes on both standard and DST days', () => {
    const NY = 'America/New_York';
    // 2026-01-15 09:00 EST = 14:00Z ; 2026-07-15 09:00 EDT = 13:00Z
    const est = layoutDayColumn([timed('2026-01-15T14:00:00Z', '2026-01-15T15:00:00Z')], '2026-01-15', NY)[0]!;
    const edt = layoutDayColumn([timed('2026-07-15T13:00:00Z', '2026-07-15T14:00:00Z')], '2026-07-15', NY)[0]!;
    expect(est.topFraction).toBeCloseTo(540 / 1440, 6);
    expect(edt.topFraction).toBeCloseTo(540 / 1440, 6);
  });
});

describe('initialScrollMinutes', () => {
  const DAY = '2026-08-24';
  it('defaults to 08:00 when there are no timed events', () => {
    expect(initialScrollMinutes([], TZ)).toBe(480);
  });
  it('defaults to 08:00 when all events start at/after 08:00', () => {
    expect(initialScrollMinutes([timed(tokyo(DAY, 9), tokyo(DAY, 10))], TZ)).toBe(480);
  });
  it('targets an early-morning event (with padding)', () => {
    expect(initialScrollMinutes([timed(tokyo(DAY, 6), tokyo(DAY, 7))], TZ)).toBe(330); // 360 - 30
  });
});
