import { afterAll, describe, expect, it } from 'vitest';
import { fromZonedTime } from 'date-fns-tz';
import { createTimesAt } from './createTimes';
import { storedFoldChoice } from '../event/formInstant';

/*
  R1-P (P8-c1.1): the initial start/end a new event gets from a click on a day
  (month cell, mobile "add") or on a time slot (week/day grid).

  WHAT A CLICK MEANS. The time grid is a fixed 24-hour WALL-CLOCK axis, 30
  minutes per slot, one row per wall time; the month cell and the mobile
  button mean "this date, at the default 09:00". So a click names a WALL CLOCK
  on a CALENDAR DATE, never an instant. Which instant that is depends on the
  zone, and around an offset change there may be none or two:

    the wall clock names one instant  -> that instant (unchanged)
    it does not exist, and nothing on that date comes before it (the date
      starts late: America/Havana 2026-03-08 has no 00:00-00:59)
                                      -> the date's first real instant (01:00).
                                         The top rows can only mean "the
                                         start of this day"; the previous
                                         evening is a different date.
    it does not exist in mid-day (America/New_York 2026-03-08 02:30)
                                      -> the form shows the clicked time and
                                         its existing notice explains it;
                                         nothing is chosen for the owner
    it happens twice                  -> the form shows the clicked time and
                                         asks which: one grid row covers both
                                         instants, so the click cannot say
    the whole date does not exist (Pacific/Apia 2011-12-30)
                                      -> as mid-day: shown, explained, not moved
                                         to another date

  The END is the start plus one hour of elapsed time when the start is
  resolved. It was the wall clock one hour later, which (a) lands in a gap or a
  fold on a DST day and (b) on EVERY day turned the 23:30 slot's "24:30" into
  00:30 of the SAME date, an end before the start. When the start is left to
  the owner, the end is the wall clock one hour later and checked the same way.

  Expected values rest on the tzdata facts recorded in docs/p8-datetime-
  contract.md §9 (Havana 2026-03-08 has no 00:00-00:59 and 2026-11-01 has it
  twice; New York's switches are at 02:00 / 01:00-01:59). The OS zone must not
  matter, so every case runs under several.
*/

const env = (globalThis as unknown as { process: { env: Record<string, string | undefined> } }).process.env;
const ORIGINAL_TZ = env.TZ;
afterAll(() => {
  if (ORIGINAL_TZ === undefined) delete env.TZ;
  else env.TZ = ORIGINAL_TZ;
});
const OS_ZONES = ['UTC', 'Asia/Tokyo', 'America/New_York', 'America/Havana', 'Pacific/Apia'];

interface Case {
  name: string;
  zone: string;
  day: string;
  minutes: number;
  start: { local: string; at: string | null };
  end: { local: string; at: string | null };
}

const CASES: Case[] = [
  {
    name: 'ordinary day, Tokyo 10:00',
    zone: 'Asia/Tokyo', day: '2026-03-07', minutes: 600,
    start: { local: '2026-03-07T10:00', at: '2026-03-07T01:00:00.000Z' },
    end: { local: '2026-03-07T11:00', at: '2026-03-07T02:00:00.000Z' },
  },
  {
    name: 'ordinary day, the 23:30 slot ends on the NEXT date (was 00:30 of the same date)',
    zone: 'Asia/Tokyo', day: '2026-03-07', minutes: 1410,
    start: { local: '2026-03-07T23:30', at: '2026-03-07T14:30:00.000Z' },
    end: { local: '2026-03-08T00:30', at: '2026-03-07T15:30:00.000Z' },
  },
  {
    name: 'ordinary hour on a 23-hour day, New York 09:00',
    zone: 'America/New_York', day: '2026-03-08', minutes: 540,
    start: { local: '2026-03-08T09:00', at: '2026-03-08T13:00:00.000Z' },
    end: { local: '2026-03-08T10:00', at: '2026-03-08T14:00:00.000Z' },
  },
  {
    name: 'R1-P: Havana 03-08 00:00 does not exist and starts the date late -> 01:00 that date (was 23:00 the day before)',
    zone: 'America/Havana', day: '2026-03-08', minutes: 0,
    start: { local: '2026-03-08T01:00', at: '2026-03-08T05:00:00.000Z' },
    end: { local: '2026-03-08T02:00', at: '2026-03-08T06:00:00.000Z' },
  },
  {
    name: 'Havana 03-08 00:30, also before the date\'s first real time -> 01:00',
    zone: 'America/Havana', day: '2026-03-08', minutes: 30,
    start: { local: '2026-03-08T01:00', at: '2026-03-08T05:00:00.000Z' },
    end: { local: '2026-03-08T02:00', at: '2026-03-08T06:00:00.000Z' },
  },
  {
    name: 'Havana 03-08 01:00 is the first real time: unchanged',
    zone: 'America/Havana', day: '2026-03-08', minutes: 60,
    start: { local: '2026-03-08T01:00', at: '2026-03-08T05:00:00.000Z' },
    end: { local: '2026-03-08T02:00', at: '2026-03-08T06:00:00.000Z' },
  },
  {
    name: 'Havana 03-07 23:30: one elapsed hour later is 01:30 the next date (the clocks skip 00:xx)',
    zone: 'America/Havana', day: '2026-03-07', minutes: 1410,
    start: { local: '2026-03-07T23:30', at: '2026-03-08T04:30:00.000Z' },
    end: { local: '2026-03-08T01:30', at: '2026-03-08T05:30:00.000Z' },
  },
  {
    name: 'New York 03-08 02:30 does not exist in mid-day: kept as clicked, not resolved',
    zone: 'America/New_York', day: '2026-03-08', minutes: 150,
    start: { local: '2026-03-08T02:30', at: null },
    end: { local: '2026-03-08T03:30', at: '2026-03-08T07:30:00.000Z' },
  },
  {
    name: 'New York 03-08 02:00 (the first missing minute): kept as clicked',
    zone: 'America/New_York', day: '2026-03-08', minutes: 120,
    start: { local: '2026-03-08T02:00', at: null },
    end: { local: '2026-03-08T03:00', at: '2026-03-08T07:00:00.000Z' },
  },
  {
    name: 'New York 03-08 01:30: the elapsed hour ends at 03:30 (was 02:30, which does not exist)',
    zone: 'America/New_York', day: '2026-03-08', minutes: 90,
    start: { local: '2026-03-08T01:30', at: '2026-03-08T06:30:00.000Z' },
    end: { local: '2026-03-08T03:30', at: '2026-03-08T07:30:00.000Z' },
  },
  {
    name: 'New York 11-01 01:30 happens twice: kept, the owner picks',
    zone: 'America/New_York', day: '2026-11-01', minutes: 90,
    start: { local: '2026-11-01T01:30', at: null },
    end: { local: '2026-11-01T02:30', at: '2026-11-01T07:30:00.000Z' },
  },
  {
    name: 'New York 11-01 00:30: the elapsed hour ends at the FIRST 01:30, and says so',
    zone: 'America/New_York', day: '2026-11-01', minutes: 30,
    start: { local: '2026-11-01T00:30', at: '2026-11-01T04:30:00.000Z' },
    end: { local: '2026-11-01T01:30', at: '2026-11-01T05:30:00.000Z' },
  },
  {
    name: 'Havana 11-01 00:00 happens twice: kept, the owner picks',
    zone: 'America/Havana', day: '2026-11-01', minutes: 0,
    start: { local: '2026-11-01T00:00', at: null },
    end: { local: '2026-11-01T01:00', at: '2026-11-01T06:00:00.000Z' },
  },
  {
    name: 'Havana 11-01 00:30 happens twice: kept, the owner picks',
    zone: 'America/Havana', day: '2026-11-01', minutes: 30,
    start: { local: '2026-11-01T00:30', at: null },
    end: { local: '2026-11-01T01:30', at: '2026-11-01T06:30:00.000Z' },
  },
  {
    name: 'Apia 2011-12-30 never happened: the date is kept, nothing resolved (was 12-29)',
    zone: 'Pacific/Apia', day: '2011-12-30', minutes: 540,
    start: { local: '2011-12-30T09:00', at: null },
    end: { local: '2011-12-30T10:00', at: null },
  },
];

describe('createTimesAt: a click names a wall clock on a date (R1-P)', () => {
  for (const os of OS_ZONES) {
    describe(`OS zone ${os}`, () => {
      for (const c of CASES) {
        it(c.name, () => {
          env.TZ = os;
          const r = createTimesAt(c.day, c.minutes, c.zone);
          expect(r).toEqual({ start: c.start, end: c.end });
        });
      }
    });
  }
});

describe('createTimesAt: invariants', () => {
  it('the form always opens on the clicked DATE', () => {
    for (const os of OS_ZONES) {
      env.TZ = os;
      for (const c of CASES) {
        expect(createTimesAt(c.day, c.minutes, c.zone).start.local.slice(0, 10), `${os} ${c.name}`).toBe(c.day);
      }
    }
  });

  it('a resolved end is exactly one hour after a resolved start', () => {
    for (const c of CASES) {
      const r = createTimesAt(c.day, c.minutes, c.zone);
      if (r.start.at) expect(Date.parse(r.end.at!) - Date.parse(r.start.at), c.name).toBe(3_600_000);
    }
  });

  it('ordinary days are unchanged: every 30-minute slot of 2026-06-15 and 2026-01-15 in four zones', () => {
    for (const os of ['UTC', 'Asia/Tokyo']) {
      env.TZ = os;
      for (const zone of ['Asia/Tokyo', 'America/New_York', 'Europe/London', 'America/Havana']) {
        for (const day of ['2026-06-15', '2026-01-15']) {
          for (let minutes = 0; minutes < 1440; minutes += 30) {
            const hh = String(Math.floor(minutes / 60)).padStart(2, '0');
            const mm = String(minutes % 60).padStart(2, '0');
            const r = createTimesAt(day, minutes, zone);
            const before = fromZonedTime(`${day}T${hh}:${mm}:00`, zone).toISOString();
            expect(r.start, `${zone} ${day} ${hh}:${mm}`).toEqual({ local: `${day}T${hh}:${mm}`, at: before });
            expect(Date.parse(r.end.at!) - Date.parse(before)).toBe(3_600_000);
          }
        }
      }
    }
  });

  it('an end that lands on a doubled wall time carries which one, so the form does not ask', () => {
    // The dialog recovers the side of a fold from the instant (storedFoldChoice),
    // which reads the wall clock in the OS zone -- the app's own zone, so set it.
    env.TZ = 'America/New_York';
    const r = createTimesAt('2026-11-01', 30, 'America/New_York');
    expect(storedFoldChoice(r.end.at!, 'America/New_York')).toBe('earlier');
  });
});
