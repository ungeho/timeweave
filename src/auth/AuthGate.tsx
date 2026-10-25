/**
 * Renders children only when the user may use the app:
 *  - local mode (no Supabase): always allowed.
 *  - Supabase mode: requires a signed-in user, otherwise shows the login page.
 *
 * Rendered inside <LanguageProvider> (App's `<main>`), so useTranslate() reads
 * a real context here. The three branches are unchanged: only the loading
 * line's wording moved into the dictionary.
 */

import type { ReactNode } from 'react';
import { useAuth } from './useAuth';
import { useTranslate } from '../i18n/useLanguage';
import { LoginPage } from '../pages/LoginPage';

export function AuthGate({ children }: { children: ReactNode }) {
  const tr = useTranslate();
  const { user, loading, authEnabled } = useAuth();

  if (!authEnabled) return <>{children}</>;
  if (loading) return <div className="app-loading">{tr('common.loading')}</div>;
  if (!user) return <LoginPage />;
  return <>{children}</>;
}
