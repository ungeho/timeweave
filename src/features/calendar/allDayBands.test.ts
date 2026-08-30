import { describe, expect, it } from 'vitest';
import type { EventOccurrence, EventRow } from '../../types/event';
import { addDaysToDateString, isoFromDateString } from '../../utils/datetime';
import { buildAllDayBands } from './allDayBands';

const WEEK = [
  '2026-08-24', '2026-08-25', '2026-08-26', '2026-08-27',
  '2026-08-28', '2026-08-29', '2026-08-30',
];

// start/end are LOCAL-midnight instants, exactly as expandEvents builds them
// (isoFromDateString), so localDayKey inverts them back cleanly on any machine.
function allDay(startDate: string, endDate: string, id = startDate): EventOccurrence {
  const event = { id, allDay: true, startDate, endDate } as unknown as EventRow;
  return {
    event,
    start: isoFromDateString(startDate),
    end: isoFromDateString(endDate),
    allDay: true,
    occurrenceKey: startDate,
    isException: false,
  };
}

/** An occurrence whose master event carries DIFFERENT dates than the instance,
 * mimicking a recurring master shared across instances. */
function occurrenceOf(master: EventRow, startDate: string, endDate: string): EventOccurrence {
  return {
    event: master,
    start: isoFromDateString(startDate),
    end: isoFromDateString(endDate),
    allDay: true,
    occurrenceKey: startDate,
    isException: false,
  };
}

describe('buildAllDayBands', () => {
  it('places a single-day event as span 1', () => {
    const { bands } = buildAllDayBands([allDay('2026-08-25', '2026-08-26')], WEEK);
    expect(bands).toHaveLength(1);
    expect(bands[0]).toMatchObject({
      startIndex: 1, span: 1, lane: 0, continuesLeft: false, continuesRight: false,
    });
  });

  it('spans multiple days within the week', () => {
    const { bands } = buildAllDayBands([allDay('2026-08-24', '2026-08-27')], WEEK); // 24,25,26
    expect(bands[0]).toMatchObject({ startIndex: 0, span: 3 });
  });

  it('flags continuesLeft when the event starts before the range', () => {
    const { bands } = buildAllDayBands([allDay('2026-08-20', '2026-08-26')], WEEK);
    expect(bands[0]).toMatchObject({ startIndex: 0, span: 2, continuesLeft: true });
  });

  it('flags continuesRight when the event ends after the range', () => {
    const { bands } = buildAllDayBands([allDay('2026-08-29', '2026-09-02')], WEEK);
    expect(bands[0]).toMatchObject({ startIndex: 5, span: 2, continuesRight: true });
  });

  it('stacks overlapping events into separate lanes', () => {
    const { bands, laneCount } = buildAllDayBands(
      [allDay('2026-08-24', '2026-08-27', 'A'), allDay('2026-08-25', '2026-08-28', 'B')],
      WEEK,
    );
    const lanes = bands.map((b) => b.lane).sort();
    expect(lanes).toEqual([0, 1]);
    expect(laneCount).toBe(2);
  });

  it('caps lanes and reports overflow per column', () => {
    const { bands, laneCount, overflow } = buildAllDayBands(
      [
        allDay('2026-08-24', '2026-08-27', 'A'),
        allDay('2026-08-24', '2026-08-27', 'B'),
        allDay('2026-08-24', '2026-08-27', 'C'),
      ],
      WEEK,
      1, // maxLanes
    );
    expect(bands).toHaveLength(1); // only lane 0 visible
    expect(laneCount).toBe(1);
    // Two hidden bands cover columns 0,1,2.
    expect(overflow.slice(0, 3)).toEqual([2, 2, 2]);
    expect(overflow.slice(3)).toEqual([0, 0, 0, 0]);
  });

  it('ignores timed occurrences', () => {
    const timed = { ...allDay('2026-08-25', '2026-08-26'), allDay: false };
    expect(buildAllDayBands([timed], WEEK).bands).toHaveLength(0);
  });

  // Regression (R7): a recurring master is shared across instances, so the band
  // span must come from each occurrence's own start/end, not occ.event's dates.
  describe('recurring all-day (shared master)', () => {
    const master = {
      id: 'm', allDay: true, startDate: '2026-08-31', endDate: '2026-09-01',
    } as unknown as EventRow;
    const SEPT_MONDAYS = ['2026-08-31', '2026-09-07', '2026-09-14', '2026-09-21', '2026-09-28'];
    // All five weekly instances, each a single day, all sharing `master`.
    const weeklyOccs = SEPT_MONDAYS.map((d) => occurrenceOf(master, d, addDaysToDateString(d, 1)));

    const weekFrom = (monday: string) =>
      Array.from({ length: 7 }, (_, i) => addDaysToDateString(monday, i));

    it('places only the in-window instance in each week, on its own day', () => {
      for (const monday of SEPT_MONDAYS) {
        const { bands, overflow } = buildAllDayBands(weeklyOccs, weekFrom(monday));
        expect(bands).toHaveLength(1);
        expect(bands[0]).toMatchObject({
          startIndex: 0, span: 1, lane: 0, continuesLeft: false, continuesRight: false,
        });
        expect(bands[0]!.occurrence.occurrenceKey).toBe(monday);
        // No false overflow from instances collapsing onto the master's day.
        expect(overflow.every((n) => n === 0)).toBe(true);
      }
    });

    it('does not collapse all instances onto the master start_date', () => {
      // The master's own day (8/31 week): exactly one band, not five.
      const { bands, overflow } = buildAllDayBands(weeklyOccs, weekFrom('2026-08-31'));
      expect(bands).toHaveLength(1);
      expect(overflow).toEqual([0, 0, 0, 0, 0, 0, 0]);
    });

    it('preserves each occurrence duration for a multi-day recurring all-day', () => {
      // 3-day master (start_date..end_date exclusive spans 3 days); a later instance.
      const multi = {
        id: 'm3', allDay: true, startDate: '2026-08-31', endDate: '2026-09-03',
      } as unknown as EventRow;
      const occ = occurrenceOf(multi, '2026-09-07', '2026-09-10'); // Mon..Wed
      const { bands } = buildAllDayBands([occ], weekFrom('2026-09-07'));
      expect(bands).toHaveLength(1);
      expect(bands[0]).toMatchObject({ startIndex: 0, span: 3 });
    });
  });
});
