-- ============================================================================
-- KEPT DELIBERATELY. What auth.uid(), current_user and session_user return
-- inside a trigger during a real request is Supabase's and PostgREST's
-- implementation detail, not TimeWeave's. Migration 0012 exempts maintenance
-- work on exactly that answer -- get it wrong and either every migration burns
-- an account's budget, or every end user is exempt. Re-run after a platform
-- upgrade, or whenever the exemption predicate is touched. Same standing as
-- 0011_enr_security_definer_probe.sql.
--
-- MEASURED PASS on production 2026-09-13, one real authenticated REST insert:
--   auth.uid()      = the JWT subject
--   current_user    = postgres        (the function owner -- SECURITY DEFINER)
--   session_user    = authenticator   (NOT `authenticated`)
--   new_rows count  = 1               (transition tables work in a real request)
--   transaction_timestamp .487264 < statement_timestamp .493064 < clock .503617
--     -> now() is ~6 ms stale in the simplest possible request. The
--        pre-registered expectation "stmt = txn" was WRONG, not the measurement:
--        PostgREST opens the transaction and then runs the statement. This is
--        why 0012 uses statement_timestamp().
-- All probe objects dropped afterwards; leftover count verified 0.
--
-- ============================================================================
-- PROBE P2 (REST leg) -- what identity does an AFTER STATEMENT, SECURITY
-- DEFINER trigger see during a REAL PostgREST request?
--
-- THE DECISION THIS FEEDS: the rate trigger must exempt maintenance work and
-- enforce on end-user requests. The proposed predicate is
--
--     if auth.uid() is null then return null; end if;
--
-- The SQL-editor simulation (tmp_probe_p2_jwt_context.sql, sections 1-2) can
-- show that auth.uid() is null with no JWT and returns the sub when the claims
-- GUC is set by hand. It CANNOT show what PostgREST itself sets, because under
-- PostgREST the connection role is `authenticator`, the request role is set per
-- request, and the claims GUC is written by PostgREST. That is what this file
-- measures, and it is the only reason it commits.
--
-- WHAT IT RECORDS, per real request:
--   auth.uid()                  -- the predicate under test
--   current_user                -- expected: the function OWNER (definer)
--   session_user                -- expected: authenticator (NOT authenticated)
--   request.jwt.claims          -- what PostgREST actually set
--   count(*) from new_rows      -- transition tables work in a real request
--   statement_timestamp() / transaction_timestamp() / clock_timestamp()
--                               -- the clock choice, measured in the real
--                                  context rather than in the editor (P4)
--
-- ############################################################################
-- SCOPE AND SAFETY
--
--   * public.events is NEVER named in this file except in the cleanup proof,
--     which only READS pg_trigger.
--   * auth.users is never written. The probe reads the caller's own JWT subject
--     out of the request context; it does not touch the auth schema at all.
--   * Two probe tables, one trigger function, one trigger. Everything is named
--     zz_probe_% and the cleanup proves 0 leftovers across EVERY schema.
--   * The recording table gets NO grants to anon or authenticated: only the
--     SECURITY DEFINER trigger writes it, and only the SQL editor reads it.
--     This mirrors the real design, where the state table is reachable by the
--     trigger alone.
--   * Default privileges on this project hand anon TRUNCATE/REFERENCES/TRIGGER/
--     MAINTAIN on any new table in public (measured 2026-09-13, P8). BOTH
--     tables and BOTH sequences revoke that, from PUBLIC / anon / authenticated
--     / service_role, before anything is granted back. The target table then
--     gets exactly INSERT + SELECT for authenticated, and its sequence USAGE +
--     SELECT; nothing else is granted anywhere. The setup report asserts this
--     rather than printing an aclitem string to be read by eye.
-- ############################################################################


-- ############################################################################
-- BLOCK 1 of 3 -- SETUP. Run once, tell me, then stop.
-- ############################################################################

begin;

-- ---------------------------------------------------------------- preflight
-- Refuse to create anything if ANY zz_probe% object already exists.
--
-- WHY THIS EXISTS: a first attempt at this setup stopped with
--   42710 policy "zz_probe_identity_ins" for table "zz_probe_identity" already exists
-- while the file contains that statement exactly once, and a read-only sweep
-- afterwards found no zz_probe% objects at all. Those two facts together mean
-- the transaction was rolled back -- so the policy that "already existed" must
-- have existed WITHIN that same execution.
--
-- This preflight tells the two candidate explanations apart instead of leaving
-- it to inference. Every catalogue row carries xmin, and age(xmin) = 0 means
-- "created by the transaction that is asking":
--
--   age 0      -> the buffer is being executed more than once inside one
--                 transaction. A client/editor problem. Nothing to clean up.
--   age > 0    -> genuine leftovers from an earlier transaction. Run cleanup.
--
-- Either way it raises BEFORE creating anything, so a failed run cannot be the
-- thing that leaves a mess behind.
do $preflight$
declare
  v_list     text;
  v_n        int;
  v_same_txn int;
begin
  select string_agg(s.kind || ' ' || s.nm || ' [age ' || s.a::text || ']', ', ' order by s.nm),
         count(*),
         count(*) filter (where s.a = 0)
    into v_list, v_n, v_same_txn
  from (
    select 'relation' as kind, c.relname::text as nm, pg_catalog.age(c.xmin) as a
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where c.relname like 'zz_probe%' or n.nspname like 'zz_probe%'
    union all
    select 'function', p.proname::text, pg_catalog.age(p.xmin)
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where p.proname like 'zz_probe%' or n.nspname like 'zz_probe%'
    union all
    select 'policy', pol.polname::text, pg_catalog.age(pol.xmin)
    from pg_policy pol
    where pol.polname like 'zz_probe%'
    union all
    select 'trigger', t.tgname::text, pg_catalog.age(t.xmin)
    from pg_trigger t
    where t.tgname like 'zz_probe%' and not t.tgisinternal
    union all
    select 'schema', n.nspname::text, pg_catalog.age(n.xmin)
    from pg_namespace n
    where n.nspname like 'zz_probe%'
  ) s;

  if v_n > 0 then
    raise exception
      'P2 preflight refused to run: % pre-existing zz_probe%% object(s) -> %',
      v_n, v_list
      using detail = case
              when v_same_txn > 0 then
                'At least one of them was created by THIS transaction (age 0). '
                'The statement buffer is being executed more than once inside a '
                'single transaction -- a client problem, not a leftover. Nothing '
                'to clean up; re-run BLOCK 1 once, on its own.'
              else
                'All of them predate this transaction. These are real leftovers: '
                'run BLOCK 3 (cleanup), confirm 0 leftovers, then re-run BLOCK 1.'
            end,
            hint = 'This run created nothing.';
  end if;
end;
$preflight$;

-- ---------------------------------------------------------------- objects
-- The insert target. Reachable over REST; holds nothing of interest.
create table public.zz_probe_identity (
  id   bigserial primary key,
  note text
);

-- Default privileges on this project hand anon / authenticated / service_role a
-- set of rights on ANY new table in public -- measured 2026-09-13 (P8):
-- anon=Dxtm, i.e. TRUNCATE, REFERENCES, TRIGGER, MAINTAIN. None of that is
-- wanted here, and TRUNCATE in particular is not stopped by RLS. So: strip
-- everything first, then grant back only what the REST call needs. PUBLIC is in
-- the revoke list too -- it holds nothing today, and that is worth keeping true
-- by statement rather than by assumption.
revoke all on table public.zz_probe_identity
  from public, anon, authenticated, service_role;
revoke all on sequence public.zz_probe_identity_id_seq
  from public, anon, authenticated, service_role;

-- The recording table. NOT reachable over REST: no grants, RLS on, no policies.
create table public.zz_probe_identity_seen (
  id              bigserial primary key,
  seen_at         timestamptz not null default clock_timestamp(),
  auth_uid        text,
  current_user_   text,
  session_user_   text,
  jwt_claims      text,
  new_rows_count  int,
  ts_statement    timestamptz,
  ts_transaction  timestamptz,
  ts_clock        timestamptz
);

alter table public.zz_probe_identity_seen enable row level security;
revoke all on table public.zz_probe_identity_seen
  from public, anon, authenticated, service_role;
revoke all on sequence public.zz_probe_identity_seen_id_seq
  from public, anon, authenticated, service_role;

create or replace function public.zz_probe_identity_rec()
returns trigger
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_uid  text;
  v_n    int;
begin
  -- auth.uid() is the predicate under test, so a raise must be recorded rather
  -- than allowed to break the request: that outcome is a result, not an error.
  begin
    v_uid := coalesce(auth.uid()::text, '<null>');
  exception when others then
    v_uid := '<raised ' || sqlstate || '>';
  end;

  select pg_catalog.count(*) into v_n from new_rows;

  insert into public.zz_probe_identity_seen (
    auth_uid, current_user_, session_user_, jwt_claims,
    new_rows_count, ts_statement, ts_transaction, ts_clock)
  values (
    v_uid,
    current_user::text,
    session_user::text,
    coalesce(pg_catalog.current_setting('request.jwt.claims', true), '<unset>'),
    v_n,
    pg_catalog.statement_timestamp(),
    pg_catalog.transaction_timestamp(),
    pg_catalog.clock_timestamp());

  return null;
end;
$fn$;

revoke execute on function public.zz_probe_identity_rec() from public;

create trigger zz_probe_identity_ai
  after insert on public.zz_probe_identity
  referencing new table as new_rows
  for each statement
  execute function public.zz_probe_identity_rec();

-- The target must accept an INSERT from `authenticated`, and PostgREST issues
-- INSERT ... RETURNING, so a SELECT policy is required as well -- without it the
-- statement fails for a reason that has nothing to do with what is being asked.
alter table public.zz_probe_identity enable row level security;
create policy zz_probe_identity_ins on public.zz_probe_identity
  for insert to authenticated with check (true);
create policy zz_probe_identity_sel on public.zz_probe_identity
  for select to authenticated using (true);

grant insert, select on table public.zz_probe_identity to authenticated;
grant usage, select on sequence public.zz_probe_identity_id_seq to authenticated;

notify pgrst, 'reload schema';

commit;

-- Everything above is one transaction: either the whole setup exists or none of
-- it does. "Partially applied setup" is now impossible by construction rather
-- than by trusting the editor to wrap the buffer.

-- ---------------------------------------------------------------- setup report
-- Part 1: EXHAUSTIVE listing of every privilege any non-owner holds on any
-- zz_probe% object. Not a check of three named roles -- if default privileges
-- hand something to a role nobody thought about, it appears here.
--
-- EXPECTED, exactly four rows and no others:
--   zz_probe_identity          | authenticated | INSERT
--   zz_probe_identity          | authenticated | SELECT
--   zz_probe_identity_id_seq   | authenticated | SELECT
--   zz_probe_identity_id_seq   | authenticated | USAGE
select c.relname::text                                as object,
       case when a.grantee = 0 then 'PUBLIC'
            else pg_catalog.pg_get_userbyid(a.grantee) end as grantee,
       a.privilege_type
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
cross join lateral aclexplode(c.relacl) a
where n.nspname = 'public'
  and c.relname like 'zz_probe%'
  and a.grantee <> c.relowner
order by 1, 2, 3;

-- Part 2: the same four conditions as pass/fail, so nothing has to be read out
-- of an aclitem string by eye.
--
-- Note on the function check: an ACL of NULL means "never touched", and an
-- untouched function is EXECUTABLE BY PUBLIC. So "no PUBLIC row" is only a pass
-- when the ACL is explicit -- both halves are asserted.
with rel as (
  select c.oid, c.relname::text as relname, c.relowner, c.relacl
  from pg_class c join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public' and c.relname like 'zz_probe%'
),
grants as (
  select r.relname,
         case when a.grantee = 0 then 'PUBLIC'
              else pg_catalog.pg_get_userbyid(a.grantee) end as grantee,
         a.privilege_type
  from rel r cross join lateral aclexplode(r.relacl) a
  where a.grantee <> r.relowner
),
fn as (
  select p.proname::text as proname, p.proacl,
         (p.proacl is null
          or exists (select 1 from aclexplode(p.proacl) x where x.grantee = 0)) as public_can_execute
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname like 'zz_probe%'
)
select ord, name, got, want,
       case when got is not distinct from want then 'ok' else 'FAIL' end as verdict
from (
  select 1 as ord,
         'anon holds nothing on any probe object' as name,
         (select count(*)::text from grants where grantee = 'anon') as got,
         '0' as want
  union all
  select 2, 'service_role holds nothing on any probe object',
         (select count(*)::text from grants where grantee = 'service_role'), '0'
  union all
  select 3, 'PUBLIC holds nothing on any probe object',
         (select count(*)::text from grants where grantee = 'PUBLIC'), '0'
  union all
  select 4, 'authenticated on target table',
         coalesce((select string_agg(privilege_type, ',' order by privilege_type)
                     from grants
                    where grantee = 'authenticated' and relname = 'zz_probe_identity'), '<none>'),
         'INSERT,SELECT'
  union all
  select 5, 'authenticated on target sequence',
         coalesce((select string_agg(privilege_type, ',' order by privilege_type)
                     from grants
                    where grantee = 'authenticated' and relname = 'zz_probe_identity_id_seq'), '<none>'),
         'SELECT,USAGE'
  union all
  select 6, 'anyone other than the owner on the seen table or its sequence',
         (select count(*)::text from grants where relname like 'zz_probe_identity_seen%'), '0'
  union all
  select 7, 'trigger function executable by PUBLIC',
         (select bool_or(public_can_execute)::text from fn), 'false'
) s
order by ord;


-- ############################################################################
-- BLOCK 2 of 3 -- READOUT. Run AFTER I have made the REST call.
-- ############################################################################
/*
select id,
       auth_uid,
       current_user_,
       session_user_,
       new_rows_count,
       left(jwt_claims, 200) as jwt_claims_head
from public.zz_probe_identity_seen
order by id;

-- The clock question, in the real request context (P4). statement_timestamp
-- and transaction_timestamp are expected to be equal for a single-statement
-- PostgREST request; clock_timestamp is expected to be >= both.
select id,
       ts_statement,
       ts_transaction,
       ts_clock,
       (ts_statement = ts_transaction)   as stmt_eq_txn,
       (ts_clock >= ts_statement)        as clock_ge_stmt
from public.zz_probe_identity_seen
order by id;

-- How many rows actually landed in the target (expected: one per REST call).
select count(*) as target_rows from public.zz_probe_identity;
*/


-- ############################################################################
-- BLOCK 3 of 3 -- CLEANUP. Run immediately after the readout.
-- Idempotent: safe to run twice, and safe after a partially-applied setup.
-- ############################################################################
/*
drop trigger if exists zz_probe_identity_ai on public.zz_probe_identity;
drop table if exists public.zz_probe_identity;          -- takes its sequence
                                                         -- and both policies
drop table if exists public.zz_probe_identity_seen;      -- takes its sequence
drop function if exists public.zz_probe_identity_rec();

notify pgrst, 'reload schema';

-- Leftover proof. All five counts must be 0, across EVERY schema.
select 'functions' as kind, count(*) as leftover
from pg_proc p where p.proname like 'zz_probe%'
union all
select 'relations', count(*)
from pg_class c where c.relname like 'zz_probe%'
union all
select 'policies', count(*)
from pg_policy pol where pol.polname like 'zz_probe%'
union all
select 'triggers', count(*)
from pg_trigger t where t.tgname like 'zz_probe%' and not t.tgisinternal
union all
select 'schemas', count(*)
from pg_namespace n where n.nspname like 'zz_probe%'
order by 1;

-- public.events, untouched: exactly the six triggers 0001 / 0008 / 0011 left.
select t.tgname
from pg_trigger t
where t.tgrelid = 'public.events'::regclass and not t.tgisinternal
order by t.tgname;
*/
