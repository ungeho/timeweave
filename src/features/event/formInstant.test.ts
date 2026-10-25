import { afterAll, describe, expect, it } from 'vitest';
import { isoFromDatetimeLocalValue, toDatetimeLocalValue } from '../../utils/datetime';
import { classifyZonedWallClock } from '../../utils/timezone';
import { checkWallTime, formInstant, formatUtcOffset, storedFoldChoice } from './formInstant';
import { expandRule } from '../../services/recurrence';
import { eventFormErrorText } from './eventFormError';

/*
  The form's conversion depends on the RUNTIME's zone (Date), so these tests
  set it. Node re-reads TZ on assignment; the original is restored so no other
  file in the worker inherits New York. No @types/node in this project, hence
  the cast.
*/
const env = (globalThis as unknown as { process: { env: Record<string, string | undefined> } }).process.env;
const ORIGINAL_TZ = env.TZ;
function inZone(tz: string) {
  env.TZ = tz;
}
afterAll(() => {
  if (ORIGINAL_TZ === undefined) delete env.TZ;
  else env.TZ = ORIGINAL_TZ;
});

const NY = 'America/New_York';
const wall = (s: string) => {
  const [d, t] = s.split('T');
  const [year, month, day] = d!.split('-').map(Number);
  const [hour, minute] = t!.split(':').map(Number);
  return { year: year!, month: month!, day: day!, hour: hour!, minute: minute!, second: 0, ms: 0 };
};

describe('classifyZonedWallClock counts, it never picks', () => {
  it('Asia/Tokyo has no DST: one instant', () => {
    expect(classifyZonedWallClock(wall('2026-03-08T02:30'), 'Asia/Tokyo')).toEqual({
      kind: 'normal',
      instantMs: Date.parse('2026-03-07T17:30:00Z'),
    });
  });

  it('New York spring: 02:00-02:59 do not exist, the edges do', () => {
    expect(classifyZonedWallClock(wall('2026-03-08T01:59'), NY).kind).toBe('normal');
    const gap = classifyZonedWallClock(wall('2026-03-08T02:30'), NY);
    expect(gap).toEqual({
      kind: 'gap',
      lastBeforeMs: Date.parse('2026-03-08T06:59:00Z'), // 01:59 EST
      firstAfterMs: Date.parse('2026-03-08T07:00:00Z'), // 03:00 EDT
      gapMinutes: 60,
    });
    expect(classifyZonedWallClock(wall('2026-03-08T02:00'), NY).kind).toBe('gap');
    expect(classifyZonedWallClock(wall('2026-03-08T02:59'), NY).kind).toBe('gap');
    expect(classifyZonedWallClock(wall('2026-03-08T03:00'), NY).kind).toBe('normal');
  });

  it('New York fall: 01:00-01:59 happen twice, an hour apart', () => {
    expect(classifyZonedWallClock(wall('2026-11-01T00:59'), NY).kind).toBe('normal');
    expect(classifyZonedWallClock(wall('2026-11-01T01:30'), NY)).toEqual({
      kind: 'fold',
      earlierMs: Date.parse('2026-11-01T05:30:00Z'),
      laterMs: Date.parse('2026-11-01T06:30:00Z'),
    });
    expect(classifyZonedWallClock(wall('2026-11-01T01:00'), NY).kind).toBe('fold');
    expect(classifyZonedWallClock(wall('2026-11-01T01:59'), NY).kind).toBe('fold');
    expect(classifyZonedWallClock(wall('2026-11-01T02:00'), NY).kind).toBe('normal');
  });

  it('does not assume an hour: Lord Howe moves 30 minutes', () => {
    const c = classifyZonedWallClock(wall('2026-10-04T02:15'), 'Australia/Lord_Howe');
    expect(c.kind).toBe('gap');
    if (c.kind === 'gap') expect(c.gapMinutes).toBe(30);
  });

  it('the answer depends on the zone passed, not on the runtime zone', () => {
    for (const tz of ['Asia/Tokyo', NY, 'UTC', 'Australia/Sydney']) {
      inZone(tz);
      expect(classifyZonedWallClock(wall('2026-11-01T01:30'), NY).kind).toBe('fold');
      expect(classifyZonedWallClock(wall('2026-03-08T02:30'), NY).kind).toBe('gap');
      expect(classifyZonedWallClock(wall('2026-10-25T01:30'), 'Europe/London').kind).toBe('fold');
    }
  });
});

describe('formInstant in a New York browser', () => {
  it('a normal time is EXACTLY the old conversion', () => {
    inZone(NY);
    for (const local of ['2026-10-18T14:30', '2026-03-08T01:59', '2026-03-08T03:00', '2026-11-01T02:00', '2026-12-31T23:59']) {
      expect(formInstant(local, NY, null)).toEqual({ ok: true, iso: isoFromDatetimeLocalValue(local) });
    }
  });

  it('a time in the spring gap is refused, not moved', () => {
    inZone(NY);
    // The OLD conversion moves it; that is what is being refused.
    expect(toDatetimeLocalValue(isoFromDatetimeLocalValue('2026-03-08T02:30'))).toBe('2026-03-08T03:30');
    expect(formInstant('2026-03-08T02:30', NY, null)).toEqual({ ok: false, reason: 'gap' });
    expect(formInstant('2026-03-08T02:30', NY, 'later')).toEqual({ ok: false, reason: 'gap' });
    expect(checkWallTime('2026-03-08T02:30', NY)).toEqual({
      kind: 'gap',
      lastBefore: '2026-03-08T01:59',
      firstAfter: '2026-03-08T03:00',
      gapMinutes: 60,
    });
  });

  it('a time in the fall fold needs a choice, and each choice is its own instant', () => {
    inZone(NY);
    expect(formInstant('2026-11-01T01:30', NY, null)).toEqual({ ok: false, reason: 'foldUnchosen' });
    const first = formInstant('2026-11-01T01:30', NY, 'earlier');
    const second = formInstant('2026-11-01T01:30', NY, 'later');
    expect(first).toEqual({ ok: true, iso: '2026-11-01T05:30:00.000Z' });
    expect(second).toEqual({ ok: true, iso: '2026-11-01T06:30:00.000Z' });
    // Both show again as the wall clock the owner typed.
    if (first.ok && second.ok) {
      expect(toDatetimeLocalValue(first.iso)).toBe('2026-11-01T01:30');
      expect(toDatetimeLocalValue(second.iso)).toBe('2026-11-01T01:30');
    }
    const check = checkWallTime('2026-11-01T01:30', NY);
    expect(check.kind).toBe('fold');
    if (check.kind === 'fold') {
      expect(check.options.map((o) => [o.abbreviation, formatUtcOffset(o.offsetMinutes)])).toEqual([
        ['EDT', 'UTC−04:00'],
        ['EST', 'UTC−05:00'],
      ]);
    }
  });

  it('B1: an event stored at the 2nd 01:30 keeps its instant when re-saved untouched', () => {
    inZone(NY);
    const stored = '2026-11-01T06:30:00.000Z'; // e.g. produced by the expander's "later" rule
    const local = toDatetimeLocalValue(stored);
    expect(local).toBe('2026-11-01T01:30');
    // The OLD save moved it to the 1st:
    expect(isoFromDatetimeLocalValue(local)).toBe('2026-11-01T05:30:00.000Z');
    // The restored choice keeps it:
    const choice = storedFoldChoice(stored, NY);
    expect(choice).toBe('later');
    expect(formInstant(local, NY, choice)).toEqual({ ok: true, iso: stored });
    // And a stored 1st stays the 1st. A DB round trip drops milliseconds; still recognised.
    expect(storedFoldChoice('2026-11-01T05:30:00+00:00', NY)).toBe('earlier');
    expect(storedFoldChoice('2026-10-18T18:30:00.000Z', NY)).toBeNull();
  });
});

describe('formInstant where Date and the calendar zone disagree', () => {
  it('a Tokyo runtime asked about New York does not intervene (the save runs in Tokyo)', () => {
    inZone('Asia/Tokyo');
    expect(checkWallTime('2026-03-08T02:30', NY)).toEqual({ kind: 'normal' });
    expect(checkWallTime('2026-11-01T01:30', NY)).toEqual({ kind: 'normal' });
    expect(formInstant('2026-11-01T01:30', NY, null)).toEqual({ ok: true, iso: isoFromDatetimeLocalValue('2026-11-01T01:30') });
  });

  it('in Tokyo, for Tokyo, nothing is ever a gap or a fold', () => {
    inZone('Asia/Tokyo');
    for (const local of ['2026-03-08T02:30', '2026-11-01T01:30', '2026-10-18T14:30']) {
      expect(formInstant(local, 'Asia/Tokyo', null)).toEqual({ ok: true, iso: isoFromDatetimeLocalValue(local) });
    }
  });

  it('London, both sides of the year', () => {
    inZone('Europe/London');
    expect(formInstant('2026-03-29T01:30', 'Europe/London', null)).toEqual({ ok: false, reason: 'gap' });
    expect(formInstant('2026-10-25T01:30', 'Europe/London', 'earlier')).toEqual({ ok: true, iso: '2026-10-25T00:30:00.000Z' });
    expect(formInstant('2026-10-25T01:30', 'Europe/London', 'later')).toEqual({ ok: true, iso: '2026-10-25T01:30:00.000Z' });
  });

  it('an unparseable value is left to the existing checks', () => {
    expect(checkWallTime('', NY)).toEqual({ kind: 'normal' });
    expect(() => formInstant('', NY, null)).toThrow();
  });
});

describe('a timed series keeps the instant chosen for its first occurrence', () => {
  it('DTSTART is never reconstructed, so the 2nd 01:30 stays the 2nd; later weeks are ordinary', () => {
    inZone(NY);
    const chosen = formInstant('2026-11-01T01:30', NY, 'later');
    expect(chosen.ok).toBe(true);
    if (!chosen.ok) return;
    const starts = expandRule('FREQ=WEEKLY;COUNT=3', chosen.iso, '2026-10-25T00:00:00Z', '2026-11-30T00:00:00Z', NY);
    expect(starts[0]).toBe('2026-11-01T06:30:00.000Z'); // exactly the chosen instant
    expect(starts.slice(1).map((iso) => toDatetimeLocalValue(iso))).toEqual(['2026-11-08T01:30', '2026-11-15T01:30']);
    // and the 1st choice is kept just as exactly
    const first = formInstant('2026-11-01T01:30', NY, 'earlier');
    if (first.ok) {
      expect(expandRule('FREQ=WEEKLY;COUNT=1', first.iso, '2026-10-25T00:00:00Z', '2026-11-30T00:00:00Z', NY)[0]).toBe(
        '2026-11-01T05:30:00.000Z',
      );
    }
  });

  it('the expander still resolves LATER occurrences on a DST day the way 0009 does (unchanged)', () => {
    inZone(NY);
    // A daily 02:30 series started before the spring change: the 03-08
    // occurrence does not exist and is resolved to the later candidate, as
    // before. The form now refuses 02:30 only as a DTSTART it is asked to save.
    const starts = expandRule('FREQ=DAILY;COUNT=3', '2026-03-07T07:30:00.000Z', '2026-03-01T00:00:00Z', '2026-03-31T00:00:00Z', NY);
    expect(starts).toEqual(['2026-03-07T07:30:00.000Z', '2026-03-08T07:30:00.000Z', '2026-03-09T06:30:00.000Z']);
  });
});

describe('the refusal sentences', () => {
  it('an emptied date still reads as before; other drafts and DST cases have their own', () => {
    const err = (issue: Parameters<typeof eventFormErrorText>[0]) => [eventFormErrorText(issue, 'ja'), eventFormErrorText(issue, 'en')];
    expect(err({ kind: 'datetime', issue: { problem: 'draft', part: 'date', empty: true } })).toEqual([
      eventFormErrorText({ kind: 'validation', key: 'event.error.dateRequired' }, 'ja'),
      eventFormErrorText({ kind: 'validation', key: 'event.error.dateRequired' }, 'en'),
    ]);
    const others = [
      err({ kind: 'datetime', issue: { problem: 'draft', part: 'time', empty: true } }),
      err({ kind: 'datetime', issue: { problem: 'draft', part: 'date', empty: false } }),
      err({ kind: 'datetime', issue: { problem: 'gap' } }),
      err({ kind: 'datetime', issue: { problem: 'foldUnchosen' } }),
    ];
    for (const [ja, en] of others) {
      expect(ja).not.toBe(en);
      expect(en).not.toMatch(/[぀-ヿ一-鿿]/);
    }
    expect(new Set(others.map(([ja]) => ja)).size).toBe(4);
  });
});
