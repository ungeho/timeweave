/**
 * A stand-in for the Supabase endpoints TimeWeave actually calls.
 *
 * WHY THIS EXISTS. Four screens -- the login page, the settings dialog, the
 * share dialog and the anonymous share page's Busy/Available body -- are gated
 * on `isSupabaseConfigured` and on a signed-in user, so local mode cannot
 * reach them. Loosening those gates in the app would be changing the thing
 * under test. Instead the app runs its REAL code path against a server that
 * speaks just enough of PostgREST and GoTrue.
 *
 * WHY IT IS SAFE.
 *   * It binds 127.0.0.1 only, so nothing it serves can leave the machine.
 *   * It is dev tooling under scripts/, so nothing in src/ imports it and it
 *     is not in the module graph vite build walks. It is never bundled and
 *     never reaches dist. The one plugin that does copy files into the build,
 *     scripts/guide-images.mjs, emits only the PNGs the image manifest lists,
 *     so this file cannot ride along as an asset either. A test asserts both.
 *   * The app's own source is untouched: `isSupabaseConfigured` becomes true
 *     because the env file says so, which is the real mechanism.
 *   * Every value below is fabricated. No production credential, user or share
 *     token is involved.
 *
 * Run: npm run shots:api        (or: node scripts/mock-supabase.mjs)
 *
 * MOVED INTO THE REPOSITORY in P7-d stage 2. It lived in a session scratchpad
 * while the first screenshots were taken, which meant the one thing it exists
 * for -- reproducing a shot later, from another machine -- was the one thing
 * it could not do.
 */

import http from 'node:http';

const PORT = 54321;

/** Flipped at runtime through /__scenario so one browser session can walk the states. */
const state = {
  // complete | indeterminate | not_requested | empty | nothing_shared | busy_wins | unavailable
  freeBusy: 'complete',
  saveFails: false,
  eventsFail: false,
  links: [
    {
      id: '11111111-1111-4111-8111-111111111111',
      label: '営業チーム Sales team',
      include_private: true,
      expires_at: null,
      revoked_at: null,
      created_at: '2026-10-01T00:00:00.000Z',
      share_available: true,
    },
    {
      id: '22222222-2222-4222-8222-222222222222',
      label: null,
      include_private: false,
      expires_at: '2026-10-20T00:00:00.000Z',
      revoked_at: null,
      created_at: '2026-10-05T00:00:00.000Z',
      share_available: false,
    },
    // Expired but NOT revoked, which is its own state: the dialog offers no
    // delete button on it and says to revoke first. Without this row the link
    // list shows only active and revoked, and the three-state table in the
    // guide would have nothing behind one of its rows.
    {
      id: '44444444-4444-4444-8444-444444444444',
      label: '期限切れ Expired link',
      include_private: false,
      expires_at: '2026-10-09T00:00:00.000Z',
      revoked_at: null,
      created_at: '2026-09-28T00:00:00.000Z',
      share_available: false,
    },
    {
      id: '33333333-3333-4333-8333-333333333333',
      label: '失効済み Revoked link',
      include_private: true,
      expires_at: null,
      revoked_at: '2026-10-08T00:00:00.000Z',
      created_at: '2026-10-02T00:00:00.000Z',
      share_available: false,
    },
  ],
  settings: { timezone: 'Asia/Tokyo', language: null },
};

/**
 * A calendar with something on it, for the month and week screenshots.
 *
 * TITLES ARE BILINGUAL, the same convention the share links above already use
 * ("営業チーム Sales team"). Event titles are the owner's own data, not UI
 * strings, so they do not translate -- and the Japanese and English shots are
 * supposed to differ only by language. One seed read in both keeps that true
 * literally, where a per-language seed would make the two pictures show
 * different calendars.
 *
 * Shape is the DB row (snake_case), which is what rowToEvent reads. Times are
 * UTC; the seed is written for a JST browser, so subtract 9 to read them back.
 */
const OWNER = '00000000-0000-4000-8000-000000000001';
const ts = { created_at: '2026-10-01T00:00:00.000Z', updated_at: '2026-10-01T00:00:00.000Z' };
const EVENT_BASE = {
  owner_id: OWNER,
  description: null,
  category: null,
  visibility: 'private',
  availability: 'busy',
  all_day: false,
  start_at: null, end_at: null, start_date: null, end_date: null,
  rrule: null,
  recurrence_id: null, recurrence_slot_start: null, recurrence_slot_date: null,
  is_cancelled: false,
  timezone: null,
  ...ts,
};
const EVENTS = [
  // A weekly recurring master: Mondays 09:00-09:30 JST. Carries a zone because
  // a timed recurrence is anchored to a wall clock (0008).
  {
    ...EVENT_BASE,
    id: 'aaaaaaaa-0000-4000-8000-000000000001',
    title: '定例 Standup',
    category: '会議 Meeting',
    start_at: '2026-10-05T00:00:00.000Z',
    end_at: '2026-10-05T00:30:00.000Z',
    rrule: 'FREQ=WEEKLY;BYDAY=MO',
    timezone: 'Asia/Tokyo',
  },
  // An all-day span. end_date is EXCLUSIVE, so this covers the 16th, 17th, 18th.
  {
    ...EVENT_BASE,
    id: 'aaaaaaaa-0000-4000-8000-000000000002',
    title: '出張 Trip',
    all_day: true,
    start_date: '2026-10-16',
    end_date: '2026-10-19',
  },
  {
    ...EVENT_BASE,
    id: 'aaaaaaaa-0000-4000-8000-000000000003',
    title: 'レビュー Review',
    category: '会議 Meeting',
    start_at: '2026-10-13T05:00:00.000Z',
    end_at: '2026-10-13T06:00:00.000Z',
  },
  {
    ...EVENT_BASE,
    id: 'aaaaaaaa-0000-4000-8000-000000000004',
    title: '面談 1-on-1',
    start_at: '2026-10-14T02:00:00.000Z',
    end_at: '2026-10-14T02:30:00.000Z',
  },
  // The one event marked available, so the guide's "visibility and
  // availability are separate" claim has a real row behind it.
  {
    ...EVENT_BASE,
    id: 'aaaaaaaa-0000-4000-8000-000000000005',
    title: '相談枠 Office hours',
    availability: 'available',
    start_at: '2026-10-15T07:00:00.000Z',
    end_at: '2026-10-15T09:00:00.000Z',
  },
];

const SLOTS = [
  { all_day: false, start: '2026-10-13T00:00:00.000Z', end: '2026-10-13T00:30:00.000Z' },
  { all_day: false, start: '2026-10-13T05:00:00.000Z', end: '2026-10-13T06:00:00.000Z' },
  { all_day: true, start_date: '2026-10-16', end_date: '2026-10-19' },
];
const AVAILABLE_SLOTS = [
  { all_day: false, start: '2026-10-14T01:00:00.000Z', end: '2026-10-14T03:00:00.000Z' },
];

/**
 * Busy winning over Available, in the shape the real RPC returns it.
 *
 * The owner marked 14:00-17:00 available and has a 15:00-16:00 event. 0024
 * subtracts in SQL (`v_avail_t - v_busy_t`), so what reaches a client is
 * ALREADY split -- an overlapping pair never crosses the wire. Sending the
 * halves is therefore not a staged picture; sending 14:00-17:00 whole would be,
 * because no server would ever say that.
 *
 * Times are UTC; a JST browser draws them as 14:00-17:00.
 */
const BUSY_WINS_BUSY = [
  { all_day: false, start: '2026-10-14T06:00:00.000Z', end: '2026-10-14T07:00:00.000Z' },
];
const BUSY_WINS_AVAILABLE = [
  { all_day: false, start: '2026-10-14T05:00:00.000Z', end: '2026-10-14T06:00:00.000Z' },
  { all_day: false, start: '2026-10-14T07:00:00.000Z', end: '2026-10-14T08:00:00.000Z' },
];

function freeBusyBody() {
  switch (state.freeBusy) {
    case 'unavailable':
      return { link_state: 'unavailable', complete: true, slots: [], available: { status: 'not_requested' } };
    case 'not_requested':
      return { link_state: 'active', complete: true, slots: SLOTS, available: { status: 'not_requested' } };
    case 'indeterminate':
      return { link_state: 'active', complete: true, slots: SLOTS, available: { status: 'indeterminate' } };
    // An exact, empty AVAILABLE answer, with busy present.
    //
    // WAS `slots: []` TOO, which is a different state: with no busy either,
    // FreeBusyPage shows the "nothing is shared" notice AND the "no open time
    // is shared" one, stacked. That conflates "the link discloses nothing" with
    // "open time was computed and there is none" -- the second is the one the
    // guide contrasts against indeterminate, and it needs busy on screen to be
    // the only banner. The all-empty case is 'nothing_shared' below.
    case 'empty':
      return { link_state: 'active', complete: true, slots: SLOTS, available: { status: 'complete', slots: [] } };
    // The link is active and discloses nothing at all in this window.
    case 'nothing_shared':
      return { link_state: 'active', complete: true, slots: [], available: { status: 'complete', slots: [] } };
    case 'busy_wins':
      return {
        link_state: 'active',
        complete: true,
        slots: BUSY_WINS_BUSY,
        available: { status: 'complete', slots: BUSY_WINS_AVAILABLE },
      };
    default:
      return {
        link_state: 'active',
        complete: true,
        slots: SLOTS,
        available: { status: 'complete', slots: AVAILABLE_SLOTS },
      };
  }
}

const USER = {
  id: '00000000-0000-4000-8000-000000000001',
  aud: 'authenticated',
  role: 'authenticated',
  email: 'demo@example.test',
  email_confirmed_at: '2026-01-01T00:00:00.000Z',
  phone: '',
  confirmed_at: '2026-01-01T00:00:00.000Z',
  last_sign_in_at: '2026-10-01T00:00:00.000Z',
  app_metadata: { provider: 'google', providers: ['google'] },
  user_metadata: { name: 'Demo Owner' },
  identities: [],
  created_at: '2026-01-01T00:00:00.000Z',
  updated_at: '2026-10-01T00:00:00.000Z',
  is_anonymous: false,
};

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'GET,POST,PATCH,DELETE,OPTIONS',
  'Access-Control-Allow-Headers': '*',
  'Access-Control-Expose-Headers': '*',
};

function send(res, code, body) {
  const payload = body === undefined ? '' : JSON.stringify(body);
  res.writeHead(code, { 'Content-Type': 'application/json', ...CORS });
  res.end(payload);
}

/** A PostgREST-shaped error, so the app's own mapping runs. */
function sendPgError(res, code, { message, details = '', hint = '', pgcode = '' }) {
  res.writeHead(code, { 'Content-Type': 'application/json', ...CORS });
  res.end(JSON.stringify({ message, details, hint, code: pgcode }));
}

function readBody(req) {
  return new Promise((resolve) => {
    let s = '';
    req.on('data', (c) => (s += c));
    req.on('end', () => {
      try {
        resolve(s ? JSON.parse(s) : {});
      } catch {
        resolve({});
      }
    });
  });
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, 'http://127.0.0.1');
  const path = url.pathname;

  if (req.method === 'OPTIONS') {
    res.writeHead(204, CORS);
    return res.end();
  }

  // ---- sign-in page for a phone (P8-mobile-1, --mode mockapi-lan) ------
  // Not part of any Supabase API. A phone has no console to paste the
  // fabricated session into (docs/p7-screenshot-procedure.md §3), so this
  // page does it. Reached as <app origin>/__mock_supabase/__mock/signin
  // through the dev server's proxy, so it runs on the APP's origin and writes
  // the key supabase-js derives from that origin's hostname. The session is
  // the same fabricated one; this server still listens on 127.0.0.1 only.
  if (path === '/__mock/signin') {
    const session = {
      access_token: 'mock', token_type: 'bearer', expires_in: 31536000, refresh_token: 'mock', user: USER,
    };
    const html = `<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width">
<title>Mock sign-in (fictional)</title>
<p>Signing in as the fictional mock user…</p>
<script>
  const s = ${JSON.stringify(session)};
  s.expires_at = Math.floor(Date.now() / 1000) + s.expires_in;
  localStorage.setItem('sb-' + location.hostname.split('.')[0] + '-auth-token', JSON.stringify(s));
  location.replace('/');
</script>`;
    res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-store' });
    return res.end(html);
  }

  // The way back out: removes the fabricated session for this origin, so the
  // phone is left signed out when testing ends (docs/p8-mobile-testing.md).
  // Only the session key; local-mode test events live under another key and
  // are cleared with the browser's site data, as the procedure says.
  if (path === '/__mock/signout') {
    const html = `<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width">
<title>Mock sign-out</title>
<p>Signing out the fictional mock user…</p>
<script>
  localStorage.removeItem('sb-' + location.hostname.split('.')[0] + '-auth-token');
  location.replace('/');
</script>`;
    res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-store' });
    return res.end(html);
  }

  // ---- test control (not part of any Supabase API) ----------------------
  if (path === '/__scenario') {
    if (url.searchParams.has('fb')) state.freeBusy = url.searchParams.get('fb');
    if (url.searchParams.has('saveFails')) state.saveFails = url.searchParams.get('saveFails') === '1';
    if (url.searchParams.has('eventsFail')) state.eventsFail = url.searchParams.get('eventsFail') === '1';
    // Clearing the zone is a real state (not a missing value), and the unset
    // notice in the settings dialog is the only thing that reports it.
    if (url.searchParams.has('tz')) {
      const v = url.searchParams.get('tz');
      state.settings.timezone = v === 'null' || v === '' ? null : v;
    }
    if (url.searchParams.has('language')) {
      const v = url.searchParams.get('language');
      state.settings.language = v === 'null' ? null : v;
    }
    return send(res, 200, { ok: true, state: { freeBusy: state.freeBusy, saveFails: state.saveFails, settings: state.settings } });
  }

  // ---- GoTrue -----------------------------------------------------------
  if (path.startsWith('/auth/v1/')) {
    if (path === '/auth/v1/user') return send(res, 200, USER);
    if (path === '/auth/v1/logout') return send(res, 204);
    if (path === '/auth/v1/token') {
      return send(res, 200, {
        access_token: 'mock-access-token',
        token_type: 'bearer',
        expires_in: 3600,
        expires_at: Math.floor(Date.now() / 1000) + 3600,
        refresh_token: 'mock-refresh-token',
        user: USER,
      });
    }
    return send(res, 200, {});
  }

  // ---- PostgREST RPC ----------------------------------------------------
  if (path.startsWith('/rest/v1/rpc/')) {
    const fn = path.slice('/rest/v1/rpc/'.length);
    const body = await readBody(req);

    if (fn === 'list_share_links') return send(res, 200, state.links);

    if (fn === 'create_share_link') {
      const label = body.p_label ?? null;
      if (label && label.length > 50) {
        return sendPgError(res, 400, { message: 'value too long', pgcode: '23514' });
      }
      const row = {
        id: crypto.randomUUID(),
        label,
        include_private: body.p_include_private ?? true,
        expires_at: body.p_expires_at ?? null,
        revoked_at: null,
        created_at: new Date().toISOString(),
        share_available: body.p_share_available ?? false,
        token: 'mock-token-' + Math.random().toString(36).slice(2, 10),
      };
      state.links.unshift({ ...row, token: undefined });
      return send(res, 200, [row]);
    }

    if (fn === 'set_share_available') {
      const l = state.links.find((x) => x.id === body.p_id);
      if (!l || l.revoked_at) return send(res, 200, false);
      l.share_available = Boolean(body.p_enabled);
      return send(res, 200, true);
    }

    if (fn === 'revoke_share_link') {
      const l = state.links.find((x) => x.id === body.p_id);
      if (!l || l.revoked_at) return send(res, 200, false);
      l.revoked_at = new Date().toISOString();
      return send(res, 200, true);
    }

    if (fn === 'delete_share_link') {
      const i = state.links.findIndex((x) => x.id === body.p_id && x.revoked_at);
      if (i === -1) return send(res, 200, false);
      state.links.splice(i, 1);
      return send(res, 200, true);
    }

    if (fn === 'get_free_busy') return send(res, 200, freeBusyBody());

    return send(res, 200, null);
  }

  // ---- PostgREST tables -------------------------------------------------
  if (path === '/rest/v1/events') {
    if (state.eventsFail) {
      return sendPgError(res, 429, { message: 'TIMEWEAVE_RATE_WRITE: too many requests', details: 'TIMEWEAVE_RATE_WRITE', hint: '30', pgcode: 'P0001' });
    }
    return send(res, 200, EVENTS);
  }

  if (path === '/rest/v1/owner_settings') {
    if (req.method === 'GET') return send(res, 200, state.settings);
    const body = await readBody(req);
    const input = Array.isArray(body) ? body[0] : body;
    if (state.saveFails) {
      // 0025's trigger marker, so the app maps it to InvalidTimezoneError and
      // the dialog's own error path runs.
      return sendPgError(res, 400, {
        message: 'TIMEWEAVE_TZ_INVALID: unsupported time zone',
        details: 'TIMEWEAVE_TZ_INVALID',
        pgcode: 'P0001',
      });
    }
    state.settings = { timezone: input.timezone ?? null, language: input.language ?? null };
    return send(res, 200, state.settings);
  }

  return send(res, 404, { message: 'not mocked: ' + path });
});

// A port left behind by an earlier capture session is the likeliest way to
// start this and get nothing. Node's default is an unhandled 'error' event and
// a stack trace, which reads as a bug in the mock rather than as "something is
// already listening".
server.on('error', (err) => {
  if (err.code === 'EADDRINUSE') {
    console.error(
      `port ${PORT} is already in use -- a mock from an earlier capture session\n` +
        'is probably still running. Stop it, then start this again.',
    );
    process.exit(1);
  }
  throw err;
});

server.listen(PORT, '127.0.0.1', () => {
  console.log(`mock supabase on http://127.0.0.1:${PORT} (loopback only)`);
});
