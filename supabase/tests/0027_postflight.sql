-- ============================================================================
-- 0027 POSTFLIGHT -- read-only. Run AFTER applying 0027_freebusy_day_start.sql.
--
-- GO requires the ZZZ row to read 0, counted over EVERY gate below.
--
-- Note for whoever runs 0025_postflight.sql after this: its F03 (helper md5 =
-- the 0025 body) and H08 (the round-trip text) now report the 0027 body. That
-- is the expected consequence of replacing the helper, not a regression; the
-- gates 0025 cared about are restated here (A*, H03-H10) against the new body.
--
-- Behaviour is covered by 0027_day_start_test.sql (real helper, real wrapper,
-- rolled back) and 0027_day_start_cases.sql (the boundary rule against the
-- client's dayStartInstantIso). B rows here are a short smoke check of the
-- function alone, and depend on this server's tzdata having the listed facts
-- (Z01 says whether it does).
--
-- HOW TO RUN (P8-finish-3b.2). This file opens its own transaction (BEGIN ...
-- ROLLBACK), so: psql -X -v ON_ERROR_STOP=1 -f <this file>, or the whole file
-- as one SQL Editor run. NOT with -1: psql's BEGIN comes first, the BEGIN below
-- only warns, and the ROLLBACK below ends psql's transaction early (on 18.6 it
-- still ended up read-only, but that is not documented; the gate checks).
-- Run as the role that applied 0027. The gate stops the run unless the
-- transaction is read-only with a 30 s limit. Cost: catalog reads and a few
-- calls of the 0027 functions on constants, and one count each of events,
-- share_links and owner_settings (C rows): linear in rows.
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
         p.proowner, p.prosecdef, p.provolatile, p.proisstrict, p.proconfig, p.prolang,
         p.prorettype, p.pronargs
  from pg_catalog.pg_proc p
  join pg_catalog.pg_namespace n on n.oid = p.pronamespace
),
wrp as (select * from fn where oid = to_regprocedure('public.get_free_busy(text, timestamptz, timestamptz, date, date)')),
cor as (select * from fn where oid = to_regprocedure('timeweave_private.free_busy_core(uuid, timestamptz, timestamptz, date, date)')),
hlp as (select * from fn where oid = to_regprocedure('timeweave_private.free_busy_available(uuid, timestamptz, timestamptz, date, date, jsonb)')),
zds as (select * from fn where oid = to_regprocedure('timeweave_private.zoned_day_start(date, text)')),
res as (
  select v.ord, v.phase, v.metric, v.expected, v.value,
         case when v.expected is null then 'context'
              when v.value is not distinct from v.expected then 'ok'
              else 'FAIL' end as status
  from (values

    -- F. fingerprints: the helper changed, nothing else did ----------------
    ('F01','fingerprint','GATE: wrapper UNCHANGED',
      '3a46a5d13e13361744860f7f270f8fbe', (select md5(body) from wrp)),
    ('F02','fingerprint','GATE: core UNCHANGED',
      'a9b4097e4b390cee1229709945475d2b', (select md5(body) from cor)),
    ('F03','fingerprint','GATE: helper is the 0027 body',
      'e7922ad9183a4b15b5481e1411e1a08c', (select md5(body) from hlp)),
    ('F04','fingerprint','GATE: helper is NOT still 0025''s',
      'false', (select (md5(body) = '23f069bd792768f9279f5308e3edbaaf')::text from hlp)),
    ('F05','fingerprint','GATE: still exactly one helper overload',
      '1', (select count(*)::text from fn where nspname = 'timeweave_private' and proname = 'free_busy_available')),
    ('F06','fingerprint','GATE: zoned_day_start is the 0027 body',
      'fe15de1e10b7d84129179ada42d72cd9', (select md5(body) from zds)),

    -- A. the helper's posture, preserved by CREATE OR REPLACE (0025 A01-A06) --
    ('A01','helper','GATE: helper NOT executable by public|anon|authenticated|service_role',
      'false|false|false|false',
      (select concat_ws('|',
        pg_catalog.has_function_privilege('public', oid, 'EXECUTE')::text,
        pg_catalog.has_function_privilege('anon', oid, 'EXECUTE')::text,
        pg_catalog.has_function_privilege('authenticated', oid, 'EXECUTE')::text,
        pg_catalog.has_function_privilege('service_role', oid, 'EXECUTE')::text) from hlp)),
    ('A02','helper','GATE: the wrapper owner CAN execute the helper (A14)',
      'true', coalesce((select pg_catalog.has_function_privilege(w.proowner, h.oid, 'EXECUTE')::text
                        from wrp w, hlp h), 'UNRESOLVED')),
    ('A03','helper','CONTEXT: wrapper owner | helper owner | zoned_day_start owner', null::text,
      coalesce((select pg_catalog.pg_get_userbyid(proowner) from wrp), '?') || ' | '
      || coalesce((select pg_catalog.pg_get_userbyid(proowner) from hlp), '?') || ' | '
      || coalesce((select pg_catalog.pg_get_userbyid(proowner) from zds), '?')),
    ('A04','helper','GATE: helper SECURITY INVOKER', 'false', (select prosecdef::text from hlp)),
    ('A05','helper','GATE: helper STABLE', 's', (select provolatile::text from hlp)),
    ('A06','helper','GATE: helper search_path pinned empty', 'search_path=""',
      (select array_to_string(proconfig, ',') from hlp)),
    ('A07','helper','GATE: the wrapper is still SECURITY DEFINER and anon-executable (contract unchanged)',
      'true|true', (select prosecdef::text || '|' || pg_catalog.has_function_privilege('anon', oid, 'EXECUTE')::text from wrp)),

    -- Z. the new function --------------------------------------------------
    ('Z01','function','GATE: zoned_day_start(date, text) exists in timeweave_private',
      'timeweave_private', (select nspname from zds)),
    ('Z02','function','GATE: returns timestamptz, two arguments, exactly one overload',
      'timestamp with time zone|2|1',
      (select pg_catalog.format_type(prorettype, null) || '|' || pronargs::text from zds)
      || '|' || (select count(*)::text from fn where nspname = 'timeweave_private' and proname = 'zoned_day_start')),
    ('Z03','function','GATE: NOT executable by public|anon|authenticated|service_role',
      'false|false|false|false',
      (select concat_ws('|',
        pg_catalog.has_function_privilege('public', oid, 'EXECUTE')::text,
        pg_catalog.has_function_privilege('anon', oid, 'EXECUTE')::text,
        pg_catalog.has_function_privilege('authenticated', oid, 'EXECUTE')::text,
        pg_catalog.has_function_privilege('service_role', oid, 'EXECUTE')::text) from zds)),
    ('Z04','function','GATE: the wrapper owner CAN execute it (the helper runs as that role)',
      'true', coalesce((select pg_catalog.has_function_privilege(w.proowner, z.oid, 'EXECUTE')::text
                        from wrp w, zds z), 'UNRESOLVED')),
    ('Z05','function','GATE: owner = helper owner',
      'true', (select (z.proowner = h.proowner)::text from zds z, hlp h)),
    ('Z06','function','GATE: SECURITY INVOKER | STABLE | STRICT | language sql',
      'false|s|true|sql',
      (select prosecdef::text || '|' || provolatile::text || '|' || proisstrict::text || '|'
              || (select lanname from pg_catalog.pg_language l where l.oid = zds.prolang) from zds)),
    ('Z07','function','GATE: search_path pinned empty', 'search_path=""',
      (select array_to_string(proconfig, ',') from zds)),
    ('Z08','function','GATE: it reads no table and calls no project function',
      '0', (select count(*)::text from regexp_matches((select body from zds), '(public|timeweave_private|auth)\.', 'g'))),
    ('Z09','function','GATE: anon cannot even reach the schema it lives in',
      'false', pg_catalog.has_schema_privilege('anon', 'timeweave_private', 'USAGE')::text),

    -- H. the helper body: three conversions replaced, every 0025 gate kept --
    ('H01','body','GATE: zoned_day_start is called exactly 5 times (6b x1, 6c x2, 7B x2)',
      '5', (select count(*)::text from regexp_matches((select body from hlp), 'timeweave_private\.zoned_day_start\(', 'g'))),
    ('H02','body','GATE: no date boundary converts directly any more',
      '0', (select count(*)::text from regexp_matches((select body from hlp), '::timestamp at time zone v_tz', 'g'))),
    ('H03','body','GATE: the DST round-trip check is still present (0025 H08, new form)',
      '1', (select count(*)::text from regexp_matches((select body from hlp),
              'zoned_day_start\(b\.d, v_tz\) at time zone v_tz\)::date = b\.d', 'g'))),
    ('H04','body','GATE: it reads owner_settings exactly once (0025 H01)',
      '1', (select count(*)::text from regexp_matches((select body from hlp), 'from public.owner_settings', 'g'))),
    ('H05','body','GATE: it NEVER reads the language column (0025 H02)',
      '0', (select count(*)::text from regexp_matches((select body from hlp), 'language', 'g'))),
    ('H06','body','GATE: it never reads share_available (0025 H03)',
      '0', (select count(*)::text from regexp_matches((select body from hlp), 'share_available', 'g'))),
    ('H07','body','GATE: the zone is re-checked with timezone_is_resolvable (0025 H04)',
      '1', (select count(*)::text from regexp_matches((select body from hlp), 'not public\.timezone_is_resolvable\(', 'g'))),
    ('H08','body','GATE: no offset is derived from the caller''s window (0025 H05)',
      '0', (select count(*)::text from regexp_matches((select body from hlp),
              'p_from_date::timestamp|p_from_date\s*-\s*p_from|p_from\s*-\s*p_from_date', 'g'))),
    ('H09','body','GATE: v_ok_tz is NOT the conversion zone (0025 H06)',
      '0', (select count(*)::text from regexp_matches((select body from hlp), 'at time zone\s+v_ok_tz|v_tz\s*:=\s*v_ok_tz', 'g'))),
    ('H10','body','GATE: fail-closed returns still reachable (0025 H07)',
      'true', (select ((select count(*) from regexp_matches((select body from hlp), 'return c_indet;', 'g')) >= 9)::text)),
    ('H11','body','GATE: all 5 calls pass a date boundary and the OWNER zone (v_tz), nothing else',
      '5', (select count(*)::text from regexp_matches((select body from hlp),
              'zoned_day_start\((b\.d|lower\(r\)|upper\(r\)|lower\(v_r_d\)|upper\(v_r_d\)), v_tz\)', 'g'))),

    -- B. smoke: the rule itself (needs the tzdata facts; see Z rows of the cases suite)
    ('B01','rule','GATE: Havana 2026-11-01 starts at the FIRST midnight',
      '2026-11-01 04:00:00+00', (timeweave_private.zoned_day_start('2026-11-01', 'America/Havana'))::text),
    ('B02','rule','GATE: Havana 2026-03-08 (no midnight) starts when the clocks jump, as before',
      '2026-03-08 05:00:00+00', (timeweave_private.zoned_day_start('2026-03-08', 'America/Havana'))::text),
    ('B03','rule','GATE: Azores 2026-10-25 starts at the FIRST midnight',
      '2026-10-25 00:00:00+00', (timeweave_private.zoned_day_start('2026-10-25', 'Atlantic/Azores'))::text),
    ('B04','rule','GATE: Apia 2011-12-30 (never happened) = where 12-31 starts',
      'true', (timeweave_private.zoned_day_start('2011-12-30', 'Pacific/Apia')
               = timeweave_private.zoned_day_start('2011-12-31', 'Pacific/Apia'))::text),
    ('B05','rule','GATE: an ordinary midnight is unchanged (Tokyo 2026-10-19)',
      '2026-10-18 15:00:00+00', (timeweave_private.zoned_day_start('2026-10-19', 'Asia/Tokyo'))::text),
    ('B06','rule','GATE: infinity passes through, NULL in -> NULL out (STRICT)',
      'infinity|null',
      (timeweave_private.zoned_day_start('infinity', 'UTC'))::text || '|'
      || coalesce((timeweave_private.zoned_day_start(null, 'UTC'))::text, 'null')),

    -- C. nothing else moved -------------------------------------------------
    ('C01','context','CONTEXT: rows events | share_links | owner_settings (compare with preflight C03)', null::text,
      (select count(*) from public.events)::text || ' | ' || (select count(*) from public.share_links)::text
      || ' | ' || (select count(*) from public.owner_settings)::text),
    ('C02','context','GATE: share_links.share_available still defaults to false and is NOT NULL',
      'false|NO',
      (select column_default || '|' || is_nullable from information_schema.columns
        where table_schema = 'public' and table_name = 'share_links' and column_name = 'share_available'))

  ) as v(ord, phase, metric, expected, value)
)
select ord, phase, metric, expected, value, status from res
union all
select 'ZZZ', 'summary', 'FAIL rows across ALL checks (GO requires 0)', '0',
       (select count(*) filter (where status = 'FAIL') from res)::text,
       case when (select count(*) filter (where status = 'FAIL') from res) = 0 then 'ok' else 'FAIL' end
order by ord;

rollback;
