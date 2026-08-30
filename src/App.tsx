import { useEffect, useState } from 'react';
import { CalendarPage } from './features/calendar/CalendarPage';
import { AuthGate } from './auth/AuthGate';
import { useAuth } from './auth/useAuth';

type Theme = 'light' | 'dark';
const THEME_KEY = 'timeweave.theme';

export function App() {
  const { user, authEnabled, signOut } = useAuth();
  const [theme, setTheme] = useState<Theme>(
    () => (localStorage.getItem(THEME_KEY) as Theme) || 'light',
  );

  useEffect(() => {
    document.documentElement.dataset.theme = theme;
    localStorage.setItem(THEME_KEY, theme);
  }, [theme]);

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
