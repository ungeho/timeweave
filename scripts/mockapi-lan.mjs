/**
 * `--mode mockapi-lan`: the mock API (scripts/mock-supabase.mjs) for a PHONE on
 * the home LAN. P8-mobile-1. Dev tooling only -- never part of a build.
 *
 * WHY. `npm run shots:app` points the app at http://localhost:54321. A phone
 * that opens http://<PC>:5199 resolves "localhost" to ITSELF, so the mock is
 * unreachable and there is no signed-in user, hence no share button. Opening
 * the mock API to the LAN would also open its fabricated auth; instead:
 *
 *   phone ──http──> Vite (LAN, :5199) ──proxy /__mock_supabase/<allowed>──> mock (127.0.0.1:54321)
 *
 * WHAT REACHES THE BROWSER, AND FROM WHERE (re-audited, P8-mobile-1 follow-up).
 * The first version called Vite's loadEnv('mockapi', ...), which MERGES .env,
 * .env.local, .env.mockapi and .env.mockapi.local and then lets every VITE_*
 * PROCESS variable override the result -- and Vite's own client env takes
 * VITE_* process variables even from an empty envDir. Measured with sentinel
 * values set in the shell: the shell's VITE_SUPABASE_ANON_KEY replaced the mock
 * key in the client, and an unrelated VITE_* shell variable was served too. Now:
 *
 *   * `.env.mockapi` is read DIRECTLY and ALONE (readMockapiEnv): no merge, no
 *     process override. Both keys must be present and non-empty, and its URL
 *     must be loopback -- the proof that it is the mock's file. Otherwise the
 *     server refuses to start.
 *   * `.env` and `.env.local` are read only to COMPARE: if the mock key or URL
 *     equals one of their values, something has been mixed up and the server
 *     refuses to start. Their values are never returned, printed or served.
 *   * The client env is emptied: envDir is this folder (no .env files) and
 *     envPrefix is a prefix nothing uses, so no VITE_* variable from a file or
 *     the shell reaches import.meta.env. The two Supabase values are DEFINED:
 *     the URL as the PAGE's own origin + /__mock_supabase (no IP is written
 *     anywhere), the key as the fabricated one from .env.mockapi.
 *   * The proxy forwards only what the app calls (GoTrue under /auth/v1/,
 *     PostgREST under /rest/v1/) and the two phone pages (sign in / sign out).
 *     Everything else under the prefix -- notably the mock's /__scenario test
 *     control -- answers 404 from the LAN; the mock itself listens on
 *     127.0.0.1 only, as before.
 *   * A build in this mode is refused, so none of this can reach dist.
 *   * The app's auth, `isSupabaseConfigured` and the share-button gate are
 *     untouched: the app takes its real Supabase code path, against the mock.
 *
 * Use only on a home LAN you trust, with fictional data, and stop the server
 * when done (docs/p8-mobile-testing.md).
 */

import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

export const MOCK_PREFIX = '/__mock_supabase';
export const MOCK_TARGET = 'http://127.0.0.1:54321';
/** The only mock paths a LAN client may reach through the proxy. */
export const ALLOWED_MOCK_PATHS = ['/auth/v1/', '/rest/v1/', '/__mock/signin', '/__mock/signout'];
/** A prefix no variable uses: nothing from a .env file or the shell is exposed. */
export const NO_CLIENT_ENV_PREFIX = 'TIMEWEAVE_MOCKAPI_LAN_EXPOSES_NOTHING_';

const ROOT = new URL('../', import.meta.url);
const KEYS = ['VITE_SUPABASE_URL', 'VITE_SUPABASE_ANON_KEY'];
const LOOPBACK = new Set(['localhost', '127.0.0.1', '[::1]', '::1']);

/** KEY=VALUE lines of one dotenv file. Comments and blank lines ignored, one layer of quotes removed. */
export function parseEnvText(text) {
  const out = {};
  for (const raw of String(text).split(/\r?\n/)) {
    const m = /^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$/.exec(raw);
    if (!m) continue;
    let v = m[2].trim();
    if ((v.startsWith('"') && v.endsWith('"')) || (v.startsWith("'") && v.endsWith("'"))) v = v.slice(1, -1);
    out[m[1]] = v;
  }
  return out;
}

/**
 * The fabricated anon key to define, from the TEXT of .env.mockapi alone.
 * `others` are the texts of .env / .env.local, used only for the conflict check.
 * Throws -- without quoting any value -- whenever it cannot be sure.
 */
export function resolveMockapiLanKey(mockapiText, others = []) {
  if (mockapiText == null) throw new Error('mockapi-lan: .env.mockapi is missing; refusing to start.');
  const mock = parseEnvText(mockapiText);
  for (const k of KEYS) {
    if (!mock[k]) throw new Error(`mockapi-lan: ${k} is missing or empty in .env.mockapi; refusing to start.`);
  }
  let host;
  try {
    host = new URL(mock.VITE_SUPABASE_URL).hostname;
  } catch {
    throw new Error('mockapi-lan: VITE_SUPABASE_URL in .env.mockapi is not a URL; refusing to start.');
  }
  if (!LOOPBACK.has(host)) {
    throw new Error('mockapi-lan: VITE_SUPABASE_URL in .env.mockapi is not a loopback address, so it is not the mock; refusing to start.');
  }
  for (const text of others) {
    if (text == null) continue;
    const real = parseEnvText(text);
    for (const k of KEYS) {
      if (real[k] && real[k] === mock[k]) {
        throw new Error(`mockapi-lan: ${k} in .env.mockapi equals a value in .env or .env.local; refusing to start.`);
      }
    }
  }
  return mock.VITE_SUPABASE_ANON_KEY;
}

/** Whether a request path under MOCK_PREFIX may be forwarded to the mock. */
export function isAllowedMockPath(urlPath) {
  if (!urlPath.startsWith(MOCK_PREFIX + '/')) return false;
  const rest = urlPath.slice(MOCK_PREFIX.length).split('?')[0];
  if (rest.includes('..')) return false;
  return ALLOWED_MOCK_PATHS.some((p) => (p.endsWith('/') ? rest.startsWith(p) : rest === p));
}

const readOrNull = (name) => {
  try {
    return readFileSync(new URL(name, ROOT), 'utf8');
  } catch {
    return null;
  }
};

/**
 * @param {'serve' | 'build'} command
 * @param {(name: string) => string | null} [read]  file reader, for tests
 */
export function mockapiLanConfig(command, read = readOrNull) {
  if (command !== 'serve') {
    throw new Error('mockapi-lan is a dev-server-only mode; it must never be built.');
  }
  const anonKey = resolveMockapiLanKey(read('.env.mockapi'), [read('.env'), read('.env.local')]);
  return {
    envDir: fileURLToPath(new URL('.', import.meta.url)),
    envPrefix: NO_CLIENT_ENV_PREFIX,
    define: {
      // An EXPRESSION, evaluated in the browser: the page's own origin.
      'import.meta.env.VITE_SUPABASE_URL': `(globalThis.location.origin + ${JSON.stringify(MOCK_PREFIX)})`,
      'import.meta.env.VITE_SUPABASE_ANON_KEY': JSON.stringify(anonKey),
    },
    server: {
      host: '0.0.0.0',
      port: 5199,
      strictPort: true,
      proxy: {
        [MOCK_PREFIX]: {
          target: MOCK_TARGET,
          changeOrigin: true,
          rewrite: (p) => p.slice(MOCK_PREFIX.length) || '/',
          // Returning false makes Vite answer 404 instead of forwarding.
          bypass: (req) => (isAllowedMockPath(req.url ?? '') ? undefined : false),
        },
      },
    },
  };
}
