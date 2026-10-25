-- ============================================================================
-- RESTORE after LEVEL 2 (emergency_disable_freebusy_all_viewers.sql): anon and
-- authenticated may execute public.get_free_busy again, through the direct
-- grants 0005 made. Nothing else. Then run emergency_check_freebusy_access.sql
-- and compare with the output saved before the stop.
-- Apply as the owner of get_free_busy.
-- ============================================================================
begin;
do $restore$
declare
  v_fn regprocedure := 'public.get_free_busy(text, timestamptz, timestamptz, date, date)'::regprocedure;
  v_owner text;
begin
  select pg_catalog.pg_get_userbyid(p.proowner) into v_owner from pg_catalog.pg_proc p where p.oid = v_fn;
  if v_owner is distinct from current_user then
    raise exception 'apply as % (owner of get_free_busy), not %', v_owner, current_user;
  end if;
  execute 'grant execute on function public.get_free_busy(text, timestamptz, timestamptz, date, date) to anon, authenticated';
  if not (pg_catalog.has_function_privilege('anon', v_fn, 'EXECUTE') and pg_catalog.has_function_privilege('authenticated', v_fn, 'EXECUTE')) then
    raise exception 'not restored: a viewer role still cannot execute get_free_busy';
  end if;
end
$restore$;
commit;
