import { describe, expect, it } from 'vitest';
import type { EventRow } from '../types/event';
import { expandEvents, expandEventsWithIssues, unexpandableMasters } from './occurrences';
import { formatRRule, parseRRule } from './recurrence';
import { formToRule, EMPTY_RECURRENCE_FORM, type RecurrenceForm } from '../features/event/recurrenceForm';

/*
  K12 (P8-finish-3a). A master whose RRULE this client cannot expand used to
  throw out of expandEvents, and the calendar -- which expands every row on each
  render -- failed to draw at all: one bad series hid every good one.

  The rule now: a series that cannot be expanded is ISOLATED as a whole (the
  master and every exception that points at it), the rest of the calendar is
  expanded exactly as before, and the isolated masters are REPORTED so the
  owner is told. Nothing new is supported: the shapes below are still rejected.

  The share page is not involved: its Busy/Available come from the server, which
  answers "incomplete"/"indeterminate" for these same rows
  (supabase/tests/P8f3a_malformed_rrule_share_test.sql).
*/

const RANGE: [string, string] = ['2026-06-01T00:00:00.000Z', '2026-06-08T00:00:00.000Z'];

/** The four K12 shapes, plus two more the parser rejects. */
const MALFORMED: Array<[string, string]> = [
  ['YEARLY', 'FREQ=YEARLY'],
  ['COUNT with UNTIL', 'FREQ=DAILY;COUNT=3;UNTIL=20260630T000000Z'],
  ['a malformed segment', 'garbage'],
  ['BYDAY=XX', 'FREQ=WEEKLY;BYDAY=XX'],
  ['INTERVAL=0', 'FREQ=DAILY;INTERVAL=0'],
  ['no FREQ', 'COUNT=3'],
];

let seq = 0;
function row(over: Partial<EventRow>): EventRow {
  seq += 1;
  return {
    id: `00000000-0000-4000-8000-${String(seq).padStart(12, '0')}`,
    ownerId: 'owner',
    title: 't',
    description: null,
    category: null,
    visibility: 'public',
    availability: 'busy',
    allDay: false,
    startAt: null,
    endAt: null,
    startDate: null,
    endDate: null,
    rrule: null,
    recurrenceId: null,
    recurrenceSlotStart: null,
    recurrenceSlotDate: null,
    isCancelled: false,
    timezone: null,
    createdAt: '2026-01-01T00:00:00.000Z',
    updatedAt: '2026-01-01T00:00:00.000Z',
    ...over,
  };
}
const timedMaster = (rrule: string, over: Partial<EventRow> = {}) =>
  row({ startAt: '2026-05-05T01:00:00.000Z', endAt: '2026-05-05T02:00:00.000Z', rrule, timezone: 'Asia/Tokyo', ...over });
const allDayMaster = (rrule: string) => row({ allDay: true, startDate: '2026-05-05', endDate: '2026-05-06', rrule });

/** A calendar with nothing wrong in it: a one-off, a weekly series with a moved and a deleted occurrence, an all-day series. */
function goodRows(): EventRow[] {
  const oneOff = row({ startAt: '2026-06-03T01:00:00.000Z', endAt: '2026-06-03T02:00:00.000Z' });
  const weekly = timedMaster('FREQ=WEEKLY;BYDAY=TU,TH');
  const moved = row({
    recurrenceId: weekly.id, recurrenceSlotStart: '2026-06-02T01:00:00.000Z',
    startAt: '2026-06-02T05:00:00.000Z', endAt: '2026-06-02T06:00:00.000Z',
  });
  const deleted = row({
    recurrenceId: weekly.id, recurrenceSlotStart: '2026-06-04T01:00:00.000Z', isCancelled: true,
    startAt: '2026-06-04T01:00:00.000Z', endAt: '2026-06-04T02:00:00.000Z',
  });
  const daily = allDayMaster('FREQ=DAILY;COUNT=40');
  return [oneOff, weekly, moved, deleted, daily];
}
const fingerprint = (rows: EventRow[]) =>
  expandEvents(rows, ...RANGE).map((o) => `${o.event.id} ${o.start} ${o.end} ${o.occurrenceKey} ${o.isException}`);

describe('K12: the client still rejects these shapes (nothing new is supported)', () => {
  it.each(MALFORMED)('%s is rejected by the parser', (_name, rrule) => {
    expect(() => parseRRule(rrule)).toThrow();
  });
});

describe('K12: a series that cannot be expanded is isolated, the rest is untouched', () => {
  const good = goodRows();
  const baseline = fingerprint(good);

  it('control: the good calendar expands as it always did', () => {
    expect(baseline.length).toBeGreaterThan(5);
    expect(expandEventsWithIssues(good, ...RANGE).unexpandable).toEqual([]);
  });

  it.each(MALFORMED)('a timed master with %s: no throw, its series is left out, the others are byte-identical', (_name, rrule) => {
    const bad = timedMaster(rrule);
    const rows = [...good, bad];
    expect(() => expandEvents(rows, ...RANGE)).not.toThrow();
    expect(fingerprint(rows)).toEqual(baseline);
    expect(expandEventsWithIssues(rows, ...RANGE).unexpandable.map((r) => r.id)).toEqual([bad.id]);
  });

  it.each(MALFORMED)('an all-day master with %s: the same', (_name, rrule) => {
    const bad = allDayMaster(rrule);
    const rows = [bad, ...good];
    expect(fingerprint(rows)).toEqual(baseline);
    expect(expandEventsWithIssues(rows, ...RANGE).unexpandable.map((r) => r.id)).toEqual([bad.id]);
  });

  it('only broken series: nothing to draw, every one reported, in row order', () => {
    const bads = MALFORMED.map(([, r]) => timedMaster(r));
    const res = expandEventsWithIssues(bads, ...RANGE);
    expect(res.occurrences).toEqual([]);
    expect(res.unexpandable.map((r) => r.id)).toEqual(bads.map((b) => b.id));
  });

  it('several broken series mixed in: all reported once, the good ones unchanged', () => {
    const b1 = timedMaster('FREQ=YEARLY');
    const b2 = allDayMaster('garbage');
    const b3 = timedMaster('FREQ=WEEKLY;BYDAY=XX');
    const rows = [b1, ...good.slice(0, 2), b2, ...good.slice(2), b3];
    expect(fingerprint(rows)).toEqual(baseline);
    expect(expandEventsWithIssues(rows, ...RANGE).unexpandable.map((r) => r.id)).toEqual([b1.id, b2.id, b3.id]);
  });

  it('the WHOLE series is isolated: an exception of a broken master is not drawn on its own', () => {
    // Opening such an exception would load the master's rule into the form,
    // which cannot read it -- so the series is withheld as one unit.
    const bad = timedMaster('FREQ=YEARLY');
    const moved = row({
      recurrenceId: bad.id, recurrenceSlotStart: '2026-05-05T01:00:00.000Z',
      startAt: '2026-06-02T09:00:00.000Z', endAt: '2026-06-02T10:00:00.000Z',
    });
    const rows = [...good, bad, moved];
    const res = expandEventsWithIssues(rows, ...RANGE);
    expect(res.occurrences.some((o) => o.event.id === moved.id || o.event.id === bad.id)).toBe(false);
    expect(fingerprint(rows)).toEqual(baseline);
    expect(res.unexpandable.map((r) => r.id)).toEqual([bad.id]);
  });

  it('a broken master far outside the range is still reported (the report does not depend on the view)', () => {
    const bad = timedMaster('garbage', { startAt: '2030-01-01T00:00:00.000Z', endAt: '2030-01-01T01:00:00.000Z' });
    expect(unexpandableMasters([...good, bad]).map((r) => r.id)).toEqual([bad.id]);
    expect(unexpandableMasters(good)).toEqual([]);
  });

  it('an empty rrule is still a one-off, as before (not reported)', () => {
    const blank = row({ startAt: '2026-06-05T01:00:00.000Z', endAt: '2026-06-05T02:00:00.000Z', rrule: '' });
    const res = expandEventsWithIssues([blank], ...RANGE);
    expect(res.occurrences.map((o) => o.event.id)).toEqual([blank.id]);
    expect(res.unexpandable).toEqual([]);
  });

  it('a master the expander rejects for another reason (an unknown zone) is isolated the same way', () => {
    const bad = timedMaster('FREQ=DAILY', { timezone: 'Not/AZone' });
    const rows = [...good, bad];
    expect(fingerprint(rows)).toEqual(baseline);
    expect(unexpandableMasters(rows).map((r) => r.id)).toEqual([bad.id]);
  });
});

describe('K12: the app itself never writes a rule it cannot read back', () => {
  // The only place a rule is written is the dialog: formatRRule(formToRule(form)).
  const forms: RecurrenceForm[] = [];
  for (const freq of ['daily', 'weekly', 'monthly'] as const) {
    for (const endMode of ['never', 'count', 'until'] as const) {
      for (const interval of [1, 3]) {
        forms.push({ ...EMPTY_RECURRENCE_FORM, freq, endMode, interval, count: 5, untilDate: '2026-12-31',
          weekdays: freq === 'weekly' ? ['MO', 'WE', 'FR'] : [] });
      }
    }
  }
  it.each(forms.map((f) => [`${f.freq}/${f.endMode}/every ${f.interval}`, f] as const))('%s round-trips', (_n, form) => {
    for (const allDay of [false, true]) {
      const rule = formToRule(form, '2026-06-02T01:00:00.000Z', 'Asia/Tokyo', allDay);
      expect(rule).not.toBeNull();
      const text = formatRRule(rule!);
      expect(() => parseRRule(text)).not.toThrow();
      const bad = allDay ? allDayMaster(text) : timedMaster(text);
      expect(unexpandableMasters([bad])).toEqual([]);
    }
  });
});
