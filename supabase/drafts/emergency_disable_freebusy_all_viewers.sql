-- ============================================================================
-- EMERGENCY, LEVEL 2 -- stop Free/Busy for EVERY viewer: anonymous ones AND
-- viewers signed in to TimeWeave (who call as `authenticated`). DRAFT; its own
-- approval. Reverse with emergency_restore_freebusy_all_viewers.sql.
-- ============================================================================
-- What it does: removes the DIRECT grants of EXECUTE on public.get_free_busy
-- to anon and to authenticated (the ones 0005 made), and nothing else.
-- Effect on the app: only the share page calls get_free_busy (FreeBusyPage via
-- shareRepository.getFreeBusy). The owner's calendar, events, settings and the
-- share-link list keep working. Share pages show their load error for everyone.
-- Like LEVEL 1, it refuses -- changing nothing -- when either role would keep
-- EXECUTE through PUBLIC or a membership, and names the path.
-- Apply as the owner of get_free_busy.
-- ============================================================================
begin;
do $stop$
declare
  v_fn regprocedure := 'public.get_free_busy(text, timestamptz, timestamptz, date, date)'::regprocedure;
  v_owner text; v_via text;
begin
  select pg_catalog.pg_get_userbyid(p.proowner) into v_owner from pg_catalog.pg_proc p where p.oid = v_fn;
  if v_owner is distinct from current_user then
    raise exception 'apply as % (owner of get_free_busy), not %', v_owner, current_user;
  end if;
  select string_agg(x, ', ') into v_via from (
    select 'PUBLIC' as x from pg_catalog.pg_proc p, pg_catalog.aclexplode(coalesce(p.proacl, pg_catalog.acldefault('f', p.proowner))) a
     where p.oid = v_fn and a.grantee = 0 and a.privilege_type = 'EXECUTE'
    union all
    select r.rolname || ' via membership in ' || g.rolname
      from pg_catalog.pg_roles r join pg_catalog.pg_auth_members m on m.member = r.oid join pg_catalog.pg_roles g on g.oid = m.roleid
     where r.rolname in ('anon', 'authenticated') and g.rolname not in ('anon', 'authenticated')
       and pg_catalog.has_function_privilege(g.oid, v_fn, 'EXECUTE')) s;
  if v_via is not null then
    raise exception 'not stopped: a viewer role would keep EXECUTE through % -- nothing was changed (see runbook §6)', v_via;
  end if;
  execute 'revoke execute on function public.get_free_busy(text, timestamptz, timestamptz, date, date) from anon, authenticated';
  if pg_catalog.has_function_privilege('anon', v_fn, 'EXECUTE') or pg_catalog.has_function_privilege('authenticated', v_fn, 'EXECUTE') then
    raise exception 'not stopped: a viewer role can still execute get_free_busy -- rolled back';
  end if;
end
$stop$;
commit;
