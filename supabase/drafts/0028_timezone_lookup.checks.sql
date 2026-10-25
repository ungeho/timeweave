-- ============================================================================
-- 0028 CHECKS -- READ ONLY. After applying 0028, and after every PostgreSQL /
-- OS / tzdata update of the server (runbook §8). Returns (id, item, value, verdict).
-- ============================================================================
-- HOW TO RUN: as ONE execution of the whole file (SQL Editor: run all; psql:
--   psql -X -1 -v ON_ERROR_STOP=1 -f supabase/drafts/0028_timezone_lookup.checks.sql).
-- The gate statement stops the run if read-only / the time limit did not apply.
--
-- HOW THE BAKED LIST IS READ. The list function's body must be EXACTLY the
-- shape 0028 writes:  select $1 = any ('{...}'::text[])  -- C08 checks that,
-- and only then is the array read out of it. A body of any other shape, or one
-- whose array cannot be read, is a GATE-FAIL here (never an empty list that
-- would make the comparisons below pass vacuously). Then the list must equal
-- pg_timezone_names AS A SET -- nothing missing (C03), nothing extra (C04), no
-- duplicate (C09), the same size and not empty (C05) -- and the function must
-- answer true for every server name (C10), i.e. it really uses that array.
-- C11: the list keeps the rest of what 0028 created it with (SECURITY INVOKER,
-- STRICT, PARALLEL SAFE, LANGUAGE sql, exactly search_path="") and is owned by
-- the owner of timezone_is_supported.
-- ============================================================================
set transaction read only;
set local statement_timeout = '10s';
select case when current_setting('transaction_read_only') = 'on' and current_setting('statement_timeout') = '10s'
            then 'gate: read only, 10s'
            else ('STOPPED: read_only=' || current_setting('transaction_read_only') || ', statement_timeout=' || current_setting('statement_timeout'))::int::text end as gate;
with
src as (select oid, proowner from pg_catalog.pg_proc where oid = to_regprocedure('public.timezone_is_supported(text)')),
lst as (select oid, prosrc, provolatile, prosecdef, proisstrict, proparallel, prolang, proconfig, proowner
        from pg_catalog.pg_proc where oid = to_regprocedure('public.timezone_name_listed(text)')),
-- C11: the other attributes 0028's CREATE FUNCTION gives the list, and the owner it inherits
attrs as (select (select prosecdef from lst) is false and (select proisstrict from lst) is true
                 and (select proparallel from lst) = 's'
                 and (select prolang from lst) = (select oid from pg_catalog.pg_language where lanname = 'sql')
                 and (select proconfig from lst) = array['search_path=""']
                 and (select proowner from lst) = (select proowner from src) as ok),
shape as (select (select prosrc from lst) ~ '^select \$1 = any \(''\{[^'']*\}''::text\[\]\)$' as ok),
baked as (
  -- read only when the shape is exact; otherwise NULL (never an empty list)
  select case when (select ok from shape) then substring((select prosrc from lst) from '^select \$1 = any \(''(\{[^'']*\})''::text\[\]\)$')::text[] end as arr
),
server as (select array_agg(name order by name) as arr from pg_catalog.pg_timezone_names),
rows as (
  select 'C00'::text as id, 'transaction_read_only (must be on) | statement_timeout (must be 10s)'::text as item,
         current_setting('transaction_read_only') || ' | ' || current_setting('statement_timeout') as value,
         case when current_setting('transaction_read_only') = 'on' and current_setting('statement_timeout') = '10s' then 'GATE-OK' else 'GATE-FAIL' end::text as verdict
  union all select 'C01', '0028 present: timezone_name_listed exists, IMMUTABLE', coalesce((select provolatile::text from lst), '(absent)'),
         case when (select provolatile from lst) = 'i' then 'GATE-OK' else 'GATE-FAIL' end
  union all select 'C11', 'list attributes: SECURITY INVOKER, STRICT, PARALLEL SAFE, LANGUAGE sql, search_path="" only, owner = owner of timezone_is_supported',
         coalesce((select 'secdef=' || prosecdef || ' strict=' || proisstrict || ' parallel=' || proparallel::text
                          || ' lang=' || (select lanname from pg_catalog.pg_language where oid = prolang)
                          || ' config=' || coalesce(proconfig::text, '(none)')
                          || ' owner=' || pg_catalog.pg_get_userbyid(proowner) from lst), '(no function)'),
         case when (select ok from attrs) is true then 'GATE-OK' else 'GATE-FAIL' end
  union all select 'C02', 'timezone_is_supported body = 0028 body (md5 after CRLF->LF)', coalesce(md5(replace((select prosrc from pg_catalog.pg_proc where oid = (select oid from src)), E'\r\n', E'\n')), '(missing)'),
         case when md5(replace((select prosrc from pg_catalog.pg_proc where oid = (select oid from src)), E'\r\n', E'\n')) = '073cd648fb8d2b7f93e0401add60e075' then 'GATE-OK' else 'GATE-FAIL' end
  union all select 'C08', 'list body has exactly the shape 0028 writes (the array can be read)', coalesce((select ok::text from shape), '(no function)'),
         case when (select ok from shape) is true and (select arr from baked) is not null then 'GATE-OK' else 'GATE-FAIL' end
  union all select 'C05', 'names: baked | server (equal and not 0)',
         coalesce(cardinality((select arr from baked))::text, '(unreadable)') || ' | ' || cardinality((select arr from server))::text,
         case when (select arr from baked) is not null and cardinality((select arr from baked)) > 0
                   and cardinality((select arr from baked)) = cardinality((select arr from server)) then 'GATE-OK' else 'GATE-FAIL' end
  union all select 'C03', 'drift: names the server knows that the list lacks (a zone ADDED by tzdata)',
         case when (select arr from baked) is null then '(unreadable)' else (select count(*) from unnest((select arr from server)) s(n) where not (s.n = any (coalesce((select arr from baked), '{}'::text[]))))::text end,
         case when (select arr from baked) is not null and (select arr from server) <@ (select arr from baked) then 'GATE-OK' else 'GATE-FAIL' end
  union all select 'C04', 'drift: names in the list the server no longer knows (a zone REMOVED by tzdata)',
         case when (select arr from baked) is null then '(unreadable)' else (select count(*) from unnest((select arr from baked)) b(n) where not (b.n = any (coalesce((select arr from server), '{}'::text[]))))::text end,
         case when (select arr from baked) is not null and (select arr from baked) <@ (select arr from server) then 'GATE-OK' else 'GATE-FAIL' end
  union all select 'C09', 'duplicate names in the list',
         coalesce((select (cardinality((select arr from baked)) - count(distinct n))::text from unnest((select arr from baked)) b(n)), '(unreadable)'),
         case when (select arr from baked) is not null
                   and cardinality((select arr from baked)) = (select count(distinct n) from unnest((select arr from baked)) b(n)) then 'GATE-OK' else 'GATE-FAIL' end
  union all select 'C10', 'the function answers true for every server name, false for a name that is not one',
         (select count(*) filter (where not public.timezone_name_listed(n)) from unnest((select arr from server)) s(n))::text || ' false | '
           || coalesce(public.timezone_name_listed('Not/AZone')::text, 'null'),
         case when exists (select 1 from lst)
                   and (select count(*) filter (where not public.timezone_name_listed(n)) from unnest((select arr from server)) s(n)) = 0
                   and public.timezone_name_listed('Not/AZone') is false then 'GATE-OK' else 'GATE-FAIL' end
  union all select 'C06', 'roles whose EXECUTE (or grant option) differs between timezone_is_supported and the list (all roles, PUBLIC and inheritance included)',
         (select count(*) from pg_catalog.pg_roles r
           where pg_catalog.has_function_privilege(r.oid, (select oid from src), 'EXECUTE') is distinct from pg_catalog.has_function_privilege(r.oid, (select oid from lst), 'EXECUTE')
              or pg_catalog.has_function_privilege(r.oid, (select oid from src), 'EXECUTE WITH GRANT OPTION') is distinct from pg_catalog.has_function_privilege(r.oid, (select oid from lst), 'EXECUTE WITH GRANT OPTION'))::text,
         case when exists (select 1 from lst) and (select count(*) from pg_catalog.pg_roles r
           where pg_catalog.has_function_privilege(r.oid, (select oid from src), 'EXECUTE') is distinct from pg_catalog.has_function_privilege(r.oid, (select oid from lst), 'EXECUTE')
              or pg_catalog.has_function_privilege(r.oid, (select oid from src), 'EXECUTE WITH GRANT OPTION') is distinct from pg_catalog.has_function_privilege(r.oid, (select oid from lst), 'EXECUTE WITH GRANT OPTION')) = 0
              then 'GATE-OK' else 'GATE-FAIL' end
)
select * from rows
union all
select 'ZZZ', 'GATE-FAIL rows', count(*) filter (where verdict = 'GATE-FAIL')::text,
       case when count(*) filter (where verdict = 'GATE-FAIL') = 0 then 'GATE-OK' else 'GATE-FAIL' end from rows
order by 1;
