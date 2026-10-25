import { useEffect, useId, useRef, useState } from 'react';
import { useTranslate } from '../../i18n/useLanguage';

/**
 * The mobile header's menu.
 *
 * A DISCLOSURE, NOT A role="menu". The difference matters: role="menu" is the
 * desktop-application widget, and taking it on means owing the arrow-key
 * model that goes with it -- Up/Down to move, Home/End, typeahead, and a
 * focus ring that lives on the widget rather than on its items. None of that
 * is what this is. These are three ordinary controls that happen to be behind
 * a button, so they stay ordinary controls: a button with aria-expanded, a
 * <nav> it points at, and Tab moving through what is inside. Assistive
 * technology gets a truthful description of a thing that is simple, instead
 * of a promise of keyboard behaviour that is not implemented.
 *
 * WHAT IT OWES ANYWAY, because a disclosure that opens over the page still
 * has to behave: Escape closes it and puts focus back on the trigger, a click
 * outside closes it, choosing an item closes it, and opening it moves focus
 * inside so a keyboard reader does not have to guess where it went.
 */

export type HeaderMenuItem = {
  /** Stable key, also used for the test id. */
  id: string;
  label: string;
  /** A link leaves the application; a button acts inside it. Exactly one. */
  href?: string;
  onSelect?: () => void;
};

export function HeaderMenu({ items }: { items: HeaderMenuItem[] }) {
  const tr = useTranslate();
  const [open, setOpen] = useState(false);
  const panelId = useId();
  const triggerRef = useRef<HTMLButtonElement>(null);
  const panelRef = useRef<HTMLDivElement>(null);
  const firstItemRef = useRef<HTMLAnchorElement | HTMLButtonElement>(null);

  /*
    Opening moves focus to the first item; closing puts it back on the
    trigger. The second half is the one that is easy to forget and the one a
    keyboard reader actually notices -- without it, Escape drops focus onto
    <body> and the next Tab starts from the top of the document.
  */
  useEffect(() => {
    if (open) firstItemRef.current?.focus();
  }, [open]);

  const close = (restoreFocus: boolean) => {
    setOpen(false);
    if (restoreFocus) triggerRef.current?.focus();
  };

  useEffect(() => {
    if (!open) return;
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') {
        e.stopPropagation();
        close(true);
      }
    };
    const onPointerDown = (e: PointerEvent) => {
      const t = e.target as Node;
      // The trigger has its own handler; closing here too would close and
      // reopen in one press.
      if (panelRef.current?.contains(t) || triggerRef.current?.contains(t)) return;
      close(false);
    };
    document.addEventListener('keydown', onKey);
    document.addEventListener('pointerdown', onPointerDown);
    return () => {
      document.removeEventListener('keydown', onKey);
      document.removeEventListener('pointerdown', onPointerDown);
    };
  }, [open]);

  return (
    <div className="header-menu">
      <button
        ref={triggerRef}
        className="btn icon header-menu-trigger"
        aria-expanded={open}
        aria-controls={panelId}
        aria-label={tr('app.menu')}
        onClick={() => setOpen((v) => !v)}
      >
        {/* The glyph is decorative: aria-label above is what is announced. */}
        <span aria-hidden="true">☰</span>
      </button>

      {open && (
        <div className="header-menu-panel" id={panelId} ref={panelRef}>
          <nav aria-label={tr('app.menu')}>
            {items.map((item, i) => {
              const ref = i === 0 ? (firstItemRef as never) : undefined;
              return item.href ? (
                <a
                  key={item.id}
                  ref={ref}
                  className="header-menu-item"
                  href={item.href}
                  data-item={item.id}
                  // A link navigates away, so there is nothing to restore
                  // focus to; closing keeps the state clean if the navigation
                  // is cancelled or the page is restored from history.
                  onClick={() => close(false)}
                >
                  {item.label}
                </a>
              ) : (
                <button
                  key={item.id}
                  ref={ref}
                  className="header-menu-item"
                  data-item={item.id}
                  onClick={() => {
                    // Close FIRST: the action may unmount this whole header
                    // (signing out does), and setting state afterwards would
                    // be setting it on something gone.
                    close(false);
                    item.onSelect?.();
                  }}
                >
                  {item.label}
                </button>
              );
            })}
          </nav>
        </div>
      )}
    </div>
  );
}
