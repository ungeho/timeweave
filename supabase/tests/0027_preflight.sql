-- ============================================================================
-- 0027 PREFLIGHT -- read-only. Run BEFORE applying 0027_freebusy_day_start.sql,
-- as the role that will apply it.
--
-- GO requires the ZZZ row to read 0. The gates ask: is this the 0025 state
-- 0027 was written against, and will the ownership coupling hold? The context
-- rows record what the operator should keep for comparison with the postflight.
--
-- COST AND LIMIT (P8-finish-3b.2): reads application data -- one count of
-- events / share_links / owner_settings (C03) and, per distinct declared zone,
-- up to 401 days probed (C02). Linear in rows and in distinct zones. The 30 s
-- limit below ends the run if that is exceeded; the gate stops it before any
-- of this if read-only or the limit did not take effect. Separate approval
-- from A1a (which reads catalogs only).
-- HOW TO RUN. This file opens its own transaction (BEGIN ... ROLLBACK), so:
-- psql -X -v ON_ERROR_STOP=1 -f <this file>, or the whole file as one SQL
-- Editor run. NOT with -1: psql's BEGIN comes first, the BEGIN below only warns,
-- and the ROLLBACK below ends psql's transaction early (on 18.6 it still ended
-- up read-only, but that is not documented; the gate checks).
-- ============================================================================

begin transaction read only;
set local timezone = 'UTC';
set local statement_timeout = '30s';
select case when current_setting('transaction_read_only') = 'on' and current_setting('statement_timeout') = '30s'
            then 'gate: read only, 30s'
            else ('STOPPED: read_only=' || current_setting('transaction_read_only') || ', statement_timeout=' || current_setting('statement_timeout'))::int::text end as gate;

with
fn as (
  select p.oid, n.nspname, p.proname,
         replace(p.prosrc, E'\r', '') as body,
         p.proowner, p.prosecdef, p.provolatile, p.proconfig
  from pg_catalog.pg_proc p
  join pg_catalog.pg_namespace n on n.oid = p.pronamespace
),
wrp as (select * from fn where oid = to_regprocedure('public.get_free_busy(text, timestamptz, timestamptz, date, date)')),
cor as (select * from fn where oid = to_regprocedure('timeweave_private.free_busy_core(uuid, timestamptz, timestamptz, date, date)')),
hlp as (select * from fn where oid = to_regprocedure('timeweave_private.free_busy_available(uuid, timestamptz, timestamptz, date, date, jsonb)')),
res as (
  select v.ord, v.metric, v.expected, v.value,
         case when v.expected is null then 'context'
              when v.value is not distinct from v.expected then 'ok'
              else 'FAIL' end as status
  from (values
    ('D01','GATE: helper is exactly the 0025 body (0025 postflight F03)',
      '23f069bd792768f9279f5308e3edbaaf', (select md5(body) from hlp)),
    ('D02','GATE: wrapper is the 0024 body (0025 postflight F01)',
      '3a46a5d13e13361744860f7f270f8fbe', (select md5(body) from wrp)),
    ('D03','GATE: core is the 0024 body (0025 postflight F02)',
      'a9b4097e4b390cee1229709945475d2b', (select md5(body) from cor)),
    ('D04','GATE: timeweave_private.zoned_day_start does not exist yet',
      'false', (to_regprocedure('timeweave_private.zoned_day_start(date, text)') is not null)::text),
    ('D05','GATE: public.owner_settings exists (0025 applied)',
      'true', (to_regclass('public.owner_settings') is not null)::text),
    ('O01','GATE: the applying role owns the helper (0027 refuses otherwise)',
      'true', (select (pg_catalog.pg_get_userbyid(proowner) = current_user)::text from hlp)),
    ('O02','GATE: wrapper owner = helper owner (0024 A14b)',
      'true', (select (w.proowner = h.proowner)::text from wrp w, hlp h)),
    ('O03','GATE: helper not executable by public|anon|authenticated|service_role',
      'false|false|false|false',
      (select concat_ws('|',
        pg_catalog.has_function_privilege('public', oid, 'EXECUTE')::text,
        pg_catalog.has_function_privilege('anon', oid, 'EXECUTE')::text,
        pg_catalog.has_function_privilege('authenticated', oid, 'EXECUTE')::text,
        pg_catalog.has_function_privilege('service_role', oid, 'EXECUTE')::text) from hlp)),
    ('O04','CONTEXT: current_user | wrapper owner | helper owner', null::text,
      current_user || ' | ' || (select pg_catalog.pg_get_userbyid(proowner) from wrp)
                   || ' | ' || (select pg_catalog.pg_get_userbyid(proowner) from hlp)),
    ('Z01','CONTEXT: this server''s tzdata has the Havana 2026-11-01 doubled midnight', null::text,
      (('2026-11-01 04:00Z'::timestamptz at time zone 'America/Havana') = '2026-11-01 00:00'
       and ('2026-11-01 05:00Z'::timestamptz at time zone 'America/Havana') = '2026-11-01 00:00')::text),
    ('Z02','CONTEXT: what 0025 does there today (expected 2026-11-01 05:00:00+00, the SECOND)', null::text,
      ((date '2026-11-01')::timestamp at time zone 'America/Havana')::text),
    ('C01','CONTEXT: owners with a declared zone', null::text,
      (select count(*)::text from public.owner_settings where timezone is not null)),
    ('C02','CONTEXT: declared zones that have a doubled local midnight in the next 400 days (these owners'' answers can change)',
      null::text,
      coalesce((select string_agg(z.tz || ':' || z.n, ',' order by z.tz)
        from (select s.timezone as tz, count(*) as n
                from (select distinct timezone from public.owner_settings
                       where timezone is not null and public.timezone_is_resolvable(timezone)) s(timezone),
                     generate_series(current_date, current_date + 400, interval '1 day') g(d)
               where ((g.d::date::timestamp at time zone s.timezone) - interval '1 second') at time zone s.timezone
                     >= g.d::date::timestamp
               group by s.timezone) z), '(none)')),
    ('C03','CONTEXT: rows events | share_links | owner_settings (unchanged by 0027)', null::text,
      (select count(*) from public.events)::text || ' | ' || (select count(*) from public.share_links)::text
      || ' | ' || (select count(*) from public.owner_settings)::text)
  ) as v(ord, metric, expected, value)
)
select ord, metric, expected, value, status from res
union all
select 'ZZZ', 'FAIL rows (GO requires 0)', '0',
       (select count(*) filter (where status = 'FAIL') from res)::text,
       case when (select count(*) filter (where status = 'FAIL') from res) = 0 then 'ok' else 'FAIL' end
order by ord;

rollback;
