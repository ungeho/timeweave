import { describe, expect, it } from 'vitest';
import {
  AVAILABLE_EMPTY_MESSAGE,
  AVAILABLE_INDETERMINATE_MESSAGE,
  availablePresentation,
  availableSlots,
  hasDisclosedAvailable,
} from './availablePresentation';
import { hasNoDisclosedBusy } from './freeBusyLayout';
import type { AvailableResult, FreeBusySlot } from '../../types/share';

const SLOT: FreeBusySlot = {
  allDay: false,
  start: '2026-09-01T09:00:00.000Z',
  end: '2026-09-01T10:00:00.000Z',
};

describe('availablePresentation', () => {
  it('hides the section for a link that never asked', () => {
    expect(availablePresentation({ status: 'not_requested' })).toBe('hidden');
  });

  it('shows the indeterminate notice, not a strip', () => {
    expect(availablePresentation({ status: 'indeterminate' })).toBe('indeterminate');
  });

  it('shows slots for a complete answer, empty or not', () => {
    expect(availablePresentation({ status: 'complete', slots: [] })).toBe('slots');
    expect(availablePresentation({ status: 'complete', slots: [SLOT] })).toBe('slots');
  });

  it('never renders an empty strip for not_requested', () => {
    // The distinction this whole union exists for: an opted-out link and an
    // opted-in link that found nothing are DIFFERENT answers, and only the
    // second one may say "no open time is shared".
    expect(availablePresentation({ status: 'not_requested' })).not.toBe('slots');
    expect(availablePresentation({ status: 'complete', slots: [] })).toBe('slots');
  });
});

describe('availableSlots', () => {
  it('returns the slots of a complete answer', () => {
    expect(availableSlots({ status: 'complete', slots: [SLOT] })).toEqual([SLOT]);
  });

  it('returns nothing for indeterminate', () => {
    // The load-bearing one. An indeterminate answer must never put blocks on
    // the grid: 0024 could not subtract busy exactly, so any block drawn would
    // be open time the backend declined to claim.
    expect(availableSlots({ status: 'indeterminate' })).toEqual([]);
  });

  it('returns nothing for not_requested', () => {
    expect(availableSlots({ status: 'not_requested' })).toEqual([]);
  });

  it('never invents slots for a state that has none', () => {
    const states: AvailableResult[] = [{ status: 'not_requested' }, { status: 'indeterminate' }];
    for (const s of states) expect(availableSlots(s)).toHaveLength(0);
  });
});

/**
 * The copy is asserted, not just its presence. Both sentences are the whole of
 * what a viewer is told in states where no blocks are drawn, and the wrong word
 * in either turns an absence of information into a claim about the owner's
 * calendar.
 */
describe('the messages', () => {
  it('the indeterminate sentence does not claim there is no open time', () => {
    expect(AVAILABLE_INDETERMINATE_MESSAGE).not.toContain('ありません');
    expect(AVAILABLE_INDETERMINATE_MESSAGE).not.toContain('空いていません');
  });

  it('the indeterminate sentence says the answer is undetermined', () => {
    expect(AVAILABLE_INDETERMINATE_MESSAGE).toContain('判定できませんでした');
  });

  it('the indeterminate sentence names no reason', () => {
    // An unexpandable recurrence is a detail of the owner's calendar, and 0023's
    // discipline -- never disclose WHY -- applies to this state too.
    for (const leak of ['繰り返し', '定期', 'recurrence', 'RRULE']) {
      expect(AVAILABLE_INDETERMINATE_MESSAGE).not.toContain(leak);
    }
  });

  it('the empty sentence speaks of what is SHARED, not of what exists', () => {
    // The owner may well have open time they simply did not mark available;
    // this page cannot tell, and must not say otherwise.
    expect(AVAILABLE_EMPTY_MESSAGE).toContain('共有');
  });

  it('the two sentences are different', () => {
    expect(AVAILABLE_INDETERMINATE_MESSAGE).not.toBe(AVAILABLE_EMPTY_MESSAGE);
  });
});

/**
 * Regression: the busy-empty notice must not appear above available blocks.
 *
 * Found in review. hasNoDisclosedBusy looks at the busy set alone, so a week
 * holding available events and no busy ones satisfied it while open time was
 * drawn below -- the page announced "no events are shared for this period"
 * immediately above the blocks it was sharing. These pin the gate that now
 * suppresses it, and pin that it is suppressed ONLY in that case.
 */
describe('hasDisclosedAvailable', () => {
  const ALLDAY: FreeBusySlot = { allDay: true, startDate: '2026-09-02', endDate: '2026-09-03' };

  it('is true when complete carries slots', () => {
    expect(hasDisclosedAvailable({ status: 'complete', slots: [SLOT] })).toBe(true);
    expect(hasDisclosedAvailable({ status: 'complete', slots: [ALLDAY] })).toBe(true);
  });

  it('is false for a complete answer that found nothing', () => {
    // Still gets the busy-empty notice: nothing is drawn, so the sentence holds.
    expect(hasDisclosedAvailable({ status: 'complete', slots: [] })).toBe(false);
  });

  it('is false for indeterminate, which draws no blocks', () => {
    expect(hasDisclosedAvailable({ status: 'indeterminate' })).toBe(false);
  });

  it('is false for not_requested', () => {
    expect(hasDisclosedAvailable({ status: 'not_requested' })).toBe(false);
  });

  it('suppresses the busy-empty notice only when blocks are really shown', () => {
    // The condition the page renders on, written out: busy disclosed nothing
    // AND no open time is drawn.
    const busyEmpty = { complete: true, slots: [] as FreeBusySlot[] };
    const show = (a: AvailableResult) =>
      hasNoDisclosedBusy(busyEmpty) && !hasDisclosedAvailable(a);
    expect(show({ status: 'not_requested' })).toBe(true);
    expect(show({ status: 'indeterminate' })).toBe(true);
    expect(show({ status: 'complete', slots: [] })).toBe(true);
    expect(show({ status: 'complete', slots: [SLOT] })).toBe(false);
  });

  it('leaves the notice alone when busy itself disclosed something', () => {
    // The gate must not change the pre-0024 behaviour: a week WITH busy blocks
    // never showed the notice, whatever availability says.
    const withBusy = { complete: true, slots: [SLOT] };
    expect(hasNoDisclosedBusy(withBusy)).toBe(false);
  });
});
