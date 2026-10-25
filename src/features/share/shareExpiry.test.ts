import { afterAll, describe, expect, it } from 'vitest';
import { shareExpiryFold, shareExpiryFromLocal, type ShareExpiryPick } from './shareExpiry';
import { shareExpiryLabel } from './shareExpiryLabel';
import { toDatetimeLocalValue } from '../../utils/datetime';

/*
  P8-c3 / P8-c3.1: the share-link expiry field -> the instant stored in
  share_links.expires_at, which the server compares with its own now()
  (`expires_at > now()`): at and after that instant the link is dead.

  The field is a native <input type="datetime-local"> read in the BROWSER's
  zone (E2). Approved rules (docs/p8-datetime-contract.md §14):
    - an ordinary wall clock      -> that instant (unchanged)
    - one that does not exist     -> refused (P8-c3; it used to become an hour LATER)
    - one that happens twice      -> refused until the owner picks the 1st or the
                                     2nd (E1; it used to take the 1st silently)
    - an instant not in the future -> refused before the RPC (E3)
  and the list shows each stored expiry with the UTC offset of THAT instant (E4).

  The OS zone stands for the browser zone, so each case runs with TZ = its zone.
  The clock is a parameter: NOW is fixed so these dates do not age into "past".
*/

const env = (globalThis as unknown as { process: { env: Record<string, string | undefined> } }).process.env;
const ORIGINAL_TZ = env.TZ;
afterAll(() => {
  if (ORIGINAL_TZ === undefined) delete env.TZ;
  else env.TZ = ORIGINAL_TZ;
});
const NOW = Date.parse('2026-01-01T00:00:00Z');
const wallOf = (iso: string, zone: string) =>
  new Intl.DateTimeFormat('en-CA', {
    timeZone: zone, hourCycle: 'h23', year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit',
  }).format(new Date(iso)).replace(', ', 'T');
const pick = (local: string, timeZone: string, choice: 'earlier' | 'later'): ShareExpiryPick => ({ local, timeZone, choice });

interface Case {
  name: string;
  zone: string;
  local: string;
  /** 'gap' | 'fold' | the instant */
  expected: 'gap' | 'fold' | string;
  /** for a fold: [1st, 2nd] */
  fold?: [string, string];
  facts: Array<[string, string]>;
}
const CASES: Case[] = [
  { name: 'Tokyo, ordinary day', zone: 'Asia/Tokyo', local: '2026-10-20T18:00', expected: '2026-10-20T09:00:00.000Z',
    facts: [['2026-10-20T09:00:00Z', '2026-10-20T18:00']] },
  { name: 'UTC', zone: 'UTC', local: '2026-03-08T02:30', expected: '2026-03-08T02:30:00.000Z',
    facts: [['2026-03-08T02:30:00Z', '2026-03-08T02:30']] },
  { name: 'New York spring gap 02:30 -> refused', zone: 'America/New_York', local: '2026-03-08T02:30', expected: 'gap',
    facts: [['2026-03-08T06:59:00Z', '2026-03-08T01:59'], ['2026-03-08T07:00:00Z', '2026-03-08T03:00']] },
  { name: 'New York spring gap, first missing minute 02:00 -> refused', zone: 'America/New_York', local: '2026-03-08T02:00',
    expected: 'gap', facts: [['2026-03-08T07:00:00Z', '2026-03-08T03:00']] },
  { name: 'New York, last minute before the gap 01:59', zone: 'America/New_York', local: '2026-03-08T01:59',
    expected: '2026-03-08T06:59:00.000Z', facts: [['2026-03-08T06:59:00Z', '2026-03-08T01:59']] },
  { name: 'New York, first minute after the gap 03:00', zone: 'America/New_York', local: '2026-03-08T03:00',
    expected: '2026-03-08T07:00:00.000Z', facts: [['2026-03-08T07:00:00Z', '2026-03-08T03:00']] },
  { name: 'New York autumn fold 01:30 -> asks', zone: 'America/New_York', local: '2026-11-01T01:30', expected: 'fold',
    fold: ['2026-11-01T05:30:00.000Z', '2026-11-01T06:30:00.000Z'],
    facts: [['2026-11-01T05:30:00Z', '2026-11-01T01:30'], ['2026-11-01T06:30:00Z', '2026-11-01T01:30']] },
  { name: 'New York, after the fold 02:00', zone: 'America/New_York', local: '2026-11-01T02:00',
    expected: '2026-11-01T07:00:00.000Z', facts: [['2026-11-01T07:00:00Z', '2026-11-01T02:00']] },
  { name: 'Havana midnight gap 00:00 -> refused', zone: 'America/Havana', local: '2026-03-08T00:00', expected: 'gap',
    facts: [['2026-03-08T04:59:00Z', '2026-03-07T23:59'], ['2026-03-08T05:00:00Z', '2026-03-08T01:00']] },
  { name: 'Havana, 23:59 the evening before', zone: 'America/Havana', local: '2026-03-07T23:59',
    expected: '2026-03-08T04:59:00.000Z', facts: [['2026-03-08T04:59:00Z', '2026-03-07T23:59']] },
  { name: 'Havana midnight fold 00:30 -> asks', zone: 'America/Havana', local: '2026-11-01T00:30', expected: 'fold',
    fold: ['2026-11-01T04:30:00.000Z', '2026-11-01T05:30:00.000Z'],
    facts: [['2026-11-01T04:30:00Z', '2026-11-01T00:30'], ['2026-11-01T05:30:00Z', '2026-11-01T00:30']] },
  { name: 'Azores midnight fold 00:00 -> asks', zone: 'Atlantic/Azores', local: '2026-10-25T00:00', expected: 'fold',
    fold: ['2026-10-25T00:00:00.000Z', '2026-10-25T01:00:00.000Z'],
    facts: [['2026-10-25T00:00:00Z', '2026-10-25T00:00'], ['2026-10-25T01:00:00Z', '2026-10-25T00:00']] },
];

describe('tzdata facts', () => {
  for (const c of CASES) it(c.name, () => { for (const [iso, w] of c.facts) expect(wallOf(iso, c.zone)).toBe(w); });
});

describe('E1/E2: the instant that is stored (browser zone = OS zone)', () => {
  for (const c of CASES) {
    it(c.name, () => {
      env.TZ = c.zone;
      const r = shareExpiryFromLocal(c.local, c.zone, null, NOW);
      if (c.expected === 'gap') expect(r.kind).toBe('gap');
      else if (c.expected === 'fold') expect(r.kind).toBe('foldUnchosen');
      else expect(r).toEqual({ kind: 'instant', iso: c.expected });
    });
  }

  it('a fold sends exactly the chosen instant: 1st and 2nd, in every fold zone', () => {
    for (const c of CASES.filter((x) => x.fold)) {
      env.TZ = c.zone;
      const first = shareExpiryFromLocal(c.local, c.zone, pick(c.local, c.zone, 'earlier'), NOW);
      const second = shareExpiryFromLocal(c.local, c.zone, pick(c.local, c.zone, 'later'), NOW);
      expect(first.kind === 'instant' && first.iso, c.name).toBe(c.fold![0]);
      expect(second.kind === 'instant' && second.iso, c.name).toBe(c.fold![1]);
      // both read back as the wall clock that was typed
      expect(wallOf(c.fold![0], c.zone)).toBe(c.local);
      expect(wallOf(c.fold![1], c.zone)).toBe(c.local);
      // and the choice is still shown with its offsets
      expect(shareExpiryFold(second)?.options.map((o) => o.iso)).toEqual(c.fold);
    }
  });

  it('New York 01:30: the two choices are UTC-04:00 and UTC-05:00, one hour apart', () => {
    env.TZ = 'America/New_York';
    const r = shareExpiryFromLocal('2026-11-01T01:30', 'America/New_York', null, NOW);
    expect(r.kind === 'foldUnchosen' && r.check.options.map((o) => [o.choice, o.offsetMinutes])).toEqual([
      ['earlier', -240], ['later', -300],
    ]);
  });

  it('a pick does not survive an edited value', () => {
    env.TZ = 'America/New_York';
    const p = pick('2026-11-01T01:30', 'America/New_York', 'later');
    expect(shareExpiryFromLocal('2026-11-01T01:45', 'America/New_York', p, NOW).kind).toBe('foldUnchosen');
    // and back on an ordinary time there is no choice left at all
    const plain = shareExpiryFromLocal('2026-11-01T03:00', 'America/New_York', p, NOW);
    expect(plain.kind).toBe('instant');
    expect(shareExpiryFold(plain)).toBeNull();
  });

  it('a pick does not survive a change of zone (the device moved)', () => {
    env.TZ = 'America/New_York';
    const madeInHavana = pick('2026-11-01T01:30', 'America/Havana', 'earlier');
    expect(shareExpiryFromLocal('2026-11-01T01:30', 'America/New_York', madeInHavana, NOW).kind).toBe('foldUnchosen');
  });

  it('the stored instant round-trips to the typed wall clock (ordinary times)', () => {
    for (const c of CASES) {
      if (c.expected === 'gap' || c.expected === 'fold') continue;
      env.TZ = c.zone;
      const r = shareExpiryFromLocal(c.local, c.zone, null, NOW);
      expect(r.kind === 'instant' && toDatetimeLocalValue(r.iso), c.name).toBe(c.local);
    }
  });

  it('an empty field is "no expiry", whatever the clock says', () => {
    env.TZ = 'Asia/Tokyo';
    expect(shareExpiryFromLocal('', 'Asia/Tokyo', null, NOW)).toEqual({ kind: 'none' });
    expect(shareExpiryFromLocal('', 'Asia/Tokyo', null, Date.parse('2999-01-01T00:00:00Z'))).toEqual({ kind: 'none' });
  });

  it('a refused gap says which times bracket it, for the explanation', () => {
    env.TZ = 'America/New_York';
    const r = shareExpiryFromLocal('2026-03-08T02:30', 'America/New_York', null, NOW);
    expect(r.kind === 'gap' && [r.check.lastBefore.slice(11), r.check.firstAfter.slice(11), r.check.gapMinutes]).toEqual(['01:59', '03:00', 60]);
  });
});

describe('E3: an expiry that is not in the future is refused before anything is sent', () => {
  const T = '2026-10-20T18:00';
  const at = Date.parse('2026-10-20T09:00:00Z'); // T in Tokyo
  it('ordinary time: past and NOW are refused, 1 ms later is accepted', () => {
    env.TZ = 'Asia/Tokyo';
    expect(shareExpiryFromLocal(T, 'Asia/Tokyo', null, at + 60_000).kind).toBe('past');
    expect(shareExpiryFromLocal(T, 'Asia/Tokyo', null, at).kind).toBe('past'); // == now: the CHECK refuses it too
    expect(shareExpiryFromLocal(T, 'Asia/Tokyo', null, at - 1)).toEqual({ kind: 'instant', iso: '2026-10-20T09:00:00.000Z' });
  });

  it('typed while it was future, pressed after it passed: refused (the check is re-run at Create)', () => {
    env.TZ = 'Asia/Tokyo';
    expect(shareExpiryFromLocal(T, 'Asia/Tokyo', null, at - 5_000).kind).toBe('instant');
    expect(shareExpiryFromLocal(T, 'Asia/Tokyo', null, at + 5_000).kind).toBe('past');
  });

  it('a fold between the two instants: the 1st is refused as past, the 2nd is accepted', () => {
    env.TZ = 'America/New_York';
    const L = '2026-11-01T01:30';
    const between = Date.parse('2026-11-01T06:00:00Z');
    expect(shareExpiryFromLocal(L, 'America/New_York', pick(L, 'America/New_York', 'earlier'), between).kind).toBe('past');
    expect(shareExpiryFromLocal(L, 'America/New_York', pick(L, 'America/New_York', 'later'), between))
      .toMatchObject({ kind: 'instant', iso: '2026-11-01T06:30:00.000Z' });
  });

  it('a fold with both instants past: refused whichever is chosen; unchosen still asks first', () => {
    env.TZ = 'America/New_York';
    const L = '2026-11-01T01:30';
    const after = Date.parse('2026-11-01T07:00:00Z');
    expect(shareExpiryFromLocal(L, 'America/New_York', null, after).kind).toBe('foldUnchosen');
    for (const ch of ['earlier', 'later'] as const) {
      expect(shareExpiryFromLocal(L, 'America/New_York', pick(L, 'America/New_York', ch), after).kind).toBe('past');
    }
  });

  it('a missing time is reported as missing even when it is also past', () => {
    env.TZ = 'America/New_York';
    expect(shareExpiryFromLocal('2026-03-08T02:30', 'America/New_York', null, Date.parse('2026-06-01T00:00:00Z')).kind).toBe('gap');
  });
});

describe('E4: the list shows the offset of the stored instant', () => {
  const cases: Array<[string, string, string, string]> = [
    // zone, instant, expected offset, expected wall clock (HH:mm)
    ['America/New_York', '2026-11-01T05:30:00.000Z', 'UTC−04:00', '01:30'],
    ['America/New_York', '2026-11-01T06:30:00.000Z', 'UTC−05:00', '01:30'],
    ['America/New_York', '2026-03-08T06:59:00.000Z', 'UTC−05:00', '01:59'],
    ['America/New_York', '2026-03-08T07:00:00.000Z', 'UTC−04:00', '03:00'],
    ['America/Havana', '2026-11-01T04:30:00.000Z', 'UTC−04:00', '00:30'],
    ['America/Havana', '2026-11-01T05:30:00.000Z', 'UTC−05:00', '00:30'],
    ['Atlantic/Azores', '2026-10-25T00:00:00.000Z', 'UTC+00:00', '00:00'],
    ['Atlantic/Azores', '2026-10-25T01:00:00.000Z', 'UTC−01:00', '00:00'],
    ['Asia/Tokyo', '2026-10-20T09:00:00.000Z', 'UTC+09:00', '18:00'],
    ['UTC', '2026-10-20T09:00:00.000Z', 'UTC+00:00', '09:00'],
    ['Asia/Kolkata', '2026-10-20T09:00:00.000Z', 'UTC+05:30', '14:30'],
    ['Asia/Kathmandu', '2026-10-20T09:00:00.000Z', 'UTC+05:45', '14:45'],
    ['Pacific/Chatham', '2026-01-10T09:00:00.000Z', 'UTC+13:45', '22:45'],
    ['Pacific/Chatham', '2026-07-10T09:00:00.000Z', 'UTC+12:45', '21:45'],
  ];
  for (const [zone, iso, off, hm] of cases) {
    it(`${zone} ${iso} -> ${hm} ${off} (ja and en)`, () => {
      env.TZ = zone;
      for (const locale of ['ja-JP', 'en-US']) {
        const s = shareExpiryLabel(iso, locale, zone);
        expect(s.endsWith(` ${off}`), `${locale}: ${s}`).toBe(true);
        const clock = /(\d{1,2}):(\d{2})(?::\d{2})?(?=\D*UTC)/.exec(s);
        expect(clock && `${clock[1]!.padStart(2, '0')}:${clock[2]}`, `${locale}: ${s}`).toBe(hm);
      }
    });
  }

  it('the offset is the stored instant\'s, not today\'s: a winter expiry in New York reads −05:00 in summer', () => {
    env.TZ = 'America/New_York';
    expect(shareExpiryLabel('2027-01-15T15:00:00.000Z', 'en-US', 'America/New_York').endsWith('UTC−05:00')).toBe(true);
    expect(shareExpiryLabel('2027-07-15T15:00:00.000Z', 'en-US', 'America/New_York').endsWith('UTC−04:00')).toBe(true);
  });

  it('the two New York 01:30s are now told apart', () => {
    env.TZ = 'America/New_York';
    const a = shareExpiryLabel('2026-11-01T05:30:00.000Z', 'ja-JP', 'America/New_York');
    const b = shareExpiryLabel('2026-11-01T06:30:00.000Z', 'ja-JP', 'America/New_York');
    expect(a.replace(/ UTC.*$/, '')).toBe(b.replace(/ UTC.*$/, ''));
    expect(a).not.toBe(b);
  });
});

// ShareDialog cannot be rendered here (vitest runs in node, no DOM), so the
// wiring is checked in its source, comments removed.
const DIALOG = (import.meta.glob('/src/features/share/ShareDialog.tsx', { query: '?raw', import: 'default', eager: true }) as Record<string, string>)[
  '/src/features/share/ShareDialog.tsx'
]!.replace(/\/\*[\s\S]*?\*\//g, '').replace(/(^|[^:])\/\/.*$/gm, '$1');

describe('ShareDialog wiring', () => {
  it('the field is judged in the browser zone on every render, with the pick', () => {
    expect(DIALOG).toMatch(/const timeZone = getUserTimeZone\(\);/);
    expect(DIALOG).toMatch(/shareExpiryFromLocal\(expiresLocal, timeZone, expiryPick\)/);
    expect(DIALOG).not.toMatch(/isoFromDatetimeLocalValue/);
  });

  it('Create judges it again with a fresh zone and clock, and returns BEFORE createShareLink', () => {
    const create = DIALOG.indexOf('const handleCreate');
    const judge = DIALOG.indexOf('shareExpiryFromLocal(expiresLocal, getUserTimeZone(), expiryPick, Date.now())', create);
    const refuse = DIALOG.indexOf("if (expiryNow.kind !== 'none' && expiryNow.kind !== 'instant')", create);
    const call = DIALOG.indexOf('createShareLink(', create);
    expect(judge).toBeGreaterThan(create);
    expect(refuse).toBeGreaterThan(judge);
    expect(call).toBeGreaterThan(refuse);
    expect(DIALOG).toMatch(/expiresAt: expiryNow\.kind === 'instant' \? expiryNow\.iso : null/);
  });

  it('a pick is made for the current value and zone, and editing the value drops it', () => {
    expect(DIALOG).toMatch(/onChoose=\{\(choice\) => setExpiryPick\(\{ local: expiresLocal, timeZone, choice \}\)\}/);
    expect(DIALOG).toMatch(/setExpiresLocal\(e\.target\.value\);\s*setExpiryPick\(null\);/);
  });

  it('the explanation is the event form\'s, for a gap or a fold, tied to the field', () => {
    expect(DIALOG).toMatch(/\(expiry\.kind === 'gap' \|\| expiryFoldCheck\) && \(\s*<div id="share-expiry-dst">\s*<WallTimeNotice/);
    expect(DIALOG).toMatch(/aria-describedby=\{expiryDescribedBy\}/);
    expect(DIALOG).toMatch(/<p id="share-expiry-error" className="form-error" role="alert">/);
  });

  it('the list line shows the offset of the stored instant', () => {
    expect(DIALOG).toMatch(/shareExpiryLabel\(l\.expiresAt, intlLocale\(language\), timeZone\)/);
  });
});
