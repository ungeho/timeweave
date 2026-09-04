import { describe, expect, it } from 'vitest';
import type { EventRow } from '../types/event';
import { seriesHasExceptions } from './seriesGuards';

const row = (over: Partial<EventRow>): EventRow => ({
  id: 'x', ownerId: 'u', title: 't', description: null, category: null, visibility: 'private',
  allDay: false, startAt: '2026-08-24T00:00:00.000Z', endAt: '2026-08-24T01:00:00.000Z',
  startDate: null, endDate: null, rrule: null, recurrenceId: null,
  recurrenceSlotStart: null, recurrenceSlotDate: null, isCancelled: false, timezone: null,
  createdAt: '2026-01-01T00:00:00.000Z', updatedAt: '2026-01-01T00:00:00.000Z', ...over,
});

describe('seriesHasExceptions', () => {
  it('is true when a master has any exception row', () => {
    const rows = [row({ id: 'm', rrule: 'FREQ=WEEKLY;BYDAY=MO' }), row({ id: 'e', recurrenceId: 'm' })];
    expect(seriesHasExceptions('m', rows)).toBe(true);
  });
  it('is false when a master has no exceptions', () => {
    const rows = [row({ id: 'm', rrule: 'FREQ=WEEKLY;BYDAY=MO' }), row({ id: 'other', recurrenceId: 'z' })];
    expect(seriesHasExceptions('m', rows)).toBe(false);
  });
});
