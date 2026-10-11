-- ============================================================================
-- TimeWeave Phase 2B (Available, step 3 of 5): anonymous AVAILABLE disclosure.
--
-- WHAT THIS IS. One NEW private function, timeweave_private.free_busy_available,
-- and a replacement of public.get_free_busy that calls it when the link opts in.
--
-- WHAT THIS IS NOT. timeweave_private.free_busy_core IS NOT TOUCHED. This file
-- contains no DDL naming it, so its body fingerprint
-- a9b4097e4b390cee1229709945475d2b must still match afterwards -- the 0024
-- postflight gates exactly that, and it is the single most important row there.
-- 0021's ten availability predicates, its six busy sources and its three
-- completeness branches are therefore untouched by construction rather than by
-- review. No change to share_links, events, any other RPC, RLS, any index, any
-- GRANT, or the client.
--
-- ============================================================================
-- TOP-LEVEL `slots` AND `complete` STILL MEAN BUSY, AND ONLY BUSY
--
-- The active answer grows one key:
--
--   { "link_state": "active",
--     "complete": <core's>, "slots": <core's>,
--     "available": { "status": ... } }
--
-- `complete` and `slots` are the core's jsonb, passed through unmodified. An
-- Available range NEVER enters `slots`, and no Available condition can ever
-- change `complete`. That separation is structural: Available is computed in a
-- different function which has no write path to the Busy result.
--
-- The unavailable answer is UNCHANGED and carries NO `available` key:
--
--   { "link_state": "unavailable", "complete": true, "slots": [] }
--
-- ============================================================================
-- AVAILABLE IS EXPLICIT, NOT THE COMPLEMENT OF BUSY
--
-- Available is derived ONLY from rows the owner marked availability='available'.
-- It is never "everything not busy". So
--
--   { "status": "complete", "slots": [] }
--
-- means "zero explicit Available ranges were safe to disclose" -- NOT "the owner
-- has no free time" and NOT "everything outside busy is unavailable". That case
-- is exact and must not be reported as indeterminate.
--
-- BUSY WINS. Where an explicit Available range overlaps confirmed Busy, the Busy
-- part is removed from the Available answer. Available never erases Busy.
--
-- ============================================================================
-- CROSS-MODEL SUBTRACTION IS DELIBERATELY UNDEFINED
--
-- Timed ranges live on instants, all-day ranges on calendar dates, and the
-- schema holds NO value that could convert between them: `timezone` is nullable
-- and belongs to a timed recurring master, there is no owner timezone column,
-- and single and all-day rows carry no zone at all. Subtracting across models
-- would therefore require inventing a timezone.
--
-- So when relevant visible explicit Available exists in one model while
-- confirmed Busy exists in the other, this function answers 'indeterminate' and
-- discloses nothing. That is conservative on purpose and will be common for
-- mixed-model calendars. The detection is a PRESENCE test on two multiranges --
-- no cast, no overlap arithmetic, nothing read from `timezone`.
--
-- ============================================================================
-- MULTIRANGE SUPPORT IS A HARD PRECONDITION
--
-- Subtraction is native: range_agg(...) of '[)' ranges, then the multirange `-`
-- operator. There is NO fallback implementation in this file and no runtime
-- choice of algorithm. 0024_preflight.sql gate R01 verifies tstzmultirange,
-- datemultirange, range_agg and the `-` operators BEFORE this file is applied;
-- if R01 fails the migration is NOT applied and the matter returns to a
-- planning gate.
--
-- Native ranges were chosen because their normalisation already matches the
-- core's: range_agg merges touching ranges exactly as 0021's gaps-and-islands
-- merges when `prev_end < s` is false, and daterange canonicalisation merges
-- consecutive days exactly as the busy all-day path already does. This is the
-- established behaviour, not a new convention.
--
-- ============================================================================
-- share_available = false DOES NO WORK
--
-- The flag is fetched by the token lookup the wrapper ALREADY performs -- one
-- more column, no second query -- and gates whether the helper is invoked at
-- all. On that branch no Available row is scanned and no recurrence is
-- expanded; the answer is {"status":"not_requested"}, which is a statement that
-- nothing was asked for, NOT an incomplete result.
--
-- ONE SNAPSHOT, ONE CORE CALL. When Available IS requested, the core and the
-- helper run in a SINGLE SQL statement via LATERAL. Both are STABLE, so a
-- function in FROM takes the calling query's snapshot and the two computations
-- cannot see different committed states. Two sequential assignments would take
-- two snapshots and could subtract a Busy set from an Available set computed
-- moments later. The core is still called exactly once on both branches, and
-- the helper never calls the core itself.
--
-- ============================================================================
-- ORDER / RE-RUNNING
--
-- Apply AFTER 0023. FORWARD ONLY: the helper is `create function`, not
-- `create or replace`, so a second application FAILS on it -- deliberately,
-- because the wrapper's `create or replace` would otherwise succeed and leave a
-- half-reapplied pair. AFTER SUCCESSFUL PRODUCTION APPLICATION THIS FILE MUST
-- NEVER BE RE-RUN; the postflight record is the closure.
-- ============================================================================

begin;

-- ============================================================================
-- 1. timeweave_private.free_busy_available
--
-- Mirrors free_busy_core's six sources with availability='available', reusing
-- the SAME recurrence helpers -- there is no second recurrence engine here, so
-- expansion semantics are identical by construction rather than by review.
--
-- SECURITY INVOKER / STABLE / search_path='' are the core's posture. It takes a
-- raw link id, so it must never be directly reachable; the REVOKE below is the
-- same one 0019 wrote for the core.
-- ============================================================================
create function timeweave_private.free_busy_available(
  p_link_id     uuid,
  p_from        timestamptz,
  p_to          timestamptz,
  p_from_date   date,
  p_to_date     date,
  p_busy_result jsonb
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
  v_exact           boolean;
  v_slot_mismatch   boolean;
  v_ok_tz           text[];
  v_tz_all          text[];
  v_busy_t          tstzmultirange;
  v_busy_d          datemultirange;
  v_avail_t         tstzmultirange;
  v_avail_d         datemultirange;
  v_slots           jsonb;
  v_cap             constant integer := public.rrule_allday_expansion_cap();
  v_timed_cap       constant integer := public.rrule_timed_expansion_cap();
  c_indet           constant jsonb := jsonb_build_object('status', 'indeterminate');
begin
  -- 1. Windows. The wrapper validated these before the core ran, so a bad
  --    window cannot reach here; fail CLOSED rather than raise, because this
  --    function's contract is to answer, never to break a valid Busy answer.
  if p_from is null or p_to is null or p_from >= p_to
     or p_from_date is null or p_to_date is null or p_from_date >= p_to_date then
    return c_indet;
  end if;

  -- 2. The Busy handoff. Everything that could make subtraction unsafe is
  --    checked HERE, before a single event row is scanned or a single rule
  --    expanded -- a Busy set that is incomplete or unreadable can never yield
  --    a disclosable Available answer, so there is nothing to compute.
  --
  --    EVERY TEST HERE MUST BE NULL-SAFE, and that is not a style preference.
  --    `p_busy_result -> 'key'` on a MISSING key yields SQL NULL, and `<>`
  --    against NULL yields NULL rather than true. An or-chain of false and NULL
  --    is NULL, and `if NULL then` does not enter the branch -- so a
  --    null-unsafe guard FAILS OPEN on exactly the malformed input it exists to
  --    reject. An earlier version of this block did, and disclosed Available
  --    for {"slots": []}; the 0024 runtime suite caught it at §13.3.
  --
  --    `is distinct from` is the null-safe comparison: it returns true when the
  --    left side is SQL NULL. So `complete` is accepted only when the key is
  --    present AND is the JSON boolean true -- a missing key, JSON null, the
  --    string "true" and false all fail closed. `slots` is rejected explicitly
  --    when absent, before jsonb_typeof is asked about it.
  if p_busy_result is null
     or jsonb_typeof(p_busy_result) is distinct from 'object'
     or (p_busy_result -> 'complete') is distinct from 'true'::jsonb
     or (p_busy_result -> 'slots') is null
     or jsonb_typeof(p_busy_result -> 'slots') is distinct from 'array'
  then
    return c_indet;
  end if;

  -- 2b. Slot element shapes, before any value is cast.
  --
  --     NULL-SAFE FOR THE SAME REASON AS THE GUARD ABOVE, and here the failure
  --     mode is subtler: this predicate sits in a WHERE, and a WHERE that
  --     evaluates to NULL does not select the row -- so `exists` returns false
  --     and the MALFORMED element passes. An earlier version used `<>` and did
  --     exactly that for {"all_day": false} with no start/end, which the 0024
  --     runtime suite caught at §13.5.
  --
  --     `is distinct from` makes a missing key, a JSON null and a wrong type
  --     all return true, so a malformed element always selects itself. The two
  --     `= 'false'/'true'::jsonb` discriminators stay plain `=`: they are only
  --     reached when the preceding test has already established that all_day
  --     IS a JSON boolean, so neither side can be SQL NULL there.
  if exists (
    select 1
    from jsonb_array_elements(p_busy_result -> 'slots') as x
    where jsonb_typeof(x) is distinct from 'object'
       or jsonb_typeof(x -> 'all_day') is distinct from 'boolean'
       or ((x -> 'all_day') = 'false'::jsonb
           and (jsonb_typeof(x -> 'start') is distinct from 'string'
             or jsonb_typeof(x -> 'end')   is distinct from 'string'))
       or ((x -> 'all_day') = 'true'::jsonb
           and (jsonb_typeof(x -> 'start_date') is distinct from 'string'
             or jsonb_typeof(x -> 'end_date')   is distinct from 'string'))
  ) then
    return c_indet;
  end if;

  -- 2c. Busy -> native multiranges, each model from its OWN keys. The core
  --     emits these with to_jsonb, whose date/time output is ISO 8601 with a
  --     UTC offset and is independent of DateStyle, so the round trip recovers
  --     the identical instant whatever the session TimeZone is. The handler
  --     catches only parse failures -- a corrupt value must not turn a valid
  --     Busy answer into an RPC error.
  begin
    -- A range whose end precedes its start is MALFORMED and fails CLOSED.
    -- Dropping it would mean subtracting less Busy than the handoff described,
    -- i.e. OVER-DISCLOSING -- the one direction this function must never err
    -- in. Raising is equally wrong: indeterminate is the answer the contract
    -- provides for "the input does not let us be sure".
    --
    -- THE TWO MODELS ARE DELIBERATELY ASYMMETRIC, because the schema is.
    -- events_time_shape (0001) permits `end_at >= start_at` for a TIMED row but
    -- requires `end_date > start_date` for an ALL-DAY one. So a zero-length
    -- timed event is LEGAL, the frozen core emits it as {start: T, end: T}, and
    -- rejecting it here would make one stray zero-length event disable
    -- Available sharing for the whole window -- changing normal, core-produced
    -- Busy semantics, which 0024 must not do. A zero-length range occupies no
    -- time, so the correct treatment is to subtract nothing and carry on.
    -- A zero-length ALL-DAY range cannot be produced at all, so for that model
    -- equality means the handoff is corrupt.
    if exists (
      select 1
      from jsonb_array_elements(p_busy_result -> 'slots') as x
      where ((x -> 'all_day') = 'false'::jsonb
             and (x ->> 'start')::timestamptz > (x ->> 'end')::timestamptz)
         or ((x -> 'all_day') = 'true'::jsonb
             and (x ->> 'start_date')::date >= (x ->> 'end_date')::date)
    ) then
      return c_indet;
    end if;

    -- The `start < end` predicate is NOT decoration: range_agg rejects an empty
    -- range, and tstzrange(T, T, '[)') is empty. A legal zero-length slot is
    -- therefore skipped here rather than constructed, which is also exactly
    -- what "contributes no busy time" means.
    select coalesce(
             range_agg(tstzrange((x ->> 'start')::timestamptz,
                                 (x ->> 'end')::timestamptz, '[)')),
             '{}'::tstzmultirange)
      into v_busy_t
    from jsonb_array_elements(p_busy_result -> 'slots') as x
    where (x -> 'all_day') = 'false'::jsonb
      and (x ->> 'start')::timestamptz < (x ->> 'end')::timestamptz;

    -- No such filter is needed for all-day: the guard above already returned
    -- for every non-positive date range, so every row reaching here is proper.
    select coalesce(
             range_agg(daterange((x ->> 'start_date')::date,
                                 (x ->> 'end_date')::date, '[)')),
             '{}'::datemultirange)
      into v_busy_d
    from jsonb_array_elements(p_busy_result -> 'slots') as x
    where (x -> 'all_day') = 'true'::jsonb;
  exception
    when invalid_datetime_format or datetime_field_overflow
      or invalid_text_representation then
      return c_indet;
  end;

  -- 3. Link context. Re-resolved by id with the core's own active predicate.
  --    The opt-in flag is deliberately NOT read here: it decides whether this
  --    function is called at all, and a second reader would be a second source
  --    of truth. Postflight A12 requires ZERO references to it in this body.
  --    Under the wrapper's single LATERAL statement this lookup shares the Busy
  --    computation's snapshot, so the two cannot disagree about the link.
  select s.owner_id, s.include_private
    into v_owner, v_include_private
  from public.share_links s
  where s.id = p_link_id
    and s.revoked_at is null
    and (s.expires_at is null or s.expires_at > now())
  limit 1;

  if v_owner is null then
    return c_indet;
  end if;

  -- 3b. Resolvable zones, collected and probed in TWO statements for 0018's
  --     measured reason: written as one query the planner pushed the probe
  --     below the DISTINCT and ran it per master. v_tz_all is deliberately NOT
  --     filtered by availability -- it is the set of zones this server must try,
  --     and a superset is correct; narrowing it would change what
  --     `timezone = any(v_ok_tz)` means below.
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

  -- 4. AVAILABLE EXACTNESS. 0021's three completeness branches, re-keyed on the
  --    master being AVAILABLE. This is genuinely new work, not a copy: 0021
  --    gated its branches on availability='busy' precisely so an unexpandable
  --    available rule would not raise the Busy warning about nothing, which
  --    means v_complete says NOTHING about the available side.
  --
  --    Any true here yields indeterminate and no slots. The reason never
  --    leaves this function: the public vocabulary is three values.
  select not exists (
    select 1
    from public.events e
    where e.owner_id = v_owner
      and (v_include_private or e.visibility <> 'private')
      and (

        ----------------------------------------------------------------------
        -- (A') An AVAILABLE recurring master that may reach the window but
        --      cannot be expanded exactly. Here `e` IS the master, so its own
        --      availability decides.
        ----------------------------------------------------------------------
        ( e.rrule is not null
          and e.availability = 'available'
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
                       -- A timed master is expandable only with a rule in the
                       -- timed subset AND a zone this server resolves. M0
                       -- (timezone IS NULL) fails the second test.
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
        -- (B') An exception whose all_day disagrees with its AVAILABLE master.
        --      The CHECKs constrain each row alone, not the pair, so the shape
        --      is reachable: the slot key is then the wrong type to detach
        --      with, and the snapshot cannot be placed either. Gated on the
        --      MASTER, never on the exception -- a BUSY exception against an
        --      available master is exactly the shape this catches.
        ----------------------------------------------------------------------
        ( e.recurrence_id is not null
          and exists (
            select 1
            from public.events m
            where m.id = e.recurrence_id
              and m.availability = 'available'
              and e.all_day is distinct from m.all_day
              and (
                    (
                      (e.all_day = false and e.start_at < p_to and e.end_at > p_from)
                      or (e.all_day = true and e.start_date < p_to_date and e.end_date > p_from_date)
                    )
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
        -- (C') An exception touching this window whose AVAILABLE parent series
        --      cannot be expanded. The parent's VISIBILITY is deliberately
        --      ignored, as in 0021: "may we disclose the master" and "can we
        --      account for the series" are different questions. The slot test
        --      uses the parent's duration and over-approximates where the
        --      parent's shape is unreadable or timed.
        ----------------------------------------------------------------------
        ( e.recurrence_id is not null
          and exists (
            select 1
            from public.events m
            where m.id = e.recurrence_id
              and m.availability = 'available'
              and (
                    (
                      (e.all_day = false and e.start_at < p_to and e.end_at > p_from)
                      or (e.all_day = true and e.start_date < p_to_date and e.end_date > p_from_date)
                    )
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
  into v_exact;

  if not v_exact then
    return c_indet;
  end if;

  -- 4b. (D') Exception slots an AVAILABLE master's expansion cannot account
  --     for. The exception side of the join is NOT filtered: a slot that
  --     matches nothing fails to detach whatever it says about itself.
  with expandable as materialized (
    select m.id, m.rrule, m.all_day, m.start_at, m.end_at, m.timezone,
           make_interval(secs => extract(epoch from (m.end_at - m.start_at))::double precision) as dur
    from public.events m
    where m.owner_id = v_owner
      and m.rrule is not null
      and m.all_day = false
      and (v_include_private or m.visibility <> 'private')
      and m.availability = 'available'
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

  if v_slot_mismatch then
    return c_indet;
  end if;

  -- 5. The six AVAILABLE sources, clipped to the window and aggregated into one
  --    native multirange per model. Structure, predicates and ordering mirror
  --    the busy pipeline's sources exactly; only `availability` is inverted.
  --    (The core is named only in this file's header, never inside this body:
  --    postflight A06 counts references to it here and requires ZERO, which is
  --    what proves this function cannot add a second core call.)
  --
  --    THE TWO DETACH ANTI-JOINS CARRY NO availability, visibility OR
  --    is_cancelled PREDICATE. Detaching is a structural fact about the series:
  --    a BUSY exception over an AVAILABLE master must remove that occurrence
  --    from the available set, or this function would disclose open time the
  --    owner has since filled. A cancelled available exception likewise still
  --    detaches while contributing nothing. Filtering either anti-join would be
  --    the mirror of the bug 0021's header warns about.
  with timed_single_avail as (
    select e.start_at as s0, e.end_at as t0
    from public.events e
    where e.owner_id = v_owner
      and e.rrule is null
      and e.recurrence_id is null
      and e.all_day = false
      and (v_include_private or e.visibility <> 'private')
      and e.availability = 'available'
      and e.start_at < p_to
      and e.end_at   > p_from
  ),
  timed_avail_master as materialized (
    select e.id, e.rrule, e.all_day, e.start_at, e.end_at, e.timezone,
           make_interval(secs => extract(epoch from (e.end_at - e.start_at))::double precision) as dur
    from public.events e
    where e.owner_id = v_owner
      and e.rrule is not null
      and e.all_day = false
      and (v_include_private or e.visibility <> 'private')
      and e.availability = 'available'
      and e.start_at < p_to
      and e.timezone = any(v_ok_tz)
      and public.rrule_timed_sql_subset(e.rrule, e.all_day)
      and coalesce(
            timeweave_private.rrule_timed_occurrence_count_in_zones(
              e.rrule, e.all_day, e.start_at, e.end_at, e.timezone, p_from, p_to, v_ok_tz),
            v_timed_cap + 1) <= v_timed_cap
  ),
  timed_avail_occ as (
    select s.t as s0, s.t + m.dur as t0
    from timed_avail_master m
    cross join lateral timeweave_private.rrule_timed_occurrence_starts_in_zones(
      m.rrule, m.all_day, m.start_at, m.end_at, m.timezone, p_from, p_to, v_ok_tz) as s(t)
    where not exists (
      select 1
      from public.events x
      where x.recurrence_id = m.id
        and x.recurrence_slot_start = s.t
    )
  ),
  timed_exception_avail as (
    select e.start_at as s0, e.end_at as t0
    from public.events e
    where e.owner_id = v_owner
      and e.recurrence_id is not null
      and e.is_cancelled = false
      and e.all_day = false
      and e.availability = 'available'
      and (v_include_private or e.visibility <> 'private')
      and e.start_at < p_to
      and e.end_at   > p_from
  ),
  timed_src as (
    select s0, t0 from timed_single_avail
    union all
    select s0, t0 from timed_avail_occ
    union all
    select s0, t0 from timed_exception_avail
  ),
  timed_clip as (
    select greatest(s0, p_from) as s, least(t0, p_to) as t
    from timed_src
  )
  select coalesce(range_agg(tstzrange(s, t, '[)')), '{}'::tstzmultirange)
    into v_avail_t
  from timed_clip
  where s < t;

  with allday_single_avail as (
    select e.start_date as sd0, e.end_date as ed0
    from public.events e
    where e.owner_id = v_owner
      and e.rrule is null
      and e.recurrence_id is null
      and e.all_day = true
      and (v_include_private or e.visibility <> 'private')
      and e.availability = 'available'
      and e.start_date < p_to_date
      and e.end_date   > p_from_date
  ),
  allday_avail_master as (
    select e.id, e.rrule, e.start_date, e.end_date
    from public.events e
    where e.owner_id = v_owner
      and e.rrule is not null
      and e.all_day = true
      and (v_include_private or e.visibility <> 'private')
      and e.availability = 'available'
      and e.start_date < p_to_date
      and public.rrule_sql_subset(e.rrule, e.all_day)
      and coalesce(
            public.rrule_allday_occurrence_count(
              e.rrule, e.all_day, e.start_date, e.end_date, p_from_date, p_to_date),
            v_cap + 1) <= v_cap
  ),
  allday_avail_occ as (
    select s.d as sd0, s.d + (m.end_date - m.start_date) as ed0
    from allday_avail_master m
    cross join lateral public.rrule_allday_occurrence_starts(
      m.rrule, true, m.start_date, m.end_date, p_from_date, p_to_date) as s(d)
    where not exists (
      select 1
      from public.events x
      where x.recurrence_id = m.id
        and x.recurrence_slot_date = s.d
    )
  ),
  allday_exception_avail as (
    select e.start_date as sd0, e.end_date as ed0
    from public.events e
    where e.owner_id = v_owner
      and e.recurrence_id is not null
      and e.is_cancelled = false
      and e.all_day = true
      and e.availability = 'available'
      and (v_include_private or e.visibility <> 'private')
      and e.start_date < p_to_date
      and e.end_date   > p_from_date
  ),
  allday_src as (
    select sd0, ed0 from allday_single_avail
    union all
    select sd0, ed0 from allday_avail_occ
    union all
    select sd0, ed0 from allday_exception_avail
  ),
  allday_clip as (
    select greatest(sd0, p_from_date) as sd, least(ed0, p_to_date) as ed
    from allday_src
  )
  select coalesce(range_agg(daterange(sd, ed, '[)')), '{}'::datemultirange)
    into v_avail_d
  from allday_clip
  where sd < ed;

  -- 6. CROSS-MODEL. A presence test on the two models, nothing more: no cast,
  --    no overlap arithmetic, no timezone read. Relevance is already baked in
  --    -- the busy multiranges were clipped by the core, the available ones by
  --    section 5 -- so only in-window material can trip this.
  if (v_avail_t <> '{}'::tstzmultirange and v_busy_d <> '{}'::datemultirange)
     or (v_avail_d <> '{}'::datemultirange and v_busy_t <> '{}'::tstzmultirange)
  then
    return c_indet;
  end if;

  -- 7. Same-model subtraction, then emission. The `-` operator removes every
  --    busy range exactly and returns a canonical multirange: non-overlapping,
  --    non-adjacent, ascending, with empty fragments already dropped. A busy
  --    range strictly inside an available one SPLITS it; one on an edge trims
  --    it; one covering it removes it. Overlapping and touching available
  --    inputs were already normalised together by range_agg above.
  --
  --    Ordering repeats the core's: all-day first by date, timed second by
  --    instant, with a fixed rank and NO date -> timestamptz cast, so it never
  --    depends on the session timezone.
  with d as (select r from unnest(v_avail_d - v_busy_d) as r),
       t as (select r from unnest(v_avail_t - v_busy_t) as r),
       u as (
    select 0 as ord_group, lower(d.r) as sort_date, null::timestamptz as sort_ts,
           jsonb_build_object(
             'all_day', true,
             'start_date', to_jsonb(lower(d.r)),
             'end_date',   to_jsonb(upper(d.r))
           ) as slot
    from d
    union all
    select 1 as ord_group, null::date as sort_date, lower(t.r) as sort_ts,
           jsonb_build_object(
             'all_day', false,
             'start', to_jsonb(lower(t.r)),
             'end',   to_jsonb(upper(t.r))
           ) as slot
    from t
  )
  select coalesce(jsonb_agg(slot order by ord_group, sort_date, sort_ts), '[]'::jsonb)
    into v_slots
  from u;

  -- An exact computation that found nothing is COMPLETE with an empty array.
  -- It says "no explicit Available range was safe to disclose", never "the
  -- owner is busy" and never "there is no free time".
  return jsonb_build_object('status', 'complete',
                            'slots', coalesce(v_slots, '[]'::jsonb));
end;
$fn$;

-- The core's own posture, for the same reason 0019 wrote it: this function
-- takes a raw link id, so a direct caller would bypass token resolution
-- entirely. It is reachable only as the definer-wrapper's callee.
revoke all on function timeweave_private.free_busy_available(
  uuid, timestamptz, timestamptz, date, date, jsonb
) from public, anon, authenticated, service_role;


-- ============================================================================
-- 2. public.get_free_busy
--
-- 0023's body with three additive changes and nothing else:
--   * the token lookup selects one more column, share_available;
--   * step 5 branches on it -- core alone, or core + helper in ONE statement;
--   * the return merges one more key.
--
-- Validation, the unavailable return, both GCRA buckets, the concurrency slot
-- and the charge are untouched, in the same order, with the same error codes.
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
  v_share   boolean;
  v_result  jsonb;
  v_avail   jsonb;
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
  c_slot_class constant integer  := 811030;   -- base; slot i uses 811030 + i
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

  -- 2. Resolve an ACTIVE token (hash compare). Invalid, expired, revoked and
  --    deleted all fall to ONE answer and nothing is charged. 0024 adds
  --    share_available to THIS lookup rather than issuing a second one.
  --
  --    THE UNAVAILABLE ANSWER IS UNCHANGED AND CARRIES NO `available` KEY. It
  --    returns here, above the rate buckets, the concurrency slot, the Busy
  --    computation, any Available computation and the charge.
  select s.id, s.owner_id, s.share_available
    into v_link, v_owner, v_share
  from public.share_links s
  where s.token_hash = encode(extensions.digest(p_token, 'sha256'), 'hex')
    and s.revoked_at is null
    and (s.expires_at is null or s.expires_at > now())
  limit 1;

  if v_link is null then
    return jsonb_build_object('link_state', 'unavailable',
                             'complete', true,
                             'slots', '[]'::jsonb);
  end if;

  -- 3. GCRA pre-check, owner bucket then link bucket. LOCK-FREE on purpose: a
  --    request that is over budget must not touch a bucket row or a slot.
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

  -- 4. One of k concurrency slots for this owner, NON-BLOCKING.
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

  -- 5. The computation. BOTH branches call free_busy_core exactly once.
  --
  --    When Available is requested the two run in ONE statement: a STABLE
  --    function in FROM takes the calling query's snapshot, so the Busy set the
  --    helper subtracts from is the one computed from the same committed state.
  --    Two sequential assignments would take two snapshots.
  --
  --    When it is not requested the helper is never invoked -- no Available row
  --    is scanned and no recurrence expanded. `not_requested` says nothing was
  --    asked for; it is NOT an incomplete result.
  if coalesce(v_share, false) then
    select c.r, a.r
      into v_result, v_avail
    from timeweave_private.free_busy_core(
           v_link, p_from, p_to, p_from_date, p_to_date) as c(r),
         lateral timeweave_private.free_busy_available(
           v_link, p_from, p_to, p_from_date, p_to_date, c.r) as a(r);
  else
    v_result := timeweave_private.free_busy_core(
                  v_link, p_from, p_to, p_from_date, p_to_date);
    v_avail  := jsonb_build_object('status', 'not_requested');
  end if;

  -- 6. Charge, once, at the very end: owner then link, a fixed order. A call
  --    that failed or timed out never reaches this point and is therefore not
  --    charged -- including one whose Available computation raised.
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

  -- `complete` and `slots` are the core's, passed through untouched: top-level
  -- still means BUSY and only busy.
  return v_result
         || jsonb_build_object('link_state', 'active')
         || jsonb_build_object('available', v_avail);
end;
$fn$;

-- ============================================================================
-- EXECUTE privileges.
--
-- Deliberately NOT restated for the wrapper. Its signature is unchanged, so
-- CREATE OR REPLACE preserved what 0005 granted (anon, authenticated). Writing
-- the grants again would hide a real failure: if they were somehow lost, the
-- postflight must say so rather than this file quietly putting them back.
--
-- free_busy_core is not replaced here at all, so 0019's revokes on it stand
-- untouched -- which is also why its body fingerprint must still match.
-- ============================================================================

commit;
