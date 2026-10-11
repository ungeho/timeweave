/**
 * Data access for `public.owner_settings` (migration 0025).
 *
 * Plain table access rather than an RPC, unlike share links: there is no
 * SECURITY DEFINER logic to run and nothing to hide from the owner. RLS does
 * the whole job -- the policies admit only `owner_id = auth.uid()` -- and
 * `owner_id` is never sent from the client, exactly as with `events`: the
 * column defaults to `auth.uid()` and the INSERT policy's WITH CHECK makes any
 * other value impossible.
 *
 * Only available in Supabase mode. Local mode has no authenticated owner, and
 * no anonymous sharing either, so the setting would have nothing to affect.
 */

import { requireSupabase } from '../lib/supabase';
import { InvalidTimezoneError } from '../errors';
import type { OwnerSettings, UiLanguage } from '../types/settings';

const TABLE = 'owner_settings';

interface OwnerSettingsDbRow {
  timezone?: string | null;
  language?: string | null;
}

/**
 * Narrow the row. An unrecognised language reads as null (follow the browser)
 * rather than being passed through: the column has a CHECK, so a value outside
 * the set means the row was written by something this build does not know
 * about, and the safe reading of "unknown" is "no preference".
 */
function mapRow(row: OwnerSettingsDbRow | null | undefined): OwnerSettings {
  const lang = row?.language;
  return {
    timezone: row?.timezone ?? null,
    language: lang === 'ja' || lang === 'en' ? (lang as UiLanguage) : null,
  };
}

/**
 * The caller's settings, or the all-null shape when they have no row yet.
 *
 * A missing row is NOT an error and must not be reported as one: every owner
 * starts without one, and `{ timezone: null }` is the state 0025 treats as
 * "undeclared", which keeps 0024's behaviour. `maybeSingle` is what makes zero
 * rows a null instead of a thrown PGRST116.
 */
export async function getOwnerSettings(): Promise<OwnerSettings> {
  const { data, error } = await requireSupabase()
    .from(TABLE)
    .select('timezone, language')
    .maybeSingle();
  if (error) throw new Error(error.message);
  return mapRow(data as OwnerSettingsDbRow | null);
}

/**
 * Create or update the caller's row.
 *
 * `upsert` on the primary key, because the owner may or may not have a row and
 * the UI should not have to know which. `owner_id` is omitted so the column
 * default (`auth.uid()`) supplies it; sending one would be both unnecessary and
 * refused by the policy if it named anybody else.
 *
 * 0025 validates the zone in a trigger -- `timezone_is_supported()` reads
 * pg_timezone_names and so cannot sit in a CHECK -- and raises 0008's
 * TIMEWEAVE_TZ_INVALID marker. That is mapped here to the error the app already
 * has for exactly this meaning, so the dialog needs no new failure branch.
 */
export async function saveOwnerSettings(input: OwnerSettings): Promise<OwnerSettings> {
  const { data, error } = await requireSupabase()
    .from(TABLE)
    .upsert(
      { timezone: input.timezone, language: input.language },
      { onConflict: 'owner_id' },
    )
    .select('timezone, language')
    .single();
  if (error) {
    const marker = `${error.details ?? ''} ${error.message ?? ''}`;
    if (marker.includes('TIMEWEAVE_TZ_INVALID')) throw new InvalidTimezoneError();
    throw new Error(error.message);
  }
  return mapRow(data as OwnerSettingsDbRow);
}
