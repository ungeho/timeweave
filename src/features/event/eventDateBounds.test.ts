import { describe, expect, it } from 'vitest';
import * as bounds from './eventDateBounds';
import { addDaysToDateString } from '../../utils/datetime';

/*
  K18 (P8-finish-3b). The database stores an event only inside
    events_allday_range  start_date, end_date (exclusive)  in [0100-01-01, 10000-01-01)
    events_timed_range   start_at,   end_at                in [0100-01-01Z, 10000-01-01Z)
  (0013). The form let a date through to 9999-12-31, so an all-day event ON
  9999-12-31 (exclusive end 10000-01-01), or a timed one whose UTC end passes
  10000-01-01 (9999-12-31 22:00 in New York), reached the database and came back
  as a generic error -- and saved without complaint in local mode, so the two
  modes disagreed. The form now refuses exactly what the database refuses, with
  its own message, in both modes. Stored data is not touched.
*/

const B = bounds as Record<string, unknown>;
const allDay = B.allDayOutOfRange as ((startDate: string, endExclusive: string) => boolean) | undefined;
const timed = B.timedOutOfRange as ((startAt: string, endAt: string) => boolean) | undefined;
const need = <T>(f: T | undefined): T => {
  if (!f) throw new Error('eventDateBounds is not implemented');
  return f;
};

describe('K18: the client bounds are the database bounds (read from 0013 itself)', () => {
  const sql = (import.meta.glob('/supabase/migrations/0013_event_row_bounds.sql', { query: '?raw', import: 'default', eager: true }) as Record<string, string>)[
    '/supabase/migrations/0013_event_row_bounds.sql'
  ] ?? '';

  it('the migration still says what this file assumes', () => {
    expect(sql).toMatch(/start_date >= date '0100-01-01'\s+and start_date < date '10000-01-01'/);
    expect(sql).toMatch(/end_date >= date '0100-01-01'\s+and end_date < date '10000-01-01'/);
    expect(sql).toMatch(/start_at >= timestamptz '0100-01-01 00:00:00\+00'\s+and start_at < timestamptz '10000-01-01 00:00:00\+00'/);
    expect(sql).toMatch(/end_at >= timestamptz '0100-01-01 00:00:00\+00'\s+and end_at < timestamptz '10000-01-01 00:00:00\+00'/);
  });

  it('and the client constants are the same numbers', () => {
    expect(B.DB_FIRST_DATE).toBe('0100-01-01');
    expect(B.DB_END_DATE_EXCLUSIVE).toBe('10000-01-01');
    expect(B.LAST_ALL_DAY_DATE).toBe('9999-12-30');
    expect(B.DB_FIRST_INSTANT_MS).toBe(Date.UTC(100, 0, 1));
    expect(B.DB_END_INSTANT_MS).toBe(Date.UTC(10000, 0, 1));
  });
});

describe('K18: all-day', () => {
  // The form stores an EXCLUSIVE end: the last day + 1.
  const range = (first: string, last: string) => need(allDay)(first, addDaysToDateString(last, 1));

  it.each([
    ['2026-10-13', '2026-10-13'],
    ['9999-12-30', '9999-12-30'],
    ['9999-12-01', '9999-12-30'],
    ['1000-01-01', '1000-01-01'],
  ])('%s .. %s is inside', (a, b) => {
    expect(range(a, b)).toBe(false);
  });

  it.each([
    ['9999-12-31', '9999-12-31'],
    ['9999-12-30', '9999-12-31'],
    ['2026-01-01', '9999-12-31'],
  ])('%s .. %s ends on 9999-12-31, past what the database can store', (a, b) => {
    expect(addDaysToDateString(b, 1)).toBe('10000-01-01');
    expect(range(a, b)).toBe(true);
  });

  it('before 0100-01-01 is outside too (the date field cannot reach it; the rule still holds)', () => {
    expect(need(allDay)('0099-12-31', '0100-01-01')).toBe(true);
  });
});

describe('K18: timed (the bound is in UTC, not in the wall clock)', () => {
  it.each([
    ['9999-12-31T13:00:00.000Z', '9999-12-31T14:00:00.000Z', false, 'Tokyo 9999-12-31 22:00-23:00'],
    ['9999-12-31T23:00:00.000Z', '9999-12-31T23:59:59.999Z', false, 'the last representable millisecond'],
    ['9999-12-31T23:00:00.000Z', '10000-01-01T00:00:00.000Z', true, 'ending exactly at the bound'],
    ['10000-01-01T03:00:00.000Z', '10000-01-01T04:00:00.000Z', true, 'New York 9999-12-31 22:00-23:00'],
    ['0099-12-31T23:00:00.000Z', '0100-01-01T01:00:00.000Z', true, 'starting before 0100'],
  ])('%s .. %s -> %s (%s)', (a, b, out) => {
    expect(need(timed)(a, b)).toBe(out);
  });
});

describe('K18: the dialog refuses before saving, in both modes', () => {
  const dialog = ((import.meta.glob('/src/features/event/EventDialog.tsx', { query: '?raw', import: 'default', eager: true }) as Record<string, string>)[
    '/src/features/event/EventDialog.tsx'
  ] ?? '').replace(/\/\*[\s\S]*?\*\//g, '').replace(/(^|[^:])\/\/.*$/gm, '$1');

  it('the all-day branch checks the exclusive end it is about to store', () => {
    expect(dialog).toMatch(/if \(allDayOutOfRange\(startDate, addDaysToDateString\(endDateInclusive, 1\)\)\) \{\s*setFormError\(\{ kind: 'validation', key: 'event\.error\.allDayOutOfRange' \}\);\s*return null;/);
    // and what is stored is that same exclusive end
    expect(dialog).toMatch(/endDate: addDaysToDateString\(endDateInclusive, 1\)/);
  });

  it('the timed branch checks the instants it is about to store', () => {
    expect(dialog).toMatch(/if \(timedOutOfRange\(startAt, endAt\)\) \{\s*setFormError\(\{ kind: 'validation', key: 'event\.error\.timedOutOfRange' \}\);\s*return null;/);
  });
});
