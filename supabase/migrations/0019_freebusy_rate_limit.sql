-- ============================================================================
-- TimeWeave Phase 6-x (A2): a rate limit and a concurrency gate on anonymous
-- Free/Busy.
--
-- WHAT THIS IS. public.get_free_busy keeps its signature, its anon +
-- authenticated grant, SECURITY DEFINER and search_path = ''. Its body becomes
-- a thin gate in front of the SAME computation, which moves verbatim into
-- timeweave_private.free_busy_core:
--
--   1. validate both windows                       (0018 code, verbatim)
--   2. resolve an ACTIVE share link from the token (0018 predicate, verbatim)
--   3. GCRA pre-check, LOCK-FREE: owner bucket, then link bucket
--   4. take one of k = 2 owner concurrency slots, NON-BLOCKING
--   5. run the computation (STABLE core -> one snapshot)
--   6. charge owner then link, once, at the very end
--
-- WHAT THIS IS NOT. No change to what a permitted call returns: the core is
-- 0018's get_free_busy body with exactly three edits (name and first argument,
-- SECURITY INVOKER, and the token lookup replaced by the link id it is handed).
-- No change to the timed/all-day helpers, the zone predicates, rrule_parse,
-- either cap, any table, index, RLS policy, trigger, quota, write rate limit or
-- share-link rule. No input-size or invalid-token defence -- that is A3.
--
-- ============================================================================
-- WHY, AND WHAT WAS MEASURED (LOCAL PostgreSQL 17.10 scratch, before writing this)
--
-- get_free_busy is the one anonymous, unmetered entry point: anyone holding a
-- share token can ask an owner's calendar to be expanded, as often as they
-- like. A1 made each call cheap for ordinary calendars; it did not bound how
-- many calls, or how many at once.
--
--   A RATE LIMIT ALONE IS NOT ENOUGH. A GCRA charge lives in the request's own
--       transaction, so a request that FAILS -- statement timeout above all --
--       rolls its charge back. Measured: work 800 ms against statement_timeout
--       600 ms, three waves of ten, every call timed out and the bucket was
--       left at zero debt. The rate limit never engaged; only serialization
--       bounded the work. So a limit on CONCURRENCY, not just on count, is what
--       protects a heavy owner.
--
--   A BLOCKING LIMITER IS WORSE THAN NONE. Charging BEFORE the computation
--       holds the bucket row until commit, so every later request for the same
--       key -- including the ones about to be refused -- queues behind the
--       running computation. Measured, 20 simultaneous calls, one key: rejects
--       waited up to 1.1 s, and with a 600 ms statement_timeout 18 of 20 ended
--       as timeouts instead of a clean 429. Charging at the END holds the row
--       for the last few milliseconds only, and refusals answer in 1-4 ms.
--
--   THE GATE MUST BE NON-BLOCKING AND COME AFTER THE PRE-CHECK. With
--       pg_try_advisory_xact_lock the gate never queues: 20 simultaneous calls
--       start exactly k computations and the other 18 are refused in 1-2 ms.
--       Putting the lock-free GCRA pre-check BEFORE the gate keeps an attacker
--       whose budget is spent from touching a slot at all: measured over a 4 s
--       flood, a legitimate viewer of ANOTHER link of the same owner saw 1 of
--       20 requests refused when the gate came first, and 0 of 20 with the
--       pre-check first.
--
--   THE CORE MUST STAY STABLE. A VOLATILE function takes a new snapshot per
--       statement, so the completeness scan, the slot-mismatch check and the
--       slot build could each see a different database. Measured: a VOLATILE
--       body saw rows committed mid-call (0 -> 5), a STABLE body did not
--       (0 -> 0), and a STABLE body called from a VOLATILE wrapper stayed
--       consistent. Hence: VOLATILE wrapper (it must write), STABLE core.
--
-- ============================================================================
-- THE NUMBERS, AND WHAT THEY MEAN
--
--   link   T = 2 s,  burst 15   -> 30 calls/min, full burst back in 30 s
--   owner  T = 1 s,  burst 40   -> 60 calls/min, full burst back in 40 s
--   owner concurrency  k = 2
--
-- One viewer clicking through 13 weeks in 10 s needs 13; the link bucket
-- allows 15 + 5 = 20 in that window. Two viewers of one link doing 10 each
-- also fit.
--
-- ONE LEAKED TOKEN CANNOT SILENCE THE OWNER'S OTHER LINKS. A single link can
-- only push the owner bucket by its own burst (15 charges x 1 s = 15 s of
-- debt) and then by T_owner/T_link = half a second per second, which the owner
-- bucket drains at 1 s/s. Fifteen seconds of debt against an allowance of 40
-- never exhausts it. Two abused links sit at 30 s, still short of 40. Only
-- three or more links abused at once -- i.e. the owner's own account -- reach
-- the owner ceiling, which is exactly what it is for: an owner with the
-- maximum 25 active links is held to 60 calls/min instead of 25 x 30.
--
-- WORST CASE COST. Per owner the gate admits at most k = 2 computations at a
-- time, whatever the rate limit does about failures, so one owner can occupy
-- at most two backends on this path.
--
-- ============================================================================
-- THE ADVISORY LOCK NAMESPACE (two-int form, as 0011/0016/0017 use)
--
--   811001  owner quota / recurrence graph      (0011, 0016, 0017)
--   811002  exception quota, keyed on master    (0011)
--   811030  RESERVED BASE for Free/Busy concurrency slots; slot i takes
--           (811030 + i, hashtext(owner_id::text)), i = 1..k, so k = 2 uses
--           811031 and 811032. 811030 + 1..9 is reserved for this purpose.
--
-- These are try-locks: they never wait, so this path cannot join a lock cycle,
-- and it takes no 811001/811002, so it cannot disturb the write-path order.
-- The key is hashtext(owner_id::text), the same 32-bit mapping 0011 already
-- uses. A hash collision would make two owners share slots -- a spurious BUSY,
-- never a bypass; at 10,000 owners the expected number of colliding pairs is
-- about 0.012.
--
-- ============================================================================
-- WHAT IS CHARGED, AND WHAT IS NOT
--
--   charged: a call that ran the computation and is about to return
--   NOT charged: an invalid, revoked or expired token (it returns the same
--                indistinguishable empty answer as before, and never reaches
--                the buckets or the gate); a RATE refusal; a BUSY refusal; a
--                computation that failed or timed out (its charge rolls back
--                with the transaction -- the gate, not the bucket, is the
--                protection there)
--
-- Because the pre-check reads without locking and the charge lands at the end,
-- up to k - 1 calls per owner can slip past a ceiling that was reached while
-- they were computing. That is bounded by the gate and is accepted.
--
-- REFUSALS (both PT429 -> HTTP 429, measured in production for 0012):
--   rate         DETAIL TIMEWEAVE_RATE_FREEBUSY       HINT retry_after_seconds=N
--   concurrency  DETAIL TIMEWEAVE_RATE_FREEBUSY_BUSY  HINT retry_after_seconds=1
-- No Retry-After header: an aborted transaction cannot set one (measured).
--
-- ============================================================================
-- VOLATILITY. get_free_busy becomes VOLATILE because it now writes. Nothing
-- else about it changes, and CREATE OR REPLACE keeps its ownership and ACL.
-- supabase-js calls RPCs with POST, and production already runs VOLATILE RPCs
-- that write (create_share_link, revoke_share_link, delete_share_link), so the
-- HTTP path is unchanged. A GET /rpc call of this function would now be
-- refused by PostgREST; the application never makes one.
--
-- ROLLBACK. Re-run 0018's get_free_busy statement as it stands there, then
-- drop timeweave_private.free_busy_core, the five parameter functions and the
-- two rate tables. Dropping the tables discards only rate state.
-- ============================================================================

begin;

-- ============================================================================
-- 1. Rate state. Two buckets, both in timeweave_private for the reason 0012
--    gives: a new table in `public` is handed anon=Dxtm by this project's
--    default privileges, and TRUNCATE is not filtered by RLS. RLS is on with
--    no policies as defence in depth, not as the defence.
--
--    tat is GCRA's theoretical arrival time; debt is (tat - now) and the
--    allowance is burst * T. charged_calls / last_charge_at are observability
--    only and never read by a decision: a refused or failed call rolls its
--    row back with everything else, so they count work DONE.
-- ============================================================================
create table timeweave_private.freebusy_owner_rate (
  owner_id       uuid primary key
                   references auth.users (id) on delete cascade,
  tat            timestamptz not null,
  charged_calls  bigint      not null,
  last_charge_at timestamptz not null
) with (fillfactor = 70);

create table timeweave_private.freebusy_link_rate (
  link_id        uuid primary key
                   references public.share_links (id) on delete cascade,
  tat            timestamptz not null,
  charged_calls  bigint      not null,
  last_charge_at timestamptz not null
) with (fillfactor = 70);

alter table timeweave_private.freebusy_owner_rate enable row level security;
alter table timeweave_private.freebusy_link_rate  enable row level security;

revoke all on table timeweave_private.freebusy_owner_rate from public;
revoke all on table timeweave_private.freebusy_owner_rate from anon, authenticated, service_role;
revoke all on table timeweave_private.freebusy_link_rate  from public;
revoke all on table timeweave_private.freebusy_link_rate  from anon, authenticated, service_role;

-- ============================================================================
-- 2. The parameters, one place each. Private: no client reads these, unlike
--    0011's and 0012's getters, so they are not in public and are granted to
--    nobody. Changing a limit is a one-line migration against these.
-- ============================================================================
create function timeweave_private.freebusy_link_rate_interval()
returns interval
language sql
immutable
set search_path = ''
as $fn$ select interval '2 seconds' $fn$;

create function timeweave_private.freebusy_link_rate_burst()
returns integer
language sql
immutable
set search_path = ''
as $fn$ select 15 $fn$;

create function timeweave_private.freebusy_owner_rate_interval()
returns interval
language sql
immutable
set search_path = ''
as $fn$ select interval '1 second' $fn$;

create function timeweave_private.freebusy_owner_rate_burst()
returns integer
language sql
immutable
set search_path = ''
as $fn$ select 40 $fn$;

create function timeweave_private.freebusy_concurrency_slots()
returns integer
language sql
immutable
set search_path = ''
as $fn$ select 2 $fn$;

-- ============================================================================
-- 3. timeweave_private.free_busy_core: 0018's get_free_busy body, with three
--    edits and nothing else.
--      * name, and p_token text -> p_link_id uuid
--      * SECURITY DEFINER -> SECURITY INVOKER (its only caller is the DEFINER
--        wrapper below, so it already runs as the owner; it needs no rights of
--        its own and is granted to nobody)
--      * the token lookup becomes a lookup BY LINK ID
--
--    It stays STABLE: every query inside one call then reads one snapshot, so
--    the completeness scan and the slots it returns cannot disagree. It also
--    re-checks revoked_at / expires_at in that snapshot, so a link revoked
--    after the wrapper resolved it still yields the empty answer.
-- ============================================================================
create function timeweave_private.free_busy_core(
  p_link_id   uuid,
  p_from      timestamptz,
  p_to        timestamptz,
  p_from_date date,
  p_to_date   date
)
returns jsonb
language plpgsql
stable
security invoker
set search_path = ''
as $fn$
declare
  v_owner           uuid;
  v_include_private boolean;
  v_complete        boolean;
  v_slots           jsonb;
  v_slot_mismatch   boolean;
  v_ok_tz           text[];
  v_tz_all          text[];
  v_cap             constant integer := public.rrule_allday_expansion_cap();
  v_timed_cap       constant integer := public.rrule_timed_expansion_cap();
begin
  -- 1. Validate BOTH windows explicitly; reject malformed or over-long ranges.
  if p_from is null or p_to is null or p_from >= p_to then
    raise exception 'invalid time window' using errcode = '22023';
  end if;
  if p_to > p_from + interval '92 days' then
    raise exception 'requested range exceeds 92 days' using errcode = '22023';
  end if;
  if p_from_date is null or p_to_date is null or p_from_date >= p_to_date then
    raise exception 'invalid date window' using errcode = '22023';
  end if;
  if p_to_date - p_from_date > 92 then
    raise exception 'requested date range exceeds 92 days' using errcode = '22023';
  end if;

  -- 2. Resolve an ACTIVE token (hash compare). Invalid/expired/revoked -> empty
  --    (no error, no existence oracle).
  select s.owner_id, s.include_private
    into v_owner, v_include_private
  from public.share_links s
  where s.id = p_link_id
    and s.revoked_at is null
    and (s.expires_at is null or s.expires_at > now())
  limit 1;

  if v_owner is null then
    return jsonb_build_object('complete', true, 'slots', '[]'::jsonb);
  end if;

  -- 2b. The zones this server can actually resolve right now, validated ONCE
  --     PER DISTINCT ZONE (0018): timezone_is_resolvable scans
  --     pg_timezone_names and probes AT TIME ZONE, and it must not run once per
  --     row on an anonymous code path.
  --
  --     TWO STATEMENTS ON PURPOSE. Written as one query with the predicate
  --     outside a SELECT DISTINCT subquery, PostgreSQL pushed the predicate
  --     below the DISTINCT and ran it once per master (measured, 0018 header).
  --     Here the first statement collects the distinct zones into a variable
  --     and the second filters that array, so the predicate's input is already
  --     distinct whatever plan either statement gets.
  --
  --     v_ok_tz IS THE EVIDENCE the timed expansion below runs on: every
  --     element passed timezone_is_resolvable in this call. The
  --     timeweave_private *_in_zones helpers accept a zone only if it is in
  --     this list, so a NULL, unsupported or unresolvable zone still yields
  --     NULL / no rows there -> complete=false, never an exception, whatever
  --     order the surrounding conditions are evaluated in. The public helpers
  --     keep validating on their own for every other caller.
  select coalesce(array_agg(distinct e.timezone), array[]::text[])
    into v_tz_all
  from public.events e
  where e.owner_id = v_owner
    and e.all_day = false
    and e.rrule is not null
    and e.timezone is not null;

  select coalesce(array_agg(z.tz), array[]::text[])
    into v_ok_tz
  from unnest(v_tz_all) as z(tz)
  where public.timezone_is_resolvable(z.tz);

  -- 3. Completeness. A row makes the answer incomplete when it could contribute
  --    busy to this window and we cannot account for it exactly.
  select not exists (
    select 1
    from public.events e
    where e.owner_id = v_owner
      and (v_include_private or e.visibility <> 'private')
      and (

        ----------------------------------------------------------------------
        -- (A) A recurring master that may reach the window but cannot be
        --     expanded: MONTHLY, COUNT, timed, malformed, unsupported, an
        --     UNTIL whose value type does not match all_day, or a rule whose
        --     expansion would exceed the runtime cap for THIS window.
        ----------------------------------------------------------------------
        ( e.rrule is not null
          and (
            (e.all_day = false and e.start_at   < p_to)
            or (e.all_day = true and e.start_date < p_to_date)
          )
          and not public.rrule_definitely_ends_before(
                    e.rrule, e.all_day,
                    e.start_date, e.end_date,
                    e.start_at,   e.end_at,
                    p_from,       p_from_date)
          and not (
                case when e.all_day is true then
                       public.rrule_sql_subset(e.rrule, e.all_day)
                       and coalesce(
                             public.rrule_allday_occurrence_count(
                               e.rrule, e.all_day, e.start_date, e.end_date,
                               p_from_date, p_to_date),
                             v_cap + 1) <= v_cap
                     else
                       -- 5b-3: a timed master is expandable only with a rule in
                       -- the timed subset AND a zone this server resolves. M0
                       -- (timezone IS NULL) fails the second test, so a legacy
                       -- master keeps forcing complete=false.
                       public.rrule_timed_sql_subset(e.rrule, e.all_day)
                       and e.timezone = any(v_ok_tz)
                       and coalesce(
                             timeweave_private.rrule_timed_occurrence_count_in_zones(
                               e.rrule, e.all_day, e.start_at, e.end_at, e.timezone,
                               p_from, p_to, v_ok_tz),
                             v_timed_cap + 1) <= v_timed_cap
                end
          )
        )

        or

        ----------------------------------------------------------------------
        -- (B) Integrity guard: an exception whose all_day disagrees with its
        --     master. The DB CHECKs constrain each row alone, not the pair, so
        --     this shape is reachable. Its slot key is then the wrong type to
        --     detach with, and its own snapshot cannot be placed either.
        --
        --     Window relevance is "snapshot overlaps the window OR the slot may
        --     touch it" -- the SAME conservative slot test as (C-2). A mismatched
        --     exception affects this window structurally (it detaches, or fails
        --     to detach, an occurrence here) even when its own snapshot sits
        --     entirely outside; keying only on the snapshot would let that slip
        --     through as complete=true.
        ----------------------------------------------------------------------
        ( e.recurrence_id is not null
          and exists (
            select 1
            from public.events m
            where m.id = e.recurrence_id
              and e.all_day is distinct from m.all_day
              and (
                    -- (B-1) the exception's own snapshot overlaps the window
                    (
                      (e.all_day = false and e.start_at < p_to and e.end_at > p_from)
                      or (e.all_day = true and e.start_date < p_to_date and e.end_date > p_from_date)
                    )
                    -- (B-2) the slot it points at may touch the window. Uses the
                    --       PARENT's duration where readable; over-approximates
                    --       (assumes it touches) when the parent is timed or its
                    --       shape is unreadable.
                 or (
                      e.recurrence_slot_date is not null
                      and e.recurrence_slot_date < p_to_date
                      and (
                            m.all_day is not true
                            or m.start_date is null or m.end_date is null
                            or e.recurrence_slot_date + (m.end_date - m.start_date) > p_from_date
                          )
                    )
                 or (
                      e.recurrence_slot_start is not null
                      and e.recurrence_slot_start < p_to
                    )
              )
          )
        )

        or

        ----------------------------------------------------------------------
        -- (C) An exception that touches this window -- either because its own
        --     snapshot lands here, or because the slot it detaches would have
        --     -- while its parent series cannot be expanded.
        --
        --     The parent's VISIBILITY is deliberately ignored: "may we disclose
        --     the master's snapshots" and "can we account for the series this
        --     disclosed exception belongs to" are different questions. Without
        --     this branch a private unsupported master could hide behind a
        --     visible exception and still report complete=true.
        --
        --     Note the slot test uses the PARENT's duration: an occurrence spans
        --     [slot, slot + duration), so a multi-day master can reach into the
        --     window from a slot that sits before it. Where the parent's shape
        --     is unknown (or timed) we over-approximate and assume it touches.
        ----------------------------------------------------------------------
        ( e.recurrence_id is not null
          and exists (
            select 1
            from public.events m
            where m.id = e.recurrence_id
              and (
                    -- (C-1) the exception's own snapshot overlaps the window
                    (
                      (e.all_day = false and e.start_at < p_to and e.end_at > p_from)
                      or (e.all_day = true and e.start_date < p_to_date and e.end_date > p_from_date)
                    )
                    -- (C-2) the detached slot's original occurrence touches it
                 or (
                      e.recurrence_slot_date is not null
                      and e.recurrence_slot_date < p_to_date
                      and (
                            m.all_day is not true
                            or m.start_date is null or m.end_date is null
                            or e.recurrence_slot_date + (m.end_date - m.start_date) > p_from_date
                          )
                    )
                 or (
                      e.recurrence_slot_start is not null
                      and e.recurrence_slot_start < p_to
                    )
              )
              and not (
                    public.rrule_definitely_ends_before(
                      m.rrule, m.all_day,
                      m.start_date, m.end_date,
                      m.start_at,   m.end_at,
                      p_from,       p_from_date)
                or (
                      case when m.all_day is true then
                             public.rrule_sql_subset(m.rrule, m.all_day)
                             and coalesce(
                                   public.rrule_allday_occurrence_count(
                                     m.rrule, m.all_day, m.start_date, m.end_date,
                                     p_from_date, p_to_date),
                                   v_cap + 1) <= v_cap
                           else
                             public.rrule_timed_sql_subset(m.rrule, m.all_day)
                             and m.timezone = any(v_ok_tz)
                             and coalesce(
                                   timeweave_private.rrule_timed_occurrence_count_in_zones(
                                     m.rrule, m.all_day, m.start_at, m.end_at, m.timezone,
                                     p_from, p_to, v_ok_tz),
                                   v_timed_cap + 1) <= v_timed_cap
                      end
                )
              )
          )
        )
      )
  )
  into v_complete;

  -- 3d. Exception slots that this server cannot account for.
  --
  --     An exception detaches its master occurrence by matching
  --     recurrence_slot_start against a generated instant. If a slot overlaps
  --     this window but equals NO generated occurrence, then whatever wrote the
  --     slot and this server disagree about where that occurrence is, and the
  --     busy set here is not the one the owner sees. The TypeScript expander
  --     does exactly that today on a DST fold, because it resolves an ambiguous
  --     local time to the other instant (Phase 5b-4).
  --
  --     Such a window is reported incomplete. No assumption is made about which
  --     direction the disagreement errs in.
  --
  --     The master VISIBILITY filter is deliberate here, unlike in the detach
  --     anti-join: this asks whether the DISCLOSED busy set is wrong, and a
  --     master excluded by include_private contributes nothing to disclose.
  --     A missing slot key on a same-shape exception counts as a mismatch too.
  with expandable as materialized (   -- see step 4: filters complete before LATERAL
    select m.id, m.rrule, m.all_day, m.start_at, m.end_at, m.timezone,
           make_interval(secs => extract(epoch from (m.end_at - m.start_at))::double precision) as dur
    from public.events m
    where m.owner_id = v_owner
      and m.rrule is not null
      and m.all_day = false
      and (v_include_private or m.visibility <> 'private')
      and m.start_at < p_to
      and m.timezone = any(v_ok_tz)
      and public.rrule_timed_sql_subset(m.rrule, m.all_day)
      and coalesce(
            timeweave_private.rrule_timed_occurrence_count_in_zones(
              m.rrule, m.all_day, m.start_at, m.end_at, m.timezone, p_from, p_to, v_ok_tz),
            v_timed_cap + 1) <= v_timed_cap
  ),
  generated as (
    select m.id, m.dur, array_agg(s.t) as starts
    from expandable m
    cross join lateral timeweave_private.rrule_timed_occurrence_starts_in_zones(
      m.rrule, m.all_day, m.start_at, m.end_at, m.timezone, p_from, p_to, v_ok_tz) as s(t)
    group by m.id, m.dur
  )
  select exists (
    select 1
    from expandable m
    join public.events x
      on x.recurrence_id = m.id
     and x.all_day = false
    left join generated g on g.id = m.id
    where (
            x.recurrence_slot_start is null
         or (
              x.recurrence_slot_start < p_to
              and x.recurrence_slot_start + m.dur > p_from
              and not (x.recurrence_slot_start = any(coalesce(g.starts, array[]::timestamptz[])))
            )
          )
  )
  into v_slot_mismatch;

  v_complete := v_complete and not v_slot_mismatch;

  -- 4. Busy intervals. Both time models now draw from three sources: single
  --    events, expanded master occurrences after detach, and non-cancelled
  --    exception snapshots -- merged per model so nothing about event count or
  --    individual boundaries survives. Titles/ids/categories are never read.
  with timed_single as (
    select e.start_at as s0, e.end_at as t0
    from public.events e
    where e.owner_id = v_owner
      and e.rrule is null
      and e.recurrence_id is null
      and e.all_day = false
      and (v_include_private or e.visibility <> 'private')
      and e.start_at < p_to
      and e.end_at   > p_from
  ),

  -- Timed masters this migration can expand exactly, for THIS window. The zone
  -- gate is the hoisted v_ok_tz, so M0 and unresolvable zones drop out here and
  -- are accounted for by branch (A) instead.
  --
  -- MATERIALIZED on purpose: every filter -- zone, subset and cap -- must be
  -- fully applied BEFORE the LATERAL expansion below runs. Without it the
  -- planner may inline this CTE and evaluate the set-returning function for
  -- rows it has not filtered yet. The helper tolerates that (an unusable zone
  -- yields no rows rather than an error), but the RPC does not depend on the
  -- helper being forgiving, nor on evaluation order.
  timed_expandable_master as materialized (
    select e.id, e.rrule, e.all_day, e.start_at, e.end_at, e.timezone,
           make_interval(secs => extract(epoch from (e.end_at - e.start_at))::double precision) as dur
    from public.events e
    where e.owner_id = v_owner
      and e.rrule is not null
      and e.all_day = false
      and (v_include_private or e.visibility <> 'private')
      and e.start_at < p_to
      and e.timezone = any(v_ok_tz)
      and public.rrule_timed_sql_subset(e.rrule, e.all_day)
      and coalesce(
            timeweave_private.rrule_timed_occurrence_count_in_zones(
              e.rrule, e.all_day, e.start_at, e.end_at, e.timezone, p_from, p_to, v_ok_tz),
            v_timed_cap + 1) <= v_timed_cap
  ),

  -- Generated occurrences, minus every slot an exception has taken over. The
  -- anti-join deliberately has NO visibility and NO is_cancelled filter:
  -- detaching is a structural fact about the series, and a private or cancelled
  -- exception removes the original occurrence just the same. Slots that match
  -- nothing are handled by step 3d, not here.
  timed_master_occ as (
    select s.t as s0, s.t + m.dur as t0
    from timed_expandable_master m
    cross join lateral timeweave_private.rrule_timed_occurrence_starts_in_zones(
      m.rrule, m.all_day, m.start_at, m.end_at, m.timezone, p_from, p_to, v_ok_tz) as s(t)
    where not exists (
      select 1
      from public.events x
      where x.recurrence_id = m.id
        and x.recurrence_slot_start = s.t
    )
  ),

  -- Timed exception snapshots. Visibility applies here -- whether to disclose
  -- this particular event -- and is evaluated independently of whether the
  -- parent was expandable, because a snapshot pins absolute instants either way.
  timed_exception_busy as (
    select e.start_at as s0, e.end_at as t0
    from public.events e
    where e.owner_id = v_owner
      and e.recurrence_id is not null
      and e.is_cancelled = false
      and e.all_day = false
      and (v_include_private or e.visibility <> 'private')
      and e.start_at < p_to
      and e.end_at   > p_from
  ),

  timed_src as (
    select s0, t0 from timed_single
    union all
    select s0, t0 from timed_master_occ
    union all
    select s0, t0 from timed_exception_busy
  ),
  timed_raw as (
    select greatest(s0, p_from) as s, least(t0, p_to) as t
    from timed_src
  ),
  timed_flag as (
    select s, t,
      case when coalesce(
             max(t) over (order by s, t rows between unbounded preceding and 1 preceding),
             '-infinity'::timestamptz) < s
           then 1 else 0 end as is_new
    from timed_raw
  ),
  timed_grp as (
    select s, t,
      sum(is_new) over (order by s, t rows between unbounded preceding and current row) as g
    from timed_flag
  ),
  timed_merged as (
    select min(s) as start_at, max(t) as end_at
    from timed_grp
    group by g
  ),

  -- Masters this migration can expand exactly, for THIS window.
  expandable_master as (
    select e.id, e.rrule, e.start_date, e.end_date
    from public.events e
    where e.owner_id = v_owner
      and e.rrule is not null
      and e.all_day = true
      and (v_include_private or e.visibility <> 'private')
      and e.start_date < p_to_date
      and public.rrule_sql_subset(e.rrule, e.all_day)
      and coalesce(
            public.rrule_allday_occurrence_count(
              e.rrule, e.all_day, e.start_date, e.end_date, p_from_date, p_to_date),
            v_cap + 1) <= v_cap
  ),

  -- Generated occurrences, minus every slot an exception has taken over.
  -- The anti-join deliberately has NO visibility and NO is_cancelled filter:
  -- detaching is a structural fact about the series, and a private or cancelled
  -- exception removes the original occurrence just the same.
  master_occ as (
    select s.d as sd0, s.d + (m.end_date - m.start_date) as ed0
    from expandable_master m
    cross join lateral public.rrule_allday_occurrence_starts(
      m.rrule, true, m.start_date, m.end_date, p_from_date, p_to_date) as s(d)
    where not exists (
      select 1
      from public.events x
      where x.recurrence_id = m.id
        and x.recurrence_slot_date = s.d
    )
  ),

  -- Exception snapshots. THIS is where visibility applies: whether to disclose
  -- this particular event. Evaluated independently of whether the parent master
  -- was expandable, because the snapshot itself is exact either way.
  exception_busy as (
    select e.start_date as sd0, e.end_date as ed0
    from public.events e
    where e.owner_id = v_owner
      and e.recurrence_id is not null
      and e.is_cancelled = false
      and e.all_day = true
      and (v_include_private or e.visibility <> 'private')
      and e.start_date < p_to_date
      and e.end_date   > p_from_date
  ),

  allday_src as (
    select e.start_date as sd0, e.end_date as ed0
    from public.events e
    where e.owner_id = v_owner
      and e.rrule is null
      and e.recurrence_id is null
      and e.all_day = true
      and (v_include_private or e.visibility <> 'private')
      and e.start_date < p_to_date
      and e.end_date   > p_from_date
    union all
    select sd0, ed0 from master_occ
    union all
    select sd0, ed0 from exception_busy
  ),
  allday_raw as (
    select greatest(sd0, p_from_date) as sd, least(ed0, p_to_date) as ed
    from allday_src
  ),
  allday_flag as (
    select sd, ed,
      case when coalesce(
             max(ed) over (order by sd, ed rows between unbounded preceding and 1 preceding),
             '-infinity'::date) < sd
           then 1 else 0 end as is_new
    from allday_raw
  ),
  allday_grp as (
    select sd, ed,
      sum(is_new) over (order by sd, ed rows between unbounded preceding and current row) as g
    from allday_flag
  ),
  allday_merged as (
    select min(sd) as start_date, max(ed) as end_date
    from allday_grp
    group by g
  ),
  slots_union as (
    -- Order WITHOUT converting between time models: all-day sorts by its date,
    -- timed by its instant, and a fixed type rank (all-day first) separates them.
    -- No date -> timestamptz cast, so ordering never depends on session timezone.
    select 0 as ord_group, am.start_date as sort_date, null::timestamptz as sort_ts,
           jsonb_build_object(
             'all_day', true,
             'start_date', to_jsonb(am.start_date),
             'end_date',   to_jsonb(am.end_date)
           ) as slot
    from allday_merged am
    union all
    select 1 as ord_group, null::date as sort_date, tm.start_at as sort_ts,
           jsonb_build_object(
             'all_day', false,
             'start', to_jsonb(tm.start_at),
             'end',   to_jsonb(tm.end_at)
           ) as slot
    from timed_merged tm
  )
  select coalesce(jsonb_agg(slot order by ord_group, sort_date, sort_ts), '[]'::jsonb)
    into v_slots
  from slots_union;

  return jsonb_build_object('complete', v_complete, 'slots', coalesce(v_slots, '[]'::jsonb));
end;
$fn$;

-- ============================================================================
-- 4. public.get_free_busy: same signature, same ACL, SECURITY DEFINER,
--    search_path = ''. VOLATILE because it now writes its buckets.
--
--    ORDER (measured; see the header): validate -> resolve link -> LOCK-FREE
--    pre-check -> NON-BLOCKING slot -> compute -> charge at the end.
--    An invalid, revoked or expired token returns the same empty answer as
--    0018 and is charged nothing.
-- ============================================================================
create or replace function public.get_free_busy(
  p_token     text,
  p_from      timestamptz,
  p_to        timestamptz,
  p_from_date date,
  p_to_date   date
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $fn$
declare
  v_link    uuid;
  v_owner   uuid;
  v_result  jsonb;
  v_tat     timestamptz;
  v_slot    integer;
  v_got     boolean := false;
  v_now     constant timestamptz := pg_catalog.statement_timestamp();
  c_link_t     constant interval := timeweave_private.freebusy_link_rate_interval();
  c_link_tau   constant interval := timeweave_private.freebusy_link_rate_burst()
                                     * timeweave_private.freebusy_link_rate_interval();
  c_owner_t    constant interval := timeweave_private.freebusy_owner_rate_interval();
  c_owner_tau  constant interval := timeweave_private.freebusy_owner_rate_burst()
                                     * timeweave_private.freebusy_owner_rate_interval();
  c_slots      constant integer  := timeweave_private.freebusy_concurrency_slots();
  c_slot_class constant integer  := 811030;   -- base; slot i uses 811030 + i (see the header)
begin
  -- 1. Validate BOTH windows explicitly; reject malformed or over-long ranges.
  --    Verbatim from 0018, and still BEFORE anything touches a bucket or a slot.
  if p_from is null or p_to is null or p_from >= p_to then
    raise exception 'invalid time window' using errcode = '22023';
  end if;
  if p_to > p_from + interval '92 days' then
    raise exception 'requested range exceeds 92 days' using errcode = '22023';
  end if;
  if p_from_date is null or p_to_date is null or p_from_date >= p_to_date then
    raise exception 'invalid date window' using errcode = '22023';
  end if;
  if p_to_date - p_from_date > 92 then
    raise exception 'requested date range exceeds 92 days' using errcode = '22023';
  end if;

  -- 2. Resolve an ACTIVE token (hash compare). Invalid/expired/revoked -> empty
  --    (no error, no existence oracle), and nothing is charged: the predicate is
  --    0018's, only the selected columns differ (the link id is needed as a key).
  select s.id, s.owner_id
    into v_link, v_owner
  from public.share_links s
  where s.token_hash = encode(extensions.digest(p_token, 'sha256'), 'hex')
    and s.revoked_at is null
    and (s.expires_at is null or s.expires_at > now())
  limit 1;

  if v_link is null then
    return jsonb_build_object('complete', true, 'slots', '[]'::jsonb);
  end if;

  -- 3. GCRA pre-check, owner bucket then link bucket. LOCK-FREE on purpose: a
  --    request that is over budget must not touch a bucket row or a slot, so a
  --    spent attacker cannot make another viewer of the same owner wait or be
  --    refused. Debt is measured as the charge below would leave it.
  select w.tat into v_tat
  from timeweave_private.freebusy_owner_rate w
  where w.owner_id = v_owner;

  if v_tat is not null and greatest(v_tat, v_now) + c_owner_t - v_now > c_owner_tau then
    raise exception
      'free/busy rate exceeded for this calendar'
      using errcode = 'PT429',
            detail  = 'TIMEWEAVE_RATE_FREEBUSY',
            hint    = 'retry_after_seconds='
                      || pg_catalog.ceil(extract(epoch from
                           (greatest(v_tat, v_now) + c_owner_t - v_now - c_owner_tau)))::text;
  end if;

  select w.tat into v_tat
  from timeweave_private.freebusy_link_rate w
  where w.link_id = v_link;

  if v_tat is not null and greatest(v_tat, v_now) + c_link_t - v_now > c_link_tau then
    raise exception
      'free/busy rate exceeded for this share link'
      using errcode = 'PT429',
            detail  = 'TIMEWEAVE_RATE_FREEBUSY',
            hint    = 'retry_after_seconds='
                      || pg_catalog.ceil(extract(epoch from
                           (greatest(v_tat, v_now) + c_link_t - v_now - c_link_tau)))::text;
  end if;

  -- 4. One of k concurrency slots for this owner, NON-BLOCKING. try-locks never
  --    wait, so this can neither queue behind a running computation nor take
  --    part in a deadlock. Transaction-scoped: released on COMMIT and on ERROR.
  for v_slot in 1 .. c_slots loop
    if pg_catalog.pg_try_advisory_xact_lock(c_slot_class + v_slot,
                                            pg_catalog.hashtext(v_owner::text)) then
      v_got := true;
      exit;
    end if;
  end loop;

  if not v_got then
    raise exception
      'free/busy is busy for this calendar'
      using errcode = 'PT429',
            detail  = 'TIMEWEAVE_RATE_FREEBUSY_BUSY',
            hint    = 'retry_after_seconds=1';
  end if;

  -- 5. The computation, unchanged, in ONE snapshot.
  v_result := timeweave_private.free_busy_core(v_link, p_from, p_to, p_from_date, p_to_date);

  -- 6. Charge, once, at the very end: owner then link, a fixed order. The row
  --    locks this takes are held only from here to commit, so a viewer never
  --    waits behind someone else's computation. A call that failed or timed out
  --    never reaches this point and is therefore not charged -- the slot above,
  --    not the bucket, is what bounds that case.
  insert into timeweave_private.freebusy_owner_rate as w
    (owner_id, tat, charged_calls, last_charge_at)
  values
    (v_owner, v_now + c_owner_t, 1, v_now)
  on conflict (owner_id) do update
    set tat            = greatest(w.tat, v_now) + c_owner_t,
        charged_calls  = w.charged_calls + 1,
        last_charge_at = v_now;

  insert into timeweave_private.freebusy_link_rate as w
    (link_id, tat, charged_calls, last_charge_at)
  values
    (v_link, v_now + c_link_t, 1, v_now)
  on conflict (link_id) do update
    set tat            = greatest(w.tat, v_now) + c_link_t,
        charged_calls  = w.charged_calls + 1,
        last_charge_at = v_now;

  return v_result;
end;
$fn$;

-- ============================================================================
-- 5. EXECUTE. Everything new is owner-only and revoked explicitly from every
--    role that could otherwise hold it. get_free_busy keeps the grants it
--    already has: CREATE OR REPLACE preserves them, and 0005's
--    `grant ... to anon, authenticated` still stands.
-- ============================================================================
revoke all on function timeweave_private.free_busy_core(uuid, timestamptz, timestamptz, date, date)
  from public, anon, authenticated, service_role;
revoke all on function timeweave_private.freebusy_link_rate_interval()  from public, anon, authenticated, service_role;
revoke all on function timeweave_private.freebusy_link_rate_burst()     from public, anon, authenticated, service_role;
revoke all on function timeweave_private.freebusy_owner_rate_interval() from public, anon, authenticated, service_role;
revoke all on function timeweave_private.freebusy_owner_rate_burst()    from public, anon, authenticated, service_role;
revoke all on function timeweave_private.freebusy_concurrency_slots()   from public, anon, authenticated, service_role;

commit;
