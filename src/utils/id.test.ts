import { afterEach, describe, expect, it, vi } from 'vitest';
import { newId } from './id';

/*
  P8-mobile-1 (M1): `crypto.randomUUID` exists only in a SECURE CONTEXT.
  Measured: the same local-mode app on http://localhost:5199 (secure) saves an
  event, and on http://<LAN IP>:5199 (not secure -- what an Android phone on
  the home LAN sees) `crypto.randomUUID` is undefined and saving fails with
  "crypto.randomUUID is not a function". `crypto.getRandomValues` -- the same
  CSPRNG -- IS available there.

  newId is used only by the local-mode event repository (Supabase mode gets
  ids from the database), and those ids are row keys, not secrets. Still, no
  fallback to Math.random: without a CSPRNG it refuses.
*/

const UUID_V4 = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
const real = globalThis.crypto;
afterEach(() => {
  vi.unstubAllGlobals();
});

describe('newId', () => {
  it('uses crypto.randomUUID when the context has it', () => {
    const spy = vi.fn(() => '00000000-0000-4000-8000-000000000000');
    vi.stubGlobal('crypto', { randomUUID: spy, getRandomValues: real.getRandomValues.bind(real) });
    expect(newId()).toBe('00000000-0000-4000-8000-000000000000');
    expect(spy).toHaveBeenCalledOnce();
  });

  it('without randomUUID (not a secure context): a v4 UUID from crypto.getRandomValues', () => {
    const grv = vi.fn((a: Uint8Array) => real.getRandomValues(a));
    vi.stubGlobal('crypto', { getRandomValues: grv });
    const id = newId();
    expect(id).toMatch(UUID_V4);
    expect(grv).toHaveBeenCalledOnce();
    expect((grv.mock.calls[0]![0] as Uint8Array).length).toBe(16);
  });

  it('the fallback sets the version and variant bits on whatever the CSPRNG returned', () => {
    vi.stubGlobal('crypto', { getRandomValues: (a: Uint8Array) => a.fill(0xff) });
    expect(newId()).toBe('ffffffff-ffff-4fff-bfff-ffffffffffff');
    vi.stubGlobal('crypto', { getRandomValues: (a: Uint8Array) => a.fill(0x00) });
    expect(newId()).toBe('00000000-0000-4000-8000-000000000000');
  });

  it('the fallback does not repeat (10,000 ids)', () => {
    vi.stubGlobal('crypto', { getRandomValues: (a: Uint8Array) => real.getRandomValues(a) });
    const seen = new Set<string>();
    for (let i = 0; i < 10_000; i++) seen.add(newId());
    expect(seen.size).toBe(10_000);
  });

  it('with no CSPRNG at all it throws instead of inventing an id', () => {
    vi.stubGlobal('crypto', undefined);
    expect(() => newId()).toThrow();
    const rnd = vi.spyOn(Math, 'random');
    try { newId(); } catch { /* expected */ }
    expect(rnd).not.toHaveBeenCalled();
  });

  it('only the local-mode repository calls it (ids in Supabase mode come from the database)', () => {
    const sources = import.meta.glob('/src/**/*.{ts,tsx}', { query: '?raw', import: 'default', eager: true }) as Record<string, string>;
    const callers = Object.entries(sources)
      .filter(([p, t]) => !p.includes('.test.') && p !== '/src/utils/id.ts' && /\bnewId\(/.test(t))
      .map(([p]) => p);
    expect(callers).toEqual(['/src/repositories/eventRepository.ts']);
    expect(Object.entries(sources).filter(([p, t]) => !p.includes('.test.') && /randomUUID/.test(t)).map(([p]) => p))
      .toEqual(['/src/utils/id.ts']);
  });
});
