import { describe, expect, it } from 'vitest';
import {
  LANGUAGES,
  browserTimezone,
  languageNotInCalculationNotice,
  timezoneChangeNeedsWarning,
  timezoneChangeNotice,
  timezoneOptions,
  timezoneUnsetNotice,
} from './timezoneSetting';

// P6 step 3 turned the four notices into functions of the display language.
// These guards are about the JAPANESE, so they call with NO ARGUMENT -- which
// is also the assertion that the default still answers exactly as the module
// constants did. The English side lives in i18n/settingsNotices.i18n.test.ts.
const TIMEZONE_CHANGE_NOTICE = timezoneChangeNotice();
const TIMEZONE_UNSET_NOTICE = timezoneUnsetNotice();
const LANGUAGE_NOT_IN_CALCULATION_NOTICE = languageNotInCalculationNotice();

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
  it('no longer claims the switch is inactive -- that notice was removed', () => {
    // It was true for four phases and is now false. The module must not export
    // it, and nothing may say it again. Read through Vite's glob rather than
    // node:fs: this project carries no @types/node and adds no dependency for
    // tooling, which is the same bargain wiring.test.ts makes.
    const mod = (
      import.meta.glob('./timezoneSetting.ts', {
        query: '?raw',
        import: 'default',
        eager: true,
      }) as Record<string, string>
    )['./timezoneSetting.ts'];
    expect(mod).toBeTypeOf('string');
    expect(mod).not.toMatch(/export function languagePendingNotice/);
    expect(mod).not.toContain('settings.language.pending');
  });

  it('keeps the Free/Busy independence as its own statement', () => {
    // The half that is still true: whatever the language does, it is not an
    // input to what anonymous viewers are told.
    expect(LANGUAGE_NOT_IN_CALCULATION_NOTICE).toContain('空き時間の計算には影響しません');
  });

  it('does NOT claim the wording is all that changes', () => {
    // The original false claim, which the pending notice replaced. Now that
    // the switch is live the wording DOES change -- but this sentence is about
    // the Free/Busy calculation, so it still must not say that.
    expect(LANGUAGE_NOT_IN_CALCULATION_NOTICE).not.toContain('文言だけが変わります');
  });
});
