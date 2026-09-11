import { describe, expect, it } from 'vitest';
import { resolveInitialTheme } from './theme';

describe('resolveInitialTheme — a stored choice outranks the OS', () => {
  it('keeps a stored dark even when the OS asks for light', () => {
    expect(resolveInitialTheme('dark', false)).toBe('dark');
  });

  it('keeps a stored light even when the OS asks for dark', () => {
    expect(resolveInitialTheme('light', true)).toBe('light');
  });

  it('follows the OS when nothing has been stored', () => {
    expect(resolveInitialTheme(null, true)).toBe('dark');
    expect(resolveInitialTheme(null, false)).toBe('light');
  });

  it('treats an unreadable stored value as no value and falls back to the OS', () => {
    // A value from an older build, hand-edited, or corrupted. Trusting it would
    // pin the session to a theme nobody asked for; refusing to fall through
    // would pin it to light.
    for (const junk of ['', 'system', 'Dark', 'true', '{}']) {
      expect(resolveInitialTheme(junk, true)).toBe('dark');
      expect(resolveInitialTheme(junk, false)).toBe('light');
    }
  });
});
