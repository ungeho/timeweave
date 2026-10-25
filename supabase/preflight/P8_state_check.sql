-- ============================================================================
-- P8 STATE CHECK (C1) -- CATALOG ONLY. READ ONLY.
-- ============================================================================
-- What A1a is not. A1a (P8_release_preflight.sql) is the BEFORE-ANY-APPLY gate:
-- it expects 0027 / 0028 / 0029 to be absent and timezone_is_supported to have
-- 0008's body, so it fails -- correctly -- once any of them is applied. After
-- each apply and after each rollback, run THIS file instead and compare its
-- STATE row with the runbook (§4 / §5):
--
--   before anything              0027=absent  0028=absent  0029=absent
--   after 0027                   0027=applied 0028=absent  0029=absent
--   after 0028                   0027=applied 0028=applied 0029=absent
--   after 0029                   0027=applied 0028=applied 0029=applied
--   rollback 0029 / 0028 / 0027  the row above the step that was undone
--
-- Each migration is classified on its own, from what it creates and the exact
-- bodies (md5 of prosrc after CRLF->LF, so a body pasted with Windows line
-- endings and one sent by psql compare equal) the repository's files produce -- verified on the
-- isolated databases:
--   absent        nothing of it exists and what it replaces has its old body
--   applied       every object it creates exists with the reviewed body,
--                 settings and grants
--   INCONSISTENT  anything else (a partial state, an unknown body, a grant that
--                 should not be there): stop
--   0028 also: APPLIED-DRIFTED -- applied, but its baked zone list no longer
--                 equals pg_timezone_names (tzdata changed): rebuild (runbook §8)
--
-- HOW TO RUN. As ONE execution of the whole file (SQL Editor: run all; psql:
--   psql -X -1 -v ON_ERROR_STOP=1 -f supabase/preflight/P8_state_check.sql).
-- The first two lines make the transaction read-only with a time limit; the
-- third statement STOPS the run with an error if either did not take effect, so
-- nothing after it runs. Cost: catalog lookups and one read of the zone list
-- (pg_timezone_names, ~0.1 s) -- no application table is read.
-- Output: names, fingerprints, counts. No application data.
-- ============================================================================
set transaction read only;
set local statement_timeout = '10s';
select case when current_setting('transaction_read_only') = 'on' and current_setting('statement_timeout') = '10s'
            then 'gate: read only, 10s'
            else ('STOPPED: read_only=' || current_setting('transaction_read_only') || ', statement_timeout=' || current_setting('statement_timeout'))::int::text end as gate;
with
helper as (select p.oid, p.proowner, md5(replace(p.prosrc, E'\r\n', E'\n')) as body from pg_catalog.pg_proc p
           where p.oid = to_regprocedure('timeweave_private.free_busy_available(uuid, timestamptz, timestamptz, date, date, jsonb)')),
zds as (select p.oid, p.proowner, md5(replace(p.prosrc, E'\r\n', E'\n')) as body, p.proacl from pg_catalog.pg_proc p
        where p.oid = to_regprocedure('timeweave_private.zoned_day_start(date, text)')),
tzs as (select p.oid, p.proowner, md5(replace(p.prosrc, E'\r\n', E'\n')) as body from pg_catalog.pg_proc p where p.oid = to_regprocedure('public.timezone_is_supported(text)')),
lst as (select p.oid, p.prosrc, p.provolatile,
               -- what 0028 creates it with besides IMMUTABLE, and the owner it inherits
               (not p.prosecdef and p.proisstrict and p.proparallel = 's'
                and p.prolang = (select l.oid from pg_catalog.pg_language l where l.lanname = 'sql')
                and p.proconfig = array['search_path=""']
                and p.proowner = (select proowner from tzs)) is true as attrs_ok
        from pg_catalog.pg_proc p where p.oid = to_regprocedure('public.timezone_name_listed(text)')),
baked as (select substring((select prosrc from lst) from '^select \$1 = any \(''(\{[^'']*\})''::text\[\]\)$')::text[] as arr),
-- 0029's trigger is judged from the catalog, not from pg_get_triggerdef's text:
-- that text names the function without its schema only when public is on the
-- search_path (so it fails a correct trigger elsewhere, and does not say WHICH
-- function). tgtype 23 = ROW | BEFORE | INSERT | UPDATE; the UPDATE columns are
-- exactly rrule and all_day; no WHEN, not a constraint trigger, no arguments.
ev as (select c.relowner from pg_catalog.pg_class c where c.oid = 'public.events'::regclass),
trg as (select t.tgenabled, t.tgfoid,
               (t.tgtype = 23 and t.tgqual is null and t.tgconstraint = 0 and t.tgnargs = 0
                and (select array_agg(a.attname::text order by a.attname) from pg_catalog.pg_attribute a
                     where a.attrelid = t.tgrelid and a.attnum = any (t.tgattr::int2[])) = array['all_day', 'rrule']) is true as shape_ok
        from pg_catalog.pg_trigger t
        where t.tgrelid = 'public.events'::regclass and t.tgname = 'events_validate_rrule'),
vfn as (select p.oid, md5(replace(p.prosrc, E'\r\n', E'\n')) as body, p.prosecdef, p.proconfig,
               (p.prosecdef and p.proconfig = array['search_path=""'] and p.proowner = (select relowner from ev)
                and p.prolang = (select l.oid from pg_catalog.pg_language l where l.lanname = 'plpgsql')) is true as attrs_ok
        from pg_catalog.pg_proc p where p.oid = to_regprocedure('public.events_validate_rrule()')),
pred as (select p.oid, md5(replace(p.prosrc, E'\r\n', E'\n')) as body,
                (not p.prosecdef and p.provolatile = 's' and p.proconfig = array['search_path=""'] and p.proowner = (select relowner from ev)
                 and p.prolang = (select l.oid from pg_catalog.pg_language l where l.lanname = 'sql')) is true as attrs_ok
         from pg_catalog.pg_proc p where p.oid = to_regprocedure('public.rrule_is_writable(text, boolean)')),
client_exec as (
  -- Owner-only functions: is EXECUTE granted to ANYONE but the owner? Read from
  -- the ACL itself (a NULL ACL means the default, which includes PUBLIC), so it
  -- covers PUBLIC (grantee 0), the client roles, and any other role. A role that
  -- gets EXECUTE by inheritance gets it from some grantee in this ACL, so it is
  -- caught at that grantee. Second net: any role that is not a superuser and not
  -- a member of the owner role but still has EXECUTE (has_function_privilege
  -- follows inheritance).
  select f,
         exists (select 1 from pg_catalog.pg_proc p, pg_catalog.aclexplode(coalesce(p.proacl, pg_catalog.acldefault('f', p.proowner))) a
                 where p.oid = f and a.privilege_type = 'EXECUTE' and a.grantee <> p.proowner)
         or exists (select 1 from pg_catalog.pg_proc p, pg_catalog.pg_roles r
                    where p.oid = f and not r.rolsuper and not pg_catalog.pg_has_role(r.oid, p.proowner, 'USAGE')
                      and pg_catalog.has_function_privilege(r.oid, p.oid, 'EXECUTE')) as any_client
  from (select oid as f from zds union all select oid from vfn union all select oid from pred) s
),
s27 as (
  select case
    when (select body from helper) = '23f069bd792768f9279f5308e3edbaaf' and not exists (select 1 from zds) then 'absent'
    when (select body from helper) = 'e7922ad9183a4b15b5481e1411e1a08c'
         and (select body from zds) = 'fe15de1e10b7d84129179ada42d72cd9'
         and (select proowner from zds) = (select proowner from helper)
         and not (select any_client from client_exec where f = (select oid from zds)) then 'applied'
    else 'INCONSISTENT' end as st,
    'helper ' || coalesce((select body from helper), '(missing)') || ', zoned_day_start ' || coalesce((select body from zds), '(missing)') as detail
),
s28 as (
  select case
    when (select body from tzs) = 'd6d46c844ff9c154870f67b757dd3b4f' and not exists (select 1 from lst) then 'absent'
    when (select body from tzs) = '073cd648fb8d2b7f93e0401add60e075' and exists (select 1 from lst)
         and (select provolatile from lst) = 'i'
         and (select attrs_ok from lst)
         and (select arr from baked) is not null and cardinality((select arr from baked)) > 0
         and not exists (  -- every role: same EXECUTE and grant option as timezone_is_supported
           select 1 from pg_catalog.pg_roles r
           where pg_catalog.has_function_privilege(r.oid, (select oid from tzs), 'EXECUTE') is distinct from pg_catalog.has_function_privilege(r.oid, (select oid from lst), 'EXECUTE')
              or pg_catalog.has_function_privilege(r.oid, (select oid from tzs), 'EXECUTE WITH GRANT OPTION') is distinct from pg_catalog.has_function_privilege(r.oid, (select oid from lst), 'EXECUTE WITH GRANT OPTION'))
      then case when (select arr from baked) @> (select array_agg(name) from pg_catalog.pg_timezone_names)
                 and (select arr from baked) <@ (select array_agg(name) from pg_catalog.pg_timezone_names)
                 and cardinality((select arr from baked)) = (select count(distinct x) from unnest((select arr from baked)) x)
                then 'applied' else 'APPLIED-DRIFTED' end
    else 'INCONSISTENT' end as st,
    'timezone_is_supported ' || coalesce((select body from tzs), '(missing)') || ', list ' ||
      case when not exists (select 1 from lst) then '(absent)' when (select arr from baked) is null then '(UNREADABLE body)'
           else cardinality((select arr from baked))::text || ' names' end
      || case when exists (select 1 from lst) and not (select attrs_ok from lst) then ', ATTRIBUTES differ' else '' end as detail
),
s29 as (
  select case
    when not exists (select 1 from trg) and not exists (select 1 from vfn) and not exists (select 1 from pred) then 'absent'
    when (select tgenabled from trg) = 'O'
         and (select shape_ok from trg)
         and (select tgfoid from trg) = (select oid from vfn)
         and (select body from vfn) = 'ee7cdb0e1367bbcefb5f8fa79c2844f8' and (select attrs_ok from vfn)
         and (select body from pred) = '2483d8d235876a95210ce2ebfc27eb35' and (select attrs_ok from pred)
         and not (select any_client from client_exec where f = (select oid from vfn))
         and not (select any_client from client_exec where f = (select oid from pred)) then 'applied'
    else 'INCONSISTENT' end as st,
    'trigger ' || coalesce((select tgenabled::text from trg), '(absent)') || ', events_validate_rrule ' || coalesce((select body from vfn), '(missing)')
      || ', rrule_is_writable ' || coalesce((select body from pred), '(missing)')
      || case when (select shape_ok from trg) is false or (select tgfoid from trg) is distinct from (select oid from vfn) and exists (select 1 from trg)
              then ', TRIGGER differs' else '' end
      || case when (select attrs_ok from vfn) is false or (select attrs_ok from pred) is false then ', ATTRIBUTES differ' else '' end as detail
),
rows as (
  select 'R00'::text as id, 'transaction_read_only (must be on)'::text as item, current_setting('transaction_read_only') as value,
         case when current_setting('transaction_read_only') = 'on' then 'GATE-OK' else 'GATE-FAIL' end::text as verdict
  union all select 'R01', 'statement_timeout (must be 10s)', current_setting('statement_timeout'),
         case when current_setting('statement_timeout') = '10s' then 'GATE-OK' else 'GATE-FAIL' end
  union all select 'S27', '0027: ' || detail, st, case when st in ('absent', 'applied') then 'GATE-OK' else 'GATE-FAIL' end from s27
  union all select 'S28', '0028: ' || detail, st, case when st in ('absent', 'applied') then 'GATE-OK' else 'GATE-FAIL' end from s28
  union all select 'S29', '0029: ' || detail, st, case when st in ('absent', 'applied') then 'GATE-OK' else 'GATE-FAIL' end from s29
  union all select 'STATE', 'compare with the runbook',
         '0027=' || (select st from s27) || ' 0028=' || (select st from s28) || ' 0029=' || (select st from s29), 'INFO'
)
select * from rows
union all
select 'ZZZ', 'GATE-FAIL rows', count(*) filter (where verdict = 'GATE-FAIL')::text,
       case when count(*) filter (where verdict = 'GATE-FAIL') = 0 then 'GATE-OK' else 'GATE-FAIL' end from rows
order by 1;
