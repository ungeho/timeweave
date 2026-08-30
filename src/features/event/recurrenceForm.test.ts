import { describe, expect, it } from 'vitest';
import type { EventOccurrence, EventRow } from '../../types/event';
import { dayStartInstantIso, zonedDayKey } from '../../utils/timezone';
import {
  EMPTY_RECURRENCE_FORM,
  formSeedForScope,
  formToRule,
  masterOccurrence,
  parsePositiveIntInput,
  ruleToForm,
  type RecurrenceForm,
} from './recurrenceForm';

const TZ = 'Asia/Tokyo';
const form = (over: Partial<RecurrenceForm>): RecurrenceForm => ({ ...EMPTY_RECURRENCE_FORM, ...over });
// An instant whose Tokyo calendar day is Monday 2026-08-24.
const MON = dayStartInstantIso('2026-08-24', TZ);

describe('formToRule', () => {
  it('returns null when freq is none', () => {
    expect(formToRule(form({ freq: 'none' }), MON, TZ, false)).toBeNull();
  });

  it('builds a weekly rule with sorted weekdays', () => {
    const rule = formToRule(form({ freq: 'weekly', weekdays: ['FR', 'MO'] }), MON, TZ, false);
    expect(rule).toMatchObject({ freq: 'WEEKLY', interval: 1, byDay: ['MO', 'FR'] });
  });

  it('defaults weekly weekday from dtstart when none chosen', () => {
    const rule = formToRule(form({ freq: 'weekly', weekdays: [] }), MON, TZ, false);
    expect(rule!.byDay).toEqual(['MO']);
  });

  it('builds a daily count rule', () => {
    expect(formToRule(form({ freq: 'daily', endMode: 'count', count: 5 }), MON, TZ, false))
      .toMatchObject({ freq: 'DAILY', count: 5 });
  });

  it('builds a timed UNTIL as an instant on the right day', () => {
    const rule = formToRule(form({ freq: 'daily', endMode: 'until', untilDate: '2026-09-02' }), MON, TZ, false);
    expect(rule!.until!.kind).toBe('instant');
    if (rule!.until!.kind === 'instant') {
      expect(zonedDayKey(rule!.until!.instant, TZ)).toBe('2026-09-02');
    }
  });

  it('builds an all-day UNTIL as a date (no conversion)', () => {
    const rule = formToRule(form({ freq: 'daily', endMode: 'until', untilDate: '2026-09-02' }), MON, TZ, true);
    expect(rule!.until).toEqual({ kind: 'date', date: '2026-09-02' });
  });

  it('throws on invalid interval / count / missing until', () => {
    expect(() => formToRule(form({ freq: 'daily', interval: 0 }), MON, TZ, false)).toThrow();
    expect(() => formToRule(form({ freq: 'daily', endMode: 'count', count: 0 }), MON, TZ, false)).toThrow();
    expect(() => formToRule(form({ freq: 'daily', endMode: 'until', untilDate: '' }), MON, TZ, false)).toThrow();
  });
});

describe('parsePositiveIntInput', () => {
  it('commits a plain positive integer', () => {
    expect(parsePositiveIntInput('5')).toEqual({ display: '5', value: 5 });
    expect(parsePositiveIntInput('10')).toEqual({ display: '10', value: 10 });
  });

  it('strips a leading zero once the value is valid (the reported bug)', () => {
    expect(parsePositiveIntInput('05')).toEqual({ display: '5', value: 5 });
    expect(parsePositiveIntInput('007')).toEqual({ display: '7', value: 7 });
  });

  it('allows an empty field without committing (keeps prior value)', () => {
    expect(parsePositiveIntInput('')).toEqual({ display: '', value: null });
    expect(parsePositiveIntInput('   ')).toEqual({ display: '', value: null });
  });

  it('does not commit values below 1', () => {
    expect(parsePositiveIntInput('0')).toEqual({ display: '0', value: null });
    expect(parsePositiveIntInput('-3')).toEqual({ display: '-3', value: null });
  });
});

describe('ruleToForm', () => {
  it('restores a weekly count rule', () => {
    expect(ruleToForm({ freq: 'WEEKLY', interval: 2, byDay: ['MO', 'WE'], count: 6 }, TZ)).toMatchObject({
      freq: 'weekly', interval: 2, weekdays: ['MO', 'WE'], endMode: 'count', count: 6,
    });
  });
  it('restores an all-day until as a date', () => {
    expect(ruleToForm({ freq: 'DAILY', interval: 1, until: { kind: 'date', date: '2026-09-02' } }, TZ))
      .toMatchObject({ freq: 'daily', endMode: 'until', untilDate: '2026-09-02' });
  });
  it('restores a timed until back to its zoned date', () => {
    expect(ruleToForm({ freq: 'DAILY', interval: 1, until: { kind: 'instant', instant: '2026-09-02T14:59:59.999Z' } }, TZ))
      .toMatchObject({ endMode: 'until', untilDate: '2026-09-02' });
  });
});

describe('formSeedForScope', () => {
  const makeMaster = (over: Partial<EventRow> = {}): EventRow => ({
    id: 'm', ownerId: 'u', title: '定例会', description: null, category: null, visibility: 'private',
    allDay: false, startAt: '2026-08-24T00:00:00.000Z', endAt: '2026-08-24T01:00:00.000Z',
    startDate: null, endDate: null, rrule: 'FREQ=WEEKLY;BYDAY=MO', recurrenceId: null,
    recurrenceSlotStart: null, recurrenceSlotDate: null, isCancelled: false,
    createdAt: '2026-01-01T00:00:00.000Z', updatedAt: '2026-01-01T00:00:00.000Z', ...over,
  });

  // An exception occurrence moved to 10:00 (master is 09:00-equivalent 00:00Z).
  const exceptionOcc = (m: EventRow): EventOccurrence => ({
    event: { ...m, id: 'e', recurrenceId: 'm', startAt: '2026-08-31T01:00:00.000Z', endAt: '2026-08-31T02:00:00.000Z' },
    start: '2026-08-31T01:00:00.000Z', end: '2026-08-31T02:00:00.000Z',
    allDay: false, occurrenceKey: '2026-08-31T00:00:00.000Z', isException: true,
  });

  it('scope "only" seeds from the occurrence itself', () => {
    const m = makeMaster();
    const seed = formSeedForScope(exceptionOcc(m), m, 'only');
    expect(seed.recurrenceEditable).toBe(false);
    expect(seed.occurrence.start).toBe('2026-08-31T01:00:00.000Z'); // the exception's time
  });

  it('scope "all" seeds from the master content, not the exception', () => {
    const m = makeMaster();
    const seed = formSeedForScope(exceptionOcc(m), m, 'all');
    expect(seed.recurrenceEditable).toBe(true);
    expect(seed.occurrence.start).toBe('2026-08-24T00:00:00.000Z'); // master base start
    expect(seed.occurrence.event.id).toBe('m');
  });

  it('masterOccurrence handles all-day masters', () => {
    const m = makeMaster({ allDay: true, startAt: null, endAt: null, startDate: '2026-08-24', endDate: '2026-08-25' });
    const occ = masterOccurrence(m);
    expect(occ.allDay).toBe(true);
    expect(occ.occurrenceKey).toBe('2026-08-24');
  });
});
