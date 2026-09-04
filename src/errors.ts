/**
 * Domain errors shared across layers (repository, hooks, UI).
 *
 * Co-located error classes (e.g. UnsupportedRRuleError in services/recurrence.ts)
 * stay next to their single owner; these cross layers — a repository raises
 * DuplicateExceptionError, a hook/guard raises SeriesEditBlockedError, the
 * timezone trio comes from either the database mapping or its TypeScript twin,
 * and the UI catches all of them — so they live in one shared module.
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

/**
 * Thrown when a time zone value is not one the database will store.
 *
 * Mirrors the DB's TIMEWEAVE_TZ_INVALID (migration 0008). USER-ACTIONABLE: the
 * browser reported a zone this server does not recognise, so the user has to
 * pick a different one — or the runtime could not report a zone at all, in
 * which case a timed recurrence cannot be created. Never resolved by falling
 * back to UTC: a guessed zone silently changes what a series means.
 */
export class InvalidTimezoneError extends Error {
  constructor(message = 'このタイムゾーンは使用できません。ブラウザの日付と時刻の設定をご確認ください') {
    super(message);
    this.name = 'InvalidTimezoneError';
  }
}

/**
 * Thrown when a timed recurring event would be stored without a time zone.
 *
 * Mirrors the DB's TIMEWEAVE_TZ_REQUIRED. Reaching this from the UI means a
 * create/convert path failed to supply one — an application bug, not something
 * the user can fix, so the message says only that the save failed.
 */
export class TimezoneRequiredError extends Error {
  constructor(message = '繰り返し予定のタイムゾーンを決定できなかったため、保存できませんでした') {
    super(message);
    this.name = 'TimezoneRequiredError';
  }
}

/**
 * Thrown when an update would remove the time zone of a timed recurring event.
 *
 * Mirrors the DB's TIMEWEAVE_TZ_CLEARED. Also an application bug: no UI offers
 * clearing a zone, and doing so would silently regress the series to
 * "unsupported" in Free/Busy.
 */
export class TimezoneClearedError extends Error {
  constructor(message = '繰り返し予定のタイムゾーンは解除できません') {
    super(message);
    this.name = 'TimezoneClearedError';
  }
}
