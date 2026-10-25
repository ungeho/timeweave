/**
 * The current route, kept in step with the browser's history.
 *
 * WHAT THIS FIXES. `App` read `window.location.pathname` during render and
 * nothing re-rendered it, so the back and forward buttons moved the URL and
 * left the screen where it was. There was only one route to leave before, so
 * the omission never showed; it would show the moment documentation pages
 * exist and a reader navigates between them.
 *
 * NO DECISIONS LIVE HERE. The parsing is `parseRoute`'s, which is pure and
 * tested in this project's node environment; this file is the subscription and
 * nothing else -- the same split `LanguageProvider` uses, where every
 * judgement sits in `languageState.ts` and the component holds only state, one
 * effect and a context.
 *
 * `useSyncExternalStore` rather than an effect and a piece of state: the
 * location is external, already-existing state, and this is the hook that
 * exists for reading it without tearing during a concurrent render.
 */

import { useMemo, useSyncExternalStore } from 'react';
import { parseRoute, type Route } from './route';
import { subscribeToLocation } from './navigate';

// Both halves of "the location changed": the buttons the browser owns, and
// the pushes this app makes. `navigate` holds the second half, because
// pushState does NOT emit popstate for its own caller -- a link that pushed
// would otherwise move the address bar and leave the screen behind.
const subscribe = subscribeToLocation;

/** The pathname, as the store's snapshot. Compared by value, so it is stable. */
function getPathname(): string {
  return window.location.pathname;
}

/** Server-side/prerender snapshot. Nothing renders this app without a DOM today. */
function getServerPathname(): string {
  return '/';
}

export function useRoute(): Route {
  const pathname = useSyncExternalStore(subscribe, getPathname, getServerPathname);
  // Parsed from the snapshot rather than stored: `parseRoute` is pure, so the
  // result is a function of the pathname and cannot drift from it.
  return useMemo(() => parseRoute(pathname), [pathname]);
}
