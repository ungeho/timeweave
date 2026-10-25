-- ROLLBACK for supabase/drafts/0028_timezone_lookup.draft.sql (DRAFT, K15).
-- Restores 0008's body of public.timezone_is_supported FIRST, then drops the
-- list. The other order would leave timezone_is_supported calling a function
-- that no longer exists (SQL function bodies are checked at creation, not kept
-- as dependencies here). Apply as the owner of timezone_is_supported.
-- NOT AUTOMATIC: the guard below refuses anything but a 0028-applied state,
-- but it does not replace C1. Before any production rollback: obtain separate
-- approval for a C1 read and for rollback, verify a known 0028-applied state,
-- and stop on inconsistencies.
begin;

do $guard$
declare v_owner text; v_body text; v_list_owner text; v_users text;
begin
  select pg_catalog.pg_get_userbyid(p.proowner), pg_catalog.md5(pg_catalog.replace(p.prosrc, E'\r\n', E'\n')) into v_owner, v_body
  from pg_catalog.pg_proc p where p.oid = 'public.timezone_is_supported(text)'::regprocedure;
  if v_owner is distinct from current_user then
    raise exception 'apply as % (owner of timezone_is_supported), not %', v_owner, current_user;
  end if;
  -- Only undo what 0028 did: timezone_is_supported must have 0028's body (md5
  -- after CRLF->LF, as in 0028's guard) and the list must exist with the same
  -- owner. 0008's body (not applied), an unknown body, or a missing list: stop,
  -- nothing is changed.
  if v_body is distinct from '073cd648fb8d2b7f93e0401add60e075' then
    raise exception 'timezone_is_supported has md5 %, not the 0028 body: not a 0028-applied state, nothing rolled back', v_body;
  end if;
  select pg_catalog.pg_get_userbyid(p.proowner) into v_list_owner
  from pg_catalog.pg_proc p where p.oid = pg_catalog.to_regprocedure('public.timezone_name_listed(text)');
  if v_list_owner is distinct from v_owner then
    raise exception 'timezone_name_listed is missing or owned by % (not %): not a 0028-applied state, nothing rolled back', v_list_owner, v_owner;
  end if;
  -- The list is dropped below. A string-bodied function that calls it is not
  -- a tracked dependency, so DROP would not refuse; look for one by name.
  select pg_catalog.string_agg(p.oid::regprocedure::text, ', ') into v_users
  from pg_catalog.pg_proc p
  where p.prosrc like '%timezone_name_listed%'
    and p.oid not in ('public.timezone_is_supported(text)'::regprocedure, 'public.timezone_name_listed(text)'::regprocedure);
  if v_users is not null then
    raise exception 'other functions refer to timezone_name_listed (%): nothing rolled back', v_users;
  end if;
end
$guard$;

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
     and exists (
           select 1
           from pg_catalog.pg_timezone_names z
           where z.name = p_tz
         );
$fn$;

drop function public.timezone_name_listed(text);

commit;
