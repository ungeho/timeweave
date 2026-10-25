import { describe, expect, it } from 'vitest';
import { ja } from './ja';
import { en } from './en';
import { LANGUAGES } from '../features/settings/timezoneSetting';

/**
 * P3-b's final step moved the APP SHELL and SIGN-IN wording into the
 * dictionary: App, AuthGate and LoginPage. With these, every component that
 * renders user-facing copy reads the dictionary.
 *
 * The second half of this file is the P3 COMPLETION AUDIT, written as tests
 * rather than as prose: each thing the audit found is pinned here, so the
 * finding cannot quietly stop being true between now and P4/P5/P6.
 *
 * As in every earlier step the Japanese is written out literally rather than
 * read back from `ja`.
 */

const JP = /[ぁ-んァ-ン一-龯]/;

const MODULES = import.meta.glob('/src/**/*.{ts,tsx}', {
  query: '?raw',
  import: 'default',
  eager: true,
}) as Record<string, string>;

const source = (path: string) => (MODULES['/src/' + path] ?? '') as string;

/** Every non-test source file, keyed by path relative to src/. */
const sources: Record<string, string> = Object.fromEntries(
  Object.entries(MODULES)
    .filter(([p]) => !p.includes('.test.'))
    .map(([p, text]) => [p.replace(/^\/src\//, ''), text]),
);

/** Source with comments stripped: these guards are about what the code DOES. */
const code = (text: string) =>
  text.replace(/\/\*[\s\S]*?\*\//g, '').replace(/(^|[^:])\/\/.*$/gm, '$1');

describe('the app shell renders the same Japanese as before', () => {
  it('the header buttons', () => {
    // The settings button shares `settings.title` with the dialog's heading:
    // it is the same destination, so one key rather than two that can drift.
    expect(ja['settings.title']).toBe('設定');
    expect(ja['app.signOut']).toBe('ログアウト');
  });

  it('the theme toggle keeps its accessible name', () => {
    // The visible content is an emoji, so this is the whole announcement.
    expect(ja['app.themeToggle']).toBe('テーマ切替');
    expect(en['app.themeToggle']).toBe('Toggle theme');
  });

  it('the auth loading line', () => {
    expect(ja['common.loading']).toBe('読み込み中…');
  });

  it('the sign-in screen', () => {
    expect(ja['login.tagline']).toBe('予定を管理し、空き時間を共有する');
    expect(ja['login.google']).toBe('Google でログイン');
  });

  it('the English sign-in copy shares OPEN TIME, not the calendar', () => {
    // The contents are never shared. The first screen a stranger sees must not
    // imply otherwise.
    const s = en['login.tagline'];
    expect(s).toMatch(/open time/i);
    expect(s).not.toMatch(/share your calendar|share your events/i);
    expect(en['login.google']).toMatch(/Google/);
  });
});

/**
 * THE HOOK-POSITION PROBLEM, pinned.
 *
 * App's header strings sit inside the <LanguageProvider> ELEMENT, but App is
 * the component that renders it, so a useTranslate() call in App would read
 * the context from above itself -- which is empty, and useLanguage throws
 * there by design rather than silently serving Japanese. That is why the shell
 * had to become a child component.
 */
describe('every translator call sits inside a provider', () => {
  it('App renders the provider, and AppShell is the child that translates', () => {
    const app = code(source('App.tsx'));
    // The shell is a separate component...
    expect(app).toMatch(/function AppShell\(/);
    // ...and it is what the provider wraps.
    expect(app).toMatch(/<LanguageProvider>\s*<AppShell/);
    // The App function itself must not call the hook.
    const appFn = app.slice(app.indexOf('export function App('));
    expect(appFn).not.toMatch(/useTranslate\(\)/);
  });

  it('the share route still gets its own provider with isPublicRoute', () => {
    const app = source('App.tsx');
    const shareBranch = app.slice(
      app.indexOf("if (route.kind === 'share')"),
      app.indexOf('</LanguageProvider>'),
    );
    expect(shareBranch).toMatch(/<LanguageProvider isPublicRoute>/);
    // And it renders FreeBusyPage, not the shell.
    expect(shareBranch).toMatch(/<FreeBusyPage token=\{route\.token\} \/>/);
    expect(shareBranch).not.toMatch(/AppShell/);
  });

  it('the theme still applies to the anonymous share route too', () => {
    // The theme state and its effect stay in App, which runs before the share
    // branch returns. Moving them into the shell would have left the share
    // page unthemed -- a regression no translation test would have caught.
    const app = code(source('App.tsx'));
    const appFn = app.slice(app.indexOf('export function App('));
    expect(appFn).toMatch(/resolveInitialTheme/);
    expect(appFn).toMatch(/document\.documentElement\.dataset\.theme = theme/);
    expect(appFn).toMatch(/localStorage\.setItem\(THEME_KEY, theme\)/);
  });
});

describe('authentication and routing are unchanged', () => {
  it('AuthGate still has its three branches in the same order', () => {
    const gate = code(source('auth/AuthGate.tsx'));
    expect(gate).toMatch(/if \(!authEnabled\) return <>\{children\}<\/>/);
    expect(gate).toMatch(/if \(loading\) return <div className="app-loading">/);
    expect(gate).toMatch(/if \(!user\) return <LoginPage \/>/);
    // Local mode (no Supabase) comes first, before anything reads `user`.
    expect(gate.indexOf('!authEnabled')).toBeLessThan(gate.indexOf('!user'));
  });

  it('sign-in and sign-out still go through useAuth', () => {
    expect(code(source('pages/LoginPage.tsx'))).toMatch(/signInWithGoogle\(\)/);
    expect(code(source('App.tsx'))).toMatch(/void signOut\(\)/);
  });

  it('the share-token route still comes from the path alone', () => {
    // P7-a moved the parsing into src/routing/route.ts, where it can be
    // exercised directly -- see routing/route.test.ts, which pins the share
    // shape against every documentation URL. What this guard still owns is
    // that App gets the token from the ROUTE and from nowhere else: no
    // second read of window.location, and no token from state or a prop.
    const app = code(source('App.tsx'));
    expect(app).toContain('const route = useRoute()');
    expect(app).toMatch(/<FreeBusyPage token=\{route\.token\} \/>/);
    expect(app).not.toMatch(/window\.location/);
    // And the parsing itself still decodes the segment.
    const routeMod = code(source('routing/route.ts'));
    expect(routeMod).toMatch(/decodeURIComponent/);
  });

  it('settings are still rendered only for a signed-in owner', () => {
    expect(code(source('App.tsx'))).toMatch(/settingsOpen && authEnabled && user/);
  });
});

describe('no language leaks between users or to an anonymous viewer', () => {
  it('the provider is the only thing that fetches settings for the language', () => {
    const callers = Object.entries(sources)
      .filter(([, text]) => /getOwnerSettings\s*\(/.test(code(text)))
      .map(([p]) => p)
      .sort();
    expect(callers).toEqual([
      'features/settings/SettingsDialog.tsx',
      'i18n/LanguageProvider.tsx',
      'repositories/ownerSettingsRepository.ts',
    ]);
  });

  it('none of the three migrated files reaches for owner settings', () => {
    for (const p of ['App.tsx', 'auth/AuthGate.tsx', 'pages/LoginPage.tsx']) {
      expect(code(source(p)), p).not.toMatch(/owner_settings|getOwnerSettings/);
    }
  });

  it('the provider still drops a previous user stored value on sign-out', () => {
    // retainStored is the guard; languageState.test.ts owns its truth table.
    // This checks the provider still routes through it rather than keeping
    // whatever it last read.
    const prov = code(source('i18n/LanguageProvider.tsx'));
    expect(prov).toMatch(/retainStored/);
  });
});

/* ------------------------------------------------------------------ *
 *  P3 COMPLETION AUDIT
 * ------------------------------------------------------------------ */

describe('AUDIT 1: every component renders only dictionary copy', () => {
  it('no .tsx outside the dictionary holds a Japanese string literal', () => {
    // The ONE exception is the weekday arrays, which are a date format and
    // belong to P4. Anything else appearing here is a missed migration.
    const offenders = Object.entries(sources)
      .filter(([p]) => p.endsWith('.tsx'))
      .filter(([, text]) => {
        // Two shapes: an array in the three grid views, a Record in the
        // recurrence editor. Both are the same seven labels and both are P4's.
        const c = code(text).replace(/const WEEKDAY_LABELS[\s\S]*?[\]}];/, '');
        return /(['"`])[^'"`\n]*[ぁ-んァ-ン一-龯][^'"`\n]*\1/.test(c);
      })
      .map(([p]) => p);
    expect(offenders).toEqual([]);
  });

  it('no .ts outside the dictionary holds one either', () => {
    // The audit originally found three, all now fixed:
    //   shareLinkLabel.ts    a pure module P3 step 2's list had missed; it
    //                        takes a `lang` like contentLimits.ts does.
    //   recurrenceOps.ts     two explicit error messages, plus one in
    //   eventRepository.ts   eventRepository -- now named by their own keys
    //                        through InvalidTimezoneError.timedRecurrenceOnly()
    //                        and SeriesEditBlockedError.timezoneChange().
    //
    // The list is EMPTY and must stay empty. The two exclusions below are the
    // weekday labels (P4) and the language autonym, which is never translated.
    //
    // generated/docs.ts IS EXCLUDED, and the distinction is the point of this
    // guard rather than an exception to it. What must come from the dictionary
    // is UI COPY -- the words the app itself speaks. The generated module is
    // the public guide CONTENT, converted at build time from content/ja and
    // content/en, and keeping prose out of the dictionary is P7's deliberate
    // separation: a translator edits Markdown, not a TypeScript map. Its
    // Japanese lives beside its English in content/, which is where the
    // translation-freshness check can see both (src/docs/content.test.ts).
    const offenders = Object.entries(sources)
      .filter(([p]) => p.endsWith('.ts') && !p.startsWith('i18n/'))
      .filter(([p]) => p !== 'generated/docs.ts')
      .filter(([, text]) => {
        const c = code(text)
          .replace(/const WEEKDAY_LABELS[\s\S]*?\};/, '')
          .replace(/label: '日本語'/, '');
        return /(['"`])[^'"`\n]*[ぁ-んァ-ン一-龯][^'"`\n]*\1/.test(c);
      })
      .map(([p]) => p)
      .sort();
    expect(offenders).toEqual([]);

    // The one exclusion is real, and is generated rather than hand-written.
    const docs = sources['generated/docs.ts'];
    expect(docs, 'generated/docs.ts must exist for its exclusion to mean anything')
      .toBeTypeOf('string');
    expect(docs).toMatch(/GENERATED by scripts\/build-docs\.mjs -- do not edit/);
  });
});

describe('AUDIT 2: the P4 date and time formats are identified and intact', () => {
  it('ONE file holds the week now -- P4 step 1 collapsed the four copies', () => {
    // The audit found four: three identical arrays and one Record keyed by
    // RFC 5545 code. This is the whole point of step 1, so the count is the
    // assertion: a second holder reappearing means someone hardcoded a week
    // again instead of calling the formatter.
    const holders = Object.entries(sources)
      .filter(([, text]) => /MO: '月'|\['月', '火'/.test(text))
      .map(([p]) => p)
      .sort();
    expect(holders).toEqual(['i18n/dateNames.ts']);
  });

  it('all four views read that one formatter', () => {
    for (const p of [
      'features/calendar/MonthView.tsx',
      'features/calendar/TimeGridView.tsx',
      'features/event/RecurrenceEditor.tsx',
      'features/share/FreeBusyPage.tsx',
    ]) {
      expect(sources[p], p).toMatch(/from '[^']*i18n\/dateNames'/);
    }
  });

  it('no weekday, month or date key exists yet', () => {
    const dateKeys = (Object.keys(ja) as string[]).filter((k) =>
      /^(weekday|month|date|time)\./.test(k),
    );
    expect(dateKeys).toEqual([]);
  });

  it('the period titles and the agenda heading now take the resolved locale', () => {
    // The audit found both reading the BROWSER's locale. P4 step 2 routed
    // both through intlLocale(language), so nothing in the app formats a date
    // against a locale the provider did not resolve.
    expect(code(source('features/calendar/CalendarToolbar.tsx'))).toMatch(
      /monthTitle\(view\.anchor, locale\)/,
    );
    expect(code(source('features/calendar/DayAgendaDialog.tsx'))).toMatch(
      /dayKeyTitle\(agenda\.dayKey, intlLocale\(language\)\)/,
    );
  });

  it('no display path reads the browser locale on its own any more', () => {
    // `resolvedOptions().timeZone` is excluded: it discovers a TIME ZONE, not
    // a date format, and utils/timezone.ts's 'en-US' probe tests whether a
    // zone NAME is usable rather than how to show one.
    const offenders = Object.entries(sources)
      .filter(([p]) => !p.startsWith('i18n/'))
      .filter(([, text]) => {
        const c = code(text);
        return (
          /toLocale(Date|Time)?String\(\s*(undefined\b|\))/.test(c) ||
          /Intl\.DateTimeFormat\(\s*\{/.test(c)
        );
      })
      .map(([p]) => p);
    expect(offenders).toEqual([]);
  });

  it('the hour labels and the clock times are still raw formats', () => {
    expect(code(source('features/calendar/TimeGridView.tsx'))).toMatch(
      /String\(h\)\.padStart\(2, '0'\)/,
    );
    // formatTime is used by the chip and by the anonymous page.
    const users = Object.entries(sources)
      .filter(([, text]) => /\bformatTime\(/.test(code(text)))
      .map(([p]) => p)
      .sort();
    expect(users).toContain('features/calendar/EventChip.tsx');
    expect(users).toContain('features/share/FreeBusyPage.tsx');
  });
});

describe('AUDIT 3: what must never be translated', () => {
  it('the language options stay autonyms and stay out of the dictionary', () => {
    // 日本語 and English name THEMSELVES. A viewer of an English UI looking
    // for Japanese searches for 日本語, not for "Japanese".
    expect(LANGUAGES.map((l) => l.label)).toEqual(['日本語', 'English']);
    const keys = (Object.keys(ja) as string[]).filter((k) =>
      /^settings\.language\.(ja|en|japanese|english)$/i.test(k),
    );
    expect(keys).toEqual([]);
  });

  it('the stored enum values travel inside the visibility labels, not instead of them', () => {
    for (const d of [ja, en]) {
      expect(d['event.visibility.private']).toContain('(private)');
      expect(d['event.visibility.busyOnly']).toContain('(busy_only)');
      expect(d['event.visibility.public']).toContain('(public)');
    }
  });

  it('the availability control names its terms through the dictionary', () => {
    // availabilityField.ts held these untranslated on purpose until P7-c:
    // the app uses the English words in Japanese too (the share dialog says
    // 空き時間(Available)). The Japanese labels now carry a Japanese name AND
    // that term, so the correspondence survives translation rather than
    // depending on there being none.
    const mod = code(source('features/event/availabilityField.ts'));
    expect(mod).toMatch(/t\('event\.availability\.busy', l\)/);
    expect(mod).toMatch(/t\('event\.availability\.available', l\)/);
    expect(mod).not.toMatch(/label: '(Busy|Available)'/);
    for (const d of [ja, en]) {
      expect(d['event.availability.busy']).toContain('Busy');
      expect(d['event.availability.available']).toContain('Available');
    }
  });

  it('the product name is never a key', () => {
    expect((Object.keys(ja) as string[]).filter((k) => /brand|timeweave/i.test(k))).toEqual([]);
    expect(source('pages/LoginPage.tsx')).toContain('>TimeWeave<');
  });
});

describe('AUDIT 4: the modules P6 must make language-aware', () => {
  it('exactly these thirteen modules name DEFAULT_LANGUAGE', () => {
    // ONCE A WORK LIST, NOW A REGISTER. When this audit was written every file
    // here pinned its wording to the default and its callers rendered the
    // result as-is. After steps 1-5 they all take a `lang` parameter instead,
    // and DEFAULT_LANGUAGE survives only as that parameter's default -- which
    // the two tests below assert. The list is kept because a NEW name
    // appearing on it is still worth seeing.
    const pinned = Object.entries(sources)
      .filter(([p]) => !p.startsWith('i18n/'))
      .filter(([, text]) => /DEFAULT_LANGUAGE/.test(code(text)))
      .map(([p]) => p)
      .sort();
    expect(pinned).toEqual([
      'errors.ts',
      'features/calendar/eventTitle.ts',
      'features/calendar/visibilityMeta.ts',
      // P7-c
      'features/event/availabilityField.ts',
      // P6 step 8
      'features/event/eventFormError.ts',
      'features/event/recurrenceForm.ts',
      'features/settings/timezoneSetting.ts',
      'features/share/availablePresentation.ts',
      'features/share/freeBusyBanner.ts',
      'features/share/freeBusyPresentation.ts',
      // P6 step 6. (Step 5's loadErrorText became i18n/errorText.ts, which
      // this list excludes along with the rest of the i18n layer -- naming
      // DEFAULT_LANGUAGE is that layer's job.)
      'features/share/shareError.ts',
      'features/share/shareLinkLabel.ts',
      'services/contentLimits.ts',
    ]);
  });

  it('eight of them are language-ready, taking lang as a parameter', () => {
    // DEFAULT_LANGUAGE appearing in a file means one of two very different
    // things, and this is the line between them. These name it only as a
    // DEFAULT on a parameter, so a caller can ask for English today.
    for (const p of [
      'services/contentLimits.ts',
      'features/share/shareLinkLabel.ts',
      // P6 step 1 converted these two.
      'features/calendar/visibilityMeta.ts',
      'features/calendar/eventTitle.ts',
      // P6 step 2 converted the three anonymous-share modules.
      'features/share/freeBusyPresentation.ts',
      'features/share/availablePresentation.ts',
      'features/share/freeBusyBanner.ts',
    ]) {
      expect(code(source(p)), p).toMatch(/lang: Language = DEFAULT_LANGUAGE/);
    }
    expect(code(source('errors.ts'))).toMatch(/localize\(lang: Language\): string/);
  });

  it('NO pinned module is left: the P6 conversion work list is empty', () => {
    // THE LIST IS DONE. Step 2 took the three anonymous-share modules, step 3
    // the settings notices, and step 4 the last one -- recurrenceForm, which
    // was the odd one out because its three messages were never module
    // constants but `throw new Error(t(key, DEFAULT_LANGUAGE))` at the moment
    // of failure. They are now a RecurrenceFormError carrying a reason, so the
    // wording is chosen by whoever renders it.
    //
    // This sweeps every source file rather than naming the ones known to have
    // been converted: the claim is now about the WHOLE tree, so a new pinned
    // string anywhere fails here instead of waiting to be noticed.
    const offenders = Object.keys(MODULES)
      .filter((p) => !p.includes('.test.'))
      .map((p) => p.replace(/^\/src\//, ''))
      .filter((p) => !p.startsWith('i18n/'))
      .filter((p) => /t\('[\w.]+', DEFAULT_LANGUAGE\)/.test(code(source(p))))
      .sort();
    expect(offenders).toEqual([]);
  });

  it('every file that still names DEFAULT_LANGUAGE uses it as a parameter default', () => {
    // The other half of the same claim. DEFAULT_LANGUAGE is still imported in
    // several modules, and that is correct -- as the fallback on a `lang`
    // parameter, which is what keeps every existing Japanese call site working.
    // What must not come back is a module that RESOLVES with it at import time.
    const namers = Object.keys(MODULES)
      .filter((p) => !p.includes('.test.'))
      .map((p) => p.replace(/^\/src\//, ''))
      .filter((p) => !p.startsWith('i18n/'))
      .filter((p) => /DEFAULT_LANGUAGE/.test(code(source(p))))
      .sort();
    for (const p of namers) {
      const mod = code(source(p));
      const ok =
        /lang: Language = DEFAULT_LANGUAGE/.test(mod) ||
        /lang = DEFAULT_LANGUAGE/.test(mod) ||
        // errors.ts renders Japanese defaults for .message, by contract, and
        // hands every other language to localize(lang).
        p === 'errors.ts' ||
        // recurrenceForm renders its default .message the same way, through a
        // helper the error class and localize() share.
        p === 'features/event/recurrenceForm.ts';
      expect(ok, `${p} names DEFAULT_LANGUAGE in an unexpected shape`).toBe(true);
    }
    // And the list is not empty, or the guard above would be vacuous.
    expect(namers.length).toBeGreaterThan(0);
  });

  it('the four settings notices P6 step 3 converted are off that list', () => {
    const mod = code(source('features/settings/timezoneSetting.ts'));
    // No module-level resolved string, and no t() handed the default.
    expect(mod).not.toMatch(/^(export )?const [A-Z_]+ = t\(/m);
    expect(mod).not.toMatch(/t\('[\w.]+', DEFAULT_LANGUAGE\)/);
    expect(mod).toMatch(/lang: Language = DEFAULT_LANGUAGE/);
    // Still pure: no hook crossed into it.
    expect(mod).not.toMatch(/useTranslate|useLanguage/);
    // The dialog passes the displayed language to all four.
    const dlg = code(source('features/settings/SettingsDialog.tsx'));
    for (const call of [
      'timezoneUnsetNotice(language)',
      'languageNotInCalculationNotice(language)',
      'timezoneChangeNotice(language)',
    ]) {
      expect(dlg, call).toContain(call);
    }
  });

  it('the three modules P6 step 2 converted are off that list', () => {
    // No module-level resolved string remains in any of them: every `t()` call
    // sits inside a function that was handed a language. The regex looks for a
    // top-level `const NAME = ...t(...)`, which is exactly the shape that
    // pinned the wording at import time.
    for (const p of [
      'features/share/freeBusyPresentation.ts',
      'features/share/availablePresentation.ts',
      'features/share/freeBusyBanner.ts',
    ]) {
      const mod = code(source(p));
      expect(mod, p).not.toMatch(/^(export )?const \w+ = t\(/m);
      // The PINNING shape specifically: a t() call handed the default. A
      // parameter default also ends in 'DEFAULT_LANGUAGE)', so matching that
      // alone would flag the very thing this step introduced.
      expect(mod, p).not.toMatch(/t\('[\w.]+', DEFAULT_LANGUAGE\)/);
      expect(mod, p).toMatch(/lang: Language = DEFAULT_LANGUAGE/);
      // Still pure: the language arrives as an argument, never from a hook.
      expect(mod, p).not.toMatch(/useTranslate|useLanguage/);
    }
  });

  it('the two modules P6 step 1 converted are off that list', () => {
    // They no longer hold a module constant at all, and all three components
    // that render a visibility or a title now pass the language.
    for (const p of ['features/calendar/visibilityMeta.ts', 'features/calendar/eventTitle.ts']) {
      const mod = code(source(p));
      expect(mod, p).not.toMatch(/^const \w+: Record<[^>]+> = \{$/m);
      expect(mod, p).not.toMatch(/useTranslate|useLanguage/);
    }
    for (const p of [
      'features/calendar/EventChip.tsx',
      'features/calendar/AllDayLane.tsx',
      'features/calendar/MonthView.tsx',
    ]) {
      expect(code(source(p)), p).toMatch(/visibilityMeta\([^)]*language\)/);
      expect(code(source(p)), p).toMatch(/eventDisplayTitle\([^)]*language\)/);
      expect(code(source(p)), p).not.toMatch(/visibilityMeta\[/);
    }
  });
});

describe('AUDIT 5: where localize(lang) will have to be called', () => {
  it('every error class carries both a key and a localize', () => {
    const errs = code(source('errors.ts'));
    const keys = [...errs.matchAll(/t\('(error\.[\w.]+)', lang\)/g)].flatMap((m) =>
      m[1] ? [m[1]] : [],
    );
    // Thirteen classes, each resolving its own key.
    expect(new Set(keys).size).toBeGreaterThanOrEqual(10);
    for (const k of keys) expect(ja, k).toHaveProperty(k);
  });

  it('the display sites still use .message, which is why P6 needs them', () => {
    // `.message` is the Japanese rendering. Each of these has to become
    // localize(language) when the switch goes live; until then they are
    // correct, because the default IS Japanese.
    //
    // NONE LEFT -- this audit's list is empty, which is the whole point of
    // steps 5 to 8. Each took one screen:
    //   5  useEvents, the worst case: its string outlived the moment it was
    //      built, because the banner sits on the main screen rather than in a
    //      dialog that closes.
    //   6  ShareDialog, the largest at the time: five catches, a validation
    //      path and two frozen notices.
    //   7  SettingsDialog, the smallest, and the only one needing no
    //      discriminated state because nothing in it validates into a message.
    //   8  EventDialog, the most sources: four catches, six validation keys
    //      and one length violation, eleven assignments in all.
    //
    // The sweep is over the WHOLE tree, not a named list, so a new screen that
    // reads `.message` fails here rather than waiting to be noticed.
    const sites = Object.entries(sources)
      .filter(([, text]) => /instanceof Error \? e\.message : String\(e\)/.test(code(text)))
      .map(([p]) => p)
      .sort();
    expect(sites).toEqual([]);
  });

  it('no component stores a resolved sentence in error state any more', () => {
    // The other half of the same claim, stated positively: every screen that
    // can show an error holds a cause or a key, and resolves at render.
    const holders: [string, string][] = [
      ['hooks/useEvents.ts', 'EventsLoadError | null'],
      ['features/share/ShareDialog.tsx', 'ShareDialogError | null'],
      ['features/settings/SettingsDialog.tsx', 'SettingsError | null'],
      ['features/event/EventDialog.tsx', 'EventFormError | null'],
    ];
    for (const [p, shape] of holders) {
      expect(code(source(p)), p).toContain(`useState<${shape}>`);
    }
    // And no error slot is typed as a plain string any more. Scoped to the
    // error/notice names on purpose: ShareDialog legitimately keeps row ids as
    // `string | null` (which row is confirming a delete, which is toggling),
    // and those are not wording.
    for (const [p] of holders) {
      const mod = code(source(p));
      expect(mod, p).not.toMatch(/\[(error|formError), set\w+\] = useState<string \| null>/);
      expect(mod, p).not.toMatch(/\[notice, setNotice\] = useState<string \| null>/);
    }
  });

  it('the converted screens resolve their wording at render, not at failure', () => {
    // The shape the two dialogs above still have to adopt: hold the cause,
    // decide the words when drawing. Asserted here rather than in each step's
    // own file because this audit is the list those two are read off.
    const hook = code(source('hooks/useEvents.ts'));
    expect(hook).toMatch(/error: EventsLoadError \| null/);
    expect(hook).toMatch(/setError\(\{ kind: 'error', cause: e \}\)/);
    // The hook knows no language, so no language change can re-run the fetch.
    expect(hook).not.toMatch(/i18n|Language|useTranslate|useLanguage|\bt\(/);
    const page = code(source('features/calendar/CalendarPage.tsx'));
    expect(page).toContain('caughtErrorText(events.error.cause, language)');

    // P6 step 6: the share dialog, whose state now holds a cause or a fact.
    const dlg = code(source('features/share/ShareDialog.tsx'));
    expect(dlg).toMatch(/useState<ShareDialogError \| null>/);
    expect(dlg).toMatch(/useState<ShareDialogNotice \| null>/);
    expect(dlg).toContain("setError({ kind: 'caught', cause: e })");
    expect(dlg).toContain('shareDialogErrorText(error, language)');
    expect(dlg).not.toMatch(/instanceof Error \? e\.message/);

    // P6 step 7: the settings dialog. One variant, so a wrapper object rather
    // than a tagged union -- but still a wrapper, so `throw null` is an error
    // and not an absence.
    const settings = code(source('features/settings/SettingsDialog.tsx'));
    expect(settings).toMatch(/useState<SettingsError \| null>/);
    expect(settings).toMatch(/useState<SettingsNotice \| null>/);
    expect(settings).toContain('setError({ cause: e })');
    expect(settings).toContain('caughtErrorText(error.cause, language)');
    expect(settings).not.toMatch(/instanceof Error \? e\.message/);
    expect(settings).not.toMatch(/setNotice\(tr\(/);

    // P6 step 8: the event dialog, three variants and eleven assignments.
    const event = code(source('features/event/EventDialog.tsx'));
    expect(event).toMatch(/useState<EventFormError \| null>/);
    expect(event).toContain("setFormError({ kind: 'caught', cause: e })");
    expect(event).toContain("setFormError({ kind: 'validation', key: ");
    expect(event).toContain("setFormError({ kind: 'contentTooLong', violation: tooLong })");
    expect(event).toContain('eventFormErrorText(formError, language)');
    expect(event).not.toMatch(/setFormError\(tr\(/);
    expect(event).not.toMatch(/errorMessage/);
  });

  it('all four converted screens read one shared helper', () => {
    // The decision -- DomainError localizes, a plain Error keeps its message,
    // anything else gets the generic sentence -- is made in exactly one place,
    // so the four screens cannot drift apart on it.
    const callers = Object.entries(sources)
      .filter(([, text]) => /caughtErrorText/.test(code(text)))
      .map(([p]) => p)
      // The module that DEFINES it, naturally.
      .filter((p) => p !== 'i18n/errorText.ts')
      .sort();
    expect(callers).toEqual([
      'features/calendar/CalendarPage.tsx',
      // EventDialog reaches it through eventFormError.ts, which also owns its
      // two validation variants.
      'features/event/eventFormError.ts',
      'features/settings/SettingsDialog.tsx',
      // ShareDialog reaches it through shareError.ts, same arrangement.
      'features/share/shareError.ts',
    ]);
  });

  it('a custom message still wins over the key -- unchanged, and now unused', () => {
    // hasCustomMessage returns the constructor's string verbatim, and that
    // behaviour is deliberately untouched: an arbitrary string cannot be
    // translated. What changed is that NO PRODUCTION SITE relies on it any
    // more. The three that did now name their wording with a key, so they
    // localize like every other error.
    const errs = code(source('errors.ts'));
    expect(errs).toMatch(/this\.hasCustomMessage \? this\.message : t\(/);
    const customCallers = Object.entries(sources)
      .filter(([, text]) =>
        /new (InvalidTimezoneError|SeriesEditBlockedError|DuplicateExceptionError)\(['"`]/.test(
          code(text),
        ),
      )
      .map(([p]) => p);
    expect(customCallers).toEqual([]);
  });

  it('the three remediated sites construct by reason, not by string', () => {
    expect(code(source('services/recurrenceOps.ts'))).toMatch(
      /InvalidTimezoneError\.timedRecurrenceOnly\(\)/,
    );
    expect(code(source('services/recurrenceOps.ts'))).toMatch(
      /SeriesEditBlockedError\.timezoneChange\(\)/,
    );
    expect(code(source('repositories/eventRepository.ts'))).toMatch(
      /InvalidTimezoneError\.timedRecurrenceOnly\(\)/,
    );
  });
});

describe('AUDIT 6: the mixing risks, and how each was closed', () => {
  it('the switch is ON -- everything below is now a closed case, not a risk', () => {
    // This audit listed the places where Japanese and English COULD mix once
    // the switch flipped. It has flipped, and each entry below records how
    // that case was closed rather than what might go wrong.
    expect(code(source('i18n/types.ts'))).toMatch(/LANGUAGE_SWITCH_ENABLED = true/);
  });

  it('the composed chip name no longer mixes -- this one was the worst, and is FIXED', () => {
    // THE AUDIT'S CLEAREST EXAMPLE, now closed by P6 step 1. The pattern
    // tr('calendar.chip.title') always followed the language; `vis.label` did
    // not, so an English UI would have read "Standup (非公開)". Both halves
    // now come from the same resolved language.
    const chip = code(source('features/calendar/EventChip.tsx'));
    expect(chip).toMatch(
      /tr\('calendar\.chip\.title', \{ title: shownTitle, visibility: vis\.label \}\)/,
    );
    expect(chip).toMatch(/const vis = visibilityMeta\(event\.visibility, language\)/);
    expect(chip).toMatch(/const shownTitle = eventDisplayTitle\(event, language\)/);
  });

  it('the error banner no longer mixes a pinned note into a lead -- FIXED', () => {
    // The audit's second-worst case, closed by P6 step 2. A rate-limit refusal
    // was the dangerous shape: the lead came from `cause.message` (Japanese,
    // built at construction) and the note from a module constant, so the two
    // halves of ONE SENTENCE could not both follow the language. The lead is
    // now read through the error's own localize(), and the note through t().
    const banner = code(source('features/share/freeBusyBanner.ts'));
    expect(banner).toMatch(/cause\.localize\(lang\)/);
    expect(banner).toMatch(/t\('share\.error\.generic', lang\)/);
    expect(banner).toMatch(/t\('share\.error\.notFreeNote', lang\)/);
    // The pinned constants are gone, not merely unused.
    expect(banner).not.toMatch(/NOT_FREE_NOTE|GENERIC/);
    // And the old reading of the lead, which is what mixed the languages.
    expect(banner).not.toMatch(/cause\.message/);
  });

  it('the settings dialog no longer mixes labels with pinned notices -- FIXED', () => {
    // Closed by P6 step 3. The labels followed the language while the four
    // notices beside them did not, so an English dialog would have warned
    // about a zone change -- the one action that retroactively changes what a
    // live share link discloses -- in Japanese.
    const dlg = code(source('features/settings/SettingsDialog.tsx'));
    expect(dlg).toMatch(/tr\('settings\.timezone\.label'\)/);
    expect(dlg).not.toMatch(/\{(TIMEZONE|LANGUAGE)_[A-Z_]*NOTICE[^}]*\}/);
    // The language self-designations stay untranslated, by design: a language
    // is named in its own language in a language picker.
    expect(dlg).toMatch(/LANGUAGES\.map/);
  });

  it('the anonymous page no longer mixes chrome with pinned banners -- FIXED', () => {
    // THE AUDIT'S HIGHEST-PRIORITY CASE, closed by P6 step 2: this page is the
    // only one an ANONYMOUS stranger sees, so its reader's language is the one
    // the app can least afford to pin. The chrome followed the viewer's
    // language while all four banners were resolved at import time.
    const page = code(source('features/share/FreeBusyPage.tsx'));
    expect(page).toMatch(/tr\('sharePage\.subtitle'\)/);
    for (const call of [
      'unavailableMessage(language)',
      'activeEmptyMessage(language)',
      'availableIndeterminateMessage(language)',
      'availableEmptyMessage(language)',
      'freeBusyErrorBanner(load.cause, language)',
    ]) {
      expect(page, call).toContain(call);
    }
    // No pinned constant is rendered any more.
    expect(page).not.toMatch(/_MESSAGE\}/);
  });
});

describe('AUDIT 7: key hygiene', () => {
  it('the two dictionaries agree on their key sets', () => {
    // Also a compile-time assertion in en.ts; this is the runtime echo, so a
    // failure names the key instead of pointing at a type.
    const jk = Object.keys(ja).sort();
    const ek = Object.keys(en).sort();
    expect(ek).toEqual(jk);
  });

  it('the placeholders agree per key', () => {
    const vars = (s: string) =>
      [...s.matchAll(/\{(\w+)\}/g)].map((m) => m[1]).sort().join(',');
    for (const k of Object.keys(ja) as (keyof typeof ja)[]) {
      expect(vars(en[k]), String(k)).toBe(vars(ja[k]));
    }
  });

  it('no English value is empty or still Japanese', () => {
    for (const k of Object.keys(en) as (keyof typeof en)[]) {
      expect(en[k].trim(), String(k)).not.toBe('');
      expect(en[k], String(k)).not.toMatch(JP);
    }
  });

  it('every key referenced in code exists in the dictionary', () => {
    const blob = Object.entries(sources)
      .filter(([p]) => !/^i18n\/(ja|en|dictionaries)\.ts$/.test(p))
      .map(([, text]) => text)
      .join('\n');
    const referenced = new Set(
      [...blob.matchAll(/\btr?\('([a-z][\w.]*)'/g)].flatMap((m) => (m[1] ? [m[1]] : [])),
    );
    const ghosts = [...referenced].filter((k) => !(k in ja));
    expect(ghosts).toEqual([]);
  });

  it('exactly three keys are unused, and each is unused for a stated reason', () => {
    // FOUND BY THE AUDIT. Left in place rather than removed, because deleting
    // dictionary entries is outside this step's scope -- reported instead.
    //   (legend.* was here until P8-mobile-2, which put the legend on the
    //   share page.)
    //   share.label.count   the ShareDialog counter still renders
    //                       `{n} / {max}` as raw JSX, so the separator is not
    //                       localisable. Wire it or drop the key.
    //   share.link.status   a composition pattern the dialog never needed --
    //                       it renders label and status as separate spans.
    //   event.untitled      an exact duplicate of calendar.untitled, which is
    //                       the one eventTitle.ts actually uses.
    const blob = Object.entries(sources)
      .filter(([p]) => !/^i18n\/(ja|en|dictionaries)\.ts$/.test(p))
      .map(([, text]) => text)
      .join('\n');
    const unused = (Object.keys(ja) as string[])
      .filter((k) => !blob.includes(`'${k}'`))
      .sort();
    expect(unused).toEqual([
      'event.untitled',
      'share.label.count',
      'share.link.status',
    ]);
  });

  it('the keys that share a value in BOTH languages are the mergeable ones', () => {
    // Not a defect: several are deliberately separate so either side can
    // change alone (calendar.allDay versus event.field.allDay is documented in
    // the dictionary). Pinned so the list is a decision, not an accident.
    const groups = new Map<string, string[]>();
    for (const k of Object.keys(ja) as (keyof typeof ja)[]) {
      const sig = `${ja[k]}\u0000${en[k]}`;
      groups.set(sig, [...(groups.get(sig) ?? []), String(k)]);
    }
    const shared = [...groups.values()]
      .filter((ks) => ks.length > 1)
      .map((ks) => ks.sort().join(' = '))
      .sort();
    expect(shared).toEqual([
      'calendar.allDay = event.field.allDay',
      'calendar.untitled = event.untitled',
      'calendar.visibility.private = calendar.visibility.privateShort',
      'calendar.visibility.public = calendar.visibility.publicShort',
      'calendar.visibility.busyOnlyShort = sharePage.block.busy',
      'common.delete = shareDialog.delete',
      // P7-e. The guide groups two chapters under the same word the settings
      // dialog is titled with. Separate keys because they are separate things:
      // renaming the dialog must not rename a section of the guide.
      'docs.group.settings = settings.title',
      'common.loading = sharePage.loading',
      'event.field.endDate = recurrence.until.label',
      'event.tz.label = settings.timezone.label',
    ].sort());
  });
});
