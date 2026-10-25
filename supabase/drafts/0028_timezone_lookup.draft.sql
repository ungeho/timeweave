-- ============================================================================
-- DRAFT -- NOT A MIGRATION. Not in supabase/migrations/ on purpose: nothing
-- applies it. Verified on an isolated copy only (P8-finish-3a.2, K15).
-- Production 0027 was applied and verified on 2026-10-22. This 0028 draft
-- remains NOT applied / NOT approved. Confirm the post-0027 C1 state and
-- get separate A3 approval before running 0028; choose the migration number
-- per the runbook.
-- ============================================================================
-- K15. public.timezone_is_supported (0008) decides membership with
--   exists (select 1 from pg_catalog.pg_timezone_names z where z.name = p_tz)
-- pg_timezone_names is a set-returning function that reads the zone files from
-- disk on EVERY call: ~145 ms per call measured on the isolated PostgreSQL 18.6
-- (Windows), ~140 ms on 17.10 in 0018's own local measurement. Production
-- PostgreSQL 17.6 measured 661.383 ms (first), 496.343 ms (second) for
-- timezone_is_supported; pg_timezone_names cost 47.023 ms with 1196 rows.
-- It is paid
--   * per ROW written with a zone (0008 BEFORE ROW trigger): 200 timed
--     recurring rows took 30.9 s -- before 0012's row-rate trigger, which runs
--     AFTER the statement, can refuse them; and
--   * per DISTINCT ZONE per anonymous get_free_busy call (0018 v_ok_tz, twice:
--     core and helper): 20 zones -> 5.95 s for one anonymous call.
--
-- THE CHANGE. The same set of names, read ONCE, when this file is applied, and
-- baked into an IMMUTABLE function as a literal array. Membership becomes an
-- array search (50,000 lookups: 4.3 ms). Every other test in
-- timezone_is_supported is kept byte for byte; only the exists(...) moves.
--
-- WHAT IT CHANGES IN MEANING. Nothing while the server's tzdata is the one the
-- list was built from (checked by the gate at the end: the list must equal
-- pg_timezone_names exactly). After a tzdata upgrade:
--   * a zone ADDED by the upgrade is refused until the list is rebuilt (re-run
--     section 1) -- the safe direction: a write is refused, nothing is shared;
--   * a zone REMOVED by the upgrade stays listed, and timezone_is_resolvable's
--     AT TIME ZONE probe (unchanged) still rejects it if PostgreSQL cannot
--     resolve it -- so the share path stays fail-closed.
--
-- APPLY AS the owner of public.timezone_is_supported (guard 0).
-- ROLLBACK: supabase/drafts/0028_timezone_lookup.rollback.sql
-- ============================================================================
begin;

do $guard$
declare v_owner text; v_body text;
begin
  select pg_catalog.pg_get_userbyid(p.proowner), pg_catalog.md5(pg_catalog.replace(p.prosrc, E'\r\n', E'\n')) into v_owner, v_body
  from pg_catalog.pg_proc p where p.oid = 'public.timezone_is_supported(text)'::regprocedure;
  if v_owner is distinct from current_user then
    raise exception 'apply as % (owner of timezone_is_supported), not %', v_owner, current_user;
  end if;
  -- The body being replaced must be the reviewed one: 0008's on the first
  -- apply (the rollback restores exactly that text), or this file's own on a
  -- re-run that rebuilds the list. Anything else: stop, nothing is changed.
  -- md5 after CRLF->LF: the SQL Editor keeps a file's CRLF in the body, psql
  -- does not; the code is the same either way.
  if v_body not in ('d6d46c844ff9c154870f67b757dd3b4f',   -- 0008
                    '073cd648fb8d2b7f93e0401add60e075') then                   -- this file
    raise exception 'timezone_is_supported has an unexpected body (md5 %): not the 0008 body this file replaces', v_body;
  end if;
end
$guard$;

-- 1. The list, baked in. Re-running this block rebuilds it (after a tzdata upgrade).
do $build$
declare v_names text[];
begin
  select array_agg(z.name order by z.name) into v_names from pg_catalog.pg_timezone_names z;
  execute format($f$
    create or replace function public.timezone_name_listed(p_tz text)
    returns boolean
    language sql
    immutable
    strict
    parallel safe
    set search_path = ''
    as %L
  $f$, format('select $1 = any (%L::text[])', v_names));
  perform set_config('timeweave.tz_listed', pg_catalog.array_length(v_names, 1)::text, true);
  execute format('comment on function public.timezone_name_listed(text) is %L',
    format('pg_timezone_names as of %s (%s names). K15: replaces a per-call read of the zone files. Rebuild after a tzdata upgrade.',
           pg_catalog.now()::date, pg_catalog.array_length(v_names, 1)));
end
$build$;

-- EXECUTE on the new function is an EXACT COPY of timezone_is_supported's ACL
-- as it stands where this is applied: every EXECUTE entry, PUBLIC included, any
-- role (not a fixed list), with the grant option where it has one; a NULL ACL
-- (never granted or revoked) means the default, which is PUBLIC.
--   Why a copy: 0008 revoked PUBLIC and granted `authenticated`, but on Supabase
-- the platform's default privileges may also have granted anon, service_role or
-- other roles when 0008 created it. Whoever can call timezone_is_supported today
-- must still be able to (the write triggers call the list through it as the
-- signed-in user, the owner_settings trigger too, a service_role write of a zone
-- row through the same path), and nobody gains anything they did not have.
-- Role membership then works the same for both, because the entries are the same.
--   Step 1 first clears what the new function was given at creation (PUBLIC by
-- default, and whatever default privileges the platform adds). Re-running this
-- block re-derives the same ACL.
do $grants$
declare r record;
begin
  execute 'revoke all on function public.timezone_name_listed(text) from public';
  for r in
    select distinct a.grantee
    from pg_catalog.pg_proc p, pg_catalog.aclexplode(coalesce(p.proacl, pg_catalog.acldefault('f', p.proowner))) a
    where p.oid = 'public.timezone_name_listed(text)'::regprocedure and a.grantee not in (0, p.proowner)
  loop
    execute format('revoke all on function public.timezone_name_listed(text) from %I', pg_catalog.pg_get_userbyid(r.grantee));
  end loop;
  for r in
    select a.grantee, bool_or(a.is_grantable) as grantable
    from pg_catalog.pg_proc p, pg_catalog.aclexplode(coalesce(p.proacl, pg_catalog.acldefault('f', p.proowner))) a
    where p.oid = 'public.timezone_is_supported(text)'::regprocedure and a.privilege_type = 'EXECUTE' and a.grantee <> p.proowner
    group by a.grantee
  loop
    execute format('grant execute on function public.timezone_name_listed(text) to %s%s',
                   case when r.grantee = 0 then 'public' else pg_catalog.quote_ident(pg_catalog.pg_get_userbyid(r.grantee)) end,
                   case when r.grantable then ' with grant option' else '' end);
  end loop;
end
$grants$;

-- 2. timezone_is_supported: 0008's body with the membership test swapped.
--    CREATE OR REPLACE keeps its owner, ACL, volatility and search_path.
create or replace function public.timezone_is_supported(p_tz text)
returns boolean
language sql
stable
set search_path = ''
as $fn$
  select p_tz is not null
     and length(p_tz) between 1 and 64
     and p_tz ~ '^[A-Za-z][A-Za-z0-9_+-]*(/[A-Za-z0-9_+-]+){0,2}$'
     and p_tz <> 'localtime'
     and p_tz not like 'posix/%'
     and p_tz not like 'right/%'
     and public.timezone_name_listed(p_tz);
$fn$;

-- 3. Gate: the baked list is exactly what the server knows right now -- every
--    known name is listed, and the list has no more names than the server has.
do $gate$
declare v_missing int; v_known int; v_listed int := current_setting('timeweave.tz_listed')::int;
begin
  select count(*), count(*) filter (where not public.timezone_name_listed(z.name)) into v_known, v_missing
  from pg_catalog.pg_timezone_names z;
  if v_missing <> 0 or v_listed <> v_known then
    raise exception 'timezone list mismatch: % known, % listed, % missing', v_known, v_listed, v_missing;
  end if;
  -- and EVERY role (inheritance and PUBLIC included, as has_function_privilege
  -- resolves them) can execute the list exactly when it can execute
  -- timezone_is_supported, and may grant it exactly when it may grant that
  if exists (
    select 1 from pg_catalog.pg_roles r
    where pg_catalog.has_function_privilege(r.oid, 'public.timezone_is_supported(text)', 'EXECUTE')
          is distinct from pg_catalog.has_function_privilege(r.oid, 'public.timezone_name_listed(text)', 'EXECUTE')
       or pg_catalog.has_function_privilege(r.oid, 'public.timezone_is_supported(text)', 'EXECUTE WITH GRANT OPTION')
          is distinct from pg_catalog.has_function_privilege(r.oid, 'public.timezone_name_listed(text)', 'EXECUTE WITH GRANT OPTION')
  ) then
    raise exception 'timezone_name_listed does not have the same EXECUTE privileges as timezone_is_supported';
  end if;
end
$gate$;

commit;
