import { useEffect, useState } from 'react';
import { CalendarPage } from './features/calendar/CalendarPage';
import { FreeBusyPage } from './features/share/FreeBusyPage';
import { AuthGate } from './auth/AuthGate';
import { useAuth } from './auth/useAuth';
import { SettingsDialog } from './features/settings/SettingsDialog';
import { LanguageProvider } from './i18n/LanguageProvider';
import { useTranslate } from './i18n/useLanguage';
import { DocsScreen } from './features/docs/DocsPage';
import { isPublicRoute } from './routing/route';
import { useRoute } from './routing/useRoute';
import { resolveInitialTheme, type Theme } from './utils/theme';
import { useIsMobile } from './hooks/useIsMobile';
import { HeaderMenu, type HeaderMenuItem } from './features/shell/HeaderMenu';

const THEME_KEY = 'timeweave.theme';

/**
 * The signed-in shell: header, main area and the settings dialog.
 *
 * SPLIT OUT OF `App` BECAUSE OF WHERE THE HOOK CAN RUN. Its strings were
 * written inside the <LanguageProvider> element, but `App` is the component
 * that RENDERS that element, so a useTranslate() call in `App` would read the
 * context from above it -- which is empty, and useLanguage throws there by
 * design rather than silently serving Japanese. Everything that needs a
 * translation therefore has to be a child, and this is that child.
 *
 * The theme deliberately stays in `App`: it applies to the anonymous share
 * route too, which returns before this component is ever rendered.
 */
function AppShell({ theme, onToggleTheme }: { theme: Theme; onToggleTheme: () => void }) {
  const tr = useTranslate();
  const { user, authEnabled, signOut } = useAuth();
  const [settingsOpen, setSettingsOpen] = useState(false);
  const isMobile = useIsMobile();

  const signedIn = Boolean(authEnabled && user);

  /*
    THE SAME FOUR CONTROLS, ARRANGED TWICE.

    P8-b1 stopped the header scrolling sideways and P8-b2 made its buttons
    44px tall, but neither changed what is IN it: four controls with word
    labels, laid out for a desktop. At 320px the words wrapped to two and
    three lines and the brand was ellipsed to "Time...", which is not a
    horizontal-scroll problem and was never going to be fixed by one.

    So below 720px the words that can move, move. Settings, the guide and
    sign-out go behind one trigger, where they get full-width lines and
    readable labels. The theme toggle stays out: it is already an icon, it is
    a toggle rather than a destination, and burying it would cost two taps
    for the one control people flip most.

    The list is built HERE, from the same conditions the desktop row uses, so
    the two arrangements cannot disagree about what exists. A control added
    to one without the other would be a control the phone cannot reach.
  */
  const menuItems: HeaderMenuItem[] = [
    ...(signedIn
      ? [{ id: 'settings', label: tr('settings.title'), onSelect: () => setSettingsOpen(true) }]
      : []),
    { id: 'docs', label: tr('docs.indexTitle'), href: '/docs' },
    ...(signedIn
      ? [{ id: 'signOut', label: tr('app.signOut'), onSelect: () => void signOut() }]
      : []),
  ];

  /*
    NO MENU WHEN THERE IS ONLY THE GUIDE IN IT. Signed out, the header holds
    the guide link and the theme toggle, which fit at 320px with room to
    spare -- and the guide matters MORE on that screen, because the reader is
    looking at a sign-in page and the guide is what explains it. Putting a
    single link behind a button would cost a tap and gain nothing.
  */
  const useMenu = isMobile && signedIn;

  return (
    <div className="app">
      <header className="app-header">
        <div className="brand">TimeWeave</div>
        <div className="app-header-actions">
          {/* Settings belong to an authenticated owner: the time zone inside
              decides how this account's all-day events are disclosed, so the
              entry point lives beside the sign-out button and nowhere near the
              anonymous share route above. */}
          {!useMenu && authEnabled && user && (
            <>
              <span className="user-email">{user.email}</span>
              <button className="btn" onClick={() => setSettingsOpen(true)}>
                {tr('settings.title')}
              </button>
              <button className="btn" onClick={() => void signOut()}>
                {tr('app.signOut')}
              </button>
            </>
          )}
          {/*
            THE GUIDE HAD NO WAY IN. P7 built nine chapters and a reader could
            reach the calendar from them, but not the other way round -- the
            P8-a audit found the link simply missing. A plain anchor, because
            this leaves the application for a different shell entirely.

            No language in the path: /docs resolves to the reader's own, and
            the guide replaces it with the resolved one so what they copy out
            of the address bar is unambiguous.
          */}
          {!useMenu && (
            <a className="btn" href="/docs">
              {tr('docs.indexTitle')}
            </a>
          )}
          {/* The visible content is an emoji, so the aria-label is the only
              thing a screen reader can announce for this button. */}
          <button className="btn icon" onClick={onToggleTheme} aria-label={tr('app.themeToggle')}>
            {theme === 'light' ? '🌙' : '☀️'}
          </button>
          {/*
            Keyed on the arrangement, so crossing 720px with the menu open
            discards it rather than leaving a panel that belongs to a header
            that is no longer there.
          */}
          {useMenu && <HeaderMenu key="mobile" items={menuItems} />}
        </div>
      </header>
      <main className="app-main">
        <AuthGate>
          <CalendarPage />
        </AuthGate>
      </main>
      {/* Rendered only for a signed-in owner: it reads and writes a row that
          RLS scopes to auth.uid(), so there is nothing for it to do without
          one, and the anonymous share route returns long before this point. */}
      {settingsOpen && authEnabled && user && (
        <SettingsDialog onClose={() => setSettingsOpen(false)} />
      )}
    </div>
  );
}

export function App() {
  const [theme, setTheme] = useState<Theme>(() =>
    resolveInitialTheme(
      localStorage.getItem(THEME_KEY),
      window.matchMedia('(prefers-color-scheme: dark)').matches,
    ),
  );

  useEffect(() => {
    document.documentElement.dataset.theme = theme;
    localStorage.setItem(THEME_KEY, theme);
  }, [theme]);

  // THE ROUTE IS PARSED IN ONE PLACE, by a pure function, and read through a
  // hook that follows the history -- so the back and forward buttons move the
  // screen and not just the URL.
  const route = useRoute();

  // Both public routes -- the anonymous share page and the documentation --
  // are rendered OUTSIDE AuthGate and marked so the provider does not ask for
  // owner_settings. The anon role holds no privilege on that table
  // (0025/0026), and in both cases the viewer OWN browser language is the
  // right answer: a stranger cannot read the owner preference, and
  // documentation has no owner in the picture at all.
  //
  // The flag is passed explicitly rather than inferred inside the provider,
  // because this line is already the one place that decides what route we are
  // on and a second inference could disagree with it.
  if (route.kind === 'share') {
    return (
      <LanguageProvider isPublicRoute>
        <div className="app">
          <FreeBusyPage token={route.token} />
        </div>
      </LanguageProvider>
    );
  }

  // The public guide. A URL whose language the build does not know, or whose
  // id is malformed, lands here too -- the reader gets the documentation own
  // apology, with a way back, rather than the calendar.
  //
  // The provider still wraps it: on a public route it resolves the VIEWER's
  // language from their browser and asks the server for nothing, which is
  // exactly what a URL that named no language needs. A URL that DID name one
  // overrides it inside the screen.
  if (isPublicRoute(route)) {
    return (
      <LanguageProvider isPublicRoute ownsDocumentLang={false}>
        <DocsScreen route={route} />
      </LanguageProvider>
    );
  }

  return (
    <LanguageProvider>
      <AppShell
        theme={theme}
        onToggleTheme={() => setTheme((t) => (t === 'light' ? 'dark' : 'light'))}
      />
    </LanguageProvider>
  );
}
