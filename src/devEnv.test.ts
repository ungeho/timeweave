import { describe, expect, it } from 'vitest';
import config from '../vite.config';
import {
  ALLOWED_MOCK_PATHS,
  isAllowedMockPath,
  mockapiLanConfig,
  MOCK_PREFIX,
  MOCK_TARGET,
  NO_CLIENT_ENV_PREFIX,
  parseEnvText,
  resolveMockapiLanKey,
} from '../scripts/mockapi-lan.mjs';

/*
  P8-mobile-1: `--mode mockapi-lan` lets a phone on the home LAN use the
  loopback mock API through a same-origin dev-server proxy.

  RE-AUDIT (follow-up). The first version used Vite's loadEnv('mockapi'),
  which merges .env, .env.local and .env.mockapi and lets every VITE_* PROCESS
  variable override them; Vite's client env also takes VITE_* process
  variables. Measured with sentinels in the shell: the shell's anon key
  replaced the mock key in the client, and an unrelated VITE_* variable was
  served. These tests pin the fix. Every input here is fabricated text --
  nothing reads the real .env files.
*/

type Cfg = {
  server?: { proxy?: Record<string, unknown>; host?: unknown };
  define?: Record<string, string>;
  envDir?: string;
  envPrefix?: string;
};
const resolve = (command: 'serve' | 'build', mode: string) =>
  (config as unknown as (e: { command: string; mode: string }) => Cfg)({ command, mode });

const MOCK = [
  '# fabricated mock file',
  'VITE_SUPABASE_URL=http://localhost:54321',
  'VITE_SUPABASE_ANON_KEY=fabricated-mock-key',
].join('\n');
const REAL = 'VITE_SUPABASE_URL=https://real-project.example.invalid\nVITE_SUPABASE_ANON_KEY=real-looking-key';
const reader = (files: Record<string, string | null>) => (name: string) => files[name] ?? null;

describe('mockapi-lan: only .env.mockapi supplies the client values', () => {
  it('the key comes from .env.mockapi, whatever .env / .env.local say', () => {
    expect(resolveMockapiLanKey(MOCK, [REAL, REAL])).toBe('fabricated-mock-key');
    const c = mockapiLanConfig('serve', reader({ '.env.mockapi': MOCK, '.env': REAL, '.env.local': REAL })) as Cfg;
    expect(c.define!['import.meta.env.VITE_SUPABASE_ANON_KEY']).toBe('"fabricated-mock-key"');
    expect(JSON.stringify(c)).not.toContain('real-looking-key');
    expect(JSON.stringify(c)).not.toContain('real-project');
  });

  it('the URL is the page\'s own origin + the prefix, never a file value', () => {
    const c = mockapiLanConfig('serve', reader({ '.env.mockapi': MOCK })) as Cfg;
    expect(c.define!['import.meta.env.VITE_SUPABASE_URL']).toBe(`(globalThis.location.origin + "${MOCK_PREFIX}")`);
  });

  it('process variables cannot override it (they are never read)', () => {
    // The resolver takes file texts only; this is the property the old loadEnv call lacked.
    expect(resolveMockapiLanKey.length).toBe(1);
    expect(String(resolveMockapiLanKey)).not.toMatch(/process\.env/);
    expect(String(mockapiLanConfig)).not.toMatch(/process\.env|loadEnv/);
  });

  it('nothing from a .env file or the shell is exposed: empty envDir and a prefix no variable uses', () => {
    const c = mockapiLanConfig('serve', reader({ '.env.mockapi': MOCK })) as Cfg;
    expect(c.envDir).toMatch(/[\\/]scripts[\\/]?$/);
    expect(Object.keys(import.meta.glob('/scripts/.env*', { query: '?raw', import: 'default', eager: true }))).toEqual([]);
    expect(c.envPrefix).toBe(NO_CLIENT_ENV_PREFIX);
    expect(NO_CLIENT_ENV_PREFIX.startsWith('VITE_')).toBe(false);
  });
});

describe('mockapi-lan: refuses to start when it cannot be sure', () => {
  const refuse = (files: Record<string, string | null>, re: RegExp) =>
    expect(() => mockapiLanConfig('serve', reader(files))).toThrow(re);

  it('no .env.mockapi', () => refuse({ '.env.local': REAL }, /\.env\.mockapi is missing/));
  it('a key missing or empty', () => {
    refuse({ '.env.mockapi': 'VITE_SUPABASE_URL=http://localhost:54321' }, /VITE_SUPABASE_ANON_KEY is missing or empty/);
    refuse({ '.env.mockapi': 'VITE_SUPABASE_URL=http://localhost:54321\nVITE_SUPABASE_ANON_KEY=' }, /VITE_SUPABASE_ANON_KEY is missing or empty/);
    refuse({ '.env.mockapi': 'VITE_SUPABASE_ANON_KEY=x' }, /VITE_SUPABASE_URL is missing or empty/);
  });
  it('a URL that is not loopback is not the mock', () => {
    refuse({ '.env.mockapi': 'VITE_SUPABASE_URL=https://real-project.example.invalid\nVITE_SUPABASE_ANON_KEY=x' }, /not a loopback/);
    refuse({ '.env.mockapi': 'VITE_SUPABASE_URL=not a url\nVITE_SUPABASE_ANON_KEY=x' }, /not a URL/);
  });
  it('a mock value equal to a real one (files mixed up)', () => {
    refuse({ '.env.mockapi': MOCK, '.env.local': 'VITE_SUPABASE_ANON_KEY=fabricated-mock-key' }, /equals a value in \.env or \.env\.local/);
    refuse({ '.env.mockapi': MOCK, '.env': 'VITE_SUPABASE_URL=http://localhost:54321' }, /equals a value in \.env or \.env\.local/);
  });
  it('the refusal never quotes a value', () => {
    try {
      mockapiLanConfig('serve', reader({ '.env.mockapi': MOCK, '.env.local': 'VITE_SUPABASE_ANON_KEY=fabricated-mock-key' }));
    } catch (e) {
      expect(String(e)).not.toContain('fabricated-mock-key');
    }
  });
  it('a build in this mode is refused, so nothing of it can reach dist', () => {
    expect(() => mockapiLanConfig('build', reader({ '.env.mockapi': MOCK }))).toThrow(/never be built/);
    expect(() => resolve('build', 'mockapi-lan')).toThrow(/never be built/);
  });
});

describe('mockapi-lan: what a LAN client can reach through the proxy', () => {
  it('only GoTrue, PostgREST and the two phone pages', () => {
    expect(ALLOWED_MOCK_PATHS).toEqual(['/auth/v1/', '/rest/v1/', '/__mock/signin', '/__mock/signout']);
    for (const p of ['/auth/v1/user', '/auth/v1/token?grant_type=refresh_token', '/rest/v1/events?select=*',
      '/rest/v1/rpc/get_free_busy', '/__mock/signin', '/__mock/signout']) {
      expect(isAllowedMockPath(MOCK_PREFIX + p), p).toBe(true);
    }
  });
  it('the mock\'s test control and anything else answer 404', () => {
    for (const p of ['/__scenario', '/__scenario?fb=empty', '/', '', '/auth', '/rest', '/__mock/signin/x',
      '/rest/v1/../__scenario', '/auth/v1/..%2F__scenario']) {
      expect(isAllowedMockPath(MOCK_PREFIX + p), p).toBe(false);
    }
    expect(isAllowedMockPath('/rest/v1/events')).toBe(false); // not under the prefix at all
  });
  it('the proxy forwards to the LOOPBACK mock, through that filter', () => {
    const c = mockapiLanConfig('serve', reader({ '.env.mockapi': MOCK })) as Cfg & {
      server: { proxy: Record<string, { target: string; rewrite: (p: string) => string; bypass: (r: { url?: string }) => unknown }> };
    };
    expect(MOCK_TARGET).toBe('http://127.0.0.1:54321');
    expect(Object.keys(c.server.proxy)).toEqual([MOCK_PREFIX]);
    const p = c.server.proxy[MOCK_PREFIX]!;
    expect(p.target).toBe(MOCK_TARGET);
    expect(p.rewrite(`${MOCK_PREFIX}/rest/v1/events`)).toBe('/rest/v1/events');
    expect(p.bypass({ url: `${MOCK_PREFIX}/rest/v1/events` })).toBeUndefined();
    expect(p.bypass({ url: `${MOCK_PREFIX}/__scenario?saveFails=1` })).toBe(false);
  });
});

describe('every other mode is exactly as before', () => {
  it('no proxy, no LAN host, no defines, no env changes', () => {
    for (const mode of ['development', 'production', 'mock', 'mockapi']) {
      for (const command of ['serve', 'build'] as const) {
        const c = resolve(command, mode);
        expect(c.server, `${command} ${mode}`).toBeUndefined();
        expect(c.define, `${command} ${mode}`).toBeUndefined();
        expect(c.envDir, `${command} ${mode}`).toBeUndefined();
        expect(c.envPrefix, `${command} ${mode}`).toBeUndefined();
      }
    }
  });
});

describe('parseEnvText', () => {
  it('reads KEY=VALUE, skips comments, strips one layer of quotes', () => {
    expect(parseEnvText('# c\nA=1\n B = "two" \nexport C=\'3\'\n\nD=')).toEqual({ A: '1', B: 'two', C: '3', D: '' });
  });
});
