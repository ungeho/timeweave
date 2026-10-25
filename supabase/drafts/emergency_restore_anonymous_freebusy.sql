-- ============================================================================
-- RESTORE after LEVEL 1 (emergency_disable_anonymous_freebusy.sql): anon may
-- execute public.get_free_busy again, through the same direct grant 0005 made.
-- Nothing else. Afterwards run emergency_check_freebusy_access.sql and compare
-- it with the output saved before the stop: it must be the same.
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
  execute 'grant execute on function public.get_free_busy(text, timestamptz, timestamptz, date, date) to anon';
  if not pg_catalog.has_function_privilege('anon', v_fn, 'EXECUTE') then
    raise exception 'not restored: anon still cannot execute get_free_busy';
  end if;
end
$restore$;
commit;
