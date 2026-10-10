import { describe, expect, it } from 'vitest';
import { AVAILABILITIES, isTitleRequired } from './availabilityField';
import * as field from './availabilityField';

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

/**
 * The control offers both values UNCONDITIONALLY.
 *
 * There is no visibility-dependent gating here, and there must not be: private
 * and available are independent settings, so the dialog has to let the owner
 * hold both at once. This is pinned as a module shape rather than as a rendered
 * select because vitest runs with environment 'node' and there is no jsdom --
 * the same constraint the header records. What it guards against is a gating
 * helper being re-introduced beside AVAILABILITIES and quietly consulted by the
 * component.
 */
describe('the availability control is independent of visibility', () => {
  it('exposes the options as a plain list, taking no visibility', () => {
    expect(Array.isArray(AVAILABILITIES)).toBe(true);
    expect(AVAILABILITIES.map((a) => a.value)).toEqual(['busy', 'available']);
  });

  it('exports nothing that could gate an option on visibility', () => {
    // Every export is either the options list or the title rule, and the title
    // rule reads availability alone. Nothing here can see a visibility, so
    // nothing here can refuse a combination of the two.
    expect(Object.keys(field).sort()).toEqual(['AVAILABILITIES', 'isTitleRequired']);
    expect(field.isTitleRequired.length).toBe(1);
  });

  it('asks a private available event for no title, exactly as a public one', () => {
    // The only rule that touches availability at all, shown not to vary with
    // visibility: it never receives one.
    expect(isTitleRequired('available')).toBe(false);
    expect(isTitleRequired('busy')).toBe(true);
  });
});
