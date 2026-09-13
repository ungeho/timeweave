/**
 * Subscribe to a CSS media query and re-render when it flips.
 *
 * WHY useSyncExternalStore RATHER THAN useState + useEffect
 *
 * A `MediaQueryList` is external mutable state, which is exactly what this hook
 * is for. The usual `useState(window.matchMedia(q).matches)` + `useEffect`
 * pairing reads the value during the FIRST render and only starts listening
 * after commit, so the first paint can disagree with the viewport and a change
 * arriving in that window is missed entirely. `useSyncExternalStore` subscribes
 * first and reads through `getSnapshot`, so React never renders a value it is
 * not already subscribed to.
 *
 * It also keeps `window` out of the render path: the component calls this hook,
 * React calls `getSnapshot`. Reading `window.innerWidth` inline during render
 * would look simpler and be wrong twice over -- it never updates on resize, and
 * it makes the component untestable outside a browser.
 *
 * `getSnapshot` must return a primitive, and it does: `.matches` is a boolean,
 * compared by value, so a fresh `MediaQueryList` per call cannot cause a loop.
 *
 * The third argument is the server/non-DOM snapshot. It returns `false`, which
 * means "not compact" -- the roomier layout. That is the safer default: a view
 * that briefly shows too few items is a smaller error than one that overflows
 * its box. The guards on `window` exist for the same reason, since the test
 * environment is `node`.
 */

import { useCallback, useSyncExternalStore } from 'react';

export function useMediaQuery(query: string): boolean {
  const subscribe = useCallback(
    (onStoreChange: () => void) => {
      if (typeof window === 'undefined' || typeof window.matchMedia !== 'function') {
        return () => {};
      }
      const mql = window.matchMedia(query);
      mql.addEventListener('change', onStoreChange);
      return () => mql.removeEventListener('change', onStoreChange);
    },
    [query],
  );

  const getSnapshot = useCallback(() => {
    if (typeof window === 'undefined' || typeof window.matchMedia !== 'function') {
      return false;
    }
    return window.matchMedia(query).matches;
  }, [query]);

  return useSyncExternalStore(subscribe, getSnapshot, () => false);
}
