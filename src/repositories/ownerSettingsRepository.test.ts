import { beforeEach, describe, expect, it, vi } from 'vitest';

// A recording fake for requireSupabase().from(table) query builders.
// Mirrors the shape ownerSettingsRepository uses and nothing more.
const h = vi.hoisted(() => {
  const calls: { table: string; op: string; payload?: unknown; opts?: unknown }[] = [];
  const state: { data: unknown; error: unknown } = { data: null, error: null };
  const result = () => Promise.resolve({ data: state.data, error: state.error });
  const client = {
    from: (table: string) => ({
      select: () => ({
        maybeSingle: () => { calls.push({ table, op: 'select.maybeSingle' }); return result(); },
        single: () => { calls.push({ table, op: 'select.single' }); return result(); },
      }),
      upsert: (payload: unknown, opts: unknown) => {
        calls.push({ table, op: 'upsert', payload, opts });
        return { select: () => ({ single: () => result() }) };
      },
    }),
  };
  return { calls, state, client };
});

vi.mock('../lib/supabase', () => ({ requireSupabase: () => h.client }));

import { InvalidTimezoneError } from '../errors';
import { getOwnerSettings, saveOwnerSettings } from './ownerSettingsRepository';

beforeEach(() => {
  h.calls.length = 0;
  h.state.data = null;
  h.state.error = null;
});

describe('getOwnerSettings', () => {
  it('reads the owner_settings table', async () => {
    h.state.data = { timezone: 'Asia/Tokyo', language: 'ja' };
    await getOwnerSettings();
    expect(h.calls[0]!.table).toBe('owner_settings');
  });

  it('maps a stored row', async () => {
    h.state.data = { timezone: 'Asia/Tokyo', language: 'ja' };
    await expect(getOwnerSettings()).resolves.toEqual({ timezone: 'Asia/Tokyo', language: 'ja' });
  });

  it('treats NO ROW as unset, not as an error', async () => {
    // Every owner starts without a row. `{timezone: null}` is the state 0025
    // reads as "undeclared", which keeps 0024's behaviour -- so a missing row
    // must resolve, never throw.
    h.state.data = null;
    await expect(getOwnerSettings()).resolves.toEqual({ timezone: null, language: null });
  });

  it('never invents a timezone for an owner who has none', async () => {
    // Defaulting to the browser zone here would make anonymous Free/Busy
    // disclose time computed against a day boundary the owner never agreed to.
    h.state.data = { timezone: null, language: 'en' };
    const s = await getOwnerSettings();
    expect(s.timezone).toBeNull();
  });

  it('reads an unrecognised language as "follow the browser"', async () => {
    h.state.data = { timezone: 'Asia/Tokyo', language: 'fr' };
    await expect(getOwnerSettings()).resolves.toEqual({ timezone: 'Asia/Tokyo', language: null });
  });

  it('throws on a real error', async () => {
    h.state.error = { message: 'boom' };
    await expect(getOwnerSettings()).rejects.toThrow(/boom/);
  });
});

describe('saveOwnerSettings', () => {
  it('upserts on the primary key and does NOT send owner_id', async () => {
    // owner_id comes from the column default (auth.uid()); sending one would be
    // refused by the INSERT policy if it named anybody else.
    h.state.data = { timezone: 'Asia/Tokyo', language: 'ja' };
    await saveOwnerSettings({ timezone: 'Asia/Tokyo', language: 'ja' });
    const call = h.calls.find((c) => c.op === 'upsert')!;
    expect(call.table).toBe('owner_settings');
    expect(call.opts).toEqual({ onConflict: 'owner_id' });
    expect(Object.keys(call.payload as object).sort()).toEqual(['language', 'timezone']);
  });

  it('sends an explicit null to clear the zone', async () => {
    // Clearing must reach the server as a value, not as an omitted key, or the
    // upsert would leave the old zone in place and the owner would believe
    // they had switched sharing back off.
    h.state.data = { timezone: null, language: null };
    await saveOwnerSettings({ timezone: null, language: null });
    const call = h.calls.find((c) => c.op === 'upsert')!;
    expect(call.payload).toEqual({ timezone: null, language: null });
  });

  it('maps the 0025 trigger marker to InvalidTimezoneError', async () => {
    // 0025 validates the zone in a trigger, because timezone_is_supported() is
    // STABLE and cannot sit in a CHECK. It raises 0008's marker, so the app's
    // existing error for that meaning is reused and the dialog needs no new
    // failure branch.
    h.state.error = { message: 'timezone is not a usable IANA zone name', details: 'TIMEWEAVE_TZ_INVALID' };
    await expect(saveOwnerSettings({ timezone: 'Mars/Olympus', language: null }))
      .rejects.toThrow(InvalidTimezoneError);
  });

  it('finds the marker in the message when details is absent', async () => {
    h.state.error = { message: 'TIMEWEAVE_TZ_INVALID', details: null };
    await expect(saveOwnerSettings({ timezone: 'x', language: null }))
      .rejects.toThrow(InvalidTimezoneError);
  });

  it('leaves an unrelated error as a plain Error', async () => {
    h.state.error = { message: 'network down', details: null };
    const p = saveOwnerSettings({ timezone: 'Asia/Tokyo', language: null });
    await expect(p).rejects.toThrow(/network down/);
    await expect(p).rejects.not.toBeInstanceOf(InvalidTimezoneError);
  });

  it('returns the server value, not the submitted one', async () => {
    h.state.data = { timezone: 'Asia/Tokyo', language: null };
    await expect(saveOwnerSettings({ timezone: 'Asia/Tokyo', language: 'en' }))
      .resolves.toEqual({ timezone: 'Asia/Tokyo', language: null });
  });
});
