// Generates supabase/tests/0027_day_start_cases.sql: the client's day-start rule
// (dayStartInstantIso, src/utils/timezone.ts) as expected values for the SQL
// function timeweave_private.zoned_day_start (migration 0027).
//
//   node scripts/gen-day-start-cases.mjs
//
// WHICH DAYS. Every zone in this runtime's tzdata is scanned for offset changes
// 2005-2030 whose jump or fold contains a local midnight; each such date, the
// day before and the day after become cases. On top of that, for the zones the
// P8-c1.2 brief names, every DST switch date 2024-2027 with its neighbours (the
// 23- and 25-hour days) and two ordinary days a year, plus the Apia 2011 skip.
//
// TZDATA CAN DIFFER between this runtime (ICU) and the database server. So
// each row also carries the FACT its expectation rests on: the wall clock one
// second before the expected start and at it. The SQL side first checks that
// its own tzdata shows the same two wall clocks; a row whose fact disagrees is
// reported as tzdata-differs, never counted as a pass or silently skipped.
import { writeFileSync } from 'node:fs';
import { pathToFileURL, fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const { dayStartInstantIso } = await import(pathToFileURL(resolve(ROOT, 'src/utils/timezone.ts')).href);
const { addDaysToDateString } = await import(pathToFileURL(resolve(ROOT, 'src/utils/datetime.ts')).href);

const FORMATS = new Map();
function wall(ms, tz) {
  let f = FORMATS.get(tz);
  if (!f) {
    f = new Intl.DateTimeFormat('en-CA', {
      timeZone: tz, hourCycle: 'h23', year: 'numeric', month: '2-digit', day: '2-digit',
      hour: '2-digit', minute: '2-digit', second: '2-digit',
    });
    FORMATS.set(tz, f);
  }
  const p = Object.fromEntries(f.formatToParts(new Date(ms)).map((x) => [x.type, x.value]));
  return `${p.year}-${p.month}-${p.day} ${p.hour}:${p.minute}:${p.second}`;
}
const offsetAt = (ms, tz) => {
  const [d, t] = wall(ms, tz).split(' ');
  const [y, mo, da] = d.split('-').map(Number);
  const [h, mi, s] = t.split(':').map(Number);
  return Date.UTC(y, mo - 1, da, h, mi, s) - Math.floor(ms / 1000) * 1000;
};
const DAY = 86_400_000;

/** Every offset change in [from, to) as { at, before, after }. */
function transitions(tz, from, to) {
  const out = [];
  let prev = offsetAt(from, tz);
  for (let t = from + DAY; t < to; t += DAY) {
    const o = offsetAt(t, tz);
    if (o === prev) continue;
    let lo = t - DAY, hi = t;
    while (hi - lo > 1000) { const mid = lo + Math.floor((hi - lo) / 2000) * 1000; if (offsetAt(mid, tz) === o) hi = mid; else lo = mid; }
    out.push({ at: hi, before: wall(hi - 1000, tz), after: wall(hi, tz) });
    prev = o;
  }
  return out;
}

const cases = new Map(); // key tz|d -> kind
const add = (tz, d, kind) => { const k = `${tz}|${d}`; if (!cases.has(k)) cases.set(k, kind); };

// 1. the midnight scan, all zones
for (const tz of Intl.supportedValuesOf('timeZone')) {
  for (const tr of transitions(tz, Date.UTC(2005, 0, 1), Date.UTC(2031, 0, 1))) {
    const crossesMidnight = tr.before.slice(0, 10) !== tr.after.slice(0, 10) || tr.after.endsWith('00:00:00');
    if (!crossesMidnight) continue;
    const back = offsetAt(tr.at, tz) < offsetAt(tr.at - 1000, tz);
    const d = tr.after.slice(0, 10);
    // a fold's doubled midnight belongs to the date the clock goes back INTO
    const day = back ? tr.after.slice(0, 10) : d;
    add(tz, addDaysToDateString(day, -1), 'neighbour');
    add(tz, day, back ? 'midnight-fold' : 'midnight-gap');
    add(tz, addDaysToDateString(day, 1), 'neighbour');
  }
}
// 2. the named zones: every switch 2024-2027 (23/25-hour days) and ordinary days
const NAMED = ['UTC', 'Asia/Tokyo', 'America/New_York', 'America/Havana', 'Atlantic/Azores',
  'America/Santiago', 'Africa/Cairo', 'Pacific/Apia'];
for (const tz of NAMED) {
  for (const y of [2024, 2025, 2026, 2027]) {
    add(tz, `${y}-01-15`, 'ordinary');
    add(tz, `${y}-06-15`, 'ordinary');
  }
  for (const tr of transitions(tz, Date.UTC(2024, 0, 1), Date.UTC(2028, 0, 1))) {
    const d = tr.after.slice(0, 10);
    add(tz, addDaysToDateString(d, -1), 'switch-neighbour');
    add(tz, d, 'switch-day');
    add(tz, addDaysToDateString(d, 1), 'switch-neighbour');
  }
}
// 3. the date that never happened
for (const d of ['2011-12-29', '2011-12-30', '2011-12-31', '2012-01-01']) add('Pacific/Apia', d, d === '2011-12-30' ? 'skipped-date' : 'neighbour');

const rows = [...cases.entries()].sort(([a], [b]) => (a < b ? -1 : 1)).map(([k, kind]) => {
  const [tz, d] = k.split('|');
  const ms = Date.parse(dayStartInstantIso(d, tz));
  return { tz, d, kind, expected: new Date(ms).toISOString().replace('T', ' ').replace('.000Z', '+00'),
           before: wall(ms - 1000, tz), at: wall(ms, tz) };
});
const kinds = {};
for (const r of rows) kinds[r.kind] = (kinds[r.kind] ?? 0) + 1;
const zones = new Set(rows.map((r) => r.tz));

const esc = (s) => s.replace(/'/g, "''");
const values = rows.map((r) => `  ('${esc(r.tz)}', date '${r.d}', '${r.kind}', '${r.expected}', '${r.before}', '${r.at}')`).join(',\n');
const icu = process.versions.icu, tzv = process.versions.tz;

const sql = `-- ============================================================================
-- 0027 BOUNDARY CASES -- GENERATED by scripts/gen-day-start-cases.mjs. Do not edit;
-- regenerate. Read-only; run AFTER 0027 (it calls 0027's zoned_day_start).
--
-- HOW TO RUN. This file opens its own transaction (BEGIN ... ROLLBACK), so:
--   psql:       psql -X -v ON_ERROR_STOP=1 -f supabase/tests/0027_day_start_cases.sql
--               NOT with -1: psql's BEGIN comes first, the BEGIN below only
--               warns, and the ROLLBACK below ends psql's transaction early.
--               (On 18.6 it still ended up read-only, but that is not
--               documented behaviour; the gate checks either way.)
--   SQL Editor: the whole file as one execution.
-- The gate (statement 4) stops the run unless the transaction is read-only with
-- a 30 s limit. Cost: ${rows.length} constant rows, no application data.
--
-- Expected = the CLIENT's dayStartInstantIso (src/utils/timezone.ts), computed
-- by Node ${process.versions.node} / ICU ${icu} / tzdata ${tzv}.
-- ${rows.length} cases in ${zones.size} zones: ${Object.entries(kinds).map(([k, n]) => `${k} ${n}`).join(', ')}.
--
-- Each row first checks this SERVER's tzdata against the fact the expectation
-- rests on (the wall clock 1 s before the expected start, and at it). Rows whose
-- fact disagrees are tzdata-differs: reported, never counted as passing.
-- GO (the ZZZ row reads ok): mismatch = 0 AND tzdata-differs = 0 AND all
-- ${rows.length} cases evaluated. A tzdata-differs row means the server's tzdata
-- disagrees with the client's about those dates: that is a FAIL to record and
-- report, not a pass -- the expectation was not checked there.
-- ============================================================================
begin transaction read only;
set local timezone = 'UTC';
set local statement_timeout = '30s';
select case when current_setting('transaction_read_only') = 'on' and current_setting('statement_timeout') = '30s'
            then 'gate: read only, 30s'
            else ('STOPPED: read_only=' || current_setting('transaction_read_only') || ', statement_timeout=' || current_setting('statement_timeout'))::int::text end as gate;

with c(tz, d, kind, expected, wall_before, wall_at) as (values
${values}
),
r as (
  select c.*,
         to_char((c.expected::timestamptz - interval '1 second') at time zone c.tz, 'YYYY-MM-DD HH24:MI:SS') = c.wall_before
         and to_char(c.expected::timestamptz at time zone c.tz, 'YYYY-MM-DD HH24:MI:SS') = c.wall_at as fact_ok,
         timeweave_private.zoned_day_start(c.d, c.tz) as got,
         (c.d::timestamp at time zone c.tz) as pg_plain
  from c
),
v as (
  select r.*, case when not fact_ok then 'tzdata-differs'
                   when got = expected::timestamptz then 'match'
                   else 'MISMATCH' end as verdict
  from r
)
select 'detail' as section, tz, d::text, kind, expected, got::text, verdict
from v where verdict <> 'match'
union all
select 'summary', kind, null, null,
       count(*)::text || ' cases',
       count(*) filter (where pg_plain <> expected::timestamptz)::text || ' where plain AT TIME ZONE (0025) differs',
       count(*) filter (where verdict = 'match')::text || ' match / '
       || count(*) filter (where verdict = 'MISMATCH')::text || ' mismatch / '
       || count(*) filter (where verdict = 'tzdata-differs')::text || ' tzdata-differs'
from v group by kind
union all
select 'ZZZ', 'all', null, null, count(*)::text || ' cases',
       count(*) filter (where pg_plain <> expected::timestamptz)::text || ' where 0025 differs',
       case when count(*) filter (where verdict = 'MISMATCH') = 0
                 and count(*) filter (where verdict = 'tzdata-differs') = 0
                 and count(*) = ${rows.length} then 'ok' else 'FAIL' end
       || ' (mismatch ' || count(*) filter (where verdict = 'MISMATCH')::text
       || ', tzdata-differs ' || count(*) filter (where verdict = 'tzdata-differs')::text || ')'
from v
order by 1, 2, 3;

rollback;
`;
const out = resolve(ROOT, 'supabase/tests/0027_day_start_cases.sql');
writeFileSync(out, sql);
console.log(`wrote ${out}: ${rows.length} cases, ${zones.size} zones`, kinds);
