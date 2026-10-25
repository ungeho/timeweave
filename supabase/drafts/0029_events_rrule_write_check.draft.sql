-- ============================================================================
-- DRAFT -- NOT A MIGRATION. Not in supabase/migrations/ on purpose: nothing
-- applies it. Verified on an isolated copy only (P8-finish-3a.2, K16).
-- ============================================================================
-- K16. public.events.rrule has one constraint: at most 255 bytes (0013). The
-- owner -- any signed-in user, through the REST API with their own token -- can
-- store any shorter text: "garbage", FREQ=YEARLY, INTERVAL=1e+23, COUNT and
-- UNTIL together, UNTIL=20261340 ... RLS keeps it inside their own calendar,
-- and the share path fails closed on it (P8f3a2_rrule_adversarial_test.sql),
-- so nothing leaks; but the client then hides the series (K12) and the app can
-- neither show nor repair it (K12-R).
--
-- THE CHANGE. A BEFORE ROW trigger refuses to WRITE a rule the app could not
-- have written:
--   * exactly the canonical text formatRRule produces --
--       FREQ=DAILY|WEEKLY|MONTHLY [;INTERVAL=1..9999] [;BYDAY=MO..SU,...]
--       [;COUNT=1..9999999 | ;UNTIL=YYYYMMDD | ;UNTIL=YYYYMMDDTHHMMSSZ]
--     upper case, in that order, no spaces, digits only -- AND
--   * a rule rrule_parse (0006) accepts as 'ok' (a real calendar date in
--     UNTIL, no repeated BYDAY, BYDAY only with WEEKLY) AND
--   * an UNTIL of the row's kind: a date for an all-day series, an instant for
--     a timed one (the SQL grammar gates already treat the other as
--     unexpandable).
-- Every rule in that set is read by the client and by SQL with the same
-- meaning (the differential corpus, 8,136 strings: 0 disagreements, and every
-- canonical string is accepted by both).
--
-- WHAT IT DOES NOT TOUCH. Rows already stored: no backfill, no CHECK (a CHECK
-- would be validated against them). An UPDATE is checked only when it changes
-- rrule or all_day, so an existing odd row can still be renamed, moved or
-- deleted. DELETE is never checked -- the owner can always remove a broken
-- series (and its exceptions cascade). Reading, sharing and rrule_parse are
-- unchanged.
--
-- THE MESSAGE. 23514 with DETAIL TIMEWEAVE_RRULE_INVALID; the text names no
-- input and no internals.
--
-- APPLY AS the owner of public.events. ROLLBACK: 0029_events_rrule_write_check.rollback.sql
-- ============================================================================
begin;

do $guard$
declare v_owner text; v_vfn text; v_pred text; v_trg_ok boolean; v_has_trg boolean;
begin
  select pg_catalog.pg_get_userbyid(c.relowner) into v_owner from pg_catalog.pg_class c where c.oid = 'public.events'::regclass;
  if v_owner is distinct from current_user then
    raise exception 'apply as % (owner of public.events), not %', v_owner, current_user;
  end if;
  -- CREATE OR REPLACE and DROP TRIGGER IF EXISTS below would silently replace
  -- objects of the same name. Proceed only when none of the three exists (the
  -- first apply) or all three are this file's own and intact (a re-run): the
  -- bodies by md5 after CRLF->LF, the trigger as C1 judges it -- enabled,
  -- calling that function, ROW | BEFORE | INSERT | UPDATE OF all_day, rrule,
  -- no WHEN. A disabled or altered trigger is not re-run over: stop, nothing is
  -- changed, and report (runbook §5).
  select pg_catalog.md5(pg_catalog.replace(p.prosrc, E'\r\n', E'\n')) into v_vfn
  from pg_catalog.pg_proc p where p.oid = pg_catalog.to_regprocedure('public.events_validate_rrule()');
  select pg_catalog.md5(pg_catalog.replace(p.prosrc, E'\r\n', E'\n')) into v_pred
  from pg_catalog.pg_proc p where p.oid = pg_catalog.to_regprocedure('public.rrule_is_writable(text, boolean)');
  select true,
         t.tgenabled = 'O' and t.tgfoid = pg_catalog.to_regprocedure('public.events_validate_rrule()')::oid
         and t.tgtype = 23 and t.tgqual is null and t.tgconstraint = 0 and t.tgnargs = 0
         and (select pg_catalog.array_agg(a.attname::text order by a.attname) from pg_catalog.pg_attribute a
              where a.attrelid = t.tgrelid and a.attnum = any (t.tgattr::int2[])) = array['all_day', 'rrule']
    into v_has_trg, v_trg_ok
  from pg_catalog.pg_trigger t where t.tgrelid = 'public.events'::regclass and t.tgname = 'events_validate_rrule';
  -- IS NOT TRUE, not NOT: a missing object makes a comparison NULL, and
  -- "if not NULL" would let the file run.
  if (   (v_vfn is null and v_pred is null and v_has_trg is null)
      or (v_vfn = 'ee7cdb0e1367bbcefb5f8fa79c2844f8' and v_pred = '2483d8d235876a95210ce2ebfc27eb35' and v_trg_ok)) is not true then
    raise exception 'events_validate_rrule / rrule_is_writable already exist and are not this file''s, intact (trigger function md5 %, predicate md5 %, trigger %): nothing is changed',
      coalesce(v_vfn, '(none)'), coalesce(v_pred, '(none)'),
      case when v_has_trg is null then '(none)' when v_trg_ok then 'as created' else 'DISABLED or ALTERED' end;
  end if;
end
$guard$;

-- 1. The rule set, as one predicate (also usable read-only, to count rows that
--    fall outside it before or after applying this).
create or replace function public.rrule_is_writable(p_rrule text, p_all_day boolean)
returns boolean
language sql
stable
set search_path = ''
as $fn$
  select p_rrule is not null
     and p_all_day is not null
     and p_rrule ~ '^FREQ=(DAILY|WEEKLY|MONTHLY)(;INTERVAL=[1-9][0-9]{0,3})?(;BYDAY=(MO|TU|WE|TH|FR|SA|SU)(,(MO|TU|WE|TH|FR|SA|SU)){0,6})?(;COUNT=[1-9][0-9]{0,6}|;UNTIL=[0-9]{8}(T[0-9]{6}Z)?)?$'
     and exists (
           select 1
           from public.rrule_parse(p_rrule) p
           where p.status = 'ok'
             and case when p_all_day then p.until_ts is null else p.until_date is null end
         );
$fn$;
revoke all on function public.rrule_is_writable(text, boolean) from public, anon, authenticated, service_role;

-- 2. The trigger function. SECURITY DEFINER so it can call the predicate and
--    rrule_parse, which no client role may execute; it reads nothing but NEW
--    and OLD.
create or replace function public.events_validate_rrule()
returns trigger
language plpgsql
security definer
set search_path = ''
as $fn$
begin
  if new.rrule is null then
    return new;
  end if;
  if tg_op = 'UPDATE'
     and new.rrule is not distinct from old.rrule
     and new.all_day is not distinct from old.all_day then
    return new;  -- an existing rule is not re-judged when it does not change
  end if;
  if not public.rrule_is_writable(new.rrule, new.all_day) then
    raise exception 'events.rrule is not a supported recurrence rule'
      using errcode = '23514',
            detail  = 'TIMEWEAVE_RRULE_INVALID',
            hint    = 'Save the series from the app, which writes only supported rules.';
  end if;
  return new;
end;
$fn$;
revoke all on function public.events_validate_rrule() from public, anon, authenticated, service_role;

drop trigger if exists events_validate_rrule on public.events;
create trigger events_validate_rrule
  before insert or update of rrule, all_day on public.events
  for each row execute function public.events_validate_rrule();

-- 3. Gate: what was just created is exactly what C1 calls 'applied' -- else
--    stop BEFORE the commit, and nothing of this file remains. In particular
--    the REVOKE above names four roles; a default privilege that granted
--    EXECUTE to any other role (or a role inheriting it) is caught here, not
--    after the commit.
do $gate$
declare v_events_owner oid := (select c.relowner from pg_catalog.pg_class c where c.oid = 'public.events'::regclass);
begin
  if (select t.tgenabled = 'O' and t.tgfoid = 'public.events_validate_rrule()'::regprocedure
             and t.tgtype = 23 and t.tgqual is null and t.tgconstraint = 0 and t.tgnargs = 0
             and (select pg_catalog.array_agg(a.attname::text order by a.attname) from pg_catalog.pg_attribute a
                  where a.attrelid = t.tgrelid and a.attnum = any (t.tgattr::int2[])) = array['all_day', 'rrule']
      from pg_catalog.pg_trigger t where t.tgrelid = 'public.events'::regclass and t.tgname = 'events_validate_rrule') is not true then
    raise exception '0029 gate: trigger events_validate_rrule is not as created';
  end if;
  if (select p.prosecdef and p.proconfig = array['search_path=""'] and p.proowner = v_events_owner
             and p.prolang = (select l.oid from pg_catalog.pg_language l where l.lanname = 'plpgsql')
             and pg_catalog.md5(pg_catalog.replace(p.prosrc, E'\r\n', E'\n')) = 'ee7cdb0e1367bbcefb5f8fa79c2844f8'
      from pg_catalog.pg_proc p where p.oid = 'public.events_validate_rrule()'::regprocedure) is not true
     or (select not p.prosecdef and p.provolatile = 's' and p.proconfig = array['search_path=""'] and p.proowner = v_events_owner
             and p.prolang = (select l.oid from pg_catalog.pg_language l where l.lanname = 'sql')
             and pg_catalog.md5(pg_catalog.replace(p.prosrc, E'\r\n', E'\n')) = '2483d8d235876a95210ce2ebfc27eb35'
      from pg_catalog.pg_proc p where p.oid = 'public.rrule_is_writable(text, boolean)'::regprocedure) is not true then
    raise exception '0029 gate: events_validate_rrule / rrule_is_writable are not as created';
  end if;
  -- the owner alone may execute either function (same test as C1)
  if exists (select 1 from pg_catalog.pg_proc p, pg_catalog.aclexplode(coalesce(p.proacl, pg_catalog.acldefault('f', p.proowner))) a
             where p.oid in ('public.events_validate_rrule()'::regprocedure, 'public.rrule_is_writable(text, boolean)'::regprocedure)
               and a.privilege_type = 'EXECUTE' and a.grantee <> p.proowner)
     or exists (select 1 from pg_catalog.pg_proc p, pg_catalog.pg_roles r
                where p.oid in ('public.events_validate_rrule()'::regprocedure, 'public.rrule_is_writable(text, boolean)'::regprocedure)
                  and not r.rolsuper and not pg_catalog.pg_has_role(r.oid, p.proowner, 'USAGE')
                  and pg_catalog.has_function_privilege(r.oid, p.oid, 'EXECUTE')) then
    raise exception '0029 gate: a role other than the owner can execute events_validate_rrule or rrule_is_writable';
  end if;
end
$gate$;

commit;
