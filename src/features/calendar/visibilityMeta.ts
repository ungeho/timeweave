/**
 * Presentation metadata for event visibility. Kept separate so labels/aria are
 * defined once. Icons are rendered as inline SVG in the UI (not emoji) to avoid
 * cross-OS rendering differences, and text labels ensure the distinction never
 * relies on color alone.
 */

import type { Visibility } from '../../types/event';

export interface VisibilityMeta {
  /** Full label, e.g. for menus/aria. */
  label: string;
  /** Short label for compact chips. */
  short: string;
}

export const visibilityMeta: Record<Visibility, VisibilityMeta> = {
  private: { label: '非公開', short: '非公開' },
  busy_only: { label: '予定あり（詳細非公開）', short: '予定あり' },
  public: { label: '公開', short: '公開' },
};
