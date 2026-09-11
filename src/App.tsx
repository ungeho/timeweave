import { useEffect, useState } from 'react';
import { CalendarPage } from './features/calendar/CalendarPage';
import { FreeBusyPage } from './features/share/FreeBusyPage';
import { AuthGate } from './auth/AuthGate';
import { useAuth } from './auth/useAuth';
import { resolveInitialTheme, type Theme } from './utils/theme';

const THEME_KEY = 'timeweave.theme';

/** Extract a share token from a /s/:token path, else null. */
function shareTokenFromPath(): string | null {
  const m = /^\/s\/([^/]+)\/?$/.exec(window.location.pathname);
  const raw = m?.[1];
  return raw === undefined ? null : decodeURIComponent(raw);
}

export function App() {
  const { user, authEnabled, signOut } = useAuth();
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

  // Public share route: anonymous, read-only, rendered OUTSIDE AuthGate.
  const shareToken = shareTokenFromPath();
  if (shareToken) {
    return (
      <div className="app">
        <FreeBusyPage token={shareToken} />
      </div>
    );
  }

  return (
    <div className="app">
      <header className="app-header">
        <div className="brand">TimeWeave</div>
        <div className="app-header-actions">
          {authEnabled && user && (
            <>
              <span className="user-email">{user.email}</span>
              <button className="btn" onClick={() => void signOut()}>ログアウト</button>
            </>
          )}
          <button
            className="btn"
            onClick={() => setTheme((t) => (t === 'light' ? 'dark' : 'light'))}
            aria-label="テーマ切替"
          >
            {theme === 'light' ? '🌙' : '☀️'}
          </button>
        </div>
      </header>
      <main className="app-main">
        <AuthGate>
          <CalendarPage />
        </AuthGate>
      </main>
    </div>
  );
}
