/**
 * Renders children only when the user may use the app:
 *  - local mode (no Supabase): always allowed.
 *  - Supabase mode: requires a signed-in user, otherwise shows the login page.
 */

import type { ReactNode } from 'react';
import { useAuth } from './useAuth';
import { LoginPage } from '../pages/LoginPage';

export function AuthGate({ children }: { children: ReactNode }) {
  const { user, loading, authEnabled } = useAuth();

  if (!authEnabled) return <>{children}</>;
  if (loading) return <div className="app-loading">読み込み中…</div>;
  if (!user) return <LoginPage />;
  return <>{children}</>;
}
