import { describe, expect, it } from 'vitest';
import { isAwaitingRows } from './loadState';

describe('isAwaitingRows — an empty grid must not stand in for an unfinished fetch', () => {
  it('is true on the first load, when nothing has arrived yet', () => {
    expect(isAwaitingRows({ loading: true, rowCount: 0 })).toBe(true);
  });

  it('is false once rows are in hand, even while reloading', () => {
    // useEvents reloads after every create/update/delete. Rows are replaced only
    // when the new list resolves, so the grid can keep showing the old ones and
    // the refetch stays invisible instead of blanking the screen.
    expect(isAwaitingRows({ loading: true, rowCount: 3 })).toBe(false);
  });

  it('is false when the fetch has settled, with or without rows', () => {
    // Settled and empty is a real answer: the calendar is genuinely empty and
    // the grid itself says so.
    expect(isAwaitingRows({ loading: false, rowCount: 0 })).toBe(false);
    expect(isAwaitingRows({ loading: false, rowCount: 3 })).toBe(false);
  });
});
