/**
 * Whether the viewport gets the mobile layout, kept in step with the viewport.
 *
 * A one-line wrapper on `useMediaQuery`, which is the part that matters: it
 * subscribes through `useSyncExternalStore` BEFORE reading, so the first paint
 * cannot disagree with the viewport and a change arriving during mount is not
 * missed. A rotation, a resize and a desktop window being dragged narrower all
 * reach the same `change` event on the MediaQueryList, so none of them needs
 * handling of its own.
 *
 * It exists as a named hook rather than `useMediaQuery(MOBILE_QUERY)` at each
 * call site so that the question being asked -- "is this the mobile layout" --
 * is the thing components read, and so the answer comes from one place when
 * P8-b2 adds the branch that depends on it.
 *
 * Outside a DOM it answers `false`: the desktop layout. That is the safer
 * default of the two, and the same one `useMediaQuery` documents.
 */

import { useMediaQuery } from './useMediaQuery';
import { MOBILE_QUERY } from '../utils/viewport';

export function useIsMobile(): boolean {
  return useMediaQuery(MOBILE_QUERY);
}
