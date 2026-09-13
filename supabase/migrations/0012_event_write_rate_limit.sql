-- TimeWeave Phase 6-x: a hard RATE limit on writes to public.events.
--
-- 0011 bounded the STOCK of rows (5000 per owner, 500 exceptions per master) and
-- said in its own "what this file does not do" section that it deliberately left
-- the FLOW unbounded: "an account may reach its ceiling as fast as it likes".
-- This file bounds the flow.
--
-- It bounds COMMITTED WRITE FLOW -- WAL, index churn, bloat, backup size -- and
-- nothing else. It is NOT a request limiter: a refused statement rolls back,
-- including its own consumption, so an attacker at the ceiling can keep asking
-- forever at no budget cost. Requests per minute remain the edge's job, exactly
-- as 0011 said. These are two different quantities and both are wanted.
--
-- ============================================================================
-- WHAT WAS MEASURED BEFORE THIS WAS WRITTEN
--
-- Every load-bearing claim below was measured on THIS production database in
-- September 2026, not reasoned about. The probes were removed afterwards.
--
--   PT429 -> HTTP 429.  Raising with errcode 'PT429' makes PostgREST answer 429,
--       from an RPC and from an AFTER STATEMENT trigger alike. DETAIL and HINT
--       pass through verbatim as `details` and `hint`. 23514 answers 400, which
--       is the wrong thing to tell a client that should back off.
--   NO Retry-After.  set_config('response.headers', ...) does NOT survive the
--       RAISE -- the aborted transaction takes the GUC with it -- and
--       set_config('response.status', ...) does not override the SQLSTATE
--       mapping either. So the seconds go in HINT, in the body. (Checked that
--       this is not merely a CORS visibility artefact: other non-safelisted
--       headers on the same endpoint ARE readable from the page.)
--   auth.uid() IS THE ONLY DISCRIMINATOR.  Inside a SECURITY DEFINER trigger
--       during a real PostgREST request: auth.uid() = the JWT subject,
--       current_user = the function owner (postgres), session_user =
--       authenticator. Neither current_user nor session_user can tell an end
--       user from maintenance work.
--   CLOCKS.  In one real request: transaction_timestamp 07:19:51.487264,
--       statement_timestamp .493064, clock_timestamp .503617. now() is already
--       ~6 ms stale in the simplest possible request, and in a multi-statement
--       transaction the gap grows without bound.
--   CONCURRENCY.  100 simultaneous REST inserts by one owner against a probe
--       carrying this exact trigger shape with burst 20: 856 ms, exactly 20
--       accepted and 80 refused with PT429, charged rows equal to committed
--       rows (the lost-update detector), and the accumulated debt exactly 20*T
--       -- i.e. not one refused attempt left a charge behind. NO ADVISORY LOCK
--       WAS PRESENT. That is why there is none here.
--   TRANSITION TABLES.  A 5-row INSERT puts 5 rows in NEW TABLE; an UPDATE
--       matching 3 puts 3 in each; an UPDATE matching 0 fires with both empty;
--       an UPDATE to identical values still counts; and INSERT ... ON CONFLICT
--       DO UPDATE splits cleanly -- new rows to the INSERT trigger, conflicting
--       rows to the UPDATE trigger, no row in both. So charging NEW TABLE rows
--       cannot double-charge, even if an upsert path is added later.
--   DEFAULT PRIVILEGES.  A new table in `public` on this project is handed
--       anon=Dxtm by default privileges -- TRUNCATE, REFERENCES, TRIGGER,
--       MAINTAIN. TRUNCATE IS NOT FILTERED BY RLS. A new SCHEMA, however, gets
--       nothing. That is why the state table lives in its own schema and why
--       "RLS on with no policies" is defence in depth here rather than the
--       defence.
--
-- ============================================================================
-- THE POLICY
--
--   sustained   60 writes / minute   (T = 1 second per row)
--   burst      120 rows              (tau = burst * T = 120 seconds)
--   keyed on   owner_id              (a normal event and an exception row share
--                                     one bucket -- they are rows in one table
--                                     owned by one person)
--   counts     INSERT and UPDATE, by ROW
--   ignores    DELETE
--
-- WHY ROWS AND NOT STATEMENTS. PostgREST turns a JSON array into ONE multi-row
-- INSERT and this trigger fires once for it. Charging per statement would make
-- "one request, five thousand rows" cost one unit, which is not a flow control.
--
-- WHY DELETE IS NOT COUNTED. It cannot be abused on its own: a sustained delete
-- flow needs an equal insert flow, and inserts are charged; a single mass delete
-- is bounded by the stock ceiling 0011 already imposes. And it must stay free
-- for the same reason 0011's quota is a delta rule -- an account that has hit a
-- limit must always be able to tidy its way back under it. A limiter that also
-- blocks cleanup traps the user it just throttled.
--
-- WHY UPDATE *IS* COUNTED. It is the one flow the stock quota is blind to: an
-- update-only loop rewrites rows forever without changing any count.
--
-- CONSEQUENCE, STATED OUT LOUD: a single statement writing more than `burst`
-- rows can never be accepted, from any state. Today every write in the app is
-- one row, so nothing is affected. A future bulk import must go through its own
-- RPC with its own policy rather than through this path.
--
-- ============================================================================
-- WHY THERE IS NO ADVISORY LOCK (0011 HAS TWO)
--
-- 0011's quota reads a count, decides, and writes -- three steps that a second
-- session can interleave, which is why it serialises them with
-- pg_advisory_xact_lock before counting.
--
-- This limiter has no read-then-decide. `INSERT ... ON CONFLICT DO UPDATE ...
-- RETURNING` is ONE statement that takes the row lock itself, re-evaluates its
-- SET expression against the LATEST COMMITTED version of the row, and hands
-- back the post-update value. The decision is made from that returned value and
-- from nothing else. A second writer blocks on the row lock and then computes
-- from the first one's committed tat.
--
-- Measured, not assumed: see CONCURRENCY above. Advisory lock class 811003
-- stays reserved and unused; 0011 numbered 811001 and 811002 and wrote down
-- that a third should not collide. If anyone ever adds a read-then-decide step
-- to this function, that reservation is where to start.
--
-- LOCK ORDER. Triggers of equal timing fire in NAME order, so on public.events
-- the order is fixed for every statement in every session:
--
--   events_quota_exception_*  (advisory 811002)
--   events_quota_owner_*      (advisory 811001)
--   events_rate_*             (row lock on the state table)
--
-- 'q' sorts before 'r', which is not an accident and must survive any rename.
-- The row lock is always taken last and is never taken anywhere else, so no
-- cycle can form. THE STATE TABLE MUST NOT BE WRITTEN FROM ANY OTHER PLACE.
--
-- ============================================================================
-- WHAT THIS FILE DOES NOT DO
--
--   * NO protection of created_at / updated_at. Those columns are writable by
--     any client today, and column-level REVOKE cannot fix it because a
--     table-level GRANT implies every column. That is real and measured, it is
--     tracked as a separate migration candidate, and it is NOT a dependency:
--     this limiter never reads either column. Its clock is the server's.
--   * NO change to public.events -- not a column, not a constraint, not a
--     policy, not a grant, not one of its six existing triggers.
--   * NO change to 0011's quotas, to get_free_busy, to the 0006-0010 expansion
--     chain, or to public.events_archive_20260912.
--   * NO edge rate limiting. Different layer, different quantity.
-- ============================================================================

begin;

-- ============================================================================
-- 1. THE PRIVATE SCHEMA.
--
-- Not `public`, and the reason is measured rather than tidy: default privileges
-- on this project hand anon TRUNCATE on every new table in public, and TRUNCATE
-- ignores row level security entirely. A limiter whose state an anonymous role
-- can empty is not a limiter. A new schema receives no default privileges, so
-- this one starts with nothing granted to anybody and stays that way.
--
-- It is also outside PostgREST's exposed schemas, which is the other half:
-- measured, a table in here answers 404 PGRST205 over REST.
-- ============================================================================
create schema timeweave_private;

revoke all on schema timeweave_private from public;
revoke all on schema timeweave_private from anon, authenticated, service_role;

comment on schema timeweave_private is
  'Internal state that no client may read or write. Not exposed by PostgREST. '
  'Nothing here is part of any API.';


-- ============================================================================
-- 2. THE STATE.
--
-- One row per owner, written only by the trigger in section 4.
--
-- SIZE: bounded by the number of accounts, not by the number of writes. A write
-- updates a row; it never inserts one after the first. No retention job, no
-- pg_cron, no growth.
--
-- LIFETIME: the row dies with the account (ON DELETE CASCADE, the same
-- mechanism events.owner_id uses). Deleting a row by hand is also safe at any
-- time -- "no row" and "fully recovered" are the same state by construction --
-- so a future pruning job for rows whose tat is far in the past needs no
-- special care.
--
-- FILLFACTOR: this is the hottest single row in the system for a busy account.
-- Leaving 30% free keeps those updates HOT, so the primary key does not churn.
--
-- RLS is enabled with NO policies as defence in depth. It is NOT the defence --
-- the schema and the empty ACL are -- and `force row level security` is
-- deliberately absent, because forcing it would lock out the SECURITY DEFINER
-- function that is the table's only legitimate writer.
-- ============================================================================
create table timeweave_private.event_write_rate (
  -- The account this bucket belongs to. CASCADE so a deleted account leaves
  -- nothing behind, exactly as it leaves no events behind.
  owner_id       uuid primary key
                   references auth.users (id) on delete cascade,

  -- GCRA's theoretical arrival time: the instant at which this owner would be
  -- back in credit. Debt is (tat - now); allowance is tau.
  tat            timestamptz not null,

  -- Observability only, never read by the decision. Counts rows that actually
  -- COMMITTED -- a refused statement rolls this back with everything else, so
  -- it is a record of work done, not of work attempted.
  charged_rows   bigint      not null,
  last_charge_at timestamptz not null
) with (fillfactor = 70);

alter table timeweave_private.event_write_rate enable row level security;

revoke all on table timeweave_private.event_write_rate from public;
revoke all on table timeweave_private.event_write_rate
  from anon, authenticated, service_role;

comment on table timeweave_private.event_write_rate is
  'GCRA rate-limit state for writes to public.events. Written ONLY by '
  'public.events_enforce_write_rate(). Writing it from anywhere else breaks the '
  'lock-ordering argument in migration 0012.';


-- ============================================================================
-- 3. THE PARAMETERS.
--
-- Functions rather than literals, for the same reason 0011 made its quotas
-- functions: the UI can show the user the number the database is enforcing,
-- instead of keeping a second copy in TypeScript that drifts.
--
-- It also gives operations a throttle that touches no DDL on public.events:
-- CREATE OR REPLACE on events_rate_burst() changes the limit for the next
-- statement, with no lock on the events table at all.
--
--   T   = 1 second   -> 60 writes per minute, sustained
--   tau = 120 * T    -> 120 rows may be written in one instant
--
-- These two numbers are a judgement, not a measurement. The shape they are a
-- judgement about was measured: at burst 20 the limiter admitted exactly 20 of
-- 100 simultaneous requests.
-- ============================================================================
create or replace function public.events_rate_interval()
returns interval
language sql
immutable
parallel safe
set search_path = ''
as $fn$ select interval '1 second' $fn$;

create or replace function public.events_rate_burst()
returns int
language sql
immutable
parallel safe
set search_path = ''
as $fn$ select 120 $fn$;


-- ============================================================================
-- 4. THE ENFORCEMENT.
--
-- Shape, and why each step is where it is:
--
--   1. exempt maintenance. Measured: auth.uid() is the only thing in scope that
--      distinguishes an end user's request from a migration, a support action or
--      a service_role script. An exempt caller returns here, having taken no
--      lock and touched no row -- which is also why a long maintenance
--      transaction cannot block a user's writes on the state row.
--   2. one bucket per owner in the statement, keys in ASCENDING order. Under RLS
--      a client statement can only touch its own rows, so this loop runs once in
--      practice; the ordering is kept anyway, for the same reason 0011 sorts its
--      keys.
--   3. charge and decide in ONE statement. The upsert returns the new tat and
--      the decision is made from that value. Never re-read the row to decide:
--      that would reintroduce exactly the read-then-decide race the advisory
--      locks in 0011 exist to close.
--
-- VOLATILE (the default) is mandatory. Marked STABLE, the function's SPI reads
-- run read-only, the command counter does not advance, and it stops seeing its
-- own statement's rows -- measured on this database, in both directions.
--
-- TG_OP IS NOT BRANCHED ON. Both triggers declare only NEW TABLE and both charge
-- the rows written, so one body serves INSERT and UPDATE with no branch. (0011
-- needs OLD TABLE because a quota is about a delta; a rate limit is about work
-- done, and an updated row is work.)
-- ============================================================================
create or replace function public.events_enforce_write_rate()
returns trigger
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  c_t      constant interval    := public.events_rate_interval();
  c_tau    constant interval    := public.events_rate_burst()
                                   * public.events_rate_interval();
  -- statement_timestamp, not now(). now() is transaction_timestamp: measured at
  -- ~6 ms stale in the simplest single-statement request, and unboundedly stale
  -- in a longer transaction, which would charge a long transaction for time it
  -- has actually served. statement_timestamp is constant for the whole of this
  -- statement -- guaranteed by the server, so every owner in the loop below is
  -- judged at one instant -- and moves with real time between statements.
  --
  -- Clock steps: greatest(tat, v_now) means a BACKWARD jump makes existing debt
  -- look further away and the limiter briefly stricter (fail-closed); a forward
  -- jump briefly forgives. Supabase slews rather than steps, so this is a note,
  -- not a mechanism.
  v_now    constant timestamptz := pg_catalog.statement_timestamp();
  v_claims text;
  v_role   text := '';
  r        record;
  v_tat    timestamptz;
begin
  -- Step 1. Maintenance is exempt.
  if auth.uid() is null then
    return null;
  end if;

  -- Belt and braces for the service_role key. auth.uid() is expected to be NULL
  -- for it (no subject claim), which the branch above already handles -- but
  -- that specific case was not measured, and the cost of being wrong is that
  -- backfills and support scripts start getting throttled. The claim itself
  -- cannot be forged: PostgREST sets it from a signature it verified.
  v_claims := pg_catalog.current_setting('request.jwt.claims', true);
  if v_claims is not null and v_claims <> '' then
    begin
      v_role := coalesce(v_claims::jsonb ->> 'role', '');
    exception when others then
      v_role := '';   -- unparseable claims are not a reason to fail a write
    end;
  end if;

  if v_role = 'service_role' then
    return null;
  end if;

  -- Step 2 and 3.
  for r in
    select n.owner_id, pg_catalog.count(*)::int as cost
    from new_rows n
    group by n.owner_id
    order by n.owner_id
  loop
    insert into timeweave_private.event_write_rate as w
      (owner_id, tat, charged_rows, last_charge_at)
    values
      (r.owner_id, v_now + r.cost * c_t, r.cost, v_now)
    on conflict (owner_id) do update
      set tat            = greatest(w.tat, v_now) + r.cost * c_t,
          charged_rows   = w.charged_rows + r.cost,
          last_charge_at = v_now
    returning w.tat into v_tat;

    if v_tat - v_now > c_tau then
      -- PT429 is what makes this an HTTP 429 instead of a 400; DETAIL is the
      -- stable token the client branches on; HINT carries the backoff, because
      -- a real Retry-After header cannot survive the abort. MESSAGE is for
      -- humans and logs and names the owner and the overshoot so a support
      -- question is answerable from one log line.
      raise exception
        'write rate exceeded: owner % is % beyond an allowance of % at % per row',
        r.owner_id, (v_tat - v_now) - c_tau, c_tau, c_t
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


-- ============================================================================
-- 5. THE TRIGGERS.
--
-- Two, not one: PostgreSQL forbids declaring transition tables on a trigger
-- registered for more than one event.
--
-- NO DELETE TRIGGER -- see the header.
--
-- THE NAMES ARE PART OF THE DESIGN. events_rate_% sorts after events_quota_%,
-- so the rate limiter's row lock is always taken after 0011's advisory locks, in
-- every statement and every session. Renaming these to anything sorting before
-- 'q' would break that ordering argument.
-- ============================================================================
drop trigger if exists events_rate_ai on public.events;
drop trigger if exists events_rate_au on public.events;

create trigger events_rate_ai
  after insert on public.events
  referencing new table as new_rows
  for each statement
  execute function public.events_enforce_write_rate();

create trigger events_rate_au
  after update on public.events
  referencing new table as new_rows
  for each statement
  execute function public.events_enforce_write_rate();


-- ============================================================================
-- 6. EXECUTE privileges.
--
-- The enforcement function is reachable only as a trigger, so PUBLIC is revoked
-- and nothing is granted back: EXECUTE on a trigger function is checked when
-- CREATE TRIGGER runs, not when it fires (measured on this database in 0011's
-- probe, with a non-owner role firing the trigger).
--
-- The two parameter functions ARE granted to authenticated, on purpose, so the
-- client can display the same numbers the database enforces. They are pure
-- constants and disclose nothing.
--
-- anon gets nothing: 0002 grants it no DML on events, so it can never reach the
-- trigger, and it has no use for a limit it cannot approach.
-- ============================================================================
revoke execute on function public.events_enforce_write_rate() from public;
revoke execute on function public.events_rate_interval()      from public;
revoke execute on function public.events_rate_burst()         from public;

grant execute on function public.events_rate_interval() to authenticated;
grant execute on function public.events_rate_burst()    to authenticated;

commit;
