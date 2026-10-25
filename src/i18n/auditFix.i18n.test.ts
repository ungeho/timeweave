import { describe, expect, it } from 'vitest';
import { t } from './t';
import { ja } from './ja';
import { en } from './en';
import {
  InvalidTimezoneError,
  SeriesEditBlockedError,
  isDomainError,
  type DomainError,
} from '../errors';
import {
  SHARE_LABEL_MAX,
  labelLengthError,
  shareLabelLength,
} from '../features/share/shareLinkLabel';

/**
 * The P3 audit's three findings, fixed.
 *
 *   shareLinkLabel.ts   a pure module P3 step 2's list had missed; its sibling
 *                       contentLimits.ts was migrated in that step.
 *   recurrenceOps.ts    two explicit Japanese error messages, and one more in
 *   eventRepository.ts  eventRepository. All three went in as a `message`
 *                       argument, which hasCustomMessage returns VERBATIM --
 *                       so they would still have been Japanese after P6.
 *
 * The claim, as in every step, is that NOTHING THE USER SEES CHANGED TODAY,
 * and the Japanese below is written out literally rather than read back from
 * the dictionary. What is new is that `localize('en')` now answers in English
 * for all three.
 */

/** The exact strings these three sites shipped before this change. */
const BEFORE = {
  labelTooLong: 'ラベルは50文字以内で入力してください',
  timezonePlacement: 'タイムゾーンを持てるのは時刻ありの繰り返し予定だけです',
  seriesTimezoneBlocked: '個別に変更した回があるため、繰り返しのタイムゾーンは変更できません',
} as const;

describe('WORK 1: the share label length rule', () => {
  it('the Japanese message is byte-identical, ceiling included', () => {
    const tooLong = 'あ'.repeat(SHARE_LABEL_MAX + 1);
    expect(labelLengthError(tooLong)).toBe(BEFORE.labelTooLong);
    // And the literal above really is the current ceiling, not a stale 50.
    expect(BEFORE.labelTooLong).toContain(String(SHARE_LABEL_MAX));
  });

  it('defaults to Japanese when no language is passed, as every caller does', () => {
    const tooLong = 'a'.repeat(SHARE_LABEL_MAX + 1);
    expect(labelLengthError(tooLong)).toMatch(/^ラベルは/);
  });

  it('renders English on request, with the number carried through', () => {
    const tooLong = 'a'.repeat(SHARE_LABEL_MAX + 1);
    const got = labelLengthError(tooLong, 'en');
    expect(got).toBe(`The label must be ${SHARE_LABEL_MAX} characters or fewer`);
    expect(got).not.toMatch(/\{max\}/);
    expect(got).not.toMatch(/[ぁ-んァ-ン一-龯]/);
  });

  it('the ceiling travels as a variable in BOTH languages', () => {
    // A hard-coded 50 in either sentence could drift from SHARE_LABEL_MAX.
    expect(ja['share.label.tooLong']).toMatch(/\{max\}/);
    expect(en['share.label.tooLong']).toMatch(/\{max\}/);
    expect(ja['share.label.tooLong']).not.toMatch(/\d/);
    expect(en['share.label.tooLong']).not.toMatch(/\d/);
  });

  it('the English says FEWER OR EQUAL, matching the inclusive limit', () => {
    // Exactly SHARE_LABEL_MAX is accepted. "under 50" or "less than 50" would
    // describe a different rule from the one the code enforces.
    expect(en['share.label.tooLong']).toMatch(/or fewer/i);
    expect(en['share.label.tooLong']).not.toMatch(/less than|under|up to \d/i);
  });
});

describe('WORK 1: the rule itself is untouched', () => {
  it('the ceiling is still 50 UTF-16 code units', () => {
    expect(SHARE_LABEL_MAX).toBe(50);
  });

  it('the limit is still INCLUSIVE', () => {
    expect(labelLengthError('a'.repeat(SHARE_LABEL_MAX))).toBeNull();
    expect(labelLengthError('a'.repeat(SHARE_LABEL_MAX + 1))).not.toBeNull();
  });

  it('it still measures the TRIMMED value', () => {
    // Trailing whitespace must never cost a character.
    expect(shareLabelLength('  ab  ')).toBe(2);
    expect(labelLengthError(' '.repeat(80) + 'a' + ' '.repeat(80))).toBeNull();
  });

  it('absent, empty and whitespace-only are all length 0 and all fit', () => {
    for (const v of [null, undefined, '', '   ']) {
      expect(shareLabelLength(v)).toBe(0);
      expect(labelLengthError(v)).toBeNull();
    }
  });

  it('a non-BMP character still costs two units', () => {
    // String.length, the same unit the HTML maxlength attribute enforces.
    expect(shareLabelLength('😀'.repeat(SHARE_LABEL_MAX / 2))).toBe(SHARE_LABEL_MAX);
    expect(labelLengthError('😀'.repeat(SHARE_LABEL_MAX / 2))).toBeNull();
    expect(labelLengthError('😀'.repeat(SHARE_LABEL_MAX / 2 + 1))).not.toBeNull();
  });

  it('the English never promises to shorten the label', () => {
    // An over-long label is refused and returned intact, never truncated.
    expect(en['share.label.tooLong']).not.toMatch(/truncat|shorten|will be cut/i);
  });
});

describe('WORK 2: the Japanese messages are byte-identical', () => {
  it('the placement rule, from both of its throw sites', () => {
    expect(InvalidTimezoneError.timedRecurrenceOnly().message).toBe(BEFORE.timezonePlacement);
  });

  it('the blocked series zone change', () => {
    expect(SeriesEditBlockedError.timezoneChange().message).toBe(BEFORE.seriesTimezoneBlocked);
  });

  it('the generic wordings are unchanged too', () => {
    // The default constructors must not have moved while the reasons were
    // being added beside them.
    expect(new InvalidTimezoneError().message).toBe(
      'このタイムゾーンは使用できません。ブラウザの日付と時刻の設定をご確認ください',
    );
    expect(new SeriesEditBlockedError().message).toBe(
      '個別に変更した回があるため、繰り返し全体の変更はできません',
    );
  });

  it('the two series wordings are different sentences', () => {
    // "the whole series cannot be edited" and "the series' ZONE cannot be
    // changed" are different refusals; one key for both would have lost that.
    expect(new SeriesEditBlockedError().message).not.toBe(
      SeriesEditBlockedError.timezoneChange().message,
    );
  });
});

describe('WORK 2: localize("en") now answers in English', () => {
  it('the placement rule', () => {
    const got = InvalidTimezoneError.timedRecurrenceOnly().localize('en');
    expect(got).toBe('Only a repeating event with a start and end time can carry a time zone');
    expect(got).not.toMatch(/[ぁ-んァ-ン一-龯]/);
  });

  it('the blocked series zone change', () => {
    const got = SeriesEditBlockedError.timezoneChange().localize('en');
    expect(got).toBe(
      'Some occurrences have been changed individually, so the time zone of the series cannot be changed',
    );
    expect(got).not.toMatch(/[ぁ-んァ-ン一-龯]/);
  });

  it('Japanese localize still equals .message, for both reasons of both classes', () => {
    const all = [
      new InvalidTimezoneError(),
      InvalidTimezoneError.timedRecurrenceOnly(),
      new SeriesEditBlockedError(),
      SeriesEditBlockedError.timezoneChange(),
    ];
    for (const e of all) expect(e.localize('ja')).toBe(e.message);
  });

  it('every one of the four produces a different string in English', () => {
    const all = [
      new InvalidTimezoneError(),
      InvalidTimezoneError.timedRecurrenceOnly(),
      new SeriesEditBlockedError(),
      SeriesEditBlockedError.timezoneChange(),
    ];
    for (const e of all) expect(e.localize('en')).not.toBe(e.message);
    expect(new Set(all.map((e) => e.localize('en'))).size).toBe(4);
  });
});

describe('WORK 2: the English keeps the meaning that matters', () => {
  it('the placement rule names BOTH conditions: a time, and repeating', () => {
    // Either half alone describes a different rule. An all-day recurring
    // master may not carry a zone, and neither may a one-off with a time.
    const s = en['error.timezonePlacement'];
    expect(s).toMatch(/repeating/i);
    expect(s).toMatch(/time/i);
  });

  it('neither new message offers a fallback zone', () => {
    // A guessed zone silently changes which instants a series occupies.
    for (const k of ['error.timezonePlacement', 'error.seriesTimezoneBlocked'] as const) {
      expect(en[k], k).not.toMatch(/\bUTC\b|\bGMT\b|default|assume|instead/i);
      expect(ja[k], k).not.toContain('UTC');
    }
  });

  it('the blocked message names the cause: occurrences changed one by one', () => {
    const s = en['error.seriesTimezoneBlocked'];
    expect(s).toMatch(/individually/i);
    expect(s).toMatch(/occurrence/i);
    // It is about the ZONE, not about editing the series as a whole.
    expect(s).toMatch(/time zone/i);
  });

  it('it is distinguishable from the generic series refusal in English too', () => {
    expect(en['error.seriesTimezoneBlocked']).not.toBe(en['error.seriesEditBlocked']);
    expect(en['error.seriesEditBlocked']).not.toMatch(/time zone/i);
  });

  it('the placement message is distinguishable from the unsupported-zone one', () => {
    // One says the ZONE is unusable; the other says the ROW may not hold one.
    expect(en['error.timezonePlacement']).not.toBe(en['error.invalidTimezone']);
    expect(en['error.invalidTimezone']).toMatch(/cannot be used/i);
    expect(en['error.timezonePlacement']).not.toMatch(/cannot be used/i);
  });

  it('one key serves both placement throw sites, since they said the same thing', () => {
    // recurrenceOps and eventRepository raised the identical sentence. Two
    // keys would have let the two drift apart in translation.
    const placementKeys = (Object.keys(ja) as string[]).filter(
      (k) => ja[k as keyof typeof ja] === BEFORE.timezonePlacement,
    );
    expect(placementKeys).toEqual(['error.timezonePlacement']);
  });
});

describe('WORK 2: the error contract is intact', () => {
  it('instanceof still identifies both classes, for both reasons', () => {
    expect(InvalidTimezoneError.timedRecurrenceOnly()).toBeInstanceOf(InvalidTimezoneError);
    expect(InvalidTimezoneError.timedRecurrenceOnly()).toBeInstanceOf(Error);
    expect(SeriesEditBlockedError.timezoneChange()).toBeInstanceOf(SeriesEditBlockedError);
    expect(SeriesEditBlockedError.timezoneChange()).toBeInstanceOf(Error);
    // And the two remain distinct from each other.
    expect(InvalidTimezoneError.timedRecurrenceOnly()).not.toBeInstanceOf(SeriesEditBlockedError);
  });

  it('name is unchanged, whichever reason built it', () => {
    expect(InvalidTimezoneError.timedRecurrenceOnly().name).toBe('InvalidTimezoneError');
    expect(SeriesEditBlockedError.timezoneChange().name).toBe('SeriesEditBlockedError');
  });

  it('code is unchanged -- one code per class, not one per wording', () => {
    // Everything that IDENTIFIES an error keeps seeing one failure. The same
    // arrangement FreeBusyRateLimitedError's two kinds use.
    expect(new InvalidTimezoneError().code).toBe('INVALID_TIMEZONE');
    expect(InvalidTimezoneError.timedRecurrenceOnly().code).toBe('INVALID_TIMEZONE');
    expect(new SeriesEditBlockedError().code).toBe('SERIES_EDIT_BLOCKED');
    expect(SeriesEditBlockedError.timezoneChange().code).toBe('SERIES_EDIT_BLOCKED');
  });

  it('messageKey follows the reason, and each key exists', () => {
    expect(new InvalidTimezoneError().messageKey).toBe('error.invalidTimezone');
    expect(InvalidTimezoneError.timedRecurrenceOnly().messageKey).toBe('error.timezonePlacement');
    expect(new SeriesEditBlockedError().messageKey).toBe('error.seriesEditBlocked');
    expect(SeriesEditBlockedError.timezoneChange().messageKey).toBe(
      'error.seriesTimezoneBlocked',
    );
    for (const e of [
      new InvalidTimezoneError(),
      InvalidTimezoneError.timedRecurrenceOnly(),
      new SeriesEditBlockedError(),
      SeriesEditBlockedError.timezoneChange(),
    ]) {
      expect(ja, e.messageKey).toHaveProperty(e.messageKey);
    }
  });

  it('messageKey renders the message the instance reports', () => {
    for (const e of [
      new InvalidTimezoneError(),
      InvalidTimezoneError.timedRecurrenceOnly(),
      new SeriesEditBlockedError(),
      SeriesEditBlockedError.timezoneChange(),
    ]) {
      expect(t(e.messageKey as 'error.invalidTimezone', 'ja')).toBe(e.message);
    }
  });

  it('reason is exposed, so a caller can branch without reading the text', () => {
    expect(new InvalidTimezoneError().reason).toBe('unsupported');
    expect(InvalidTimezoneError.timedRecurrenceOnly().reason).toBe('timedRecurrenceOnly');
    expect(new SeriesEditBlockedError().reason).toBe('editAll');
    expect(SeriesEditBlockedError.timezoneChange().reason).toBe('timezoneChange');
  });

  it('isDomainError still recognises them', () => {
    expect(isDomainError(InvalidTimezoneError.timedRecurrenceOnly())).toBe(true);
    expect(isDomainError(SeriesEditBlockedError.timezoneChange())).toBe(true);
  });

  it('they still satisfy the DomainError shape', () => {
    const e: DomainError = InvalidTimezoneError.timedRecurrenceOnly();
    expect(typeof e.code).toBe('string');
    expect(typeof e.messageKey).toBe('string');
    expect(typeof e.hasCustomMessage).toBe('boolean');
    expect(typeof e.localize('en')).toBe('string');
  });
});

describe('WORK 2: the custom-message behaviour is deliberately unchanged', () => {
  it('an explicit message still wins over the key, in every language', () => {
    const e = new InvalidTimezoneError('独自の文言');
    expect(e.message).toBe('独自の文言');
    expect(e.hasCustomMessage).toBe(true);
    expect(e.localize('ja')).toBe('独自の文言');
    expect(e.localize('en')).toBe('独自の文言');
  });

  it('an explicit message wins even when a reason is given', () => {
    // `message` keeps its place as the FIRST parameter, so nothing that
    // already passed one changed meaning.
    const e = new SeriesEditBlockedError('独自の文言', 'timezoneChange');
    expect(e.message).toBe('独自の文言');
    expect(e.localize('en')).toBe('独自の文言');
    // The reason is still recorded, and so is the key it would have used.
    expect(e.reason).toBe('timezoneChange');
    expect(e.messageKey).toBe('error.seriesTimezoneBlocked');
  });

  it('the three remediated sites are NOT custom-message sites any more', () => {
    for (const e of [
      InvalidTimezoneError.timedRecurrenceOnly(),
      SeriesEditBlockedError.timezoneChange(),
    ]) {
      expect(e.hasCustomMessage).toBe(false);
    }
  });
});
