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
 * How long to wait, in words, for a rate-limit refusal that knows the answer.
 *
 * Seconds below a minute, rounded-up minutes above it. Zero is treated as "no
 * useful number", the same contract parseRetryAfterSeconds enforces: the
 * database only ever reports a positive wait when it refuses, so the parser
 * already turns a 0 into null. The guard stays here because the constructor is
 * public, and "約0秒後にお試しください" would read as a bug rather than as guidance.
 */
function retryAdvice(seconds: number | null): string {
  if (seconds === null || seconds <= 0) {
    return 'しばらく待ってからもう一度お試しください';
  }
  const label = seconds < 60 ? `${seconds}秒` : `${Math.ceil(seconds / 60)}分`;
  return `約${label}後にもう一度お試しください`;
}

/**
 * Thrown when writes were refused for arriving too fast.
 *
 * Mirrors the DB's TIMEWEAVE_RATE_EVENTS (migration 0012). USER-ACTIONABLE, and
 * temporary: the limiter refills continuously, so waiting is the whole remedy.
 * Nothing was written and nothing was charged -- a refused statement rolls back
 * its own consumption -- so the same save can simply be repeated later.
 *
 * `retryAfterSeconds` is whatever the database's HINT carried, or null when it
 * carried nothing usable. It is exposed as a field, not just baked into the
 * message, so a future UI can disable the save button for that long instead of
 * asking the user to count.
 *
 * DO NOT retry automatically on this error. The budget is not consumed by a
 * refusal, so an automatic retry costs the user nothing -- but it also achieves
 * nothing except hammering the same wall, and the whole point of the limit is
 * to stop a client from writing as fast as it can.
 */
export class WriteRateLimitedError extends Error {
  readonly retryAfterSeconds: number | null;

  constructor(retryAfterSeconds: number | null = null, message?: string) {
    super(
      message ??
        `保存が短時間に集中したため、一時的に制限しています。${retryAdvice(retryAfterSeconds)}`,
    );
    this.name = 'WriteRateLimitedError';
    this.retryAfterSeconds = retryAfterSeconds;
  }
}

/**
 * Thrown when an account is at its ceiling for stored events.
 *
 * Mirrors the DB's TIMEWEAVE_QUOTA_EVENTS (migration 0011). USER-ACTIONABLE:
 * 0011's quota is a delta rule, so an account at its ceiling can always still
 * edit and delete -- only growing is refused. That is why the advice to delete
 * something is always a route out, and never a dead end.
 *
 * The number itself is deliberately absent from this message. The database owns
 * it (`events_max_per_owner()`, granted to authenticated for exactly this
 * reason); repeating it here would create a second copy that can drift.
 */
export class EventQuotaExceededError extends Error {
  constructor(message = '保存できる予定の上限に達しました。不要な予定を削除してから、もう一度お試しください') {
    super(message);
    this.name = 'EventQuotaExceededError';
  }
}

/**
 * Thrown when one recurring series has reached its ceiling for per-occurrence
 * changes.
 *
 * Mirrors the DB's TIMEWEAVE_QUOTA_EXCEPTIONS (migration 0011). Cancellation
 * tombstones count towards it -- a "delete this occurrence" is an exception row
 * like any other -- so the way back under the limit is not always "delete an
 * override"; it may be re-shaping the series instead. The wording therefore asks
 * the user to tidy the per-occurrence changes rather than asserting that a
 * deletable one exists.
 */
export class ExceptionQuotaExceededError extends Error {
  constructor(message = 'この繰り返し予定の個別変更が上限に達しました。個別変更を整理してから、もう一度お試しください') {
    super(message);
    this.name = 'ExceptionQuotaExceededError';
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
