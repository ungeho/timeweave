import { describe, expect, it } from 'vitest';
import type { FreeBusySlot } from '../types/share';
import { mergeAllDay, mergeFreeBusySlots, mergeTimed } from './mergeIntervals';

describe('mergeTimed', () => {
  const T = (start: string, end: string) => ({ start, end });

  it('returns [] for empty input', () => {
    expect(mergeTimed([])).toEqual([]);
  });

  it('keeps a single interval', () => {
    expect(mergeTimed([T('2026-09-01T09:00:00Z', '2026-09-01T10:00:00Z')]))
      .toEqual([T('2026-09-01T09:00:00Z', '2026-09-01T10:00:00Z')]);
  });

  it('merges overlapping intervals (and sorts unsorted input)', () => {
    expect(mergeTimed([
      T('2026-09-01T10:00:00Z', '2026-09-01T11:30:00Z'),
      T('2026-09-01T09:00:00Z', '2026-09-01T10:30:00Z'),
    ])).toEqual([T('2026-09-01T09:00:00Z', '2026-09-01T11:30:00Z')]);
  });

  it('merges adjacent (touching) intervals', () => {
    expect(mergeTimed([
      T('2026-09-01T09:00:00Z', '2026-09-01T10:00:00Z'),
      T('2026-09-01T10:00:00Z', '2026-09-01T11:00:00Z'),
    ])).toEqual([T('2026-09-01T09:00:00Z', '2026-09-01T11:00:00Z')]);
  });

  it('keeps disjoint intervals separate', () => {
    const a = T('2026-09-01T09:00:00Z', '2026-09-01T10:00:00Z');
    const b = T('2026-09-01T11:00:00Z', '2026-09-01T12:00:00Z');
    expect(mergeTimed([b, a])).toEqual([a, b]);
  });

  it('absorbs an interval fully contained in another', () => {
    expect(mergeTimed([
      T('2026-09-01T09:00:00Z', '2026-09-01T12:00:00Z'),
      T('2026-09-01T10:00:00Z', '2026-09-01T11:00:00Z'),
    ])).toEqual([T('2026-09-01T09:00:00Z', '2026-09-01T12:00:00Z')]);
  });

  it('treats differently-formatted instants of the same moment as touching', () => {
    // +00:00 vs Z, milliseconds omitted — same instant, should merge.
    expect(mergeTimed([
      T('2026-09-01T09:00:00Z', '2026-09-01T10:00:00.000Z'),
      T('2026-09-01T10:00:00+00:00', '2026-09-01T11:00:00Z'),
    ])).toHaveLength(1);
  });
});

describe('mergeAllDay', () => {
  const D = (startDate: string, endDate: string) => ({ startDate, endDate });

  it('merges overlapping date ranges', () => {
    expect(mergeAllDay([D('2026-09-01', '2026-09-04'), D('2026-09-03', '2026-09-06')]))
      .toEqual([D('2026-09-01', '2026-09-06')]);
  });

  it('merges adjacent date ranges (end == next start, exclusive)', () => {
    expect(mergeAllDay([D('2026-09-01', '2026-09-02'), D('2026-09-02', '2026-09-03')]))
      .toEqual([D('2026-09-01', '2026-09-03')]);
  });

  it('keeps ranges with a gap separate', () => {
    const a = D('2026-09-01', '2026-09-02');
    const b = D('2026-09-04', '2026-09-05');
    expect(mergeAllDay([b, a])).toEqual([a, b]);
  });
});

describe('mergeFreeBusySlots', () => {
  it('merges per type and never mixes timed with all-day', () => {
    const slots: FreeBusySlot[] = [
      { allDay: false, start: '2026-09-01T09:00:00Z', end: '2026-09-01T10:00:00Z' },
      { allDay: false, start: '2026-09-01T10:00:00Z', end: '2026-09-01T11:00:00Z' },
      { allDay: true, startDate: '2026-09-01', endDate: '2026-09-02' },
      { allDay: true, startDate: '2026-09-02', endDate: '2026-09-03' },
    ];
    expect(mergeFreeBusySlots(slots)).toEqual([
      { allDay: true, startDate: '2026-09-01', endDate: '2026-09-03' },
      { allDay: false, start: '2026-09-01T09:00:00Z', end: '2026-09-01T11:00:00Z' },
    ]);
  });

  it('handles an empty list', () => {
    expect(mergeFreeBusySlots([])).toEqual([]);
  });
});
