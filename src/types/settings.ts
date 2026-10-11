/**
 * Per-owner preferences (migration 0025).
 *
 * THE TWO FIELDS LOOK ALIKE AND ARE NOT. Keeping them apart is the whole point
 * of this file:
 *
 *   timezone  belongs to the OWNER and is READ BY SQL. It is what anchors an
 *             all-day event to real instants when anonymous Free/Busy has to
 *             subtract all-day Busy from timed Available. Changing it changes
 *             what a share link discloses.
 *   language  belongs to whoever is LOOKING and is read by nothing but the UI.
 *             It never reaches the Free/Busy computation -- 0025 declares the
 *             column and then never selects it, so that is structural rather
 *             than a convention.
 *
 * The anonymous share page follows neither of these for display: it has no
 * owner session, so its language comes from the browser. It does follow the
 * owner's `timezone` for MEANING, because an all-day event is the owner's
 * calendar day and not the viewer's.
 */

/** The languages the UI can be switched to. `null` means "follow the browser". */
export type UiLanguage = 'ja' | 'en';

export interface OwnerSettings {
  /**
   * IANA zone name, or null when the owner has not declared one.
   *
   * NULL IS A MEANINGFUL STATE, not a missing value to be defaulted. Guessing a
   * zone here would make anonymous Free/Busy disclose available time computed
   * against a day boundary the owner never agreed to, which is the one mistake
   * 0025 exists to prevent. Unset keeps 0024's behaviour: cross-model windows
   * answer `indeterminate` and disclose nothing.
   */
  timezone: string | null;
  /** null means the UI follows the browser's preference. */
  language: UiLanguage | null;
}
