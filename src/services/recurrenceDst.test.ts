import { afterAll, describe, expect, it } from 'vitest';
import type { EventOccurrence, EventRow } from '../types/event';
import { expandEvents } from './occurrences';
import { expandRule } from './recurrence';
import { buildCancellation, buildException } from './exceptionEdit';
import { resolveZonedWallClock } from '../utils/timezone';
import { addDaysToDateString } from '../utils/datetime';

/*
  P8-c2: recurring series on DST days -- WHAT THE EXPANDER DOES TODAY.

  These are CHARACTERIZATION tests. They pin the current rule, which no one has
  yet decided to change (docs/p8-datetime-contract.md §12), so that any change
  to it is a visible, deliberate failure and never a silent move of somebody's
  existing occurrences -- or of the exceptions keyed to them.

  THE CURRENT RULE, for a timed master that carries a zone (M1, the normal
  case since Phase 5b-4): every occurrence after DTSTART is DTSTART's wall
  clock on that date, resolved in the master's zone by resolveZonedWallClock:
    - a wall clock that happens twice -> the LATER instant (the 2nd 01:30)
    - a wall clock that does not exist -> the LATER candidate, i.e. the wall
      clock pushed forward by the size of the jump (02:30 -> 03:30)
  which is PostgreSQL's `AT TIME ZONE`, i.e. what the shared Free/Busy RPC
  computes (0009/0018). The duration is elapsed time, so the end moves with
  the start. DTSTART itself is never re-resolved.

  A legacy master WITHOUT a zone (M0) is expanded in the OS zone with a local
  Date, which picks the EARLIER of two (JavaScript's rule) -- a known
  divergence, pinned below; the server does not expand M0 at all.

  Expected instants come from the runtime's tzdata and each case re-checks the
  transition it rests on. The OS zone must not matter for M1, so the M1 rows run
  under six OS zones.
*/

const env = (globalThis as unknown as { process: { env: Record<string, string | undefined> } }).process.env;
const ORIGINAL_TZ = env.TZ;
afterAll(() => {
  if (ORIGINAL_TZ === undefined) delete env.TZ;
  else env.TZ = ORIGINAL_TZ;
});
const OS_ZONES = ['UTC', 'Asia/Tokyo', 'America/New_York', 'America/Havana', 'Atlantic/Azores', 'America/Godthab'];

const wallOf = (iso: string, zone: string) =>
  new Intl.DateTimeFormat('en-CA', {
    timeZone: zone, hourCycle: 'h23', year: 'numeric', month: '2-digit', day: '2-digit',
    hour: '2-digit', minute: '2-digit', weekday: 'short',
  }).format(new Date(iso));
const at = (zone: string, y: number, mo: number, d: number, h: number, mi: number) =>
  new Date(resolveZonedWallClock({ year: y, month: mo, day: d, hour: h, minute: mi, second: 0, ms: 0 }, zone)).toISOString();

const row = (over: Partial<EventRow>): EventRow => ({
  id: 'm', ownerId: 'o', title: 't', description: null, category: null,
  visibility: 'public', availability: 'busy', allDay: false,
  startAt: null, endAt: null, startDate: null, endDate: null, rrule: null,
  recurrenceId: null, recurrenceSlotStart: null, recurrenceSlotDate: null,
  isCancelled: false, timezone: null,
  createdAt: '2026-01-01T00:00:00.000Z', updatedAt: '2026-01-01T00:00:00.000Z',
  ...over,
});
/** An exception as the repository would return it after the app wrote it. */
const asRow = (id: string, input: ReturnType<typeof buildCancellation>): EventRow =>
  row({ ...input, id, timezone: null } as Partial<EventRow>);

interface Case {
  name: string;
  zone: string;
  rrule: string;
  /** DTSTART: an ordinary day before the switch */
  start: [number, number, number, number, number];
  from: string;
  to: string;
  /** the tzdata facts: [instant, wall clock it must show] */
  facts: Array<[string, string]>;
  expected: string[];
}

const CASES: Case[] = [
  {
    name: 'Asia/Tokyo weekly Sunday 09:00 (no DST): every week the same instant',
    zone: 'Asia/Tokyo', rrule: 'FREQ=WEEKLY;BYDAY=SU', start: [2026, 2, 22, 9, 0],
    from: '2026-03-01T00:00:00Z', to: '2026-03-16T00:00:00Z',
    facts: [['2026-03-08T00:00:00Z', 'Sun, 2026-03-08, 09:00']],
    expected: ['2026-03-01T00:00:00.000Z', '2026-03-08T00:00:00.000Z', '2026-03-15T00:00:00.000Z'],
  },
  {
    name: 'New York weekly Sunday 02:30, spring gap 2026-03-08: that day it is 03:30 EDT (pushed forward)',
    zone: 'America/New_York', rrule: 'FREQ=WEEKLY;BYDAY=SU', start: [2026, 2, 22, 2, 30],
    from: '2026-03-01T00:00:00Z', to: '2026-03-16T00:00:00Z',
    facts: [['2026-03-08T06:59:00Z', 'Sun, 2026-03-08, 01:59'], ['2026-03-08T07:00:00Z', 'Sun, 2026-03-08, 03:00']],
    expected: ['2026-03-01T07:30:00.000Z', '2026-03-08T07:30:00.000Z', '2026-03-15T06:30:00.000Z'],
  },
  {
    name: 'New York weekly Sunday 01:30, autumn fold 2026-11-01: the 2nd 01:30 (EST)',
    zone: 'America/New_York', rrule: 'FREQ=WEEKLY;BYDAY=SU', start: [2026, 10, 18, 1, 30],
    from: '2026-10-25T00:00:00Z', to: '2026-11-09T00:00:00Z',
    facts: [['2026-11-01T05:30:00Z', 'Sun, 2026-11-01, 01:30'], ['2026-11-01T06:30:00Z', 'Sun, 2026-11-01, 01:30']],
    expected: ['2026-10-25T05:30:00.000Z', '2026-11-01T06:30:00.000Z', '2026-11-08T06:30:00.000Z'],
  },
  {
    name: 'New York daily 01:30 across the fold: one occurrence per day, never both 01:30s',
    zone: 'America/New_York', rrule: 'FREQ=DAILY', start: [2026, 10, 25, 1, 30],
    from: '2026-10-31T00:00:00Z', to: '2026-11-03T00:00:00Z',
    facts: [['2026-11-01T05:30:00Z', 'Sun, 2026-11-01, 01:30'], ['2026-11-01T06:30:00Z', 'Sun, 2026-11-01, 01:30']],
    expected: ['2026-10-31T05:30:00.000Z', '2026-11-01T06:30:00.000Z', '2026-11-02T06:30:00.000Z'],
  },
  {
    name: 'Havana weekly Sunday 00:30, midnight gap 2026-03-08: 01:30 CDT the same Sunday',
    zone: 'America/Havana', rrule: 'FREQ=WEEKLY;BYDAY=SU', start: [2026, 2, 22, 0, 30],
    from: '2026-03-01T00:00:00Z', to: '2026-03-16T00:00:00Z',
    facts: [['2026-03-08T04:59:00Z', 'Sat, 2026-03-07, 23:59'], ['2026-03-08T05:00:00Z', 'Sun, 2026-03-08, 01:00']],
    expected: ['2026-03-01T05:30:00.000Z', '2026-03-08T05:30:00.000Z', '2026-03-15T04:30:00.000Z'],
  },
  {
    name: 'Havana weekly Sunday 00:30, midnight fold 2026-11-01: the 2nd 00:30 (CST)',
    zone: 'America/Havana', rrule: 'FREQ=WEEKLY;BYDAY=SU', start: [2026, 10, 18, 0, 30],
    from: '2026-10-25T00:00:00Z', to: '2026-11-09T00:00:00Z',
    facts: [['2026-11-01T04:30:00Z', 'Sun, 2026-11-01, 00:30'], ['2026-11-01T05:30:00Z', 'Sun, 2026-11-01, 00:30']],
    expected: ['2026-10-25T04:30:00.000Z', '2026-11-01T05:30:00.000Z', '2026-11-08T05:30:00.000Z'],
  },
  {
    name: 'Azores weekly Sunday 00:30, midnight fold 2026-10-25: the 2nd 00:30 (-01)',
    zone: 'Atlantic/Azores', rrule: 'FREQ=WEEKLY;BYDAY=SU', start: [2026, 10, 11, 0, 30],
    from: '2026-10-18T00:00:00Z', to: '2026-11-02T00:00:00Z',
    facts: [['2026-10-25T00:30:00Z', 'Sun, 2026-10-25, 00:30'], ['2026-10-25T01:30:00Z', 'Sun, 2026-10-25, 00:30']],
    expected: ['2026-10-18T00:30:00.000Z', '2026-10-25T01:30:00.000Z', '2026-11-01T01:30:00.000Z'],
  },
  {
    // CURRENT BEHAVIOUR, NOT ENDORSED: the "push forward" half of the rule moves
    // this one occurrence to the next DATE (Sunday) -- see §12, decision D2.
    name: 'Nuuk weekly Saturday 23:30, gap 2026-03-28 23:00 -> 03-29 00:00: lands on SUNDAY 00:30',
    zone: 'America/Godthab', rrule: 'FREQ=WEEKLY;BYDAY=SA', start: [2026, 3, 14, 23, 30],
    from: '2026-03-21T00:00:00Z', to: '2026-04-05T00:00:00Z',
    facts: [['2026-03-29T00:59:00Z', 'Sat, 2026-03-28, 22:59'], ['2026-03-29T01:00:00Z', 'Sun, 2026-03-29, 00:00']],
    expected: ['2026-03-22T01:30:00.000Z', '2026-03-29T01:30:00.000Z'],
  },
];

const expandCase = (c: Case) => {
  const [y, mo, d, h, mi] = c.start;
  const startIso = at(c.zone, y, mo, d, h, mi);
  return expandRule(c.rrule, startIso, c.from, c.to, c.zone);
};

describe('the tzdata facts these cases rest on', () => {
  for (const c of CASES) {
    it(c.name, () => {
      for (const [iso, w] of c.facts) expect(wallOf(iso, c.zone), iso).toBe(w);
    });
  }
});

describe('timed series with a zone (M1): the current rule, in every OS zone', () => {
  for (const os of OS_ZONES) {
    describe(`OS ${os}`, () => {
      for (const c of CASES) {
        it(c.name, () => {
          env.TZ = os;
          expect(expandCase(c)).toEqual(c.expected);
        });
      }
    });
  }
});

describe('series invariants on DST days (M1)', () => {
  it('no instant twice, strictly increasing, one occurrence per scheduled date', () => {
    for (const c of CASES) {
      const r = expandCase(c);
      expect(new Set(r).size, c.name).toBe(r.length);
      for (let i = 1; i < r.length; i++) expect(r[i]! > r[i - 1]!, c.name).toBe(true);
    }
  });

  it('the weekday is kept on every case except the Nuuk gap that crosses midnight', () => {
    for (const c of CASES) {
      const days = expandCase(c).map((iso) => wallOf(iso, c.zone).slice(0, 3));
      const want = c.rrule.includes('BYDAY=SA') ? 'Sat' : 'Sun';
      if (c.zone === 'America/Godthab') {
        // pinned as it is today: the 03-28 occurrence shows on Sunday 03-29
        expect(days).toEqual(['Sat', 'Sun']);
      } else if (c.rrule.startsWith('FREQ=WEEKLY')) {
        expect(days.every((x) => x === want), c.name).toBe(true);
      }
    }
  });

  it('ordinary days before and after the switch keep the wall clock (local "same time every week", not a fixed UTC step)', () => {
    const c = CASES[2]!; // New York 01:30
    const r = expandCase(c);
    expect(r.map((iso) => wallOf(iso, c.zone).slice(-5))).toEqual(['01:30', '01:30', '01:30']);
    // the UTC step is NOT constant across the switch: 7 days + 1 hour
    expect(Date.parse(r[1]!) - Date.parse(r[0]!)).toBe(7 * 86_400_000 + 3_600_000);
    expect(Date.parse(r[2]!) - Date.parse(r[1]!)).toBe(7 * 86_400_000);
  });

  it('a legacy master WITHOUT a zone (M0) takes the 1st 01:30 -- the documented divergence', () => {
    env.TZ = 'America/New_York';
    const c = CASES[2]!;
    const startIso = at(c.zone, 2026, 10, 18, 1, 30);
    expect(expandRule(c.rrule, startIso, c.from, c.to, null)).toEqual([
      '2026-10-25T05:30:00.000Z', '2026-11-01T05:30:00.000Z', '2026-11-08T06:30:00.000Z',
    ]);
  });
});

// ---------------------------------------------------------------------------
// Exceptions: an exception names its occurrence by the GENERATED instant
// (recurrence_slot_start), so it keeps pointing at the same occurrence exactly
// as long as the rule above does not change.
// ---------------------------------------------------------------------------
const master = (zone: string, startIso: string, endIso: string, rrule: string): EventRow =>
  row({ id: 'm', rrule, startAt: startIso, endAt: endIso, timezone: zone });

describe('exceptions on DST-day occurrences (M1)', () => {
  const zone = 'America/New_York';
  const s = at(zone, 2026, 10, 18, 1, 30);
  const m = master(zone, s, new Date(Date.parse(s) + 30 * 60_000).toISOString(), 'FREQ=WEEKLY;BYDAY=SU');
  const from = '2026-10-25T00:00:00Z', to = '2026-11-09T00:00:00Z';
  const occs = () => expandEvents([m], from, to);

  it('deleting the fold occurrence removes that one and no other, in every OS zone', () => {
    env.TZ = 'Asia/Tokyo';
    const fold = occs().find((o) => o.start === '2026-11-01T06:30:00.000Z')!;
    const tomb = asRow('x1', buildCancellation(fold));
    expect(tomb.recurrenceSlotStart).toBe('2026-11-01T06:30:00.000Z');
    for (const os of OS_ZONES) {
      env.TZ = os;
      expect(expandEvents([m, tomb], from, to).map((o) => o.start), os)
        .toEqual(['2026-10-25T05:30:00.000Z', '2026-11-08T06:30:00.000Z']);
    }
  });

  it('editing the fold occurrence (moved to 03:00) replaces exactly that slot, in every OS zone', () => {
    env.TZ = 'UTC';
    const fold = occs().find((o) => o.start === '2026-11-01T06:30:00.000Z')!;
    const moved = asRow('x2', buildException(fold, {
      title: 'moved', description: null, category: null, visibility: 'public', availability: 'busy',
      allDay: false, startAt: '2026-11-01T08:00:00.000Z', endAt: '2026-11-01T08:30:00.000Z',
      startDate: null, endDate: null,
    } as never));
    for (const os of OS_ZONES) {
      env.TZ = os;
      const got = expandEvents([m, moved], from, to);
      expect(got.map((o: EventOccurrence) => `${o.start}${o.isException ? '*' : ''}`), os).toEqual([
        '2026-10-25T05:30:00.000Z', '2026-11-01T08:00:00.000Z*', '2026-11-08T06:30:00.000Z',
      ]);
      expect(got.find((o) => o.isException)!.occurrenceKey).toBe('2026-11-01T06:30:00.000Z');
    }
  });

  it('a slot written at the OTHER 01:30 detaches nothing (why the server reports such a window incomplete)', () => {
    // e.g. written by an M0-era expander. The generated occurrence stays; the
    // server side (0021 §3d) marks the Busy answer complete=false for it.
    const stray = row({ id: 'x3', recurrenceId: 'm', isCancelled: true, recurrenceSlotStart: '2026-11-01T05:30:00.000Z',
      startAt: '2026-11-01T05:30:00.000Z', endAt: '2026-11-01T06:00:00.000Z' });
    env.TZ = 'America/New_York';
    expect(expandEvents([m, stray], from, to).map((o) => o.start))
      .toEqual(['2026-10-25T05:30:00.000Z', '2026-11-01T06:30:00.000Z', '2026-11-08T06:30:00.000Z']);
  });

  it('deleting the spring-gap occurrence (02:30 -> 03:30) removes that one only', () => {
    const z = 'America/New_York';
    const s2 = at(z, 2026, 2, 22, 2, 30);
    const m2 = master(z, s2, new Date(Date.parse(s2) + 30 * 60_000).toISOString(), 'FREQ=WEEKLY;BYDAY=SU');
    env.TZ = 'Asia/Tokyo';
    const gapOcc = expandEvents([m2], '2026-03-01T00:00:00Z', '2026-03-16T00:00:00Z')
      .find((o) => o.start === '2026-03-08T07:30:00.000Z')!;
    const tomb = asRow('x4', buildCancellation(gapOcc));
    for (const os of OS_ZONES) {
      env.TZ = os;
      expect(expandEvents([m2, tomb], '2026-03-01T00:00:00Z', '2026-03-16T00:00:00Z').map((o) => o.start), os)
        .toEqual(['2026-03-01T07:30:00.000Z', '2026-03-15T06:30:00.000Z']);
    }
  });

  it('the end moves with the start (elapsed duration), also on the switch day', () => {
    env.TZ = 'UTC';
    for (const o of occs()) expect(Date.parse(o.end) - Date.parse(o.start)).toBe(30 * 60_000);
  });
});

describe('all-day series keep their calendar dates across DST (OS zone = calendar zone)', () => {
  for (const [os, from, to, dates] of [
    ['America/New_York', '2026-10-17T00:00:00Z', '2026-11-16T00:00:00Z', ['2026-10-18', '2026-10-25', '2026-11-01', '2026-11-08', '2026-11-15']],
    ['America/Havana', '2026-02-27T00:00:00Z', '2026-03-23T00:00:00Z', ['2026-03-01', '2026-03-08', '2026-03-15', '2026-03-22']],
    ['America/Havana', '2026-10-24T00:00:00Z', '2026-11-16T00:00:00Z', ['2026-10-25', '2026-11-01', '2026-11-08', '2026-11-15']],
    ['Atlantic/Azores', '2026-10-17T00:00:00Z', '2026-11-02T00:00:00Z', ['2026-10-18', '2026-10-25', '2026-11-01']],
    ['Asia/Tokyo', '2026-10-17T00:00:00Z', '2026-11-02T00:00:00Z', ['2026-10-18', '2026-10-25', '2026-11-01']],
  ] as const) {
    it(`${os}: weekly Sunday all-day, ${dates[0]} ..`, () => {
      env.TZ = os;
      const m = row({ id: 'a', allDay: true, rrule: 'FREQ=WEEKLY;BYDAY=SU', startDate: dates[0], endDate: addDaysToDateString(dates[0], 1) });
      const got = expandEvents([m], from, to);
      expect(got.map((o) => o.occurrenceKey)).toEqual([...dates]);
      // deleting the switch-day occurrence detaches exactly that date
      const sw = got.find((o) => o.occurrenceKey === dates[1])!;
      const tomb = asRow('t', buildCancellation(sw));
      expect(expandEvents([m, tomb], from, to).map((o) => o.occurrenceKey)).toEqual(dates.filter((d) => d !== dates[1]));
    });
  }
});
