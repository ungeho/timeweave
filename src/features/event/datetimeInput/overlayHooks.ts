import { useEffect, useLayoutEffect, useState, type KeyboardEvent, type RefObject } from 'react';

/**
 * The picker overlays (calendar, clock) open ON TOP of the event dialog or
 * sheet, which already holds the page's scroll lock and Escape handling
 * (useDialogChrome). These hooks add only what an overlay needs on its own.
 */

/**
 * Put focus back on whatever opened the overlay when it closes.
 *
 * A LAYOUT effect, and called before the overlay's own focusing effect.
 * MEASURED: as a passive effect it ran after the clock's layout effect had
 * already moved focus onto the dial, so it "remembered" the dial -- an element
 * about to be removed -- and closing the clock left focus nowhere.
 */
export function useReturnFocus(): void {
  useLayoutEffect(() => {
    const opener = document.activeElement as HTMLElement | null;
    return () => opener?.focus?.();
  }, []);
}

/**
 * The VISUAL viewport's box: what is actually visible above a soft keyboard.
 * A bottom sheet positioned against the layout viewport would sit under the
 * keyboard. null where the API is missing; the overlay then falls back to the
 * layout viewport.
 */
export function useVisualViewportBox(enabled: boolean): { top: number; height: number } | null {
  const [box, setBox] = useState<{ top: number; height: number } | null>(null);
  useEffect(() => {
    const v = typeof window === 'undefined' ? undefined : window.visualViewport;
    if (!enabled || !v) return;
    const update = () => setBox({ top: v.offsetTop, height: v.height });
    update();
    v.addEventListener('resize', update);
    v.addEventListener('scroll', update);
    return () => {
      v.removeEventListener('resize', update);
      v.removeEventListener('scroll', update);
    };
  }, [enabled]);
  return box;
}

/**
 * Escape closes the overlay (and only the overlay: the dialog underneath must
 * not also close), and Tab cycles inside it.
 */
export function overlayKeyHandler(panel: RefObject<HTMLElement | null>, onEscape: () => void) {
  return (e: KeyboardEvent<HTMLElement>) => {
    if (e.key === 'Escape') {
      e.preventDefault();
      e.stopPropagation();
      e.nativeEvent.stopImmediatePropagation();
      onEscape();
      return;
    }
    if (e.key !== 'Tab' || !panel.current) return;
    const items = [...panel.current.querySelectorAll<HTMLElement>('button:not([disabled]), input, [tabindex="0"]')].filter(
      (el) => el.tabIndex !== -1,
    );
    if (items.length === 0) return;
    const first = items[0]!;
    const last = items[items.length - 1]!;
    if (e.shiftKey && document.activeElement === first) {
      e.preventDefault();
      last.focus();
    } else if (!e.shiftKey && document.activeElement === last) {
      e.preventDefault();
      first.focus();
    }
  };
}
