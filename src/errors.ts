/**
 * Domain errors shared across layers (repository, hooks, UI).
 *
 * Co-located error classes (e.g. UnsupportedRRuleError in services/recurrence.ts)
 * stay next to their single owner; these cross layers — a repository raises
 * DuplicateExceptionError, a hook/guard raises SeriesEditBlockedError, the
 * timezone trio comes from either the database mapping or its TypeScript twin,
 * and the UI catches all of them — so they live in one shared module.
 *
 * CODE AND WORDING ARE SEPARATE (i18n P3). Each class carries a stable `code`
 * and the `messageKey` its wording lives under, and builds its default
 * `message` by rendering that key in Japanese. Three things are deliberately
 * unchanged by that:
 *
 *   `instanceof`  still how every call site identifies an error. The survey
 *                 before this change found exactly one such check outside
 *                 tests (freeBusyBanner) and none on `.name` or on the message
 *                 text, so no call site had to be rewritten.
 *   `.message`    still returns the same Japanese sentence, byte for byte, so
 *                 all ten `e instanceof Error ? e.message : String(e)` sites
 *                 keep working and the screen does not move.
 *   an explicit `message` argument still wins where a constructor took one.
 *
 * What the key BUYS is that P6 can render `t(err.messageKey, lang, …)` rather
 * than reading `.message`, without touching these classes again. `code` is for
 * anything that must name an error without caring how it reads.
 */

import { t } from './i18n/t';
import { ja as jaDict, type MessageKey } from './i18n/ja';
import { DEFAULT_LANGUAGE, type ExtractVars, type Language } from './i18n/types';

/** Stable identifiers, independent of wording and of language. */
export type ErrorCode =
  | 'DUPLICATE_EXCEPTION'
  | 'SERIES_EDIT_BLOCKED'
  | 'WRITE_RATE_LIMITED'
  | 'FREEBUSY_RATE_LIMITED'
  | 'SHARE_LINK_RATE_LIMITED'
  | 'SHARE_LINK_ACTIVE_QUOTA'
  | 'SHARE_LINK_TOTAL_QUOTA'
  | 'RECURRENCE_GRAPH'
  | 'EVENT_QUOTA'
  | 'EXCEPTION_QUOTA'
  | 'INVALID_TIMEZONE'
  | 'TIMEZONE_REQUIRED'
  | 'TIMEZONE_CLEARED'
  /**
   * The recurrence FORM's three validation refusals (P6 step 4).
   *
   * The code is registered here, with the others, because this union is the
   * registry of everything that can identify an error -- but the class itself
   * lives beside formToRule in features/event/recurrenceForm.ts. That is this
   * module's own rule, stated at the top: errors that cross layers live here,
   * errors with a single owner stay with it. formToRule is thrown from and
   * caught within features/event, so it is the second kind. Satisfying
   * `DomainError` is what makes the distinction free -- isDomainError and
   * localize() work on it exactly as they do on the classes below.
   */
  | 'RECURRENCE_FORM';

/**
 * What every domain error here exposes beyond `Error`.
 *
 * Declared as an interface the classes satisfy rather than a base class, so
 * `instanceof` keeps naming the specific error and a narrowing helper can ask
 * about the shape without a new inheritance level.
 */
export interface DomainError extends Error {
  readonly code: ErrorCode;
  readonly messageKey: MessageKey;
  /**
   * True when the thrower supplied its own wording.
   *
   * Three production call sites do (recurrenceOps twice, eventRepository
   * once), and an arbitrary string cannot be translated -- so `localize`
   * returns it unchanged rather than silently replacing it with the generic
   * sentence for the code.
   */
  readonly hasCustomMessage: boolean;
  /**
   * The message in any language. `.message` is exactly this in Japanese.
   *
   * THIS IS WHAT P6 CALLS. `t(err.messageKey, lang)` cannot be the display
   * path: the rate-limited keys need an {advice} variable the caller would
   * have to know to supply, FreeBusy's key is typed as the whole union so the
   * compiler cannot check it, and a custom message would be thrown away.
   * Each class knows all three answers about itself; the display site should
   * not have to.
   */
  localize(lang: Language): string;
}

/** Whether a caught value is one of this module's errors. */
export function isDomainError(e: unknown): e is DomainError {
  return e instanceof Error && typeof (e as Partial<DomainError>).code === 'string';
}

/**
 * The keys that take no variables.
 *
 * Narrowing the helper below to these is not tidiness: `t` demands exactly the
 * variables a key declares, and a helper typed over the whole key union would
 * have to demand the widest set from every caller. Restricting the input makes
 * the zero-argument call correct AND stops anyone passing a key like
 * `error.writeRateLimited`, whose `{advice}` would otherwise reach the screen
 * unfilled.
 */
type KeyWithoutVars = {
  [K in MessageKey]: [ExtractVars<(typeof jaDict)[K]>] extends [never] ? K : never;
}[MessageKey];

/** Render a variable-free key in Japanese -- the wording `.message` always had. */
const ja = (key: KeyWithoutVars): string => t(key, DEFAULT_LANGUAGE);

/**
 * Thrown when creating an exception row would collide with an existing exception
 * for the SAME master occurrence (DB partial unique index -> SQLSTATE 23505).
 * The occurrence already has an override/cancellation.
 */
export class DuplicateExceptionError extends Error {
  readonly code = 'DUPLICATE_EXCEPTION' as const;
  readonly messageKey = 'error.duplicateException' as const;

  readonly hasCustomMessage: boolean;

  constructor(message?: string) {
    super(message ?? ja('error.duplicateException'));
    this.name = 'DuplicateExceptionError';
    this.hasCustomMessage = message !== undefined;
  }

  localize(lang: Language): string {
    return this.hasCustomMessage ? this.message : t('error.duplicateException', lang);
  }
}

/**
 * Thrown when an "edit all" is attempted on a series that already has exception
 * rows. Because exceptions are full snapshots (independent title/etc.), editing
 * the whole series would silently leave those exceptions stale, so it is blocked.
 * "Delete all", and "this occurrence only", remain allowed.
 */
export type SeriesEditBlockedReason = 'editAll' | 'timezoneChange';

export class SeriesEditBlockedError extends Error {
  readonly code = 'SERIES_EDIT_BLOCKED' as const;
  readonly reason: SeriesEditBlockedReason;
  /**
   * Follows `reason`, not the class: changing the whole series and changing
   * only its zone read differently, and the zone one used to be passed in as
   * a Japanese string. `code` stays single, because for everything that
   * IDENTIFIES errors these are one refusal with two wordings -- the same
   * arrangement FreeBusyRateLimitedError's two kinds use.
   */
  readonly messageKey: MessageKey;

  readonly hasCustomMessage: boolean;

  constructor(message?: string, reason: SeriesEditBlockedReason = 'editAll') {
    super(
      message ??
        (reason === 'timezoneChange'
          ? ja('error.seriesTimezoneBlocked')
          : ja('error.seriesEditBlocked')),
    );
    this.name = 'SeriesEditBlockedError';
    this.reason = reason;
    this.messageKey =
      reason === 'timezoneChange' ? 'error.seriesTimezoneBlocked' : 'error.seriesEditBlocked';
    this.hasCustomMessage = message !== undefined;
  }

  /**
   * The series' ZONE cannot move because occurrences were changed one by one.
   *
   * A named constructor rather than a second positional argument, so the call
   * site reads as the rule it is enforcing and `message` keeps its place as
   * the first parameter -- every existing `new SeriesEditBlockedError(...)`
   * means exactly what it did before.
   */
  static timezoneChange(): SeriesEditBlockedError {
    return new SeriesEditBlockedError(undefined, 'timezoneChange');
  }

  localize(lang: Language): string {
    // The key is re-derived from `reason` rather than read from
    // `this.messageKey`, which is typed as the whole union and so cannot tell
    // `t` which variables it needs. Deriving it keeps the call literal.
    if (this.hasCustomMessage) return this.message;
    return this.reason === 'timezoneChange'
      ? t('error.seriesTimezoneBlocked', lang)
      : t('error.seriesEditBlocked', lang);
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
export function retryAdvice(seconds: number | null, lang = DEFAULT_LANGUAGE): string {
  if (seconds === null || seconds <= 0) {
    return t('error.retry.wait', lang);
  }
  return seconds < 60
    ? t('error.retry.seconds', lang, { seconds })
    : t('error.retry.minutes', lang, { minutes: Math.ceil(seconds / 60) });
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
  readonly code = 'WRITE_RATE_LIMITED' as const;
  readonly messageKey = 'error.writeRateLimited' as const;
  readonly retryAfterSeconds: number | null;

  readonly hasCustomMessage: boolean;

  constructor(retryAfterSeconds: number | null = null, message?: string) {
    super(message ?? t('error.writeRateLimited', DEFAULT_LANGUAGE, { advice: retryAdvice(retryAfterSeconds) }));
    this.name = 'WriteRateLimitedError';
    this.retryAfterSeconds = retryAfterSeconds;
    this.hasCustomMessage = message !== undefined;
  }

  localize(lang: Language): string {
    return this.hasCustomMessage
      ? this.message
      : t('error.writeRateLimited', lang, { advice: retryAdvice(this.retryAfterSeconds, lang) });
  }
}

/**
 * Thrown when anonymous Free/Busy was refused for arriving too fast, or while
 * the same calendar was already being computed.
 *
 * Mirrors the DB's two 0019 markers, and only those:
 *   'rate'  TIMEWEAVE_RATE_FREEBUSY       the owner's or the link's GCRA budget
 *                                         is spent. The wait can be tens of
 *                                         seconds; the HINT carries it.
 *   'busy'  TIMEWEAVE_RATE_FREEBUSY_BUSY  every one of the owner's concurrency
 *                                         slots (k, currently 2) was taken by
 *                                         computations already running. k lives
 *                                         in the database, so this number is
 *                                         not a promise the client can keep --
 *                                         nothing here depends on its value.
 *                                         Nothing is queued and the slots are
 *                                         released at commit, so this one
 *                                         clears in about a second -- which is
 *                                         exactly what 0019's HINT says.
 *
 * WHY 'rate' DOES NOT SAY WHICH BUCKET. 0019 raises the owner refusal and the
 * link refusal with the SAME detail marker; only their MESSAGE differs, and a
 * message is prose this codebase never parses. Telling an anonymous viewer
 * "the owner's budget is spent" would also disclose that OTHER share links of
 * the same calendar are being used, which the share page must never reveal. So
 * the two stay one kind on purpose, and separating them would be a database
 * change, not a client one.
 *
 * USER-ACTIONABLE and temporary in both kinds: waiting is the whole remedy, and
 * a refusal charges nothing (0019 charges at the end of a successful call), so
 * the same view can simply be re-requested later.
 *
 * DO NOT retry automatically. A refusal costs the viewer no budget, but an
 * automatic retry achieves nothing except hammering the same wall -- and for
 * 'busy' it would spend the slot the running computations need to finish.
 */
export class FreeBusyRateLimitedError extends Error {
  readonly code = 'FREEBUSY_RATE_LIMITED' as const;
  readonly kind: 'rate' | 'busy';
  readonly retryAfterSeconds: number | null;
  /**
   * The two kinds read differently, so the key follows `kind` rather than the
   * class. `code` stays single, because for everything that identifies errors
   * these remain one failure with two wordings -- which is also why 0019
   * raises both with the same DETAIL marker.
   */
  readonly messageKey: MessageKey;
  readonly hasCustomMessage: boolean;

  constructor(
    kind: 'rate' | 'busy',
    retryAfterSeconds: number | null = null,
    message?: string,
  ) {
    const key: MessageKey =
      kind === 'busy' ? 'error.freeBusyBusy' : 'error.freeBusyRateLimited';
    super(message ?? t(key, DEFAULT_LANGUAGE, { advice: retryAdvice(retryAfterSeconds) }));
    this.messageKey = key;
    this.name = 'FreeBusyRateLimitedError';
    this.hasCustomMessage = message !== undefined;
    this.kind = kind;
    this.retryAfterSeconds = retryAfterSeconds;
  }

  localize(lang: Language): string {
    // The key is re-derived from `kind` rather than read from `this.messageKey`,
    // which is typed as the whole MessageKey union and so cannot tell `t` which
    // variables it needs. Deriving it here keeps the call literal and checked.
    return this.hasCustomMessage
      ? this.message
      : this.kind === 'busy'
        ? t('error.freeBusyBusy', lang, { advice: retryAdvice(this.retryAfterSeconds, lang) })
        : t('error.freeBusyRateLimited', lang, { advice: retryAdvice(this.retryAfterSeconds, lang) });
  }
}

/**
 * Thrown when share links were refused for being created too fast.
 *
 * Mirrors the DB's TIMEWEAVE_RATE_SHARE_LINKS (migration 0016), which reuses
 * 0012's limiter keyed to its own state table. USER-ACTIONABLE and temporary:
 * the bucket refills continuously, and a refused INSERT rolls its own charge
 * back, so the same creation can simply be repeated later.
 *
 * `retryAfterSeconds` is whatever the database's HINT carried, or null when it
 * carried nothing usable -- the same best-effort contract the write and
 * Free/Busy limiters use.
 *
 * DO NOT retry automatically: a refusal costs the owner no budget, but retrying
 * on their behalf only hammers the same wall.
 */
export class ShareLinkRateLimitedError extends Error {
  readonly code = 'SHARE_LINK_RATE_LIMITED' as const;
  readonly messageKey = 'error.shareLinkRateLimited' as const;
  readonly retryAfterSeconds: number | null;

  readonly hasCustomMessage: boolean;

  constructor(retryAfterSeconds: number | null = null, message?: string) {
    super(message ?? t('error.shareLinkRateLimited', DEFAULT_LANGUAGE, { advice: retryAdvice(retryAfterSeconds) }));
    this.name = 'ShareLinkRateLimitedError';
    this.retryAfterSeconds = retryAfterSeconds;
    this.hasCustomMessage = message !== undefined;
  }

  localize(lang: Language): string {
    return this.hasCustomMessage
      ? this.message
      : t('error.shareLinkRateLimited', lang, { advice: retryAdvice(this.retryAfterSeconds, lang) });
  }
}

/**
 * Thrown when an account already holds as many ACTIVE share links as it may.
 *
 * Mirrors the DB's TIMEWEAVE_QUOTA_SHARE_LINKS_ACTIVE (migration 0016).
 * USER-ACTIONABLE: 0016's quota is a delta rule, so an owner at the ceiling can
 * still revoke -- and revoking is exactly what frees an active slot, which is
 * why this message can name a remedy the UI actually offers.
 *
 * The ceiling itself is deliberately absent from the message: the database owns
 * it (share_links_max_active_per_owner()), and repeating the number here would
 * create a second copy that can drift.
 */
export class ShareLinkActiveQuotaExceededError extends Error {
  readonly code = 'SHARE_LINK_ACTIVE_QUOTA' as const;
  readonly messageKey = 'error.shareLinkActiveQuota' as const;

  readonly hasCustomMessage: boolean;

  constructor(message?: string) {
    super(message ?? ja('error.shareLinkActiveQuota'));
    this.name = 'ShareLinkActiveQuotaExceededError';
    this.hasCustomMessage = message !== undefined;
  }

  localize(lang: Language): string {
    return this.hasCustomMessage ? this.message : t('error.shareLinkActiveQuota', lang);
  }
}

/**
 * Thrown when an account holds as many share links IN TOTAL as it may, counting
 * revoked ones.
 *
 * Mirrors the DB's TIMEWEAVE_QUOTA_SHARE_LINKS_TOTAL (migration 0016), whose
 * HINT reads "Delete revoked share links to free capacity; revoking alone does
 * not." The message now says the same thing, because ShareDialog offers that
 * delete (0015's delete_share_link) and the owner can act on the advice.
 *
 * It names BOTH steps on purpose. Deleting is what frees a slot, but 0015 only
 * deletes an already-revoked row, so an owner whose links are all still active
 * has nothing to delete yet and would read "delete one" as advice that does not
 * apply to them. It also keeps saying what will NOT work, because "just revoke
 * one" is the obvious wrong guess and costs a link.
 *
 * The ceiling stays out of the text: the database owns it
 * (share_links_max_total_per_owner()), and a copy here could drift.
 */
export class ShareLinkTotalQuotaExceededError extends Error {
  readonly code = 'SHARE_LINK_TOTAL_QUOTA' as const;
  readonly messageKey = 'error.shareLinkTotalQuota' as const;

  readonly hasCustomMessage: boolean;

  constructor(message?: string) {
    super(message ?? ja('error.shareLinkTotalQuota'));
    this.name = 'ShareLinkTotalQuotaExceededError';
    this.hasCustomMessage = message !== undefined;
  }

  localize(lang: Language): string {
    return this.hasCustomMessage ? this.message : t('error.shareLinkTotalQuota', lang);
  }
}

/**
 * Thrown when a write would break the recurrence graph: an exception row that
 * does not belong to a recurring master of the same all-day kind, or a master
 * with exceptions that would stop being one.
 *
 * Mirrors the DB's TIMEWEAVE_RECURRENCE_GRAPH (migration 0017). Reaching this
 * from the UI means a guard did not hold -- seriesGuards already blocks the
 * "edit all" that could produce it -- so it is an application bug, not
 * something the user can fix. The message therefore says only that the save
 * failed: naming the graph, the master or the exception count would expose
 * internals without giving the user anything to act on.
 */
export class RecurrenceGraphViolationError extends Error {
  readonly code = 'RECURRENCE_GRAPH' as const;
  readonly messageKey = 'error.recurrenceGraph' as const;

  readonly hasCustomMessage: boolean;

  constructor(message?: string) {
    super(message ?? ja('error.recurrenceGraph'));
    this.name = 'RecurrenceGraphViolationError';
    this.hasCustomMessage = message !== undefined;
  }

  localize(lang: Language): string {
    return this.hasCustomMessage ? this.message : t('error.recurrenceGraph', lang);
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
  readonly code = 'EVENT_QUOTA' as const;
  readonly messageKey = 'error.eventQuota' as const;

  readonly hasCustomMessage: boolean;

  constructor(message?: string) {
    super(message ?? ja('error.eventQuota'));
    this.name = 'EventQuotaExceededError';
    this.hasCustomMessage = message !== undefined;
  }

  localize(lang: Language): string {
    return this.hasCustomMessage ? this.message : t('error.eventQuota', lang);
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
  readonly code = 'EXCEPTION_QUOTA' as const;
  readonly messageKey = 'error.exceptionQuota' as const;

  readonly hasCustomMessage: boolean;

  constructor(message?: string) {
    super(message ?? ja('error.exceptionQuota'));
    this.name = 'ExceptionQuotaExceededError';
    this.hasCustomMessage = message !== undefined;
  }

  localize(lang: Language): string {
    return this.hasCustomMessage ? this.message : t('error.exceptionQuota', lang);
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
export type InvalidTimezoneReason = 'unsupported' | 'timedRecurrenceOnly';

export class InvalidTimezoneError extends Error {
  readonly code = 'INVALID_TIMEZONE' as const;
  /**
   * 'unsupported'          the zone itself is not one the database will store
   *                        (the DB's TIMEWEAVE_TZ_INVALID).
   * 'timedRecurrenceOnly'  the zone is fine but the ROW may not hold one: only
   *                        a timed recurring master can. Raised from two
   *                        places with the identical sentence, which is why
   *                        both now share one key.
   */
  readonly reason: InvalidTimezoneReason;
  /** Follows `reason`; `code` stays single. See SeriesEditBlockedError. */
  readonly messageKey: MessageKey;

  readonly hasCustomMessage: boolean;

  constructor(message?: string, reason: InvalidTimezoneReason = 'unsupported') {
    super(
      message ??
        (reason === 'timedRecurrenceOnly'
          ? ja('error.timezonePlacement')
          : ja('error.invalidTimezone')),
    );
    this.name = 'InvalidTimezoneError';
    this.reason = reason;
    this.messageKey =
      reason === 'timedRecurrenceOnly' ? 'error.timezonePlacement' : 'error.invalidTimezone';
    this.hasCustomMessage = message !== undefined;
  }

  /**
   * Only a TIMED RECURRING event may carry a zone.
   *
   * A named constructor, so `message` keeps its place as the first parameter
   * and every existing `new InvalidTimezoneError(...)` still means what it did.
   */
  static timedRecurrenceOnly(): InvalidTimezoneError {
    return new InvalidTimezoneError(undefined, 'timedRecurrenceOnly');
  }

  localize(lang: Language): string {
    if (this.hasCustomMessage) return this.message;
    return this.reason === 'timedRecurrenceOnly'
      ? t('error.timezonePlacement', lang)
      : t('error.invalidTimezone', lang);
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
  readonly code = 'TIMEZONE_REQUIRED' as const;
  readonly messageKey = 'error.timezoneRequired' as const;

  readonly hasCustomMessage: boolean;

  constructor(message?: string) {
    super(message ?? ja('error.timezoneRequired'));
    this.name = 'TimezoneRequiredError';
    this.hasCustomMessage = message !== undefined;
  }

  localize(lang: Language): string {
    return this.hasCustomMessage ? this.message : t('error.timezoneRequired', lang);
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
  readonly code = 'TIMEZONE_CLEARED' as const;
  readonly messageKey = 'error.timezoneCleared' as const;

  readonly hasCustomMessage: boolean;

  constructor(message?: string) {
    super(message ?? ja('error.timezoneCleared'));
    this.name = 'TimezoneClearedError';
    this.hasCustomMessage = message !== undefined;
  }

  localize(lang: Language): string {
    return this.hasCustomMessage ? this.message : t('error.timezoneCleared', lang);
  }
}
