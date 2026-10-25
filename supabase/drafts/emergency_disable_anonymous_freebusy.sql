-- ============================================================================
-- EMERGENCY, LEVEL 1 -- stop ANONYMOUS Free/Busy at once (K15 load, or any
-- incident on the share path). DRAFT for the release runbook; needs its own
-- approval. Reverse with emergency_restore_anonymous_freebusy.sql.
-- ============================================================================
-- What it does: removes anon's DIRECT grant of EXECUTE on public.get_free_busy
-- (the one 0005 made), and nothing else. Share pages opened without a TimeWeave
-- login then get a permission error (the page shows its load error); nothing
-- is disclosed, no data is touched, links are not revoked and work again after
-- the restore.
-- What it does NOT stop:
--   * a viewer who is SIGNED IN to TimeWeave in the same browser calls as
--     `authenticated` and still gets answers -> LEVEL 2
--     (emergency_disable_freebusy_all_viewers.sql);
--   * writes, sign-ups, other endpoints -> platform levers (runbook §6).
-- It refuses, changing nothing, when anon would keep EXECUTE some other way
-- (through PUBLIC, or a role anon belongs to): removing that is a broader
-- change than an emergency stop should make blind, and it names the path.
-- Run emergency_check_freebusy_access.sql before (save it) and after.
-- Apply as the owner of get_free_busy.
-- ============================================================================
begin;
do $stop$
declare
  v_fn regprocedure := 'public.get_free_busy(text, timestamptz, timestamptz, date, date)'::regprocedure;
  v_owner text; v_anon oid := (select oid from pg_catalog.pg_roles where rolname = 'anon'); v_via text;
begin
  select pg_catalog.pg_get_userbyid(p.proowner) into v_owner from pg_catalog.pg_proc p where p.oid = v_fn;
  if v_owner is distinct from current_user then
    raise exception 'apply as % (owner of get_free_busy), not %', v_owner, current_user;
  end if;
  -- other paths to EXECUTE that a revoke from anon would not close
  select string_agg(x, ', ') into v_via from (
    select 'PUBLIC' as x from pg_catalog.pg_proc p, pg_catalog.aclexplode(coalesce(p.proacl, pg_catalog.acldefault('f', p.proowner))) a
     where p.oid = v_fn and a.grantee = 0 and a.privilege_type = 'EXECUTE'
    union all
    select 'membership in ' || g.rolname from pg_catalog.pg_auth_members m join pg_catalog.pg_roles g on g.oid = m.roleid
     where m.member = v_anon and pg_catalog.has_function_privilege(g.oid, v_fn, 'EXECUTE')) s;
  if v_via is not null then
    raise exception 'not stopped: anon would keep EXECUTE through % -- nothing was changed (see runbook §6)', v_via;
  end if;
  execute 'revoke execute on function public.get_free_busy(text, timestamptz, timestamptz, date, date) from anon';
  if pg_catalog.has_function_privilege(v_anon, v_fn, 'EXECUTE') then
    raise exception 'not stopped: anon can still execute get_free_busy -- rolled back';
  end if;
end
$stop$;
commit;
