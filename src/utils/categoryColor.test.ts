import { describe, expect, it } from 'vitest';
import { categoryColor } from './categoryColor';

describe('categoryColor', () => {
  it('is deterministic for the same category', () => {
    expect(categoryColor('work')).toEqual(categoryColor('work'));
  });

  it('maps different categories to different colors', () => {
    expect(categoryColor('work').bg).not.toBe(categoryColor('study').bg);
  });

  it('returns a neutral color for null/empty', () => {
    expect(categoryColor(null).bg).toBe('var(--bg-muted)');
    expect(categoryColor('').bg).toBe('var(--bg-muted)');
  });

  it('uses white foreground for generated colors (contrast)', () => {
    expect(categoryColor('anything').fg).toBe('#ffffff');
  });

  it('constrains lightness so generated colors stay in a readable band', () => {
    const m = /hsl\(\d+ \d+% (\d+)%\)/.exec(categoryColor('work').bg);
    expect(m).not.toBeNull();
    expect(Number(m![1])).toBe(42);
  });

  it('honours user overrides', () => {
    expect(categoryColor('work', { work: '#123456' }).bg).toBe('#123456');
  });
});
