import { afterAll, describe, expect, it } from 'vitest';
import { isoFromDatetimeLocalValue, toDatetimeLocalValue } from '../../utils/datetime';
import { checkWallTime, foldInstant, storedFoldChoice } from './formInstant';
import { editTimezoneIntent, timezonePlacementOk } from '../../services/timezoneRules';

/*
  P8-c4: a TIMED ONE-OFF event and time zones -- what the app does today.
  CHARACTERIZATION: nothing here is a new rule (docs/p8-datetime-contract.md §15).

  THE CONTRACT. A timed one-off stores only instants (start_at / end_at). It has
  no zone of its own: events.timezone must be NULL on it (0008's
  events_timezone_placement CHECK; timezonePlacementOk is its twin). The dialog
  shows and reads its wall clock in the BROWSER's zone (getUserTimeZone = the
  zone `Date` uses), so:
    open   local  = toDatetimeLocalValue(start)                 (browser zone)
           pick   = storedFoldChoice(start, zone)               (which of two, if a fold)
    save   start  = fold ? foldInstant(check, pick) : isoFromDatetimeLocalValue(local)
  These are the calls EventDialog makes; this file runs them under different
  OS zones (= browser zones) to measure create / reopen / untouched save.
*/

const env = (globalThis as unknown as { process: { env: Record<string, string | undefined> } }).process.env;
const ORIGINAL_TZ = env.TZ;
afterAll(() => {
  if (ORIGINAL_TZ === undefined) delete env.TZ;
  else env.TZ = ORIGINAL_TZ;
});
const wallOf = (iso: string, zone: string) =>
  new Intl.DateTimeFormat('en-CA', {
    timeZone: zone, hourCycle: 'h23', year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit',
  }).format(new Date(iso)).replace(', ', 'T');

/** What the dialog shows for a stored instant in browser zone `zone`. */
function open(iso: string, zone: string) {
  env.TZ = zone;
  const local = toDatetimeLocalValue(iso);
  return { local, check: checkWallTime(local, zone), pick: storedFoldChoice(iso, zone) };
}
/** What an UNTOUCHED save writes back. */
function saveUntouched(iso: string, zone: string): string | null {
  const o = open(iso, zone);
  if (o.check.kind === 'gap') return null;
  if (o.check.kind === 'fold') return foldInstant(o.check, o.pick);
  return isoFromDatetimeLocalValue(o.local);
}

describe('create: the wall clock is read in the browser zone', () => {
  it('a 09:00 New York meeting, entered from a Tokyo browser, has to be typed as 23:00 Tokyo time', () => {
    env.TZ = 'Asia/Tokyo';
    // 2026-11-10 09:00 EST = 14:00Z = 23:00 JST
    expect(wallOf('2026-11-10T14:00:00Z', 'America/New_York')).toBe('2026-11-10T09:00');
    expect(isoFromDatetimeLocalValue('2026-11-10T23:00')).toBe('2026-11-10T14:00:00.000Z');
    // typing "09:00" in Tokyo means 09:00 JST, which is 19:00 the day before in New York
    expect(isoFromDatetimeLocalValue('2026-11-10T09:00')).toBe('2026-11-10T00:00:00.000Z');
    expect(wallOf('2026-11-10T00:00:00Z', 'America/New_York')).toBe('2026-11-09T19:00');
  });

  it('the same text gives different instants in different browser zones', () => {
    const got: Record<string, string> = {};
    for (const z of ['UTC', 'Asia/Tokyo', 'America/New_York', 'Asia/Kolkata', 'Asia/Kathmandu']) {
      env.TZ = z;
      got[z] = isoFromDatetimeLocalValue('2026-11-10T09:00');
    }
    expect(got).toEqual({
      UTC: '2026-11-10T09:00:00.000Z',
      'Asia/Tokyo': '2026-11-10T00:00:00.000Z',
      'America/New_York': '2026-11-10T14:00:00.000Z',
      'Asia/Kolkata': '2026-11-10T03:30:00.000Z',
      'Asia/Kathmandu': '2026-11-10T03:15:00.000Z',
    });
  });

  it('a one-off may not carry a zone (0008), and gains one only by becoming a series', () => {
    expect(timezonePlacementOk({ allDay: false, rrule: null, recurrenceId: null, timezone: 'America/New_York' })).toBe(false);
    expect(timezonePlacementOk({ allDay: false, rrule: null, recurrenceId: null, timezone: null })).toBe(true);
    // one-off -> weekly: the BROWSER's zone is adopted
    expect(editTimezoneIntent({ allDay: false, rrule: null }, { allDay: false, rrule: 'FREQ=WEEKLY' }, 'Asia/Tokyo'))
      .toEqual({ kind: 'adopt', timezone: 'Asia/Tokyo' });
    // series -> one-off: nothing to adopt; the save clears the zone with the rule
    expect(editTimezoneIntent({ allDay: false, rrule: 'FREQ=WEEKLY' }, { allDay: false, rrule: null }, 'Asia/Tokyo'))
      .toEqual({ kind: 'keep' });
  });
});

describe('reopen in another browser zone: shown in the new zone, the instant is kept', () => {
  const ZONES = ['UTC', 'Asia/Tokyo', 'America/New_York', 'America/Havana', 'Atlantic/Azores',
    'Asia/Kolkata', 'Asia/Kathmandu', 'Australia/Lord_Howe', 'Pacific/Chatham'];

  it('the New York meeting reopened in New York reads 09:00, in Tokyo 23:00', () => {
    expect(open('2026-11-10T14:00:00.000Z', 'America/New_York').local).toBe('2026-11-10T09:00');
    expect(open('2026-11-10T14:00:00.000Z', 'Asia/Tokyo').local).toBe('2026-11-10T23:00');
  });

  it('an untouched save writes back the same instant -- every 15 minutes across each zone\'s switches, in every browser zone', () => {
    // instants around New York, Havana, Azores, Lord Howe and Chatham switches of 2026
    const windows = [
      '2026-03-08T00:00:00Z', '2026-11-01T00:00:00Z', // New York, Havana
      '2026-03-29T00:00:00Z', '2026-10-25T00:00:00Z', // Azores
      '2026-04-04T12:00:00Z', '2026-10-03T12:00:00Z', // Lord Howe (30-min switch)
      '2026-04-04T12:00:00Z', '2026-09-26T12:00:00Z', // Chatham
    ];
    let checked = 0;
    for (const zone of ZONES) {
      for (const w of windows) {
        for (let k = 0; k < 4 * 24; k++) {
          const iso = new Date(Date.parse(w) + k * 15 * 60_000).toISOString();
          expect(saveUntouched(iso, zone), `${zone} ${iso}`).toBe(iso);
          checked++;
        }
      }
    }
    expect(checked).toBe(9 * 8 * 96);
  });

  it('a stored instant never reopens as a time that does not exist', () => {
    for (const zone of ['America/New_York', 'America/Havana', 'Atlantic/Azores', 'Australia/Lord_Howe']) {
      for (let k = 0; k < 96; k++) {
        const iso = new Date(Date.parse('2026-03-08T00:00:00Z') + k * 15 * 60_000).toISOString();
        expect(open(iso, zone).check.kind, `${zone} ${iso}`).not.toBe('gap');
      }
    }
  });
});

describe('DST: created in one zone, reopened where the time happens twice', () => {
  it('created in Tokyo at the 1st New York 01:30, reopened in New York: shows the fold with the 1st selected, kept', () => {
    env.TZ = 'Asia/Tokyo';
    const iso = isoFromDatetimeLocalValue('2026-11-01T14:30'); // 14:30 JST
    expect(iso).toBe('2026-11-01T05:30:00.000Z');
    const o = open(iso, 'America/New_York');
    expect(o.local).toBe('2026-11-01T01:30');
    expect(o.check.kind).toBe('fold');
    expect(o.pick).toBe('earlier');
    expect(saveUntouched(iso, 'America/New_York')).toBe(iso);
  });

  it('the 2nd New York 01:30 (created in Tokyo as 15:30) reopens with the 2nd selected, kept', () => {
    const iso = '2026-11-01T06:30:00.000Z';
    expect(open(iso, 'America/New_York').pick).toBe('later');
    expect(saveUntouched(iso, 'America/New_York')).toBe(iso);
  });

  it('the 2nd Havana 00:30 reopened in New York is the 1st New York 01:30 -- a different side, still the same instant', () => {
    const iso = '2026-11-01T05:30:00.000Z';
    expect(wallOf(iso, 'America/Havana')).toBe('2026-11-01T00:30');
    expect(open(iso, 'America/Havana').pick).toBe('later');
    expect(open(iso, 'America/New_York').pick).toBe('earlier');
    expect(saveUntouched(iso, 'America/New_York')).toBe(iso);
  });

  it('the New York spring gap cannot be typed in New York; from Tokyo the same instants are ordinary times', () => {
    env.TZ = 'America/New_York';
    expect(checkWallTime('2026-03-08T02:30', 'America/New_York').kind).toBe('gap');
    env.TZ = 'Asia/Tokyo';
    // 02:30 "New York time" does not exist; 01:59 EST and 03:00 EDT do, and are 15:59 / 16:00 JST
    expect(isoFromDatetimeLocalValue('2026-03-08T15:59')).toBe('2026-03-08T06:59:00.000Z');
    expect(isoFromDatetimeLocalValue('2026-03-08T16:00')).toBe('2026-03-08T07:00:00.000Z');
    expect(wallOf('2026-03-08T07:00:00Z', 'America/New_York')).toBe('2026-03-08T03:00');
  });

  it('a fold in the browser zone is resolved by the owner, a fold elsewhere never is (no question is asked)', () => {
    // typing 01:30 on 2026-11-01 in New York asks; typing the same text in Tokyo does not
    env.TZ = 'America/New_York';
    expect(checkWallTime('2026-11-01T01:30', 'America/New_York').kind).toBe('fold');
    env.TZ = 'Asia/Tokyo';
    expect(checkWallTime('2026-11-01T01:30', 'Asia/Tokyo').kind).toBe('normal');
  });
});

describe('a related edge, pinned as it is (not a zone question)', () => {
  it('an untouched save keeps whole minutes only: seconds written by some other path would be dropped', () => {
    // The dialog edits minutes (datetime-local, HH:mm). Every write path in the
    // app produces whole minutes, so this matters only for rows written
    // elsewhere. Recorded in §15 as a residual, not changed here.
    expect(saveUntouched('2026-11-10T14:00:00.000Z', 'America/New_York')).toBe('2026-11-10T14:00:00.000Z');
    expect(saveUntouched('2026-11-10T14:00:30.000Z', 'America/New_York')).toBe('2026-11-10T14:00:00.000Z');
  });
});
