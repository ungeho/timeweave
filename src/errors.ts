/**
 * Domain errors shared across layers (repository, hooks, UI).
 *
 * Co-located error classes (e.g. UnsupportedRRuleError in services/recurrence.ts)
 * stay next to their single owner; these two cross layers — a repository raises
 * DuplicateExceptionError, a hook/guard raises SeriesEditBlockedError, and the UI
 * catches both — so they live in one shared module.
 */

/**
 * Thrown when creating an exception row would collide with an existing exception
 * for the SAME master occurrence (DB partial unique index -> SQLSTATE 23505).
 * The occurrence already has an override/cancellation.
 */
export class DuplicateExceptionError extends Error {
  constructor(message = 'この繰り返し予定の回には、すでに個別の変更が存在します') {
    super(message);
    this.name = 'DuplicateExceptionError';
  }
}

/**
 * Thrown when an "edit all" is attempted on a series that already has exception
 * rows. Because exceptions are full snapshots (independent title/etc.), editing
 * the whole series would silently leave those exceptions stale, so it is blocked.
 * "Delete all", and "this occurrence only", remain allowed.
 */
export class SeriesEditBlockedError extends Error {
  constructor(message = '個別に変更した回があるため、繰り返し全体の変更はできません') {
    super(message);
    this.name = 'SeriesEditBlockedError';
  }
}
