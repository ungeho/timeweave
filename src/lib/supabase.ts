/**
 * Supabase client singleton.
 *
 * The URL and anon key come from Vite env vars. The anon key is public by
 * design — real access control is enforced by Row Level Security in the DB.
 *
 * When the env vars are absent (e.g. local development without a Supabase
 * project), `supabase` is null and the app falls back to the localStorage
 * repository + no-auth "local mode". This keeps the app runnable without
 * secrets and avoids hard-coupling to a hosting provider.
 */

import { createClient, type SupabaseClient } from '@supabase/supabase-js';

const url = import.meta.env.VITE_SUPABASE_URL;
const anonKey = import.meta.env.VITE_SUPABASE_ANON_KEY;

export const isSupabaseConfigured = Boolean(url && anonKey);

export const supabase: SupabaseClient | null = isSupabaseConfigured
  ? createClient(url, anonKey)
  : null;

/** Narrowing helper: returns the client or throws if it isn't configured. */
export function requireSupabase(): SupabaseClient {
  if (!supabase) {
    throw new Error('Supabase is not configured (missing VITE_SUPABASE_URL / VITE_SUPABASE_ANON_KEY).');
  }
  return supabase;
}
