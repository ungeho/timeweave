-- ============================================================================
-- P8 RELEASE PREFLIGHT, STAGE A1b -- DATA COUNTS. READ ONLY. SEPARATE APPROVAL.
-- ============================================================================
-- HOW TO RUN: one execution of the whole file (SQL Editor: run all; psql:
--   psql -X -1 -v ON_ERROR_STOP=1 -f <this file>), and only after A1a came back with:
--   R00 = on (read-only took effect), F01 and F02 GATE-OK (the two application
--   functions called here are the reviewed code), S01 not WARN (fewer than a
--   million events; otherwise ask before running this).
--
-- WHAT THIS STAGE DOES. Scans public.events once per item (no index exists on
-- rrule; each item is a sequential scan) and owner_settings once, and calls
-- public.rrule_parse once per recurring master. Measured on the isolated
-- database with 101,000 events / 20,200 masters: each item 4-27 ms, rrule_parse
-- over 20,200 all-distinct rules 91 ms, the whole stage well under a second.
-- It grows linearly with the rows. Line 2 stops it at 30 s.
--
-- READ ONLY: the same two lines as A1a, and the same check (R00). The functions
-- it calls: rrule_parse (STABLE, SECURITY INVOKER, plpgsql, no writes in its
-- body -- reviewed, and fingerprinted by A1a F01) and catalog functions.
--
-- OUTPUT: counts only. No title, description, category, owner id, token,
-- label or rrule text.
-- ============================================================================
set transaction read only;
set local statement_timeout = '30s';
-- GATE: stops the run here, BEFORE any scan of application data, unless both
-- lines above are in effect (see A1a for how this is guaranteed and measured).
select case when current_setting('transaction_read_only') = 'on' and current_setting('statement_timeout') = '30s'
            then 'gate: read only, 30s'
            else ('STOPPED: read_only=' || current_setting('transaction_read_only') || ', statement_timeout=' || current_setting('statement_timeout'))::int::text end as gate;
with
guard as (
  select 'R00'::text as id, 'this run'::text as area, 'transaction_read_only (must be on)'::text as item,
         current_setting('transaction_read_only') as value,
         case when current_setting('transaction_read_only') = 'on' then 'GATE-OK' else 'GATE-FAIL' end::text as verdict
  union all select 'R01', 'this run', 'statement_timeout in effect (must be 30s)', current_setting('statement_timeout'),
         case when current_setting('statement_timeout') = '30s' then 'GATE-OK' else 'GATE-FAIL' end
),
ev as (select e.all_day, e.rrule, e.timezone, e.recurrence_id from public.events e),
masters as (select all_day, rrule, timezone from ev where rrule is not null),
parsed as (select m.all_day, m.rrule, p.status, p.until_date, p.until_ts from masters m, lateral public.rrule_parse(m.rrule) p),
dat as (
  select 'D01'::text as id, 'data'::text as area, 'events: rows | recurring masters | exceptions'::text as item,
    (select count(*) from ev)::text || ' | ' || (select count(*) from masters)::text || ' | ' || (select count(*) from ev where recurrence_id is not null)::text as value, 'INFO'::text as verdict
  union all select 'D02', 'data (K1)', 'timed recurring masters with NO zone (legacy M0)',
    (select count(*) from masters where not all_day and timezone is null)::text, 'INFO'
  union all select 'D03', 'data (K12)', 'masters by rrule_parse status: ok | malformed | unsupported',
    (select count(*) filter (where status = 'ok') || ' | ' || count(*) filter (where status = 'malformed') || ' | ' || count(*) filter (where status = 'unsupported') from parsed), 'INFO'
  union all select 'D04', 'data (K13)', 'masters whose INTERVAL is not 1..9999 in plain digits',
    (select count(*) from masters where rrule ~* 'INTERVAL=' and rrule !~ '(^|;)INTERVAL=[1-9][0-9]{0,3}(;|$)')::text, 'INFO'
  union all select 'D05', 'data (K14)', 'masters whose COUNT is not 1..9,999,999 in plain digits',
    (select count(*) from masters where rrule ~* 'COUNT=' and rrule !~ '(^|;)COUNT=[1-9][0-9]{0,6}(;|$)')::text, 'INFO'
  union all select 'D06', 'data (K16)', 'masters the draft 0029 check would refuse if written today (they are NOT touched by it)',
    (select count(*) from parsed where not (
       rrule ~ '^FREQ=(DAILY|WEEKLY|MONTHLY)(;INTERVAL=[1-9][0-9]{0,3})?(;BYDAY=(MO|TU|WE|TH|FR|SA|SU)(,(MO|TU|WE|TH|FR|SA|SU)){0,6})?(;COUNT=[1-9][0-9]{0,6}|;UNTIL=[0-9]{8}(T[0-9]{6}Z)?)?$'
       and status = 'ok' and case when all_day then until_ts is null else until_date is null end))::text,
    'INFO'
  union all select 'D07', 'data (K15)', 'distinct zones on timed masters: total | the most any one owner uses',
    (select count(distinct timezone) from masters where timezone is not null)::text || ' | ' ||
    coalesce((select max(c)::text from (select count(distinct e.timezone) c from public.events e where e.rrule is not null and e.timezone is not null group by e.owner_id) z), '0'),
    case when coalesce((select max(c) from (select count(distinct e.timezone) c from public.events e where e.rrule is not null and e.timezone is not null group by e.owner_id) z), 0) > 5 then 'WARN' else 'INFO' end
  -- D08: per owner with a zone, up to 401 days probed with two AT TIME ZONE each
  -- (stops at the first hit). Linear in such owners: 101 owners took 11 ms.
  union all select 'D08', 'data (K6)', 'owners with a declared zone | of those, zones with a doubled midnight in the next 400 days',
    (select count(*) from public.owner_settings where timezone is not null)::text || ' | ' ||
    (select count(*) from public.owner_settings s where s.timezone is not null and exists (
       select 1 from generate_series(current_date, current_date + 400, interval '1 day') d
       where (d::timestamp at time zone s.timezone) - ((d::timestamp - interval '1 hour') at time zone s.timezone) > interval '1 hour'))::text,
    'INFO'
  union all select 'D09', 'data (K18)', 'rows outside 0013 bounds (impossible while the CHECKs exist)',
    (select count(*) from public.events e where (e.end_date is not null and e.end_date >= date '10000-01-01') or (e.end_at is not null and e.end_at >= timestamptz '10000-01-01 00:00Z'))::text,
    'INFO'
),
allrows as (select * from guard union all select * from dat)
select id, area, item, value, verdict from allrows
union all
select 'ZZZ', 'summary', 'GATE-FAIL rows', count(*) filter (where verdict = 'GATE-FAIL')::text,
       case when count(*) filter (where verdict = 'GATE-FAIL') = 0 then 'GATE-OK' else 'GATE-FAIL' end
from allrows
order by 1;
