import { describe, expect, it } from 'vitest';
import { browserLanguages } from './browserLanguages';
import { LANGUAGE_SWITCH_ENABLED } from './types';

/**
 * Structural guards on the P2 wiring.
 *
 * These read the source rather than render it, because vitest runs with
 * `environment: 'node'` and jsdom is not added -- the provider itself cannot
 * be mounted here. What CAN be checked is the shape of the code, and the two
 * properties below are exactly the ones a rendering test would be used for
 * elsewhere: that the browser is read in one place, and that the anonymous
 * route never reaches for owner_settings.
 */

// Vite's glob rather than node:fs. This project carries no @types/node and
// adds no dependency for tooling; `eager` + `?raw` hands over every source
// file's text at build time, which is all a structural check needs.
const MODULES = import.meta.glob('/src/**/*.{ts,tsx}', {
  query: '?raw',
  import: 'default',
  eager: true,
}) as Record<string, string>;

/** Source text keyed by path relative to src/, test files excluded. */
const sources: Record<string, string> = Object.fromEntries(
  Object.entries(MODULES)
    .filter(([p]) => !p.includes('.test.'))
    .map(([p, text]) => [p.replace(/^\/src\//, ''), text]),
);

const sourceFiles = Object.keys(sources);
const read = (p: string) => sources[p] ?? '';
const rel = (p: string) => p;

/**
 * Source with comments removed.
 *
 * These guards are about what the code DOES, and this codebase explains its
 * reasoning at length -- several files discuss `navigator.languages` in prose
 * precisely because reading it is a decision worth recording. Matching raw
 * text would flag that documentation as a violation and push the next person
 * to delete the explanation to make a test pass, which is the opposite of
 * what the test is for.
 */
const code = (p: string) =>
  read(p)
    .replace(/\/\*[\s\S]*?\*\//g, '')
    .replace(/(^|[^:])\/\/.*$/gm, '$1');

describe('the browser language is read in exactly one place', () => {
  it('only i18n/browserLanguages.ts touches navigator.language(s)', () => {
    // Scattered reads are how a header ends up in one language and a dialog in
    // another. Before P2 there were zero reads; this keeps it at one.
    const offenders = sourceFiles
      // The real read goes through a local alias (`nav.languages`), so the
      // signal is the PROPERTY, not the `navigator` identifier -- which
      // ShareDialog legitimately uses for `navigator.clipboard`.
      .filter((p) => /\.languages\b|\bnavigator\s*\.\s*language\b/.test(code(p)))
      .map(rel);
    expect(offenders).toEqual(['i18n/browserLanguages.ts']);
  });

  it('returns an array even with no navigator, as in this test environment', () => {
    const got = browserLanguages();
    expect(Array.isArray(got)).toBe(true);
  });
});

describe('the anonymous share page never reaches for owner_settings', () => {
  it('FreeBusyPage does not import or name owner settings', () => {
    // anon holds no privilege on that table (0025/0026). A read here would
    // raise 42501 and take the share page down -- and it would be asking the
    // wrong question, since an anonymous viewer needs their own language.
    const page = code('features/share/FreeBusyPage.tsx');
    expect(page).not.toMatch(/owner_settings|ownerSettingsRepository|getOwnerSettings/);
  });

  it('App renders the share route inside a provider marked isPublicRoute', () => {
    // The flag is what short-circuits the fetch. If the share branch ever
    // renders a bare <LanguageProvider>, the provider would try to load
    // settings for whatever session happens to exist in that tab.
    const app = read('App.tsx');
    const shareBranch = app.slice(app.indexOf("if (route.kind === 'share')"), app.indexOf('</LanguageProvider>'));
    expect(shareBranch).toMatch(/<LanguageProvider isPublicRoute>/);
  });

  it('only the provider fetches settings for language purposes', () => {
    // SettingsDialog also calls getOwnerSettings, by design: it needs the
    // timezone too, and it runs only when an owner opens it. Any THIRD caller
    // would be an unplanned query on every page load.
    const callers = sourceFiles
      .filter((p) => /getOwnerSettings\s*\(/.test(code(p)))
      .map(rel)
      .sort();
    expect(callers).toEqual([
      'features/settings/SettingsDialog.tsx',
      'i18n/LanguageProvider.tsx',
      'repositories/ownerSettingsRepository.ts',
    ]);
  });
});

describe('P2 changes nothing the user can see', () => {
  it('only migrated components read the language', () => {
    // An allowlist grown one component at a time, like the t() one. Reading
    // the language was safe during P3 because LANGUAGE_SWITCH_ENABLED pinned
    // what the provider handed out to the default -- a component on this list
    // rendered Japanese for everyone, including a viewer whose browser
    // resolved to English. That pin is off as of the end of P6, so from here
    // the list's job is simply to be complete: every component that renders
    // copy is on it, and a new one must be added deliberately.
    const MIGRATED = [
      // P3-b step 1: the share UI
      'features/share/FreeBusyPage.tsx',
      'features/share/ShareDialog.tsx',
      // P3-b step 2: the event create/edit UI
      'features/event/EventDialog.tsx',
      'features/event/RecurrenceEditor.tsx',
      // P3-b step 3: the settings dialog and the calendar toolbar
      'features/settings/SettingsDialog.tsx',
      'features/calendar/CalendarToolbar.tsx',
      // P3-b step 4: the calendar display
      // P8-b2: the day listing moved out of DayAgendaDialog into AgendaList
      // so the phone and the dialog show the same one. It renders the group
      // headings and the empty-day sentence, so it reads copy.
      'features/calendar/AgendaList.tsx',
      // P8-b2: the mobile calendar. All three render copy -- the strip and the
      // compact month because a dot has no text and their accessible names
      // carry it instead, the shell because it labels its own controls.
      'features/calendar/mobile/CompactMonth.tsx',
      'features/calendar/mobile/DateStrip.tsx',
      'features/calendar/mobile/MobileCalendar.tsx',
      'features/calendar/AllDayLane.tsx',
      'features/calendar/CalendarPage.tsx',
      'features/calendar/DayAgendaDialog.tsx',
      'features/calendar/EventChip.tsx',
      'features/calendar/MonthView.tsx',
      'features/calendar/TimeGridView.tsx',
      // P3-b final step: the app shell and sign-in. With these, every
      // component that renders user-facing copy is on this list -- so from
      // here the guard's job inverts: it stops being a record of progress and
      // becomes the check that nothing NEW renders copy without being noticed.
      'App.tsx',
      // P8-b5.5: the mobile header's menu. It renders the labels that used to
      // be on the header buttons themselves -- which is the whole point of
      // it, since a word label is what a 320px header could not fit.
      'features/shell/HeaderMenu.tsx',
      // P8-b5.6b-2: the date/time inputs that replaced the native controls,
      // their calendar and clock, and the DST notice under the timed fields.
      // Each renders its own copy (buttons, refusals, the gap/fold sentences).
      'features/event/datetimeInput/CalendarPicker.tsx',
      'features/event/datetimeInput/ClockDialog.tsx',
      'features/event/datetimeInput/DateTimeInputs.tsx',
      'features/event/WallTimeNotice.tsx',
      'auth/AuthGate.tsx',
      'pages/LoginPage.tsx',
    ].sort();

    const consumers = sourceFiles
      .filter((p) => !rel(p).startsWith('i18n/'))
      .filter((p) => /useTranslate\s*\(/.test(code(p)))
      .map(rel)
      .sort();
    expect(consumers).toEqual(MIGRATED);
  });

  it('the switch is ON, so migrated components render the resolved language', () => {
    // THE SINGLE LINE P6 FLIPPED, at the end of the phase. While it was false
    // every component above showed Japanese no matter what resolveLanguage
    // answered, which is what made migrating ~196 strings safe one step at a
    // time. The provider now hands out `resolvedLanguage` itself.
    expect(LANGUAGE_SWITCH_ENABLED).toBe(true);
    const provider = code('i18n/LanguageProvider.tsx');
    expect(provider).toContain(
      'const language = LANGUAGE_SWITCH_ENABLED ? resolvedLanguage : DEFAULT_LANGUAGE',
    );
  });

  it('only files already migrated import t()', () => {
    // AN ALLOWLIST, GROWN ONE FILE PER STEP -- not a check that was deleted
    // when it became inconvenient. P3 moves ~196 strings behind `t()`, and
    // this list is the record of how far that has got. A file appearing here
    // without being added deliberately is the thing worth catching: it means
    // someone started a migration without the tests that go with it.
    //
    // P3 step 1: errors.ts. Its classes now carry a key and render it in
    // Japanese for `.message`, so nothing on screen changed.
    const MIGRATED = [
      // P3 step 1
      'errors.ts',
      // P3 step 2 -- the pure presentation and validation modules
      'features/calendar/eventTitle.ts',
      'features/calendar/visibilityMeta.ts',
      'features/event/recurrenceForm.ts',
      'features/settings/timezoneSetting.ts',
      'features/share/availablePresentation.ts',
      'features/share/freeBusyBanner.ts',
      'features/share/freeBusyPresentation.ts',
      'services/contentLimits.ts',
      // P3 audit remediation -- the module step 2's list had missed. Same
      // shape as contentLimits.ts: a ceiling carried as a variable and a
      // `lang` parameter defaulting to the default language.
      'features/share/shareLinkLabel.ts',
      // P6 step 8 -- the event dialog's error line. Its five validation keys
      // take no variables, so one variant of the state carries a key and this
      // module renders it; the other two defer to caughtErrorText and
      // contentLimits.
      'features/event/eventFormError.ts',
      // P7-c -- the availability control. Held the English terms directly
      // until the user guide was written and the Japanese form was read as
      // a whole; the Japanese labels now keep those terms in parentheses.
      'features/event/availabilityField.ts',
      // P7-e -- the guide's own chrome. The screens cannot use useTranslate:
      // the language they render in comes from the URL, which overrides the
      // provider so that a shared documentation link shows the recipient what
      // the sender saw. So they resolve copy themselves, through the one
      // wrapper in this module.
      'features/docs/docsView.ts',
      // P8-b5.6b-2 -- the event dialog's date/time refusals. eventFormError.ts
      // delegates its new 'datetime' variant here, so that module keeps only
      // its five original validation keys.
      'features/event/datetimeInput/dateTimeIssueText.ts',
    ].sort();

    const importers = sourceFiles
      .filter((p) => !rel(p).startsWith('i18n/'))
      .filter((p) => /from\s+['"].*i18n\/t['"]/.test(code(p)))
      .map(rel)
      .sort();
    expect(importers).toEqual(MIGRATED);
    // P6 steps 5-6: the wording for a CAUGHT value is decided in
    // i18n/errorText.ts, which this list does not cover because it is part of
    // the i18n layer itself. Its two consumers reach `t` through it rather
    // than importing the dictionary, which is why neither appears above.
    for (const p of ['features/calendar/CalendarPage.tsx', 'features/share/shareError.ts']) {
      expect(code(p), p).toMatch(/caughtErrorText/);
      expect(code(p), p).not.toMatch(/from\s+['"].*i18n\/t['"]/);
    }
  });

  it('a migrated file renders Japanese, so the screen does not move before P6', () => {
    // The whole safety of migrating during P3 rests on this: components and
    // modules may read `t`, but the language they are handed stays the default
    // until LANGUAGE_SWITCH_ENABLED flips. errors.ts does it explicitly by
    // passing DEFAULT_LANGUAGE; components do it through the provider.
    const errs = code('errors.ts');
    expect(errs).toMatch(/DEFAULT_LANGUAGE/);
    expect(errs).not.toMatch(/resolvedLanguage|useLanguage|useTranslate/);
  });

  it('the language itself is read only by the settings dialog and the date formats', () => {
    // `useTranslate()` is the API components use for COPY they look up by key;
    // `useLanguage()` is for the ones that need the language VALUE, to hand to
    // a pure function. There are three reasons to need it, and every entry
    // below is one of them:
    //   the settings dialog, pushing a saved value back into the provider;
    //   a DATE OR TIME FORMAT -- weekday names (P4 step 1) or a locale for
    //   Intl (P4 step 2) -- which cannot come from a dictionary key;
    //   a PURE MODULE that resolves copy itself (P6 step 1): visibilityMeta
    //   and eventDisplayTitle take the language rather than pinning it.
    // A new entry means one of those three started happening somewhere else,
    // which is exactly the thing worth noticing.
    const consumers = sourceFiles
      .filter((p) => !rel(p).startsWith('i18n/'))
      .filter((p) => /useLanguage\s*\(/.test(code(p)))
      .map(rel)
      .sort();
    expect(consumers).toEqual([
      'features/calendar/AllDayLane.tsx',
      // P6 step 5: the load-error banner resolves its wording at render
      'features/calendar/CalendarPage.tsx',
      // P4 step 2: a locale for Intl
      'features/calendar/CalendarToolbar.tsx',
      'features/calendar/DayAgendaDialog.tsx',
      // P4 step 2 and P6 step 1
      'features/calendar/EventChip.tsx',
      'features/calendar/MonthView.tsx',
      // P4 step 1: weekday names
      'features/calendar/TimeGridView.tsx',
      // P8-b2: the three mobile calendar components. Each needs the LANGUAGE
      // value rather than a key, because each formats a DATE -- a weekday
      // initial, a day number, a month title -- and a date format cannot come
      // from a dictionary entry. The second of the three reasons this list
      // names.
      'features/calendar/mobile/CompactMonth.tsx',
      'features/calendar/mobile/DateStrip.tsx',
      'features/calendar/mobile/MobileCalendar.tsx',
      // P7-e: the guide reads the VIEWER's resolved language and then lets
      // the URL override it. A documentation URL that names no language is
      // the only case where the viewer own browser decides, and this is
      // where that value is read.
      'features/docs/DocsPage.tsx',
      // P6 step 8: the error line resolves its wording at render
      'features/event/EventDialog.tsx',
      // P6 step 1: visibilityMeta + eventDisplayTitle
      // P4 step 1: weekday names
      'features/event/RecurrenceEditor.tsx',
      // P8-b5.6b-2: the calendar formats a month title and full dates for
      // Intl and names the weekdays, and the date input shows the weekday
      // beside the date -- DATE FORMATS, the second reason above.
      'features/event/datetimeInput/CalendarPicker.tsx',
      'features/event/datetimeInput/DateTimeInputs.tsx',
      // the one non-date, non-module reason
      'features/settings/SettingsDialog.tsx',
      // several reasons at once
      'features/share/FreeBusyPage.tsx',
      'features/share/ShareDialog.tsx',
    ]);
  });

  it('the settings dialog no longer says the switch is not live', () => {
    // REMOVED BY THE FINAL STEP OF P6, and this guard is now the inverse of
    // what it was for four phases. Removing the notice earlier would have been
    // the failure the phase ordering existed to prevent -- the owner told
    // their choice applies, picking English, and still seeing Japanese.
    // Keeping it now would be the mirror of that: the choice DOES apply, so
    // the sentence would be false.
    const dialog = read('features/settings/SettingsDialog.tsx');
    expect(dialog).not.toContain('languagePendingNotice');
    // The statement that is still true stayed.
    expect(dialog).toContain('languageNotInCalculationNotice(language)');
  });
});

describe('P2 does not touch Free/Busy or time zones', () => {
  it('the share repository is unchanged by i18n', () => {
    const repo = code('repositories/shareRepository.ts');
    expect(repo).not.toMatch(/i18n|Language|resolveLanguage/);
  });

  it('timezone resolution does not consult the display language', () => {
    // The two are independent, and the zone side must stay owner-driven.
    const tz = code('utils/timezone.ts');
    expect(tz).not.toMatch(/i18n|resolveLanguage|intlLocale/);
  });

  it('the zone-validity probe still pins en-US', () => {
    // utils/timezone.ts checks whether a zone NAME is usable; localising that
    // call would change what it tests.
    const tz = read('utils/timezone.ts');
    expect(tz).toMatch(/Intl\.DateTimeFormat\('en-US'/);
  });
});
