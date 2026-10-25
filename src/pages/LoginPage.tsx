import { useAuth } from '../auth/useAuth';
import { useTranslate } from '../i18n/useLanguage';

/**
 * Minimal login screen: a single "Sign in with Google" action.
 *
 * Reached through AuthGate, which renders inside <LanguageProvider>, so the
 * wording follows whatever language the provider resolved -- which until P6 is
 * pinned to the default for everyone. "TimeWeave" is a product name and stays
 * a literal; "Google" likewise, inside the button's key.
 */
export function LoginPage() {
  const tr = useTranslate();
  const { signInWithGoogle } = useAuth();
  return (
    <div className="login">
      <div className="login-card">
        <h1 className="login-brand">TimeWeave</h1>
        <p className="login-sub">{tr('login.tagline')}</p>
        <button className="btn primary login-btn" onClick={() => void signInWithGoogle()}>
          {tr('login.google')}
        </button>
      </div>
    </div>
  );
}
