-- ============================================================================
-- KEPT DELIBERATELY. This is a question about the SERVER -- PostgREST's error
-- mapping -- not about TimeWeave's data, and the answer can change under a
-- PostgREST or Supabase platform upgrade. Migration 0012's entire error contract
-- (PT429 -> HTTP 429, DETAIL as the client's discriminator, the backoff in HINT
-- because no header survives) rests on what this file measured. Re-run it before
-- trusting that contract again after any platform upgrade. Same standing as
-- 0011_enr_security_definer_probe.sql.
--
-- MEASURED PASS on production 2026-09-13:
--   80  PT429                 -> HTTP 429
--   81  DETAIL                -> `details`, verbatim
--   82  response.headers      -> does NOT survive the RAISE (no Retry-After)
--   83  response.status       -> does NOT override the SQLSTATE mapping
--   84  raise from a TRIGGER  -> identical to raise from an RPC
--   control: 23514            -> HTTP 400
-- All probe objects dropped afterwards; leftover count verified 0.
--
-- ============================================================================
-- PROBE P8 -- how does PostgREST turn a raised error into an HTTP response, and
-- can a rate-limit rejection be an HTTP 429?
--
-- ALREADY MEASURED, 2026-09-13, against PRODUCTION over the real REST endpoint
-- with a real user JWT. No rows were written: both payloads carried a 300-char
-- title, which the 0011 content CHECK refuses, so neither statement could
-- commit whatever else happened.
--
--   A) BEFORE ROW trigger raise (0008 TIMEWEAVE_TZ_REQUIRED, errcode 23514)
--      -> HTTP 400
--      -> {"code":"23514",
--          "details":"TIMEWEAVE_TZ_REQUIRED",
--          "hint":"Set events.timezone when creating a timed recurrence, ...",
--          "message":"a timed recurring event must carry an IANA time zone"}
--
--   B) plain CHECK constraint violation (events_title_len, errcode 23514)
--      -> HTTP 400
--      -> {"code":"23514","details":null,"hint":null,
--          "message":"new row for relation \"events\" violates check
--                     constraint \"events_title_len\""}
--
-- So the existing contract is confirmed end to end: DETAIL passes through
-- verbatim as `details`, HINT passes through as `hint`, and 23514 is HTTP 400.
-- A 23514 rate rejection would therefore work -- and would be a 400, which is
-- the wrong thing to tell a client that should back off.
--
-- WHAT IS STILL UNMEASURED, and is all this file exists for:
--   80  does errcode 'PT429' produce HTTP 429 on this PostgREST?
--   81  does DETAIL still pass through unchanged on the PT429 path?
--   82  does set_config('response.headers', ...) survive a RAISE, so a real
--       Retry-After header can be sent?
--   83  does set_config('response.status', ...) override the mapping?
--   84  do 80-83 behave the same when the raise comes from an AFTER STATEMENT
--       TRIGGER rather than from an RPC -- which is where the real one lives.
--
-- ############################################################################
-- THIS FILE COMMITS. It cannot be rolled back, because PostgREST has to be able
-- to SEE the objects. Every object it creates is named zz_probe_%, nothing it
-- creates outlives the CLEANUP block, and public.events is never named in this
-- file at all -- grep it: the string "events" appears only in these comments
-- and in the token TIMEWEAVE_RATE_EVENTS.
-- ############################################################################

-- ############################################################################
-- SETUP BLOCK -- run this once, then make the REST calls, then run CLEANUP.
-- ############################################################################

-- Four RPCs. Each one only raises; none of them reads or writes any table.
-- SECURITY INVOKER, so they carry no privilege of their own.
create or replace function public.zz_probe_pt429()
returns void language plpgsql security invoker set search_path = '' as $fn$
begin
  raise exception 'write rate exceeded: probe'
    using errcode = 'PT429',
          detail  = 'TIMEWEAVE_RATE_EVENTS',
          hint    = 'retry_after_seconds=7';
end;
$fn$;

create or replace function public.zz_probe_23514()
returns void language plpgsql security invoker set search_path = '' as $fn$
begin
  raise exception 'write rate exceeded: probe'
    using errcode = '23514',
          detail  = 'TIMEWEAVE_RATE_EVENTS',
          hint    = 'retry_after_seconds=7';
end;
$fn$;

-- Does a header set before the raise survive the aborted transaction?
create or replace function public.zz_probe_pt429_hdr()
returns void language plpgsql security invoker set search_path = '' as $fn$
begin
  perform pg_catalog.set_config('response.headers',
                                '[{"Retry-After": "7"}]', true);
  raise exception 'write rate exceeded: probe'
    using errcode = 'PT429',
          detail  = 'TIMEWEAVE_RATE_EVENTS',
          hint    = 'retry_after_seconds=7';
end;
$fn$;

-- Does response.status override the SQLSTATE mapping on the error path?
create or replace function public.zz_probe_status_override()
returns void language plpgsql security invoker set search_path = '' as $fn$
begin
  perform pg_catalog.set_config('response.status', '429', true);
  raise exception 'write rate exceeded: probe'
    using errcode = '23514',
          detail  = 'TIMEWEAVE_RATE_EVENTS',
          hint    = 'retry_after_seconds=7';
end;
$fn$;

-- CREATE FUNCTION grants EXECUTE to PUBLIC by default, which would expose these
-- to `anon` as well. They only raise, so the exposure is harmless -- but 0011's
-- rule is that nothing is reachable by accident, so revoke first, grant second.
revoke execute on function public.zz_probe_pt429()           from public;
revoke execute on function public.zz_probe_23514()           from public;
revoke execute on function public.zz_probe_pt429_hdr()       from public;
revoke execute on function public.zz_probe_status_override() from public;

grant execute on function public.zz_probe_pt429()            to authenticated;
grant execute on function public.zz_probe_23514()            to authenticated;
grant execute on function public.zz_probe_pt429_hdr()        to authenticated;
grant execute on function public.zz_probe_status_override()  to authenticated;

-- 84: the same raise, but from an AFTER STATEMENT trigger on a table of its
-- own. SECURITY DEFINER, matching the shape the real rate trigger will have.
--
-- THE TABLE CAN NEVER HOLD A ROW: its AFTER STATEMENT trigger raises
-- unconditionally, so every INSERT into it aborts. It exists only to be a
-- statement that fails.
create table public.zz_probe_hits (id bigserial primary key, note text);

create or replace function public.zz_probe_trigger_pt429()
returns trigger language plpgsql security definer set search_path = '' as $fn$
begin
  perform pg_catalog.set_config('response.headers', '[{"Retry-After": "7"}]', true);
  raise exception 'write rate exceeded: probe (trigger)'
    using errcode = 'PT429',
          detail  = 'TIMEWEAVE_RATE_EVENTS',
          hint    = 'retry_after_seconds=7';
end;
$fn$;

-- A function returning `trigger` cannot be called directly and PostgREST does
-- not expose one, so this revoke changes nothing today. It is here because
-- "nothing is reachable by accident" should not have an exception in it.
revoke execute on function public.zz_probe_trigger_pt429() from public;

create trigger zz_probe_hits_ai after insert on public.zz_probe_hits
  referencing new table as new_rows for each statement
  execute function public.zz_probe_trigger_pt429();

-- RLS on from the start, with exactly the two policies the probe needs. The
-- SELECT policy is not optional plumbing: PostgREST issues INSERT ... RETURNING,
-- and with RLS on and no SELECT policy the statement fails for a reason that has
-- nothing to do with what check 84 is asking.
alter table public.zz_probe_hits enable row level security;
create policy zz_probe_hits_ins on public.zz_probe_hits
  for insert to authenticated with check (true);
create policy zz_probe_hits_sel on public.zz_probe_hits
  for select to authenticated using (true);

grant insert, select on table public.zz_probe_hits to authenticated;
grant usage, select on sequence public.zz_probe_hits_id_seq to authenticated;

notify pgrst, 'reload schema';

-- ---------------------------------------------------------------- setup report
-- What now exists, and who can reach it. Read this before making any REST call:
-- anon must appear NOWHERE in the acl column.
select 'function' as kind,
       p.proname::text as name,
       pg_catalog.array_to_string(p.proacl, ' | ') as acl
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname like 'zz_probe%'
union all
select 'table',
       c.relname::text,
       pg_catalog.array_to_string(c.relacl, ' | ')
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public' and c.relname like 'zz_probe%'
union all
select 'policy',
       pol.polname::text,
       pg_catalog.pg_get_expr(pol.polqual, pol.polrelid)
from pg_policy pol
join pg_class c on c.oid = pol.polrelid
where c.relname like 'zz_probe%'
order by 1, 2;


-- ############################################################################
-- THE MEASUREMENT. Run these with a REAL user JWT (the app's session, or curl).
-- Record: HTTP status, the Retry-After response header, and the JSON body.
--
--   POST /rest/v1/rpc/zz_probe_pt429              -- check 80, 81
--   POST /rest/v1/rpc/zz_probe_23514              -- control, expect 400
--   POST /rest/v1/rpc/zz_probe_pt429_hdr          -- check 82
--   POST /rest/v1/rpc/zz_probe_status_override    -- check 83
--   POST /rest/v1/zz_probe_hits   {"note":"x"}    -- check 84
--
-- headers: apikey: <publishable key>
--          Authorization: Bearer <user access token>
--          Content-Type: application/json
--
-- PASS for 80 = HTTP 429 with body.details = 'TIMEWEAVE_RATE_EVENTS'.
-- If 80 FAILS (PostgREST does not honour PTxxx here), the design falls back to
-- errcode 23514 -- already proven to work end to end, at the cost of an HTTP
-- 400 for something that is not the client's data being wrong. In that case the
-- token in `details` stays the only contract and the edge layer, not the DB, is
-- what can return a true 429.
-- ############################################################################


-- ############################################################################
-- CLEANUP BLOCK -- run this immediately after the measurement.
-- Every statement is idempotent, so it is safe to run twice, and safe to run
-- after a partially-applied setup.
-- ############################################################################
drop trigger if exists zz_probe_hits_ai on public.zz_probe_hits;
drop table if exists public.zz_probe_hits;          -- takes its sequence and
                                                    -- both policies with it
drop function if exists public.zz_probe_trigger_pt429();
drop function if exists public.zz_probe_pt429();
drop function if exists public.zz_probe_23514();
drop function if exists public.zz_probe_pt429_hdr();
drop function if exists public.zz_probe_status_override();

notify pgrst, 'reload schema';

-- ---------------------------------------------------------------- proof
-- All four counts must be 0. This looks in EVERY schema, not just public, so a
-- mistyped schema qualifier in the setup cannot hide a leftover.
select 'functions' as kind, count(*) as leftover
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where p.proname like 'zz_probe%'
union all
select 'tables/sequences', count(*)
from pg_class c join pg_namespace n on n.oid = c.relnamespace
where c.relname like 'zz_probe%'
union all
select 'policies', count(*)
from pg_policy pol where pol.polname like 'zz_probe%'
union all
select 'triggers', count(*)
from pg_trigger t where t.tgname like 'zz_probe%' and not t.tgisinternal
order by 1;

-- ---------------------------------------------------------------- events, untouched
-- This probe never names public.events. Confirm it anyway -- the trigger list
-- and the grants must be exactly what 0001 / 0008 / 0011 left behind:
-- 6 triggers (set_updated_at, validate_timezone, 4 quota) and no zz_probe%.
select t.tgname
from pg_trigger t
where t.tgrelid = 'public.events'::regclass and not t.tgisinternal
order by t.tgname;
