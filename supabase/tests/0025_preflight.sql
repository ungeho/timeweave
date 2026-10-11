-- ============================================================================
-- 0025 PREFLIGHT -- read-only. Run BEFORE applying 0025_freebusy_crossmodel.sql.
--
-- GO requires P00 = 0.
--
-- What this is asking. 0025 replaces one function and adds one table, and it
-- leans on four things it does not create: the 0024 helper it is replacing, the
-- wrapper that calls it, 0008's timezone gate, and the private schema the
-- trigger lives in. Every check below is either "the thing 0025 will replace is
-- the thing we think it is" or "the thing 0025 will lean on exists".
--
-- Rows whose `expected` is NULL are CONTEXT: recorded for the postflight to
-- compare against, never a pass/fail on their own.
-- ============================================================================

begin transaction read only;

with
fn as (
  select p.oid, n.nspname, p.proname,
         replace(p.prosrc, E'\r', '') as body,
         p.proowner, p.prosecdef, p.provolatile, p.proconfig
  from pg_catalog.pg_proc p
  join pg_catalog.pg_namespace n on n.oid = p.pronamespace
),
wrp as (
  select * from fn
  where oid = to_regprocedure('public.get_free_busy(text, timestamptz, timestamptz, date, date)')
),
cor as (
  select * from fn
  where oid = to_regprocedure('timeweave_private.free_busy_core(uuid, timestamptz, timestamptz, date, date)')
),
hlp as (
  select * from fn
  where oid = to_regprocedure('timeweave_private.free_busy_available(uuid, timestamptz, timestamptz, date, date, jsonb)')
),
res as (
  select v.ord, v.phase, v.metric, v.expected, v.value,
         case when v.expected is null then 'context'
              when v.value is not distinct from v.expected then 'ok'
              else 'FAIL'
         end as status
  from (values

    -- A. the function 0025 will REPLACE -----------------------------------
    ('A01','helper','GATE: 0024 helper is present',
      'true', (select (count(*) = 1)::text from hlp)),
    ('A02','helper','GATE: its body is 0024''s, byte for byte (CR-stripped md5)',
      'ac87ef2526ab12f0f7c4d8c2142bcbd0', (select md5(body) from hlp)),
    ('A03','helper','GATE: exactly one overload exists, so REPLACE cannot fork it',
      '1', (select count(*)::text from fn
            where nspname = 'timeweave_private' and proname = 'free_busy_available')),
    ('A04','helper','GATE: SECURITY INVOKER (0025 keeps this posture)',
      'false', (select prosecdef::text from hlp)),
    ('A05','helper','GATE: STABLE',
      's', (select provolatile::text from hlp)),
    ('A06','helper','GATE: search_path is pinned empty',
      'search_path=""', (select array_to_string(proconfig, ',') from hlp)),
    ('A07','helper','CONTEXT: owner (CREATE OR REPLACE must preserve it)',
      null::text, (select pg_catalog.pg_get_userbyid(proowner) from hlp)),
    ('A08','helper','CONTEXT: NOT executable by public|anon|authenticated|service_role',
      null::text,
      (select concat_ws('|',
        pg_catalog.has_function_privilege('public', oid, 'EXECUTE'),
        pg_catalog.has_function_privilege('anon', oid, 'EXECUTE'),
        pg_catalog.has_function_privilege('authenticated', oid, 'EXECUTE'),
        pg_catalog.has_function_privilege('service_role', oid, 'EXECUTE')) from hlp)),

    -- B. the two functions 0025 must NOT touch ----------------------------
    ('B01','wrapper','GATE: wrapper body is post-0024 and must stay so',
      '3a46a5d13e13361744860f7f270f8fbe', (select md5(body) from wrp)),
    ('B02','core','GATE: frozen core body',
      'a9b4097e4b390cee1229709945475d2b', (select md5(body) from cor)),
    ('B03','wrapper','GATE: SECURITY DEFINER',
      'true', (select prosecdef::text from wrp)),
    ('B04','wrapper','GATE: the wrapper owner CAN execute the helper (A14)',
      'true',
      coalesce((select pg_catalog.has_function_privilege(w.proowner, h.oid, 'EXECUTE')::text
                from wrp w, hlp h), 'UNRESOLVED')),
    ('B05','wrapper','CONTEXT: wrapper owner | helper owner',
      null::text,
      coalesce((select pg_catalog.pg_get_userbyid(w.proowner) from wrp w), '?')
      || ' | ' ||
      coalesce((select pg_catalog.pg_get_userbyid(h.proowner) from hlp h), '?')),
    ('B06','wrapper','CONTEXT: PUBLIC EXECUTE on the wrapper (postflight compares)',
      null::text,
      pg_catalog.has_function_privilege('public',
        'public.get_free_busy(text, timestamptz, timestamptz, date, date)','EXECUTE')::text),

    -- C. dependencies 0025 LEANS ON ---------------------------------------
    ('C01','dep','GATE: timeweave_private schema exists (trigger goes there)',
      'true', (select (count(*) = 1)::text from pg_catalog.pg_namespace
               where nspname = 'timeweave_private')),
    ('C02','dep','GATE: public.timezone_is_supported exists (0008)',
      'true', (to_regprocedure('public.timezone_is_supported(text)') is not null)::text),
    ('C03','dep','GATE: public.timezone_is_resolvable exists (0008)',
      'true', (to_regprocedure('public.timezone_is_resolvable(text)') is not null)::text),
    ('C04','dep','GATE: timezone_is_supported is NOT immutable, so a CHECK is wrong',
      'false',
      (select (provolatile = 'i')::text from fn
       where oid = to_regprocedure('public.timezone_is_supported(text)'))),
    ('C05','dep','GATE: auth.uid() exists (owner_id default)',
      'true', (to_regprocedure('auth.uid()') is not null)::text),
    ('C06','dep','GATE: multirange types are available (PG14+)',
      'true', (to_regtype('tstzmultirange') is not null
               and to_regtype('datemultirange') is not null)::text),
    ('C07','dep','GATE: share_links carries share_available (0022)',
      'true', (select (count(*) = 1)::text from information_schema.columns
               where table_schema='public' and table_name='share_links'
                 and column_name='share_available')),
    ('C08','dep','GATE: events carries availability (0020)',
      'true', (select (count(*) = 1)::text from information_schema.columns
               where table_schema='public' and table_name='events'
                 and column_name='availability')),

    -- D. collision / re-apply risk ----------------------------------------
    ('D01','collision','GATE: public.owner_settings does NOT exist yet',
      'false', (to_regclass('public.owner_settings') is not null)::text),
    ('D02','collision','GATE: the 0025 trigger function does not exist yet',
      'false',
      (to_regprocedure('timeweave_private.owner_settings_validate_timezone()') is not null)::text),
    ('D03','collision','CONTEXT: a name close enough to collide',
      null::text,
      (select coalesce(string_agg(c.relname, ','), '(none)')
       from pg_catalog.pg_class c join pg_catalog.pg_namespace n on n.oid = c.relnamespace
       where n.nspname = 'public' and c.relname like '%owner_setting%')),

    -- E. the Busy contract 0025 must not disturb ---------------------------
    ('E01','busy','GATE: the wrapper calls free_busy_core exactly twice',
      '2', (select count(*)::text from regexp_matches((select body from wrp),
              'free_busy_core\(', 'g'))),
    ('E02','busy','GATE: the wrapper calls the helper exactly once',
      '1', (select count(*)::text from regexp_matches((select body from wrp),
              'free_busy_available\(', 'g'))),
    ('E03','busy','GATE: the helper never reads share_available (A12 of 0024)',
      '0', (select count(*)::text from regexp_matches((select body from hlp),
              'share_available', 'g'))),
    ('E04','busy','CONTEXT: rows in events / share_links (blast radius)',
      null::text,
      (select count(*)::text from public.events) || ' / ' ||
      (select count(*)::text from public.share_links)),
    ('E05','busy','CONTEXT: share links already opted in to Available',
      null::text,
      (select count(*)::text from public.share_links
       where share_available and revoked_at is null))

  ) as v(ord, phase, metric, expected, value)
)
select ord, phase, metric, expected, value, status from res
union all
-- P00 over EVERY row above, not a sample. A summary that covers only some of
-- its own checks reads green while the rest fail, which is worse than a FAIL
-- because nobody looks twice at a zero.
select 'ZZZ', 'summary', 'FAIL rows across ALL checks (GO requires 0)', '0',
       (select count(*) filter (where status = 'FAIL') from res)::text,
       case when (select count(*) filter (where status = 'FAIL') from res) = 0
            then 'ok' else 'FAIL' end
order by ord;

rollback;
