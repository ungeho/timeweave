import { describe, expect, it } from 'vitest';
import { AVAILABILITIES, isTitleRequired } from './availabilityField';

/**
 * The validation rule the dialog reads, pinned here because the dialog itself
 * cannot be tested: vitest runs with environment 'node' and this project has no
 * jsdom. Keeping the decision in a function is what makes it checkable at all.
 */

describe('isTitleRequired', () => {
  it('requires a title for a busy event, as it always has', () => {
    expect(isTitleRequired('busy')).toBe(true);
  });

  it('does not require one for an available event', () => {
    expect(isTitleRequired('available')).toBe(false);
  });
});

describe('AVAILABILITIES', () => {
  it('offers exactly the two stored values', () => {
    expect(AVAILABILITIES.map((a) => a.value)).toEqual(['busy', 'available']);
  });

  it('lists the default first, so the control opens on it', () => {
    expect(AVAILABILITIES[0]!.value).toBe('busy');
  });

  it('gives every option a non-empty label', () => {
    for (const a of AVAILABILITIES) expect(a.label).not.toBe('');
  });
});
