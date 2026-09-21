import { describe, expect, it } from 'vitest';
import { eventDisplayTitle } from './eventTitle';

/**
 * The product rule these pin down:
 *
 *   busy + title       -> the title
 *   busy + no title    -> "(無題)", exactly as the three chips showed before
 *   available + title  -> the title
 *   available + none   -> "空き時間", because an available span with no name is
 *                         a normal thing rather than a missing value
 *
 * And, underneath it, the reason the function exists at all: the stand-in is
 * never written anywhere. Nothing here asserts on a stored row, because nothing
 * stores these strings -- see the module header.
 */

describe('eventDisplayTitle: busy', () => {
  it('uses the event title when there is one', () => {
    expect(eventDisplayTitle({ title: '定例会', availability: 'busy' })).toBe('定例会');
  });

  it('falls back to the existing untitled label when the title is empty', () => {
    expect(eventDisplayTitle({ title: '', availability: 'busy' })).toBe('(無題)');
  });
});

describe('eventDisplayTitle: available', () => {
  it('uses the event title when there is one', () => {
    // An available event can be a real event -- "ゲーム, but come and find me".
    expect(eventDisplayTitle({ title: 'ゲーム', availability: 'available' })).toBe('ゲーム');
  });

  it('falls back to its own label, not the untitled one', () => {
    const shown = eventDisplayTitle({ title: '', availability: 'available' });
    expect(shown).toBe('空き時間');
    expect(shown).not.toBe(eventDisplayTitle({ title: '', availability: 'busy' }));
  });
});

describe('eventDisplayTitle: what counts as "no title"', () => {
  it('treats only the empty string as absent', () => {
    // Trimming is readForm's job, and a title of spaces is a title the owner
    // typed. Silently replacing it here would hide that from them.
    expect(eventDisplayTitle({ title: ' ', availability: 'available' })).toBe(' ');
  });

  it('never returns an empty string', () => {
    for (const availability of ['busy', 'available'] as const) {
      expect(eventDisplayTitle({ title: '', availability })).not.toBe('');
    }
  });
});
