import { describe, expect, it } from 'vitest';
import {
  DuplicateExceptionError,
  EventQuotaExceededError,
  ExceptionQuotaExceededError,
  FreeBusyRateLimitedError,
  InvalidTimezoneError,
  RecurrenceGraphViolationError,
  SeriesEditBlockedError,
  ShareLinkActiveQuotaExceededError,
  ShareLinkRateLimitedError,
  ShareLinkTotalQuotaExceededError,
  TimezoneClearedError,
  TimezoneRequiredError,
  WriteRateLimitedError,
  isDomainError,
  retryAdvice,
  type DomainError,
} from './errors';
import { t } from './i18n/t';

/**
 * P3 step 1 moved the wording of these classes into the dictionary. The whole
 * claim of that step is that NOTHING ELSE CHANGED, so this file pins the three
 * things that could have.
 *
 * The Japanese strings below are copied from the classes as they stood BEFORE
 * the change -- written out in full rather than read from the dictionary,
 * because a test that asks the dictionary whether it matches the dictionary
 * proves nothing. These are the sentences users have been seeing.
 */

const BEFORE = {
  duplicateException: 'この繰り返し予定の回には、すでに個別の変更が存在します',
  seriesEditBlocked: '個別に変更した回があるため、繰り返し全体の変更はできません',
  shareLinkActiveQuota:
    '有効な共有リンクの数が上限に達しました。不要なリンクを失効させてから、もう一度お試しください',
  shareLinkTotalQuota:
    '共有リンクの総数が上限に達しました。失効済みのリンクを削除すると枠が空きます（失効させるだけでは総数は減りません）。失効済みがなければ、不要なリンクを先に失効させてください',
  recurrenceGraph: '予定を保存できませんでした。操作をやり直してください。',
  eventQuota: '保存できる予定の上限に達しました。不要な予定を削除してから、もう一度お試しください',
  exceptionQuota:
    'この繰り返し予定の個別変更が上限に達しました。個別変更を整理してから、もう一度お試しください',
  invalidTimezone: 'このタイムゾーンは使用できません。ブラウザの日付と時刻の設定をご確認ください',
  timezoneRequired: '繰り返し予定のタイムゾーンを決定できなかったため、保存できませんでした',
  timezoneCleared: '繰り返し予定のタイムゾーンは解除できません',
} as const;

describe('the Japanese message is byte-identical to before P3', () => {
  it('the simple errors', () => {
    expect(new DuplicateExceptionError().message).toBe(BEFORE.duplicateException);
    expect(new SeriesEditBlockedError().message).toBe(BEFORE.seriesEditBlocked);
    expect(new ShareLinkActiveQuotaExceededError().message).toBe(BEFORE.shareLinkActiveQuota);
    expect(new ShareLinkTotalQuotaExceededError().message).toBe(BEFORE.shareLinkTotalQuota);
    expect(new RecurrenceGraphViolationError().message).toBe(BEFORE.recurrenceGraph);
    expect(new EventQuotaExceededError().message).toBe(BEFORE.eventQuota);
    expect(new ExceptionQuotaExceededError().message).toBe(BEFORE.exceptionQuota);
    expect(new InvalidTimezoneError().message).toBe(BEFORE.invalidTimezone);
    expect(new TimezoneRequiredError().message).toBe(BEFORE.timezoneRequired);
    expect(new TimezoneClearedError().message).toBe(BEFORE.timezoneCleared);
  });

  it('the rate-limited errors, including the retry advice they embed', () => {
    expect(new WriteRateLimitedError(null).message).toBe(
      '保存が短時間に集中したため、一時的に制限しています。しばらく待ってからもう一度お試しください',
    );
    expect(new WriteRateLimitedError(7).message).toBe(
      '保存が短時間に集中したため、一時的に制限しています。約7秒後にもう一度お試しください',
    );
    expect(new WriteRateLimitedError(90).message).toBe(
      '保存が短時間に集中したため、一時的に制限しています。約2分後にもう一度お試しください',
    );
    expect(new ShareLinkRateLimitedError(30).message).toBe(
      '共有リンクの作成が短時間に集中したため、一時的に制限しています。約30秒後にもう一度お試しください',
    );
    expect(new FreeBusyRateLimitedError('rate', 12).message).toBe(
      '空き時間の取得が短時間に集中したため、一時的に制限しています。約12秒後にもう一度お試しください',
    );
    expect(new FreeBusyRateLimitedError('busy', 1).message).toBe(
      '空き時間の計算が混み合っています。約1秒後にもう一度お試しください',
    );
  });

  it('retryAdvice keeps its boundaries', () => {
    // 0 and negative mean "no useful number", 59 is still seconds, 60 rounds
    // to one minute, 61 rounds up to two.
    expect(retryAdvice(null)).toBe('しばらく待ってからもう一度お試しください');
    expect(retryAdvice(0)).toBe('しばらく待ってからもう一度お試しください');
    expect(retryAdvice(-5)).toBe('しばらく待ってからもう一度お試しください');
    expect(retryAdvice(59)).toBe('約59秒後にもう一度お試しください');
    expect(retryAdvice(60)).toBe('約1分後にもう一度お試しください');
    expect(retryAdvice(61)).toBe('約2分後にもう一度お試しください');
  });

  it('an explicit message still wins over the dictionary', () => {
    expect(new InvalidTimezoneError('独自の文言').message).toBe('独自の文言');
    expect(new WriteRateLimitedError(5, '独自の文言').message).toBe('独自の文言');
  });
});

describe('identification is unchanged', () => {
  it('instanceof still works, and still distinguishes the classes', () => {
    const e: unknown = new InvalidTimezoneError();
    expect(e instanceof InvalidTimezoneError).toBe(true);
    expect(e instanceof TimezoneRequiredError).toBe(false);
    expect(e instanceof Error).toBe(true);
  });

  it('name is unchanged', () => {
    expect(new DuplicateExceptionError().name).toBe('DuplicateExceptionError');
    expect(new FreeBusyRateLimitedError('busy').name).toBe('FreeBusyRateLimitedError');
  });

  it('the fields other code reads are unchanged', () => {
    expect(new WriteRateLimitedError(42).retryAfterSeconds).toBe(42);
    expect(new FreeBusyRateLimitedError('busy', 3).kind).toBe('busy');
    expect(new FreeBusyRateLimitedError('rate', 3).retryAfterSeconds).toBe(3);
  });
});

describe('the new code and key', () => {
  const all: DomainError[] = [
    new DuplicateExceptionError(),
    new SeriesEditBlockedError(),
    new WriteRateLimitedError(),
    new FreeBusyRateLimitedError('rate'),
    new ShareLinkRateLimitedError(),
    new ShareLinkActiveQuotaExceededError(),
    new ShareLinkTotalQuotaExceededError(),
    new RecurrenceGraphViolationError(),
    new EventQuotaExceededError(),
    new ExceptionQuotaExceededError(),
    new InvalidTimezoneError(),
    new TimezoneRequiredError(),
    new TimezoneClearedError(),
  ];

  it('every class carries a code and a key', () => {
    for (const e of all) {
      expect(typeof e.code).toBe('string');
      expect(e.code).not.toBe('');
      expect(typeof e.messageKey).toBe('string');
    }
  });

  it('codes are unique', () => {
    const codes = all.map((e) => e.code);
    expect(new Set(codes).size).toBe(codes.length);
  });

  it('the key renders the message the class reports', () => {
    // For the variable-free errors the two must agree exactly; this is what
    // lets P6 switch the display from `.message` to `t(key, lang)` without
    // changing a single Japanese sentence.
    const pairs: [DomainError, string][] = [
      [new DuplicateExceptionError(), BEFORE.duplicateException],
      [new EventQuotaExceededError(), BEFORE.eventQuota],
      [new InvalidTimezoneError(), BEFORE.invalidTimezone],
    ];
    for (const [e, expected] of pairs) {
      expect(e.message).toBe(expected);
      expect(t(e.messageKey as 'error.duplicateException', 'ja')).toBe(expected);
    }
  });

  it('FreeBusy picks its key from the kind, keeping one code', () => {
    const rate = new FreeBusyRateLimitedError('rate');
    const busy = new FreeBusyRateLimitedError('busy');
    expect(rate.code).toBe(busy.code);
    expect(rate.messageKey).not.toBe(busy.messageKey);
  });

  it('isDomainError recognises them and rejects anything else', () => {
    expect(isDomainError(new EventQuotaExceededError())).toBe(true);
    expect(isDomainError(new Error('plain'))).toBe(false);
    expect(isDomainError('string')).toBe(false);
    expect(isDomainError(null)).toBe(false);
  });
});

describe('the English wording is ready for P6', () => {
  it('fills the retry advice rather than leaving a placeholder', () => {
    const s = t('error.writeRateLimited', 'en', { advice: retryAdvice(7, 'en') });
    expect(s).not.toMatch(/\{advice\}/);
    // The unit is abbreviated so that "1 sec" and "45 sec" are both
    // correct without plural rules (P5 audit).
    expect(s).toMatch(/7 sec\b/);
  });

  it('formats seconds and minutes separately in English too', () => {
    expect(retryAdvice(30, 'en')).toMatch(/about 30 sec\b/);
    expect(retryAdvice(90, 'en')).toMatch(/about 2 min\b/);
    // The whole reason for the abbreviation: one is the ordinary output
    // of a 60-second window, and "about 1 minutes" would be wrong.
    expect(retryAdvice(60, 'en')).toBe('Please try again in about 1 min');
    expect(retryAdvice(1, 'en')).toBe('Please try again in about 1 sec');
    expect(retryAdvice(null, 'en')).toMatch(/wait a moment/i);
  });

  it('keeps the quota numbers out of the English copy too', () => {
    // The database owns the ceiling (events_max_per_owner()); a copy in a
    // message would drift. The Japanese already avoided naming it.
    expect(t('error.eventQuota', 'en')).not.toMatch(/\d/);
    expect(t('error.shareLinkActiveQuota', 'en')).not.toMatch(/\d/);
  });
});

/**
 * `localize` — the display path P6 will use.
 *
 * Added after measuring that `t(err.messageKey, lang)` cannot serve: the
 * rate-limited keys need an {advice} variable, FreeBusy's key is typed as the
 * whole union so the call does not compile, and a custom message would be
 * silently replaced by the generic sentence for its code. All three are
 * pinned below.
 */
describe('localize', () => {
  it('in Japanese it equals .message, for every class', () => {
    const all = [
      new DuplicateExceptionError(),
      new SeriesEditBlockedError(),
      new WriteRateLimitedError(7),
      new WriteRateLimitedError(null),
      new FreeBusyRateLimitedError('rate', 12),
      new FreeBusyRateLimitedError('busy', 1),
      new ShareLinkRateLimitedError(30),
      new ShareLinkActiveQuotaExceededError(),
      new ShareLinkTotalQuotaExceededError(),
      new RecurrenceGraphViolationError(),
      new EventQuotaExceededError(),
      new ExceptionQuotaExceededError(),
      new InvalidTimezoneError(),
      new TimezoneRequiredError(),
      new TimezoneClearedError(),
    ];
    for (const e of all) {
      expect(e.localize('ja'), `${e.name} must match its own message`).toBe(e.message);
    }
  });

  it('renders English, with the retry advice filled in', () => {
    const s = new WriteRateLimitedError(7).localize('en');
    expect(s).not.toMatch(/\{advice\}/);
    expect(s).toMatch(/7 sec\b/);
    expect(s).not.toMatch(/[ぁ-んァ-ヶ一-龯]/);
  });

  it('carries the seconds through, in both unit forms', () => {
    expect(new WriteRateLimitedError(45).localize('en')).toMatch(/45 sec\b/);
    expect(new WriteRateLimitedError(120).localize('en')).toMatch(/2 min\b/);
    expect(new WriteRateLimitedError(null).localize('en')).toMatch(/wait a moment/i);
  });

  it('keeps FreeBusy kind apart in English as well', () => {
    const rate = new FreeBusyRateLimitedError('rate', 5).localize('en');
    const busy = new FreeBusyRateLimitedError('busy', 5).localize('en');
    expect(rate).not.toBe(busy);
    // "is busy being calculated" put two meanings of `busy` five words
    // apart, in an app where Busy is an availability term (P5 audit).
    expect(busy).toMatch(/already being calculated/i);
    expect(busy).not.toMatch(/is busy/i);
    for (const s of [rate, busy]) expect(s).not.toMatch(/\{advice\}/);
  });

  it('returns a CUSTOM message unchanged, in every language', () => {
    // Three production sites supply their own wording. An arbitrary string
    // cannot be translated, and replacing it with the generic sentence would
    // lose the specific thing the thrower wanted to say.
    const e = new InvalidTimezoneError('タイムゾーンを持てるのは時刻ありの繰り返し予定だけです');
    expect(e.hasCustomMessage).toBe(true);
    expect(e.localize('ja')).toBe('タイムゾーンを持てるのは時刻ありの繰り返し予定だけです');
    expect(e.localize('en')).toBe('タイムゾーンを持てるのは時刻ありの繰り返し予定だけです');
  });

  it('marks the default-message case as not custom', () => {
    expect(new InvalidTimezoneError().hasCustomMessage).toBe(false);
    expect(new WriteRateLimitedError(5).hasCustomMessage).toBe(false);
  });

  it('every class produces a different string in English than in Japanese', () => {
    // A class whose localize ignored `lang` would pass every test above.
    for (const e of [
      new EventQuotaExceededError(),
      new InvalidTimezoneError(),
      new FreeBusyRateLimitedError('busy', 2),
      new WriteRateLimitedError(2),
    ]) {
      expect(e.localize('en')).not.toBe(e.localize('ja'));
    }
  });
});
