-- ROLLBACK for supabase/drafts/0029_events_rrule_write_check.draft.sql (DRAFT, K16).
-- Trigger first, then the functions it uses. No data is touched.
-- Apply as the owner of public.events.
-- NOT AUTOMATIC: the guard below refuses anything but a 0029-applied state,
-- but it does not replace C1 (runbook §5).
begin;

do $guard$
declare v_owner text; v_vfn text; v_pred text; v_trg_ok boolean; v_users text;
begin
  select pg_catalog.pg_get_userbyid(c.relowner) into v_owner from pg_catalog.pg_class c where c.oid = 'public.events'::regclass;
  if v_owner is distinct from current_user then
    raise exception 'apply as % (owner of public.events), not %', v_owner, current_user;
  end if;
  -- Only undo what 0029 did: both functions with 0029's bodies (md5 after
  -- CRLF->LF), and the trigger present, calling that function, with 0029's
  -- shape (ROW | BEFORE | INSERT | UPDATE OF all_day, rrule; no WHEN). Not
  -- applied, an unknown body, or a changed trigger: stop, nothing is changed.
  select pg_catalog.md5(pg_catalog.replace(p.prosrc, E'\r\n', E'\n')) into v_vfn
  from pg_catalog.pg_proc p where p.oid = pg_catalog.to_regprocedure('public.events_validate_rrule()');
  select pg_catalog.md5(pg_catalog.replace(p.prosrc, E'\r\n', E'\n')) into v_pred
  from pg_catalog.pg_proc p where p.oid = pg_catalog.to_regprocedure('public.rrule_is_writable(text, boolean)');
  if v_vfn is distinct from 'ee7cdb0e1367bbcefb5f8fa79c2844f8' or v_pred is distinct from '2483d8d235876a95210ce2ebfc27eb35' then
    raise exception 'not a 0029-applied state (trigger function md5 %, predicate md5 %): nothing rolled back',
      coalesce(v_vfn, '(none)'), coalesce(v_pred, '(none)');
  end if;
  select t.tgfoid = pg_catalog.to_regprocedure('public.events_validate_rrule()')::oid
         and t.tgtype = 23 and t.tgqual is null and t.tgconstraint = 0 and t.tgnargs = 0
         and (select pg_catalog.array_agg(a.attname::text order by a.attname) from pg_catalog.pg_attribute a
              where a.attrelid = t.tgrelid and a.attnum = any (t.tgattr::int2[])) = array['all_day', 'rrule']
    into v_trg_ok
  from pg_catalog.pg_trigger t where t.tgrelid = 'public.events'::regclass and t.tgname = 'events_validate_rrule';
  if v_trg_ok is not true then
    raise exception 'trigger events_validate_rrule is missing or not the one 0029 created: nothing rolled back';
  end if;
  -- The predicate is dropped below. A string-bodied function that calls it is
  -- not a tracked dependency, so DROP would not refuse; look for one by name.
  select pg_catalog.string_agg(p.oid::regprocedure::text, ', ') into v_users
  from pg_catalog.pg_proc p
  where p.prosrc like '%rrule_is_writable%'
    and p.oid not in (pg_catalog.to_regprocedure('public.events_validate_rrule()'), pg_catalog.to_regprocedure('public.rrule_is_writable(text, boolean)'));
  if v_users is not null then
    raise exception 'other functions refer to rrule_is_writable (%): nothing rolled back', v_users;
  end if;
end
$guard$;

drop trigger if exists events_validate_rrule on public.events;
drop function if exists public.events_validate_rrule();
drop function if exists public.rrule_is_writable(text, boolean);

commit;
