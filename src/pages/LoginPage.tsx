import { useAuth } from '../auth/useAuth';

/** Minimal login screen: a single "Sign in with Google" action. */
export function LoginPage() {
  const { signInWithGoogle } = useAuth();
  return (
    <div className="login">
      <div className="login-card">
        <h1 className="login-brand">TimeWeave</h1>
        <p className="login-sub">予定を管理し、空き時間を共有する</p>
        <button className="btn primary login-btn" onClick={() => void signInWithGoogle()}>
          Google でログイン
        </button>
      </div>
    </div>
  );
}
