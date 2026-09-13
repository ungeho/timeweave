-- ============================================================================
-- KEPT DELIBERATELY. Migration 0012 carries no advisory lock, and this file is
-- the only evidence for why that is safe. The claim is about PostgreSQL's
-- behaviour under concurrency, measured through the real PostgREST path, so it
-- is worth re-running after a major PostgreSQL upgrade or if anyone proposes
-- changing the upsert into a read-then-decide. Same standing as
-- 0011_enr_security_definer_probe.sql.
--
-- MEASURED PASS on production 2026-09-13, at probe parameters T = 60 s /
-- burst = 20 (chosen so token recovery cannot influence the result):
--   100 simultaneous REST inserts by one owner, 856 ms wall clock
--   HTTP 201 x 20, HTTP 429 x 80, no other status, no network error
--   every refusal: code PT429, details TIMEWEAVE_RATE_EVENTS
--   charged cost 20 = committed rows 20        (the lost-update detector)
--   debt exactly 1200 s = 20 x T               (no refused attempt left a charge)
--   overshoot of all 80 refusals within 0.372 s of each other, all under 60 s
--   GET on the state table -> 404 PGRST205     (invisible to PostgREST)
-- All probe objects dropped afterwards; leftover count verified 0.
--
-- ============================================================================
-- PROBE P3 (REST leg) -- is the GCRA upsert a HARD limit under real
-- concurrency, with NO advisory lock?
--
-- THE CLAIM UNDER TEST: the rate trigger needs no pg_advisory_xact_lock,
-- because `INSERT ... ON CONFLICT DO UPDATE ... RETURNING` takes the row lock
-- itself, re-evaluates its SET expression against the latest COMMITTED row, and
-- RETURNING hands back that post-update value. If that is wrong, two concurrent
-- writers for one owner both compute from the same stale tat, both commit, and
-- the limit is not hard -- the exact race 0011's advisory lock exists to kill.
--
-- A two-session psql rehearsal was the original plan. It is rejected: the
-- Supabase SQL editor cannot hold a transaction open between runs, psql is not
-- available, and dblink would need a connection string (a credential) plus an
-- extension install on production. This measures the same claim through the
-- path that will actually carry it -- PostgREST, its connection pool, READ
-- COMMITTED, 100 requests fired at once -- which is stronger evidence than a
-- hand-interleaved rehearsal, not weaker.
--
-- ############################################################################
-- PARAMETERS, AND WHY THEY ARE NOT THE PRODUCTION ONES
--
--   T   = 60 s   (emission interval)
--   tau = 20 * T = 1200 s   (burst allowance = 20 writes)
--
-- The production proposal is T = 1 s / burst = 120. Those numbers are WRONG FOR
-- THIS TEST: at T = 1 s, a run lasting a few seconds emits a few fresh tokens
-- while it is running, so "exactly 20 accepted" would be a time-dependent
-- expectation and a disagreement would prove nothing. At T = 60 s the next
-- token is 60 seconds away, so as long as the 100 requests finish within 60
-- seconds -- they take a few -- token recovery cannot contribute a single extra
-- acceptance. The concurrency question is then the only variable left.
--
-- VALIDITY CONDITION, stated in advance: the wall-clock duration of the 100
-- requests must be < 60 s. It is measured client-side and reported with the
-- results. If it is not met, the run is void, not a failure.
--
-- ############################################################################
-- PRE-REGISTERED EXPECTATIONS (fixed before the run, by agreement)
--
--   SQL side
--     R1  target rows                         = 20
--     R2  state rows                          = 1
--     R3  accepted_cost                       = 20
--     R4  target rows = accepted_cost         -> true
--     R5  tat - first_charge_at               = 1200 s exactly (= 20 * T)
--     R6  distinct owner in target            = 1, and equal to state.owner_id
--
--   Client side (reported by me)
--     C1  HTTP 201 responses                  = 20
--     C2  HTTP 429 responses                  = 80
--     C3  every 429 body                      code PT429, details
--                                             TIMEWEAVE_RATE_EVENTS
--     C4  wall-clock duration                 < 60 s  (validity condition)
--     C5  GET /rest/v1/rate_state             404 PGRST205 (state table is
--                                             invisible to PostgREST)
--
-- HOW TO READ A DISAGREEMENT
--   target > 20 AND accepted_cost < target -> LOST UPDATE. Two writers computed
--       from one tat. The upsert alone is not enough: adopt the advisory lock on
--       class 811003 and re-measure. This is the single outcome that changes the
--       migration.
--   target = accepted_cost = 21, duration >= 60 s -> token recovery, not a bug.
--       The run is void; re-run.
--   target < 20 -> over-rejection. The arithmetic or the clock is wrong, not the
--       locking.
--   R5 <> 1200 s with R3 = 20 -> a rejected attempt left debt behind, i.e. the
--       rollback did not take the increment with it. That would break the
--       "refused work is not charged" property.
--
-- ############################################################################
-- SCOPE AND SAFETY
--   * public.events is never named except in the cleanup proof, which only
--     READS pg_trigger.
--   * The GCRA state lives in its OWN schema (zz_probe_private), mirroring the
--     production decision to keep it out of `public` -- where default
--     privileges hand anon TRUNCATE, and TRUNCATE ignores RLS (measured, P8).
--     The schema is named zz_probe_% so the leftover sweep covers it, and it is
--     NOT the real timeweave_private: nothing here pre-creates migration state.
--   * NO advisory lock anywhere. That absence is the thing being tested.
--   * One owner: the logged-in user, via `default auth.uid()` and an RLS check,
--     exactly as public.events does it.
--   * Everything is named zz_probe_% and the cleanup proves 0 leftovers.
-- ############################################################################


-- ############################################################################
-- BLOCK 1 of 3 -- SETUP. Run once, tell me, then stop.
-- ############################################################################

begin;

-- ---------------------------------------------------------------- preflight
-- Same guard as P2: refuse to create anything if ANY zz_probe% object exists,
-- and say whether what was found came from THIS transaction (age 0 -> the
-- buffer is being executed twice, a client problem) or an earlier one
-- (age > 0 -> real leftovers, run cleanup first).
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
    from pg_policy pol where pol.polname like 'zz_probe%'
    union all
    select 'trigger', t.tgname::text, pg_catalog.age(t.xmin)
    from pg_trigger t where t.tgname like 'zz_probe%' and not t.tgisinternal
    union all
    select 'schema', n.nspname::text, pg_catalog.age(n.xmin)
    from pg_namespace n where n.nspname like 'zz_probe%'
  ) s;

  if v_n > 0 then
    raise exception
      'P3 preflight refused to run: % pre-existing zz_probe%% object(s) -> %',
      v_n, v_list
      using detail = case
              when v_same_txn > 0 then
                'At least one was created by THIS transaction (age 0): the buffer '
                'is being executed more than once inside one transaction. Nothing '
                'to clean up; run BLOCK 1 once, on its own.'
              else
                'All of them predate this transaction: real leftovers. Run BLOCK 3, '
                'confirm 0 leftovers, then re-run BLOCK 1.'
            end,
            hint = 'This run created nothing.';
  end if;
end;
$preflight$;

-- ---------------------------------------------------------------- state side
-- Its own schema, not public: this is the production shape, and the reason is
-- measured rather than stylistic (anon gets TRUNCATE on new public tables, and
-- TRUNCATE is not filtered by RLS).
create schema zz_probe_private;
revoke all on schema zz_probe_private from public, anon, authenticated, service_role;

create table zz_probe_private.rate_state (
  owner_id        uuid primary key,
  tat             timestamptz not null,   -- GCRA theoretical arrival time
  first_charge_at timestamptz not null,   -- set on the INSERT arm only
  accepted_cost   bigint      not null    -- rows actually charged (committed)
);

alter table zz_probe_private.rate_state enable row level security;  -- no policies
revoke all on table zz_probe_private.rate_state
  from public, anon, authenticated, service_role;

-- ---------------------------------------------------------------- target side
-- The stand-in for public.events: same owner mechanism, same RLS shape.
create table public.zz_probe_rate_target (
  id       bigserial primary key,
  owner_id uuid not null default auth.uid(),
  note     text
);

revoke all on table public.zz_probe_rate_target
  from public, anon, authenticated, service_role;
revoke all on sequence public.zz_probe_rate_target_id_seq
  from public, anon, authenticated, service_role;

-- ---------------------------------------------------------------- the trigger
-- The production shape, minus nothing except the parameters: AFTER STATEMENT,
-- SECURITY DEFINER, search_path = '', cost grouped by owner from new_rows, keys
-- taken in ascending order, and NO ADVISORY LOCK.
create or replace function public.zz_probe_rate_enforce()
returns trigger
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  c_t     constant interval    := interval '60 seconds';
  c_tau   constant interval    := 20 * interval '60 seconds';
  v_now   constant timestamptz := pg_catalog.statement_timestamp();
  r       record;
  v_tat   timestamptz;
begin
  -- Maintenance work is exempt. Measured in P2: inside a definer trigger during
  -- a real PostgREST request auth.uid() is the JWT subject, and it is NULL in
  -- the SQL editor -- current_user and session_user cannot tell the two apart.
  if auth.uid() is null then
    return null;
  end if;

  for r in
    select n.owner_id, pg_catalog.count(*)::int as cost
    from new_rows n
    group by n.owner_id
    order by n.owner_id
  loop
    insert into zz_probe_private.rate_state as w
      (owner_id, tat, first_charge_at, accepted_cost)
    values
      (r.owner_id, v_now + r.cost * c_t, v_now, r.cost)
    on conflict (owner_id) do update
      set tat           = greatest(w.tat, v_now) + r.cost * c_t,
          accepted_cost = w.accepted_cost + r.cost
    returning w.tat into v_tat;

    if v_tat - v_now > c_tau then
      raise exception
        'write rate exceeded: owner % is % ahead of its allowance',
        r.owner_id, (v_tat - v_now) - c_tau
        using errcode = 'PT429',
              detail  = 'TIMEWEAVE_RATE_EVENTS',
              hint    = 'retry_after_seconds='
                        || pg_catalog.ceil(
                             extract(epoch from ((v_tat - v_now) - c_tau)))::text;
    end if;
  end loop;

  return null;
end;
$fn$;

revoke execute on function public.zz_probe_rate_enforce() from public;

create trigger zz_probe_rate_ai
  after insert on public.zz_probe_rate_target
  referencing new table as new_rows
  for each statement
  execute function public.zz_probe_rate_enforce();

-- RLS exactly as public.events has it: own rows only, on both arms. The SELECT
-- policy is also what lets PostgREST's INSERT ... RETURNING work.
alter table public.zz_probe_rate_target enable row level security;
create policy zz_probe_rate_ins on public.zz_probe_rate_target
  for insert to authenticated with check (owner_id = auth.uid());
create policy zz_probe_rate_sel on public.zz_probe_rate_target
  for select to authenticated using (owner_id = auth.uid());

grant insert, select on table public.zz_probe_rate_target to authenticated;
grant usage, select on sequence public.zz_probe_rate_target_id_seq to authenticated;

notify pgrst, 'reload schema';

commit;

-- ---------------------------------------------------------------- setup report
-- Part 1: every privilege any non-owner holds on any zz_probe% object, in any
-- schema. EXPECTED, exactly four rows:
--   zz_probe_rate_target        | authenticated | INSERT
--   zz_probe_rate_target        | authenticated | SELECT
--   zz_probe_rate_target_id_seq | authenticated | SELECT
--   zz_probe_rate_target_id_seq | authenticated | USAGE
-- Nothing on zz_probe_private.rate_state, and nothing for anon / service_role /
-- PUBLIC anywhere. This is also the first measurement of whether this project's
-- default privileges reach into a NEWLY CREATED schema -- the real migration
-- depends on the answer being "no".
select n.nspname::text || '.' || c.relname::text        as object,
       case when a.grantee = 0 then 'PUBLIC'
            else pg_catalog.pg_get_userbyid(a.grantee) end as grantee,
       a.privilege_type
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
cross join lateral aclexplode(c.relacl) a
where (c.relname like 'zz_probe%' or n.nspname like 'zz_probe%')
  and a.grantee <> c.relowner
order by 1, 2, 3;

-- Part 2: the same conditions as pass/fail, plus the two that matter most for
-- this probe: no advisory lock in the function body, and the state table
-- unreachable by anyone but its owner.
with rel as (
  select c.oid, n.nspname::text as nsp, c.relname::text as relname, c.relowner, c.relacl
  from pg_class c join pg_namespace n on n.oid = c.relnamespace
  where c.relname like 'zz_probe%' or n.nspname like 'zz_probe%'
),
grants as (
  select r.nsp, r.relname,
         case when a.grantee = 0 then 'PUBLIC'
              else pg_catalog.pg_get_userbyid(a.grantee) end as grantee,
         a.privilege_type
  from rel r cross join lateral aclexplode(r.relacl) a
  where a.grantee <> r.relowner
),
fn as (
  select p.proname::text as proname, p.proacl,
         pg_catalog.pg_get_functiondef(p.oid) as src,
         (p.proacl is null
          or exists (select 1 from aclexplode(p.proacl) x where x.grantee = 0)) as public_can_execute
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname like 'zz_probe%'
)
select ord, name, got, want,
       case when got is not distinct from want then 'ok' else 'FAIL' end as verdict
from (
  select 1 as ord, 'anon holds nothing on any probe object' as name,
         (select count(*)::text from grants where grantee = 'anon') as got, '0' as want
  union all
  select 2, 'service_role holds nothing on any probe object',
         (select count(*)::text from grants where grantee = 'service_role'), '0'
  union all
  select 3, 'PUBLIC holds nothing on any probe object',
         (select count(*)::text from grants where grantee = 'PUBLIC'), '0'
  union all
  select 4, 'authenticated on target table',
         coalesce((select string_agg(privilege_type, ',' order by privilege_type) from grants
                    where grantee = 'authenticated' and relname = 'zz_probe_rate_target'), '<none>'),
         'INSERT,SELECT'
  union all
  select 5, 'authenticated on target sequence',
         coalesce((select string_agg(privilege_type, ',' order by privilege_type) from grants
                    where grantee = 'authenticated' and relname = 'zz_probe_rate_target_id_seq'), '<none>'),
         'SELECT,USAGE'
  union all
  select 6, 'anyone other than the owner on the state table',
         (select count(*)::text from grants where nsp = 'zz_probe_private'), '0'
  union all
  select 7, 'trigger function executable by PUBLIC',
         (select bool_or(public_can_execute)::text from fn), 'false'
  union all
  select 8, 'trigger function contains an advisory lock',
         (select bool_or(src ilike '%advisory%')::text from fn), 'false'
  union all
  select 9, 'state table starts empty',
         (select count(*)::text from zz_probe_private.rate_state), '0'
  union all
  select 10, 'target table starts empty',
         (select count(*)::text from public.zz_probe_rate_target), '0'
) s
order by ord;


-- ############################################################################
-- BLOCK 2 of 3 -- READOUT. Run AFTER I have fired the 100 requests.
-- Every expectation below was fixed before the run.
-- ############################################################################
/*
-- Raw state, for the record. debt_seconds is the number the assertion actually
-- compares; debt_span is kept beside it only because it is easier to read.
select owner_id, tat, first_charge_at, accepted_cost,
       tat - first_charge_at                        as debt_span,
       extract(epoch from (tat - first_charge_at))  as debt_seconds
from zz_probe_private.rate_state;

-- The assertions.
--
-- NOTE ON uuid: PostgreSQL has no min(uuid) / max(uuid) aggregate (uuid has the
-- btree and hash support that DISTINCT and ORDER BY need, but not those two
-- aggregates). So the single state row is picked with ORDER BY ... LIMIT 1
-- instead of aggregated, and the owner comparison is expressed as "no target
-- row has an owner other than the state row's" -- same claim as R7 before, with
-- no aggregate over a uuid anywhere. R1-R7 keep their meaning and their
-- pre-registered expectations unchanged.
with t as (
  select count(*)::bigint             as target_rows,
         count(distinct owner_id)::bigint as target_owners
  from public.zz_probe_rate_target
),
s as (
  select count(*)::bigint as state_rows
  from zz_probe_private.rate_state
),
s1 as (
  select owner_id,
         accepted_cost,
         tat - first_charge_at as debt_span
  from zz_probe_private.rate_state
  order by owner_id
  limit 1
),
own as (
  select exists (select 1 from s1)
         and not exists (
           select 1
           from public.zz_probe_rate_target g
           where not exists (select 1 from s1 where s1.owner_id = g.owner_id)
         ) as target_owner_matches_state
)
select ord, name, got, want,
       case when got is not distinct from want then 'ok' else 'FAIL' end as verdict
from (
  select 1 as ord, 'R1 target rows' as name,
         (select target_rows::text from t) as got, '20' as want
  union all
  select 2, 'R2 state rows', (select state_rows::text from s), '1'
  union all
  select 3, 'R3 accepted_cost', (select accepted_cost::text from s1), '20'
  union all
  select 4, 'R4 target rows = accepted_cost (lost update detector)',
         (select (t.target_rows = s1.accepted_cost)::text from t, s1), 'true'
  union all
  -- Compared in SECONDS, not as an interval literal. The first version of this
  -- assertion compared against '20:00:00' -- twenty HOURS, sixty times the
  -- intended 1200 s. The header pre-registered the right number (1200 s = 20 x
  -- T); only this literal was wrong, and the measurement that "failed" it was
  -- in fact the expected 00:20:00. Comparing epoch seconds removes both the
  -- unit slip and any dependence on how an interval is rendered.
  select 5, 'R5 debt_span = 1200 s = 20 x T (no debt from rejected attempts)',
         (select (extract(epoch from s1.debt_span) = 1200)::text from s1), 'true'
  union all
  select 6, 'R6 distinct owners in target', (select target_owners::text from t), '1'
  union all
  select 7, 'R7 target owner = state owner',
         (select target_owner_matches_state::text from own), 'true'
) x
order by ord;
*/


-- ############################################################################
-- BLOCK 3 of 3 -- CLEANUP. Run immediately after the readout.
-- Idempotent: safe to run twice, and safe after a partially-applied setup.
-- ############################################################################
/*
drop trigger if exists zz_probe_rate_ai on public.zz_probe_rate_target;
drop table if exists public.zz_probe_rate_target;      -- takes its sequence
                                                        -- and both policies
drop function if exists public.zz_probe_rate_enforce();
drop schema if exists zz_probe_private cascade;        -- takes the state table

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
