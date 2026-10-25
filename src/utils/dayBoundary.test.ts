import { afterAll, describe, expect, it } from 'vitest';
import { fromZonedTime } from 'date-fns-tz';
import { addDaysToDateString } from './datetime';
import { dayStartInstantIso, zonedDayKey } from './timezone';
import { dayRange, weekRange } from '../features/calendar/weekGrid';
import { monthGridRange } from '../features/calendar/monthGrid';
import { busyForDay } from '../features/share/freeBusyLayout';
import { formToRule, EMPTY_RECURRENCE_FORM } from '../features/event/recurrenceForm';
import type { FreeBusySlot } from '../types/share';

/*
  R1 (P8-c1): the calendar day as a RANGE OF INSTANTS, in zones whose UTC
  offset changes at or across local midnight.

  THE RULE. Day D in zone Z starts at the EARLIEST instant whose wall-clock
  date in Z is D or later, and ends where D+1 starts (half-open). So:
    - an ordinary midnight          -> that instant
    - a midnight that never happens -> the instant the clocks jump (the first
      wall time that does exist, e.g. 01:00)
    - a midnight that happens twice -> the FIRST of the two
    - a whole day that never happens (Pacific/Apia, 2011-12-30) -> an empty
      range, starting and ending where the next day starts
  It is what a JavaScript Date does for a local midnight, which is why the
  month view (local Date midnights) was already right and the week/day views,
  the share page and a repeat's end date (fromZonedTime) were not.

  WHERE THE EXPECTED VALUES COME FROM. Not from memory: a scan of the runtime's
  own tzdata (Node 24, ICU 78.3, tz 2026b) for every zone whose offset change
  contains a local midnight, 2005-2030 (docs/p8-datetime-contract.md §9). Each
  case below also RE-CHECKS that its transition exists in the tzdata the test
  runs on, so a future tzdata change fails loudly instead of silently testing
  nothing.

  The OS zone must not matter, so every check runs under several.
*/

const env = (globalThis as unknown as { process: { env: Record<string, string | undefined> } }).process.env;
const ORIGINAL_TZ = env.TZ;
afterAll(() => {
  if (ORIGINAL_TZ === undefined) delete env.TZ;
  else env.TZ = ORIGINAL_TZ;
});
const OS_ZONES = ['UTC', 'Asia/Tokyo', 'America/New_York', 'America/Havana', 'Pacific/Apia'];

const wallOf = (ms: number, zone: string) =>
  new Intl.DateTimeFormat('en-CA', {
    timeZone: zone, hourCycle: 'h23', year: 'numeric', month: '2-digit', day: '2-digit',
    hour: '2-digit', minute: '2-digit', second: '2-digit',
  })
    .format(new Date(ms))
    .replace(', ', 'T');
const start = (day: string, zone: string) => Date.parse(dayStartInstantIso(day, zone));
const H = 3_600_000;

interface Case {
  zone: string;
  day: string;
  /** the expected first instant of `day` */
  start: string;
  /** the tzdata fact the expectation rests on: wall clock 1s before / at the switch */
  switchAt: string;
  before: string;
  after: string;
  /** length of `day` in hours */
  hours: number;
}

const CASES: Case[] = [
  // Midnight never happens: 23:59:59 is followed by 01:00:00.
  { zone: 'America/Havana', day: '2026-03-08', start: '2026-03-08T05:00:00.000Z', switchAt: '2026-03-08T05:00:00.000Z', before: '2026-03-07T23:59:59', after: '2026-03-08T01:00:00', hours: 23 },
  { zone: 'America/Santiago', day: '2026-09-06', start: '2026-09-06T04:00:00.000Z', switchAt: '2026-09-06T04:00:00.000Z', before: '2026-09-05T23:59:59', after: '2026-09-06T01:00:00', hours: 23 },
  { zone: 'Africa/Cairo', day: '2026-04-24', start: '2026-04-23T22:00:00.000Z', switchAt: '2026-04-23T22:00:00.000Z', before: '2026-04-23T23:59:59', after: '2026-04-24T01:00:00', hours: 23 },
  // Midnight happens twice: at 01:00 the clocks go back to 00:00.
  { zone: 'America/Havana', day: '2026-11-01', start: '2026-11-01T04:00:00.000Z', switchAt: '2026-11-01T05:00:00.000Z', before: '2026-11-01T00:59:59', after: '2026-11-01T00:00:00', hours: 25 },
  // A whole day never happens: 2011-12-29 23:59:59 is followed by 2011-12-31 00:00:00.
  { zone: 'Pacific/Apia', day: '2011-12-30', start: '2011-12-30T10:00:00.000Z', switchAt: '2011-12-30T10:00:00.000Z', before: '2011-12-29T23:59:59', after: '2011-12-31T00:00:00', hours: 0 },
  // An ordinary DST change away from midnight: the midnights are ordinary, the days are not 24h.
  { zone: 'America/New_York', day: '2026-03-08', start: '2026-03-08T05:00:00.000Z', switchAt: '2026-03-08T07:00:00.000Z', before: '2026-03-08T01:59:59', after: '2026-03-08T03:00:00', hours: 23 },
  { zone: 'America/New_York', day: '2026-11-01', start: '2026-11-01T04:00:00.000Z', switchAt: '2026-11-01T06:00:00.000Z', before: '2026-11-01T01:59:59', after: '2026-11-01T01:00:00', hours: 25 },
];

describe('the tzdata facts the cases rest on are present in this runtime', () => {
  it.each(CASES.map((c) => [c.zone, c.day, c] as const))('%s %s', (_z, _d, c) => {
    const t = Date.parse(c.switchAt);
    expect(wallOf(t - 1000, c.zone)).toBe(c.before);
    expect(wallOf(t, c.zone)).toBe(c.after);
  });
});

describe('R1: dayStartInstantIso is the first instant of the calendar day', () => {
  for (const os of OS_ZONES) {
    describe(`OS zone ${os}`, () => {
      it.each(CASES.map((c) => [c.zone, c.day, c] as const))('%s %s', (_z, _d, c) => {
        env.TZ = os;
        expect(dayStartInstantIso(c.day, c.zone)).toBe(c.start);
        const next = start(addDaysToDateString(c.day, 1), c.zone);
        expect((next - Date.parse(c.start)) / H).toBe(c.hours);
      });

      it('the previous, same and next days are contiguous and never overlap', () => {
        env.TZ = os;
        for (const c of CASES) {
          const days = [-2, -1, 0, 1, 2].map((n) => addDaysToDateString(c.day, n));
          const starts = days.map((d) => start(d, c.zone));
          for (let i = 1; i < starts.length; i++) expect(starts[i]!).toBeGreaterThanOrEqual(starts[i - 1]!);
          // Just before a day's start is the previous day (or earlier); at the start it is that day (or later).
          for (const [i, d] of days.entries()) {
            const s = starts[i]!;
            expect(zonedDayKey(new Date(s - 1).toISOString(), c.zone) < d).toBe(true);
            expect(zonedDayKey(new Date(s).toISOString(), c.zone) >= d).toBe(true);
          }
        }
      });
    });
  }

  it('an ordinary midnight is exactly what it was before (fromZonedTime), all of 2026, several zones', () => {
    for (const os of ['UTC', 'Asia/Tokyo']) {
      env.TZ = os;
      for (const zone of ['Asia/Tokyo', 'UTC', 'America/New_York', 'Europe/London', 'Australia/Sydney']) {
        let day = '2026-01-01';
        for (let i = 0; i < 365; i++) {
          expect(dayStartInstantIso(day, zone), `${os} ${zone} ${day}`).toBe(fromZonedTime(`${day}T00:00:00`, zone).toISOString());
          day = addDaysToDateString(day, 1);
        }
      }
    }
  });
});

describe('R1 where it showed: ranges, the share page, a repeat end date', () => {
  it('the day view of the day BEFORE a midnight gap covers its own last hour', () => {
    for (const os of OS_ZONES) {
      env.TZ = os;
      const r = dayRange(new Date('2026-03-07T17:00:00Z'), 'America/Havana'); // noon, 7 March, Havana
      expect(r).toEqual({ startIso: '2026-03-07T05:00:00.000Z', endIso: '2026-03-08T05:00:00.000Z' });
      // 23:30 on the 7th is inside it (it was cut off before the fix)
      const t = Date.parse('2026-03-08T04:30:00Z');
      expect(t >= Date.parse(r.startIso) && t < Date.parse(r.endIso)).toBe(true);
    }
  });

  it('a week view still covers exactly seven days of its zone', () => {
    env.TZ = 'UTC';
    const r = weekRange(new Date('2026-03-05T17:00:00Z'), 'America/Havana'); // Mon 2 - Sun 8 March
    expect(zonedDayKey(r.startIso, 'America/Havana')).toBe('2026-03-02');
    expect(wallOf(Date.parse(r.startIso), 'America/Havana')).toBe('2026-03-02T00:00:00');
    expect(wallOf(Date.parse(r.endIso), 'America/Havana')).toBe('2026-03-09T00:00:00');
  });

  it('the month view (local Date midnights) agrees with dayStartInstantIso when the OS zone is the calendar zone', () => {
    for (const zone of ['America/Havana', 'America/Santiago', 'Africa/Cairo', 'America/New_York', 'Asia/Tokyo']) {
      env.TZ = zone;
      for (const anchor of ['2026-03-15T12:00:00Z', '2026-09-15T12:00:00Z', '2026-04-15T12:00:00Z', '2026-11-15T12:00:00Z']) {
        const r = monthGridRange(new Date(anchor));
        const firstKey = zonedDayKey(r.startIso, zone);
        expect(r.startIso, `${zone} ${anchor}`).toBe(dayStartInstantIso(firstKey, zone));
        const lastKey = zonedDayKey(new Date(Date.parse(r.endIso) - 1).toISOString(), zone);
        expect(r.endIso, `${zone} ${anchor}`).toBe(dayStartInstantIso(addDaysToDateString(lastKey, 1), zone));
      }
    }
  });

  const slot = (start: string, end: string): FreeBusySlot => ({ allDay: false, start, end });

  it('share page: a busy hour just before a midnight gap is shown on its own day, once', () => {
    for (const os of OS_ZONES) {
      env.TZ = os;
      const late = slot('2026-03-08T04:30:00Z', '2026-03-08T05:00:00Z'); // 23:30-24:00 on the 7th, Havana
      expect(busyForDay('2026-03-07', 'America/Havana', [late]).timed).toHaveLength(1);
      expect(busyForDay('2026-03-08', 'America/Havana', [late]).timed).toHaveLength(0);
    }
  });

  it('share page: the first 00:xx of a doubled midnight belongs to that day, not the day before', () => {
    for (const os of OS_ZONES) {
      env.TZ = os;
      const firstMidnight = slot('2026-11-01T04:00:00Z', '2026-11-01T04:30:00Z'); // 00:00-00:30 (1st), Havana
      expect(busyForDay('2026-11-01', 'America/Havana', [firstMidnight]).timed).toHaveLength(1);
      expect(busyForDay('2026-10-31', 'America/Havana', [firstMidnight]).timed).toHaveLength(0);
    }
  });

  it('share page: per-day pieces never overlap, never leave a gap, and add up to the slot', () => {
    for (const os of OS_ZONES) {
      env.TZ = os;
      for (const c of CASES) {
        const from = start(addDaysToDateString(c.day, -1), c.zone);
        const to = start(addDaysToDateString(c.day, 2), c.zone);
        const slots = [
          slot(new Date(from + 30 * 60_000).toISOString(), new Date(to - 30 * 60_000).toISOString()), // spans three days
          slot(new Date(Date.parse(c.start)).toISOString(), new Date(Date.parse(c.start) + 60 * 60_000).toISOString()), // starts at a boundary
          slot(new Date(Date.parse(c.start) - 60 * 60_000).toISOString(), new Date(Date.parse(c.start)).toISOString()), // ends at a boundary
        ];
        for (const s of slots) {
          if (s.allDay) continue;
          const pieces = [-1, 0, 1, 2]
            .map((n) => busyForDay(addDaysToDateString(c.day, n), c.zone, [s]).timed)
            .flat()
            .map((p) => [Date.parse(p.start), Date.parse(p.end)] as const)
            .sort((a, b) => a[0] - b[0]);
          let total = 0;
          for (let i = 0; i < pieces.length; i++) {
            total += pieces[i]![1] - pieces[i]![0];
            if (i > 0) expect(pieces[i]![0], `${os} ${c.zone} ${c.day}`).toBe(pieces[i - 1]![1]); // contiguous, no overlap
          }
          expect(total).toBe(Date.parse(s.end) - Date.parse(s.start));
        }
      }
    }
  });

  it('share page: busy and open time are clipped by the same days, so neither can show through the other', () => {
    env.TZ = 'Asia/Tokyo';
    const busy = [slot('2026-03-08T04:30:00Z', '2026-03-08T05:30:00Z')];
    const open = [slot('2026-03-08T04:30:00Z', '2026-03-08T05:30:00Z')];
    for (const d of ['2026-03-07', '2026-03-08']) {
      expect(busyForDay(d, 'America/Havana', open).timed).toEqual(busyForDay(d, 'America/Havana', busy).timed);
    }
  });

  it('a timed repeat ending on the day before a midnight gap keeps that day’s last hour', () => {
    for (const os of OS_ZONES) {
      env.TZ = os;
      const rule = formToRule(
        { ...EMPTY_RECURRENCE_FORM, freq: 'daily', endMode: 'until', untilDate: '2026-03-07' },
        '2026-03-01T04:30:00.000Z',
        'America/Havana',
        false,
      );
      // The end of the 7th is the instant the 8th starts (01:00 CDT), minus 1 ms.
      expect(rule?.until).toEqual({ kind: 'instant', instant: '2026-03-08T04:59:59.999Z' });
    }
  });
});

describe('addDaysToDateString is calendar arithmetic, whatever the OS zone', () => {
  it('steps over a day that one zone skipped', () => {
    for (const os of OS_ZONES) {
      env.TZ = os;
      expect(addDaysToDateString('2011-12-29', 1), os).toBe('2011-12-30');
      expect(addDaysToDateString('2011-12-31', -1), os).toBe('2011-12-30');
      expect(addDaysToDateString('2026-03-07', 1), os).toBe('2026-03-08');
      expect(addDaysToDateString('2026-12-31', 1), os).toBe('2027-01-01');
      expect(addDaysToDateString('2028-02-28', 1), os).toBe('2028-02-29');
    }
  });
});

describe('reading a wall clock does not depend on the OS zone', () => {
  it('a Tokyo wall time that does not exist in the OS zone is still read as itself', async () => {
    const { zonedMinutesOfDay, zonedWallClockOf } = await import('./timezone');
    // 2026-03-08 02:30 in Tokyo is 2026-03-07T17:30Z. That wall time does not
    // exist in New York (or Havana) that day; date-fns-tz formatInTimeZone,
    // which the helpers used before P8-c1, read it as 03:30 there.
    const iso = '2026-03-07T17:30:00.000Z';
    for (const os of [...OS_ZONES, 'Europe/London']) {
      env.TZ = os;
      expect(zonedDayKey(iso, 'Asia/Tokyo'), os).toBe('2026-03-08');
      expect(zonedMinutesOfDay(iso, 'Asia/Tokyo'), os).toBe(150);
      expect(zonedWallClockOf(Date.parse(iso), 'Asia/Tokyo'), os).toEqual({
        year: 2026, month: 3, day: 8, hour: 2, minute: 30, second: 0, ms: 0,
      });
    }
  });
});
