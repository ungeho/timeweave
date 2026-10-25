/**
 * The two things every dialog in this app owes its reader: Escape closes it,
 * and the page behind it does not scroll.
 *
 * P8-b3 wrote this inline in EventDialog. P8-b4 needs the same in the share
 * and settings dialogs, and a third copy is where the three would start to
 * disagree -- the lock in particular, because getting its RESTORE wrong is
 * invisible until two dialogs overlap.
 *
 * WHY THE RESTORE READS THE PREVIOUS VALUE rather than clearing. Two dialogs
 * can be open at once (the day agenda opens the event form over itself), and
 * both run this. The inner one records the 'hidden' the outer one set and
 * puts it back on unmount, so the page stays locked while the outer dialog is
 * still there. Clearing to '' instead would unlock the page underneath a
 * dialog that is still open, and only in the nested case -- the one nobody
 * tests by hand.
 *
 * It does NOT trap focus. That needs a container ref, a tabbable query and a
 * decision about where focus returns, and getting it half right is worse than
 * leaving the browser's own behaviour alone; it is recorded as unverified
 * rather than implemented blind.
 */

import { useEffect } from 'react';

/**
 * @param onClose  what Escape should do.
 * @param blocked  when true, Escape does nothing -- a save or delete is in
 *                 flight and closing would abandon a request whose result the
 *                 reader still needs to see. The lock stays either way.
 */
export function useDialogChrome(onClose: () => void, blocked?: () => boolean): void {
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape' && !blocked?.()) onClose();
    };
    document.addEventListener('keydown', onKey);
    const previous = document.body.style.overflow;
    document.body.style.overflow = 'hidden';
    return () => {
      document.removeEventListener('keydown', onKey);
      document.body.style.overflow = previous;
    };
    // `blocked` is read through a ref-backed closure at call sites, so it is
    // deliberately not a dependency: re-running this would release and retake
    // the lock on every render that changed it.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [onClose]);
}
