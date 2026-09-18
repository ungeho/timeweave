-- ============================================================================
-- TimeWeave Phase 6-x (M-D): share-link quotas and a create-rate limit.
--
-- WHAT THIS IS. Two ceilings on the STOCK of share links an owner may hold and
-- one limit on the FLOW at which they may be created -- the share_links
-- counterpart of what 0011 and 0012 did for public.events:
--
--   active links  <= 25  per owner    (share_links_max_active_per_owner)
--   total rows    <= 200 per owner    (share_links_max_total_per_owner)
--   creates       sustained 1 per minute, burst 5, per owner (GCRA)
--
-- All three are enforced by statement-level AFTER triggers on
-- public.share_links, so they bind EVERY writer: create_share_link today, and
-- any future RPC, script or migration. create_share_link itself (0005) is not
-- touched -- the token-generation path stays exactly as it was.
--
-- WHAT THIS IS NOT. No change to revoke_share_link, delete_share_link (0015),
-- get_free_busy, the table's privileges, its RLS policy, its CHECKs (0014) or
-- its indexes. No DELETE trigger, no rate charge on UPDATE. Nothing touches
-- public.events or timeweave_private.event_write_rate. No new advisory-lock
-- class. The TRUNCATE privilege service_role holds on share_links is a known,
-- separate item and is deliberately left alone here.
--
-- ============================================================================
-- WHAT "ACTIVE" MEANS -- THE EXISTING CONTRACT, NOT A NEW ONE
--
--   active  =  revoked_at is null and (expires_at is null or expires_at > now())
--
-- which is exactly the predicate get_free_busy uses to decide whether a token
-- still answers, and exactly what the P2 precheck measured as "active". A link
-- that has expired but was never revoked is therefore NOT active -- it serves
-- nothing -- but it IS a row, so it counts toward the total.
--
-- The two quotas have different remedies and that is why they are separate:
--
--   active full  -> revoke a link. That frees an active slot at once.
--   total  full  -> delete a REVOKED link (delete_share_link, 0015). Revoking
--                   does not help: a revoked row still occupies the total.
--
-- So each has its own DETAIL token, and a client can tell its user which of
-- the two actions will actually work. The lifecycle active -> revoke -> delete
-- is the escape route from both, and nothing in this file charges or blocks
-- either step of it.
--
-- now() and not statement_timestamp() in the active test, deliberately: it
-- matches get_free_busy's definition to the letter. now() can only be older
-- than the true instant, so a link that expires mid-transaction is still
-- counted as active -- the conservative direction.
--
-- ============================================================================
-- SERIALIZATION: 811001 IS REUSED, AND NO NEW LOCK CLASS IS ADDED
--
-- A count followed by a comparison is a TOCTOU race on its own: two creates
-- can both count 24 and both commit. The quota trigger therefore takes
--
--   pg_advisory_xact_lock(811001, hashtext(owner_id::text))
--
-- -- the SAME class and the SAME key 0011's events_enforce_owner_quota uses --
-- for every owner whose count could rise, in ascending owner order, before it
-- counts. A second writer for the same owner blocks there; under READ
-- COMMITTED its count, taken after the wait, sees the first writer's committed
-- row. Measured on real PostgreSQL 17.10 (Matrix D): 30 of 30 simultaneous
-- create pairs at active 24, and 30 of 30 at total 199, admitted exactly one.
--
-- Why reuse 811001 instead of a class of our own:
--   * Advisory locks are reentrant on the same (class, key). A transaction
--     that already holds 811001 for this owner pays nothing to take it again.
--   * NO NEW CLASS MEANS NO NEW ORDERING OBLIGATION. 0011 fixes a global
--     acquisition order -- class 811002 before class 811001 -- and argues its
--     deadlock freedom from it. This file takes only 811001, so within any one
--     statement it cannot invert that order. A migration that introduces a new
--     class, or makes this trigger take 811002, must re-argue 0011's deadlock
--     proof from scratch.
--   * A shared owner lock serializes an events write and a share-link create
--     for the same owner, so their two rate-state rows can never be locked in
--     opposite orders by two transactions.
--
-- That order is a per-STATEMENT property, and has been since 0011: a
-- transaction that inserts a plain event (811001) and then an exception row
-- (811002) takes them in the reverse order and can deadlock against a
-- transaction doing the opposite -- measured with 0011 alone. A share-link
-- create behaves exactly like that plain event insert (measured, identical
-- 40P01), so it adds no new case. No current code path reaches it: PostgREST
-- runs one statement per request.
--
-- WHICH STATEMENTS JOIN 811001, AND WHY REVOKE AND DELETE DO NOT
--
--   INSERT                              locks and checks
--   UPDATE that raises active or total  locks and checks the rising count
--   UPDATE that lowers them (revoke)    no lock, no check
--   DELETE                              no lock, no trigger at all
--
-- A statement that can only LOWER a count cannot push anyone over a ceiling,
-- so it needs neither the check nor the lock -- 0011's delta rule, applied
-- here unchanged. Two further reasons, both measured in Matrix D:
--   * Refusing a lowering statement would break the escape route. An owner
--     already over a limit (a legacy row, a restore) must still be able to
--     revoke; the delta rule guarantees it. Tested at 27 active.
--   * A revoke or delete that joined 811001 would take the lock AFTER its row
--     lock. Then T1 {create; revoke X} against T2 {revoke X} deadlocks: T1
--     holds 811001 and waits for X, T2 holds X and waits for 811001. Measured:
--     40P01 for that variant, none without it.
--
-- THE ACCEPTED COST: a create that races an UNCOMMITTED revoke or delete still
-- sees the row (READ COMMITTED hides the uncommitted change, not the row) and
-- can be refused although capacity is about to free up. That is a false
-- NEGATIVE, never an over-admission: the count can only err high. It fails
-- closed, clears on retry, and needs two concurrent requests to happen at all
-- -- in the UI a revoke or delete commits before the next create is sent. It
-- is accepted rather than paid for with the deadlock above. Measured: across
-- 30 create||delete and 30 create||create||delete trials at total 200 the
-- total never exceeded 200.
--
-- A create refused by the quota releases 811001 at the moment of the error,
-- not at ROLLBACK (PostgreSQL aborts the transaction's resources when the
-- statement fails). An aborted-but-open transaction never blocks the owner.
--
-- ============================================================================
-- ISOLATION: READ COMMITTED IS THE PREMISE
--
-- The quota guarantee above holds under READ COMMITTED, which is what
-- PostgREST runs. It is the same premise 0011 rests on.
--
-- Under REPEATABLE READ the count does NOT re-read after the lock wait: the
-- losing transaction counts with the snapshot it took before waiting, and its
-- own quota check passes. Measured: with no other conflict, two REPEATABLE READ
-- creates at active 24 both commit and the owner ends at 26. 0011 behaves the
-- same way (5001 of 5000 measured).
--
-- For writers this file CHARGES, the second transaction is in practice stopped
-- by a serialization failure on the rate-state row below. THAT IS NOT PART OF
-- THE QUOTA GUARANTEE AND MUST NOT BE RELIED ON AS ONE: it is a side effect of
-- the rate limiter, it disappears for every writer the rate limiter exempts,
-- and it would disappear altogether if the rate limiter were changed. KNOWN
-- CONSTRAINT: a rate-exempt, trusted writer (auth.uid() is null, or a
-- service_role JWT -- migrations, maintenance, restores) that writes directly
-- under REPEATABLE READ can take an owner past either ceiling. SERIALIZABLE is
-- safe: its predicate tracking refuses the second writer on its own.
--
-- ============================================================================
-- THE RATE LIMIT
--
-- GCRA keyed on owner_id, the same algorithm and shape as 0012, in its own
-- table so it can neither consume nor be consumed by the events allowance:
--
--   T   = 1 minute per create      sustained 1 create / minute
--   tau = burst * T = 5 minutes    burst 5
--   charge:  tat := greatest(tat, now) + cost * T      (tat := now + cost * T
--                                                       on an owner's first create)
--   allow while  tat - now <= tau;  refuse when  tat - now > tau
--   retry_after_seconds = ceil((tat - now) - tau)
--
-- From an empty state the 1st..5th immediate creates reach tat - now = 60,
-- 120, 180, 240, 300 seconds and are admitted; the 6th reaches 360 > 300 and
-- is refused with retry_after_seconds=60 -- exactly one sustained slot.
--
-- cost is the number of rows the STATEMENT inserted for that owner, read from
-- the transition table. create_share_link inserts one row per call, but a
-- privileged multi-row INSERT is charged per row, so the burst cannot be
-- bypassed by batching: six rows in one statement from an empty state are
-- refused as a whole.
--
-- The clock is statement_timestamp(), for 0012's reason: now() is the
-- transaction start, measured ~6 ms stale in the simplest request.
--
-- Concurrency needs no lock of its own: INSERT ... ON CONFLICT DO UPDATE ...
-- RETURNING is one statement that row-locks the owner's state, re-evaluates
-- against the latest committed version and returns the post-update value,
-- which is the only thing the decision reads. 0012 measured this in
-- production; here 811001 already serializes same-owner creates before this
-- trigger runs, so the row lock is uncontended in practice.
--
-- Exemptions follow 0012 exactly: auth.uid() is null (maintenance, migrations)
-- and a JWT whose role claim is service_role. The QUOTAS exempt nobody: they
-- are invariants, not a traffic policy.
--
-- NOT CHARGED: UPDATE and DELETE. Revoking and deleting are how an owner gets
-- back under a quota, and the escape route must never cost allowance. There is
-- no rate trigger on UPDATE or DELETE for that reason.
--
-- ============================================================================
-- ORDER OF THE TWO TRIGGERS, AND WHY A REFUSED CREATE LEAVES NO DEBT
--
-- Triggers of the same timing fire in name order. share_links_quota_* sorts
-- before share_links_rate_*, so the quota decides first. Renaming either
-- trigger can silently reverse this.
--
-- Quota first because the quota is the permanent condition: an owner at 200
-- of 200 who is told "retry in 60 seconds" will retry forever, while "delete a
-- revoked link" is the action that works. It also means a quota refusal never
-- writes the rate state at all.
--
-- Beyond that, NO refusal leaves debt, and not because of any bookkeeping: the
-- rate trigger writes its new tat and THEN raises, and the raise aborts the
-- whole transaction, taking that write with it. The same holds when the INSERT
-- itself fails on a 0014 CHECK -- the AFTER triggers never run. Only a create
-- that commits is ever charged.
--
-- ============================================================================
-- ERRORS, following 0011 (quota) and 0012 (rate)
--
--   active quota   23514  DETAIL TIMEWEAVE_QUOTA_SHARE_LINKS_ACTIVE
--   total quota    23514  DETAIL TIMEWEAVE_QUOTA_SHARE_LINKS_TOTAL
--   create rate    PT429  DETAIL TIMEWEAVE_RATE_SHARE_LINKS
--                         HINT   retry_after_seconds=N
--
-- DETAIL is the machine-readable discriminator; MESSAGE is for humans and logs
-- and may change. When a create would break both quotas, ACTIVE is reported --
-- the one a normal account meets first.
-- ============================================================================
begin;

-- ============================================================================
-- 1. Rate state. Own table, own schema, nobody's privileges.
--
-- timeweave_private exists since 0012 with every privilege revoked from
-- PUBLIC, anon, authenticated and service_role. The table is revoked again
-- explicitly anyway: default privileges on this project hand new tables to
-- roles by default (measured in 0012, and seen on share_links itself), and
-- this file does not assume a new table is born clean.
-- ============================================================================
create table timeweave_private.share_link_create_rate (
  owner_id        uuid primary key
                    references auth.users (id) on delete cascade,
  tat             timestamptz not null,
  charged_creates bigint      not null,
  last_charge_at  timestamptz not null
) with (fillfactor = 70);

alter table timeweave_private.share_link_create_rate enable row level security;

revoke all on table timeweave_private.share_link_create_rate from public;
revoke all on table timeweave_private.share_link_create_rate
  from anon, authenticated, service_role;

comment on table timeweave_private.share_link_create_rate is
  'GCRA rate-limit state for creates on public.share_links. Written ONLY by '
  'public.share_links_enforce_create_rate(). Independent of event_write_rate.';

-- ============================================================================
-- 2. The four numbers, one function each, as in 0011 and 0012.
-- ============================================================================
create or replace function public.share_links_max_active_per_owner()
returns int
language sql
immutable
parallel safe
set search_path = ''
as $fn$ select 25 $fn$;

create or replace function public.share_links_max_total_per_owner()
returns int
language sql
immutable
parallel safe
set search_path = ''
as $fn$ select 200 $fn$;

create or replace function public.share_links_rate_interval()
returns interval
language sql
immutable
parallel safe
set search_path = ''
as $fn$ select interval '1 minute' $fn$;

create or replace function public.share_links_rate_burst()
returns int
language sql
immutable
parallel safe
set search_path = ''
as $fn$ select 5 $fn$;

-- ============================================================================
-- 3. The quotas.
--
-- Per owner, the statement's DELTA to each count: for an INSERT, the rows it
-- adds; for an UPDATE, new rows minus old rows, which also covers a row moved
-- between owners -- the destination gains and is checked, the source only
-- loses and is not. Only an owner whose active or total count RISES is
-- locked, and only the count that rises is checked.
-- ============================================================================
create or replace function public.share_links_enforce_quota()
returns trigger
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  c_lock_class constant int := 811001;
  v_max_active int := public.share_links_max_active_per_owner();
  v_max_total  int := public.share_links_max_total_per_owner();
  v_now        timestamptz := pg_catalog.now();
  v_keys       uuid[];
  v_active     uuid[];
  v_total      uuid[];
  v_key        uuid;
  r            record;
begin
  if tg_op = 'INSERT' then
    select array_agg(d.owner_id order by d.owner_id),
           array_agg(d.owner_id order by d.owner_id) filter (where d.d_active > 0),
           array_agg(d.owner_id order by d.owner_id) filter (where d.d_total > 0)
      into v_keys, v_active, v_total
    from (
      select n.owner_id,
             count(*) filter (
               where n.revoked_at is null
                 and (n.expires_at is null or n.expires_at > v_now)) as d_active,
             count(*) as d_total
      from new_rows n
      group by n.owner_id
    ) d
    where d.d_active > 0 or d.d_total > 0;
  else
    select array_agg(d.owner_id order by d.owner_id),
           array_agg(d.owner_id order by d.owner_id) filter (where d.d_active > 0),
           array_agg(d.owner_id order by d.owner_id) filter (where d.d_total > 0)
      into v_keys, v_active, v_total
    from (
      select x.owner_id,
             sum(x.a) as d_active,
             sum(x.t) as d_total
      from (
        select n.owner_id,
               case when n.revoked_at is null
                     and (n.expires_at is null or n.expires_at > v_now)
                    then 1 else 0 end as a,
               1 as t
        from new_rows n
        union all
        select o.owner_id,
               case when o.revoked_at is null
                     and (o.expires_at is null or o.expires_at > v_now)
                    then -1 else 0 end,
               -1
        from old_rows o
      ) x
      group by x.owner_id
    ) d
    where d.d_active > 0 or d.d_total > 0;
  end if;

  -- Nothing rose: a revoke, an expiry shortened, a label edit. No lock.
  if v_keys is null then
    return null;
  end if;

  -- Ascending owner order, 811001 only (see the header on lock order).
  foreach v_key in array v_keys loop
    perform pg_catalog.pg_advisory_xact_lock(
      c_lock_class, pg_catalog.hashtext(v_key::text)
    );
  end loop;

  for r in
    select s.owner_id,
           count(*) as n_total,
           count(*) filter (
             where s.revoked_at is null
               and (s.expires_at is null or s.expires_at > v_now)) as n_active
    from public.share_links s
    where s.owner_id = any(v_keys)
    group by s.owner_id
    order by s.owner_id
  loop
    if r.owner_id = any(coalesce(v_active, '{}'::uuid[]))
       and r.n_active > v_max_active then
      raise exception
        'share link quota exceeded: owner % would hold % active links, limit is %',
        r.owner_id, r.n_active, v_max_active
        using errcode = '23514',
              detail  = 'TIMEWEAVE_QUOTA_SHARE_LINKS_ACTIVE',
              hint    = 'Revoke an existing share link to free an active slot.';
    end if;
    if r.owner_id = any(coalesce(v_total, '{}'::uuid[]))
       and r.n_total > v_max_total then
      raise exception
        'share link quota exceeded: owner % would hold % share links, limit is %',
        r.owner_id, r.n_total, v_max_total
        using errcode = '23514',
              detail  = 'TIMEWEAVE_QUOTA_SHARE_LINKS_TOTAL',
              hint    = 'Delete revoked share links to free capacity; '
                        'revoking alone does not.';
    end if;
  end loop;

  return null;
end;
$fn$;

-- ============================================================================
-- 4. The create rate. 0012's function, keyed to its own state table.
-- ============================================================================
create or replace function public.share_links_enforce_create_rate()
returns trigger
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  c_t      constant interval    := public.share_links_rate_interval();
  c_tau    constant interval    := public.share_links_rate_burst()
                                   * public.share_links_rate_interval();
  v_now    constant timestamptz := pg_catalog.statement_timestamp();
  v_claims text;
  v_role   text := '';
  r        record;
  v_tat    timestamptz;
begin
  -- Maintenance and migrations run with no JWT subject.
  if auth.uid() is null then
    return null;
  end if;

  -- A service_role JWT is exempt, as in 0012. A malformed claims string is
  -- treated as "not service_role", never as an error.
  v_claims := pg_catalog.current_setting('request.jwt.claims', true);
  if v_claims is not null and v_claims <> '' then
    begin
      v_role := coalesce(v_claims::jsonb ->> 'role', '');
    exception when others then
      v_role := '';
    end;
  end if;
  if v_role = 'service_role' then
    return null;
  end if;

  for r in
    select n.owner_id, pg_catalog.count(*)::int as cost
    from new_rows n
    group by n.owner_id
    order by n.owner_id
  loop
    insert into timeweave_private.share_link_create_rate as w
      (owner_id, tat, charged_creates, last_charge_at)
    values
      (r.owner_id, v_now + r.cost * c_t, r.cost, v_now)
    on conflict (owner_id) do update
      set tat             = greatest(w.tat, v_now) + r.cost * c_t,
          charged_creates = w.charged_creates + r.cost,
          last_charge_at  = v_now
    returning w.tat into v_tat;

    if v_tat - v_now > c_tau then
      raise exception
        'share link create rate exceeded: owner % is % beyond an allowance of % at % per link',
        r.owner_id, (v_tat - v_now) - c_tau, c_tau, c_t
        using errcode = 'PT429',
              detail  = 'TIMEWEAVE_RATE_SHARE_LINKS',
              hint    = 'retry_after_seconds='
                        || pg_catalog.ceil(
                             extract(epoch from ((v_tat - v_now) - c_tau)))::text;
    end if;
  end loop;

  return null;
end;
$fn$;

-- ============================================================================
-- 5. Triggers. NAME ORDER IS PART OF THE DESIGN: quota_* fires before rate_*.
--
-- INSERT and UPDATE are separate registrations because a trigger with
-- transition tables may name only one event. There is deliberately no DELETE
-- trigger and no rate trigger on UPDATE.
-- ============================================================================
drop trigger if exists share_links_quota_ai on public.share_links;
drop trigger if exists share_links_quota_au on public.share_links;
drop trigger if exists share_links_rate_ai  on public.share_links;

create trigger share_links_quota_ai
  after insert on public.share_links
  referencing new table as new_rows
  for each statement
  execute function public.share_links_enforce_quota();

create trigger share_links_quota_au
  after update on public.share_links
  referencing old table as old_rows new table as new_rows
  for each statement
  execute function public.share_links_enforce_quota();

create trigger share_links_rate_ai
  after insert on public.share_links
  referencing new table as new_rows
  for each statement
  execute function public.share_links_enforce_create_rate();

-- ============================================================================
-- 6. EXECUTE. The enforce functions are callable by nobody but their owner --
-- revoked from anon and authenticated explicitly as well as from PUBLIC, so a
-- default-privilege grant cannot leave them reachable. The four getters follow
-- 0011 and 0012: readable by authenticated so a client can show the limits,
-- and revoked from anon for the same default-privilege reason.
-- ============================================================================
revoke execute on function public.share_links_enforce_quota()       from public, anon, authenticated;
revoke execute on function public.share_links_enforce_create_rate() from public, anon, authenticated;
revoke execute on function public.share_links_max_active_per_owner() from public, anon;
revoke execute on function public.share_links_max_total_per_owner()  from public, anon;
revoke execute on function public.share_links_rate_interval()        from public, anon;
revoke execute on function public.share_links_rate_burst()           from public, anon;

grant execute on function public.share_links_max_active_per_owner() to authenticated;
grant execute on function public.share_links_max_total_per_owner()  to authenticated;
grant execute on function public.share_links_rate_interval()        to authenticated;
grant execute on function public.share_links_rate_burst()           to authenticated;

commit;
