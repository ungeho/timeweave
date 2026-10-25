/**
 * Horizontal swipe on the phone calendar (P8-mobile-1, M4).
 *
 *   list   swipe left -> next day,   right -> previous day
 *   month  swipe left -> next month, right -> previous month
 *
 * WHY POINTER EVENTS WITH touch-action: pan-y. The swipe area declares
 * `touch-action: pan-y pinch-zoom`, so the BROWSER keeps vertical scrolling
 * and pinch-zoom, and only a horizontal drag reaches the page as pointer
 * moves. When the browser takes a gesture for scrolling it sends
 * pointercancel, which drops the swipe -- so a vertical scroll can never turn
 * into a page change. No library, no preventDefault on touchmove (that would
 * need a non-passive listener and costs scroll smoothness).
 *
 * Touch only: a mouse drag on a narrow desktop window selects text, as it
 * always did. One gesture is one step, decided on pointerup; the click a
 * browser may still deliver after a recognised swipe is swallowed, so a card
 * or a date under the finger is not opened by accident.
 */
import { useEffect, useRef } from 'react';

export type SwipeDirection = 'left' | 'right';

/** Minimum horizontal travel, in CSS px. */
export const SWIPE_MIN_DX = 56;
/** |dx| must be at least this many times |dy|: clearly horizontal. */
export const SWIPE_RATIO = 2;
/** Slower than this is a drag, not a swipe. */
export const SWIPE_MAX_MS = 800;

/** The decision, pure: a recognised swipe, or null. */
export function classifySwipe(dx: number, dy: number, ms: number): SwipeDirection | null {
  if (!(ms >= 0) || ms > SWIPE_MAX_MS) return null;
  if (Math.abs(dx) < SWIPE_MIN_DX) return null;
  if (Math.abs(dx) < SWIPE_RATIO * Math.abs(dy)) return null;
  return dx < 0 ? 'left' : 'right';
}

/**
 * Attach to the element that should respond. `onSwipe` may change between
 * renders; the listeners are installed once.
 */
export function useHorizontalSwipe<T extends HTMLElement>(onSwipe: (dir: SwipeDirection) => void) {
  const ref = useRef<T>(null);
  const handler = useRef(onSwipe);
  handler.current = onSwipe;

  useEffect(() => {
    const el = ref.current;
    if (!el) return;
    let start: { id: number; x: number; y: number; t: number } | null = null;
    let swallowUntil = 0;

    const down = (e: PointerEvent) => {
      // A new touch is a new gesture: whatever click it produces is its own.
      // Without this, a quick tap right after a swipe was swallowed too
      // (measured: a card tapped ~0.4 s after a swipe did not open).
      swallowUntil = 0;
      if (e.pointerType !== 'touch' || !e.isPrimary) return;
      start = { id: e.pointerId, x: e.clientX, y: e.clientY, t: e.timeStamp };
    };
    const up = (e: PointerEvent) => {
      if (!start || e.pointerId !== start.id) return;
      const s = start;
      start = null;
      const dir = classifySwipe(e.clientX - s.x, e.clientY - s.y, e.timeStamp - s.t);
      if (!dir) return;
      // Only the click of THIS gesture, which follows pointerup at once.
      swallowUntil = e.timeStamp + 300;
      handler.current(dir);
    };
    const cancel = (e: PointerEvent) => {
      if (start && e.pointerId === start.id) start = null;
    };
    const click = (e: MouseEvent) => {
      if (e.timeStamp <= swallowUntil) {
        e.preventDefault();
        e.stopPropagation();
      }
    };

    el.addEventListener('pointerdown', down);
    el.addEventListener('pointerup', up);
    el.addEventListener('pointercancel', cancel);
    el.addEventListener('click', click, true);
    return () => {
      el.removeEventListener('pointerdown', down);
      el.removeEventListener('pointerup', up);
      el.removeEventListener('pointercancel', cancel);
      el.removeEventListener('click', click, true);
    };
  }, []);

  return ref;
}
