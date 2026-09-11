/**
 * What the calendar's view area is allowed to claim, given the fetch state.
 *
 * An empty month/week/day grid is not a neutral picture: it states "there is
 * nothing here". While the first rows are still in flight that statement is not
 * known to be true, so the view must not make it -- the same rule the share page
 * applies to an empty Free/Busy week (`features/share/freeBusyLayout`).
 *
 * The test is `loading AND no rows in hand`, never `loading` alone, because
 * `useEvents` reloads after EVERY mutation. Keying off `loading` by itself would
 * blank the whole calendar on each save or delete. Rows survive a reload --
 * `useEvents` replaces them only once the new list resolves -- so whenever any
 * are in hand the grid stays up and the refetch is invisible.
 *
 * A failed load is not this state either: `useEvents` leaves `loading` false and
 * keeps the rows it already had, so the error banner is what speaks there.
 */
export function isAwaitingRows(state: { loading: boolean; rowCount: number }): boolean {
  return state.loading && state.rowCount === 0;
}
