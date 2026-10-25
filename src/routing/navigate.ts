/**
 * Moving between screens without a reload.
 *
 * WHY THIS EXISTS SEPARATELY. `useRoute` reads the location through
 * `useSyncExternalStore` and subscribes to `popstate` -- which the browser
 * fires for the back and forward buttons but NOT for the caller of
 * `pushState`. So a link that pushed a URL would change the address bar and
 * leave the screen where it was: the exact bug `useRoute` was written to fix,
 * reintroduced from the other side. The push and the notification have to
 * happen together, and this is the one place that does both.
 *
 * NO ROUTE KNOWLEDGE LIVES HERE. It moves to a path; what that path means is
 * `parseRoute`'s answer, and it is re-derived from the location afterwards
 * rather than passed around -- so the URL and the screen cannot disagree.
 */

/** Everyone currently watching the location. */
const listeners = new Set<() => void>();

/**
 * Subscribe to every location change, however it happened.
 *
 * Covers both halves: `popstate` for the buttons the browser owns, and this
 * module's own set for the pushes the app makes.
 */
export function subscribeToLocation(onChange: () => void): () => void {
  listeners.add(onChange);
  window.addEventListener('popstate', onChange);
  return () => {
    listeners.delete(onChange);
    window.removeEventListener('popstate', onChange);
  };
}

function notify(): void {
  // Copied first: a listener that unsubscribes while being called would
  // otherwise mutate the set mid-iteration.
  for (const l of [...listeners]) l();
}

/**
 * Go to an in-app path.
 *
 * `replace` is for a URL the reader did not ask for -- normalising `/docs/x`
 * to `/ja/docs/x` so the link can be shared unambiguously. Pushing that would
 * put a URL in the history that nobody chose and that the back button would
 * have to step through.
 *
 * Only a root-relative path is accepted. An absolute URL here would be a way
 * to send a reader somewhere else entirely from what looks like in-app
 * navigation, and nothing in this app needs it.
 */
export function navigate(path: string, options?: { replace?: boolean }): void {
  if (!path.startsWith('/') || path.startsWith('//')) return;
  if (options?.replace) window.history.replaceState(null, '', path);
  else window.history.pushState(null, '', path);
  notify();
}

/**
 * Whether a click should be left to the browser.
 *
 * A modified click is the reader asking for a new tab or a download, and
 * intercepting it would take that away. A non-primary button likewise.
 */
export function isPlainLeftClick(e: {
  button: number;
  metaKey: boolean;
  ctrlKey: boolean;
  shiftKey: boolean;
  altKey: boolean;
  defaultPrevented: boolean;
}): boolean {
  return (
    !e.defaultPrevented &&
    e.button === 0 &&
    !e.metaKey &&
    !e.ctrlKey &&
    !e.shiftKey &&
    !e.altKey
  );
}
