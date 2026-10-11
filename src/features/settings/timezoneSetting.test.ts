import { describe, expect, it } from 'vitest';
import {
  LANGUAGES,
  LANGUAGE_NOT_IN_CALCULATION_NOTICE,
  LANGUAGE_PENDING_NOTICE,
  TIMEZONE_CHANGE_NOTICE,
  TIMEZONE_UNSET_NOTICE,
  browserTimezone,
  timezoneChangeNeedsWarning,
  timezoneOptions,
} from './timezoneSetting';

describe('timezoneOptions', () => {
  it('offers a non-empty list', () => {
    expect(timezoneOptions().length).toBeGreaterThan(0);
  });

  it('includes zones the project already uses', () => {
    const all = timezoneOptions();
    expect(all).toContain('Asia/Tokyo');
    expect(all).toContain('America/New_York');
  });

  it('offers IANA names, never fixed offsets', () => {
    // An offset like "+09:00" is not a zone: it has no DST rules, so an all-day
    // event anchored to one would drift against the owner's actual calendar
    // twice a year. 0008 refuses such values and this list must not suggest them.
    for (const z of timezoneOptions().slice(0, 200)) {
      expect(z).not.toMatch(/^[+-]\d/);
    }
  });
});

describe('browserTimezone', () => {
  it('returns something usable', () => {
    const tz = browserTimezone();
    expect(typeof tz).toBe('string');
    expect(tz).not.toBe('');
  });
});

/**
 * The warning gate. Getting this wrong in either direction is a real cost:
 * warning on every save trains the owner to click through it, and not warning
 * on a real change lets a live share link start disclosing different hours
 * with no notice at all.
 */
describe('timezoneChangeNeedsWarning', () => {
  it('warns when a zone is set for the FIRST time', () => {
    // The moment all-day events stop being uninterpretable and start being
    // disclosed -- exactly when the owner should be told.
    expect(timezoneChangeNeedsWarning(null, 'Asia/Tokyo')).toBe(true);
  });

  it('warns when the zone moves', () => {
    expect(timezoneChangeNeedsWarning('Asia/Tokyo', 'America/New_York')).toBe(true);
  });

  it('warns when the zone is CLEARED', () => {
    // Clearing re-hides available time on cross-model windows, which is also a
    // change in what the link discloses.
    expect(timezoneChangeNeedsWarning('Asia/Tokyo', null)).toBe(true);
  });

  it('does not warn when nothing changed', () => {
    expect(timezoneChangeNeedsWarning('Asia/Tokyo', 'Asia/Tokyo')).toBe(false);
    expect(timezoneChangeNeedsWarning(null, null)).toBe(false);
  });
});

describe('the notices', () => {
  it('the change notice says all-day events are reinterpreted', () => {
    expect(TIMEZONE_CHANGE_NOTICE.join('')).toContain('終日');
  });

  it('the change notice says anonymous sharing can change', () => {
    expect(TIMEZONE_CHANGE_NOTICE.join('')).toContain('匿名共有');
  });

  it('the change notice says TIMED events do NOT move', () => {
    // The correction an owner most needs: start_at is an absolute instant, so
    // a 09:00 meeting stays at that instant whatever the zone setting says.
    expect(TIMEZONE_CHANGE_NOTICE.join('')).toContain('変わりません');
  });

  it('the unset notice names the exact shape that fails', () => {
    // "sometimes it does not work" is what cost this project a long hunt once.
    const t = TIMEZONE_UNSET_NOTICE;
    expect(t).toContain('終日');
    expect(t).toContain('空き時間');
  });

  it('the unset notice frames hiding as the SAFE outcome, not a failure', () => {
    expect(TIMEZONE_UNSET_NOTICE).toContain('安全');
  });
});

describe('LANGUAGES', () => {
  it('offers exactly the two stored values', () => {
    expect(LANGUAGES.map((l) => l.value)).toEqual(['ja', 'en']);
  });

  it('labels each one in its own language', () => {
    expect(LANGUAGES.find((l) => l.value === 'ja')!.label).toBe('日本語');
    expect(LANGUAGES.find((l) => l.value === 'en')!.label).toBe('English');
  });

  it('carries nothing about time zones', () => {
    // The two settings are independent; a language option that mentioned a zone
    // would be the first step towards coupling them.
    for (const l of LANGUAGES) expect(l.label).not.toMatch(/UTC|GMT|\//);
  });
});

/**
 * The language control must not claim a feature that does not exist.
 *
 * The translation layer is a separate phase; today every string is Japanese.
 * A settings screen that says "the wording changes" and then does not change
 * it teaches the user that saving is broken, which is a worse outcome than
 * admitting the switch is not live.
 */
describe('the language notices', () => {
  it('says plainly that switching is NOT in effect yet', () => {
    expect(LANGUAGE_PENDING_NOTICE).toContain('まだ有効になっていません');
  });

  it('says what the user will actually see', () => {
    expect(LANGUAGE_PENDING_NOTICE).toContain('日本語');
  });

  it('says the value is still kept, so saving is not pointless', () => {
    expect(LANGUAGE_PENDING_NOTICE).toContain('保存');
  });

  it('does NOT claim the wording changes', () => {
    // The exact false claim this replaced.
    expect(LANGUAGE_PENDING_NOTICE).not.toContain('文言だけが変わります');
    expect(LANGUAGE_NOT_IN_CALCULATION_NOTICE).not.toContain('文言だけが変わります');
  });

  it('keeps the Free/Busy independence as its own statement', () => {
    expect(LANGUAGE_NOT_IN_CALCULATION_NOTICE).toContain('空き時間の計算には影響しません');
  });

  it('keeps the two statements separate', () => {
    // One is about a feature that is not ready; the other is a permanent
    // property. Merging them would make the permanent one look temporary.
    expect(LANGUAGE_PENDING_NOTICE).not.toBe(LANGUAGE_NOT_IN_CALCULATION_NOTICE);
  });
});
