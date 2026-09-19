-- ============================================================================
-- TimeWeave Phase 6-x (A1): Free/Busy validates each time zone once per call.
--
-- WHAT THIS IS. A pure read-path optimisation of get_free_busy. It changes WHERE
-- and HOW OFTEN the time-zone predicate runs inside one call, and nothing about
-- what the call returns:
--
--   A1a  step 2b now evaluates timezone_is_resolvable once per DISTINCT
--        candidate zone, by construction.
--   A1b  get_free_busy expands timed series through two internal helpers that
--        take the call's already-resolved zone list instead of re-validating
--        the zone themselves on every invocation.
--
-- WHAT THIS IS NOT. No change to timezone_is_supported, timezone_is_resolvable,
-- the 0008 write trigger, rrule_parse, either grammar gate, either expansion
-- cap, the all-day helpers, any table, index, RLS policy, trigger, quota, rate
-- limit, share-link rule or grant on an existing object. No anonymous rate
-- limit (A2), no response-size bound (A3). No table, no cache, no persistent or
-- session state, no advisory lock, no write of any kind: every function here is
-- STABLE and reads nothing but its arguments and public.events/share_links as
-- before.
--
-- ============================================================================
-- WHY. MEASURED LOCALLY ONLY (PostgreSQL 17.10 scratch, before this file).
--
-- Almost all of get_free_busy's cost for a timed recurring master was the
-- pg_timezone_names membership lookup inside timezone_is_supported (~140 ms
-- per call on that machine; the AT TIME ZONE probe itself ~0.3 ms). No claim
-- is made here about production timings or about why the lookup is slow.
--
-- For ONE timed DAILY master with no exceptions, one get_free_busy call ran
-- timezone_is_resolvable 6 times: once in step 2b and five times inside the
-- helpers -- rrule_timed_occurrence_count at steps 3(A), 3d and 4, and
-- rrule_timed_occurrence_starts at step 4 plus the count it calls for its own
-- cap check. A relevant timed exception added 3 more. Two masters in one zone
-- cost 12, two masters in two zones also 12: validation scaled with MASTERS,
-- not with zones.
--
-- Two separate causes, fixed separately:
--
--   A1a. Step 2b was written as "SELECT DISTINCT zone ... WHERE
--        timezone_is_resolvable(zone)" in a subquery. PostgreSQL pushes a
--        qualifier on a DISTINCT output column below the DISTINCT (measured:
--        the predicate appeared as a Filter on the events scan, 13 calls for
--        14 masters in 4 zones). The "once per distinct zone" the 0009 comment
--        promised never happened.
--
--        Fix: two statements. The first collects array_agg(DISTINCT zone) into
--        a variable; the second filters unnest(that array). The predicate's
--        input is an array that is already distinct, so the number of calls is
--        bounded by the number of distinct zones WHATEVER plan is chosen --
--        this does not depend on predicate pushdown rules or on CTE
--        materialisation semantics.
--
--   A1b. The timed helpers re-validate the zone on every call. That is
--        DELIBERATE defensive layering (0009 step 2b comment) and it stays for
--        every direct caller. Only get_free_busy, which has just resolved the
--        zones itself, now uses a path that consumes that result.
--
-- ============================================================================
-- THE TRUSTED PATH, AND WHY IT IS NOT A BYPASS
--
--   timeweave_private.rrule_timed_occurrence_count_in_zones (..., p_resolvable_zones text[])
--   timeweave_private.rrule_timed_occurrence_starts_in_zones(..., p_resolvable_zones text[])
--
-- Each is the 0010 helper of the same stem, arithmetic untouched, with ONE
-- difference: the zone guard is membership in p_resolvable_zones instead of a
-- call to timezone_is_resolvable. The list is not a claim ("already
-- validated = true"); it is the evidence itself -- the exact output of
-- get_free_busy's step 2b, where every element passed timezone_is_resolvable in
-- this call. The starts helper's defence-in-depth cap check calls the PRIVATE
-- count with the same list, so validation cannot creep back in through it.
--
-- Fail-soft is preserved exactly: a NULL zone, a NULL or empty list, or a zone
-- absent from the list gives count -> NULL and starts -> no rows, the same
-- answers an unresolvable zone gave before, which the caller already turns
-- into complete=false.
--
-- EVALUATION ORDER DOES NOT MATTER. SQL does not promise the order in which
-- the conditions of an AND are evaluated, and get_free_busy passes each helper
-- call alongside an `e.timezone = any(v_ok_tz)` guard (kept, as defence in
-- depth). Because the helper checks membership ITSELF, before any AT TIME
-- ZONE, a zone outside the list can never reach a conversion, whichever of the
-- two conditions the planner evaluates first. A currently fail-soft zone cannot
-- become a whole-RPC exception.
--
-- MISUSE IS LOUD, NOT SILENT. A caller that puts a zone into the list without
-- resolving it gets exactly what the old helper was protecting against: AT TIME
-- ZONE raises invalid_parameter_value. get_free_busy cannot do this -- the list
-- comes only from step 2b -- and nobody else can call the helpers (below).
--
-- ============================================================================
-- WHO CAN CALL WHAT
--
-- The private helpers live in timeweave_private (0012): no USAGE for PUBLIC,
-- anon, authenticated or service_role, and not a PostgREST-exposed schema.
-- They are SECURITY INVOKER with search_path = '' and fully qualified
-- references, like the 0009/0010 helpers, because they read no table and need
-- no rights of their own. EXECUTE is revoked from PUBLIC, anon, authenticated
-- and service_role explicitly; only the owner can run them, and get_free_busy
-- reaches them as the definer.
--
-- The public helpers keep their exact signatures, attributes, ownership and
-- ACL (CREATE OR REPLACE preserves the last two). Their bodies become thin
-- self-validating wrappers: they run their original argument checks and their
-- original timezone_is_resolvable guard VERBATIM, in the original order, and
-- only then delegate with the one-element list array[p_timezone]. A direct
-- caller therefore gets the same standalone validation, the same NULL / no-row
-- answers, and the same exception texts and SQLSTATE as before; only the error
-- CONTEXT gains a frame. No overload and no trust flag is added.
--
-- PRIVILEGE PREREQUISITE. The wrapper runs as its caller, so its caller needs
-- EXECUTE on the private helper and USAGE on timeweave_private. The owner has
-- both. Since 0009 no other role has EXECUTE on the public timed helpers
-- (0009 revoked it from PUBLIC and granted nothing), so no caller that can run
-- them today loses anything. If some role were ever granted EXECUTE on a public
-- timed helper, its direct calls would fail with "permission denied for
-- schema timeweave_private" -- a loud failure, never a silent wrong answer.
-- The 0018 preflight refuses to proceed unless both helpers' EXECUTE is held by
-- their owner alone and all involved objects share one owner.
--
-- ============================================================================
-- ACCEPTED RESIDUAL. Before this file each helper re-resolved the zone at its
-- own call time; now a zone resolved in step 2b is trusted for the rest of the
-- same call. A tzdata update retiring that zone in the middle of one
-- get_free_busy call is the only way the two can differ. Not reproduced; it
-- would surface as a raised invalid_parameter_value for that one call.
--
-- ROLLBACK. Re-run the three CREATE OR REPLACE FUNCTION statements exactly as
-- they stand in 0009 (get_free_busy) and 0010 (the two timed helpers), then
-- drop the two timeweave_private functions. There is no state to restore.
-- ============================================================================

begin;

-- ============================================================================
-- 1. timeweave_private.rrule_timed_occurrence_count_in_zones
--
-- 0010's rrule_timed_occurrence_count, arithmetic verbatim, plus one argument
-- and a membership zone guard in place of timezone_is_resolvable.
-- ============================================================================
create function timeweave_private.rrule_timed_occurrence_count_in_zones(
  p_rrule    text,
  p_all_day  boolean,
  p_start_at timestamptz,
  p_end_at   timestamptz,
  p_timezone text,
  p_from     timestamptz,
  p_to       timestamptz,
  p_resolvable_zones text[]
)
returns bigint
language plpgsql
stable
security invoker
set search_path = ''
as $fn$
declare
  p        record;
  v_n      integer;
  v_b      integer;
  v_s      integer;
  v_pw0    integer;
  v_d0     date;
  v_w0     date;
  v_durs   numeric;
  v_durd   integer;
  v_fromd  date;
  v_tod    date;
  v_untild date;
  v_lo     numeric;
  v_hi     numeric;
begin
  if p_all_day is not false then return null; end if;
  if p_start_at is null or p_end_at is null
     or p_from is null or p_to is null then
    return null;
  end if;
  -- 0018: the zone guard is MEMBERSHIP in the caller's resolved list, not a
  -- fresh timezone_is_resolvable call (see the 0018 header). A NULL zone, a
  -- NULL or empty list, or a zone absent from it gives NULL -- the same
  -- fail-closed answer an unresolvable zone gave before, which the caller's
  -- coalesce(count, cap + 1) rule turns into complete=false. It is checked
  -- here, before any AT TIME ZONE, so the caller's evaluation order is
  -- irrelevant. No exception handler is added anywhere below.
  if p_timezone is null
     or not coalesce(p_timezone = any(p_resolvable_zones), false) then
    return null;
  end if;
  if not public.rrule_timed_sql_subset(p_rrule, p_all_day) then return null; end if;

  select * into p from public.rrule_parse(p_rrule);

  v_n     := p.interval_n;
  v_durs  := extract(epoch from (p_end_at - p_start_at));
  v_durd  := ceil(v_durs / 86400.0)::integer;   -- whole days the span can cover
  v_d0    := (p_start_at at time zone p_timezone)::date;
  v_fromd := (p_from at time zone p_timezone)::date - 1;
  v_tod   := (p_to   at time zone p_timezone)::date + 1;
  if p.until_ts is not null then
    v_untild := (p.until_ts at time zone p_timezone)::date;
  end if;

  -- NOTE ON DIVISION: every quotient is cast to numeric before floor().
  -- Postgres integer division truncates TOWARD ZERO, not downward, so on a
  -- negative numerator (a series starting after the window) integer maths would
  -- round the range inward and drop occurrences -- a false-free.
  if p.freq = 'DAILY' then
    v_lo := greatest(0, floor((v_fromd - v_durd - v_d0)::numeric / v_n));
    v_hi := floor((v_tod - v_d0)::numeric / v_n);
    if v_untild is not null then
      v_hi := least(v_hi, floor((v_untild - v_d0)::numeric / v_n));
    end if;
    -- COUNT: ordinal(i) = i.
    if p.count_n is not null then
      v_hi := least(v_hi, (p.count_n - 1)::numeric);
    end if;
    return greatest(0, v_hi - v_lo + 1)::bigint;
  else
    -- BYDAY omitted means "the weekday of DTSTART", i.e. exactly one per week.
    v_b  := coalesce(array_length(p.byday, 1), 1);
    -- Week anchor: the Monday of DTSTART's LOCAL week (RFC 5545 default
    -- WKST=MO), the same anchor 0007 and services/recurrence.ts use.
    v_w0 := v_d0 - (extract(isodow from v_d0)::integer - 1);
    v_lo := greatest(0, floor((v_fromd - v_durd - 7 - v_w0)::numeric / (7 * v_n)));
    v_hi := floor((v_tod - v_w0)::numeric / (7 * v_n)) + 1;
    if v_untild is not null then
      v_hi := least(v_hi, floor((v_untild - v_w0)::numeric / (7 * v_n)));
    end if;
    -- COUNT: DTSTART's weekday is read in the MASTER ZONE, like every other
    -- calendar field on this path.
    if p.count_n is not null then
      v_s := extract(isodow from v_d0)::integer - 1;
      if p.byday is null then
        v_pw0 := 1;
      else
        select count(*)
          into v_pw0
        from unnest(p.byday) as tok
        where array_position(array['MO','TU','WE','TH','FR','SA','SU'], tok) - 1 >= v_s;
      end if;
      if p.count_n <= v_pw0 then
        v_hi := least(v_hi, 0::numeric);
      else
        v_hi := least(v_hi, 1 + floor((p.count_n - 1 - v_pw0)::numeric / v_b));
      end if;
    end if;
    return greatest(0, (v_hi - v_lo + 1) * v_b)::bigint;
  end if;
end;
$fn$;

-- ============================================================================
-- 2. timeweave_private.rrule_timed_occurrence_starts_in_zones
--
-- 0010's rrule_timed_occurrence_starts, arithmetic verbatim, plus one argument,
-- the membership zone guard, and its cap probe routed to the private count.
-- The exception texts keep the public name: the public wrapper raises them.
-- ============================================================================
create function timeweave_private.rrule_timed_occurrence_starts_in_zones(
  p_rrule    text,
  p_all_day  boolean,
  p_start_at timestamptz,
  p_end_at   timestamptz,
  p_timezone text,
  p_from     timestamptz,
  p_to       timestamptz,
  p_resolvable_zones text[]
)
returns setof timestamptz
language plpgsql
stable
security invoker
set search_path = ''
as $fn$
declare
  p        record;
  v_cnt    bigint;
  v_n      integer;
  v_d0     date;
  v_w0     date;
  v_tod0   time;
  v_durs   numeric;
  v_dur    interval;
  v_durd   integer;
  v_dtl    timestamp;
  v_fromd  date;
  v_tod    date;
  v_untild date;
  v_lo     bigint;
  v_hi     bigint;
  v_offs   integer[];
  v_i      bigint;
  v_j      integer;
  v_k      integer;
  v_s      integer;
  v_pw0    integer;
  v_ord    bigint;
  v_off    integer;
  v_cl     timestamp;
  v_start  timestamptz;
begin
  -- CLASS 1 -- caller wiring. Returning an empty set for these would be
  -- indistinguishable from "this series has no busy here", i.e. a silent
  -- false-free, so they fail loudly.
  if p_all_day is not false
     or p_start_at is null or p_end_at is null
     or p_from is null or p_to is null
     or not public.rrule_timed_sql_subset(p_rrule, p_all_day) then
    raise exception
      'rrule_timed_occurrence_starts: precondition violated (timed row with non-null instants and rrule_timed_sql_subset = true required)';
  end if;

  -- CLASS 2 -- data or environment drift. A zone that was storable when the row
  -- was written can stop resolving later, and a legacy M0 master carries none at
  -- all. Neither is a fault, and neither may take the anonymous Free/Busy RPC
  -- down, so this returns NO ROWS instead of raising.
  -- 0018: the zone guard is MEMBERSHIP in the caller's resolved list, not a
  -- fresh timezone_is_resolvable call (see the 0018 header). A NULL zone, a
  -- NULL or empty list, or a zone absent from it gives NO ROWS, exactly as an
  -- unresolvable zone did before.
  if p_timezone is null
     or not coalesce(p_timezone = any(p_resolvable_zones), false) then
    return;
  end if;

  -- Defence in depth: the caller also checks the cap, but a runaway loop here
  -- would be far worse than a loud error.
  -- 0018: the PRIVATE count, with the same list, so this defence-in-depth
  -- probe does not re-run zone validation.
  v_cnt := timeweave_private.rrule_timed_occurrence_count_in_zones(
             p_rrule, p_all_day, p_start_at, p_end_at, p_timezone, p_from, p_to,
             p_resolvable_zones);
  if v_cnt is null or v_cnt > public.rrule_timed_expansion_cap() then
    raise exception
      'rrule_timed_occurrence_starts: expansion cap exceeded (% candidates)', coalesce(v_cnt, -1);
  end if;

  select * into p from public.rrule_parse(p_rrule);

  v_n     := p.interval_n;
  v_durs  := extract(epoch from (p_end_at - p_start_at));
  v_dur   := make_interval(secs => v_durs::double precision);
  v_durd  := ceil(v_durs / 86400.0)::integer;
  v_dtl   := p_start_at at time zone p_timezone;
  v_d0    := v_dtl::date;
  v_tod0  := v_dtl::time;
  v_fromd := (p_from at time zone p_timezone)::date - 1;
  v_tod   := (p_to   at time zone p_timezone)::date + 1;
  if p.until_ts is not null then
    v_untild := (p.until_ts at time zone p_timezone)::date;
  end if;

  if p.freq = 'DAILY' then
    v_lo := greatest(0, floor((v_fromd - v_durd - v_d0)::numeric / v_n))::bigint;
    v_hi := floor((v_tod - v_d0)::numeric / v_n)::bigint;
    if v_untild is not null then
      v_hi := least(v_hi, floor((v_untild - v_d0)::numeric / v_n)::bigint);
    end if;
    if p.count_n is not null then
      v_hi := least(v_hi, (p.count_n - 1)::bigint);
    end if;

    for v_i in v_lo .. v_hi loop
      v_ord := v_i;   -- ordinal(i) = i
      v_cl := (v_d0 + (v_i * v_n)::integer) + v_tod0;
      -- DTSTART keeps its stored instant; see the header note on folds.
      if v_cl = v_dtl then
        v_start := p_start_at;
      else
        v_start := v_cl at time zone p_timezone;
      end if;
      if v_start >= p_start_at
         and (p.until_ts is null or v_start <= p.until_ts)
         and (p.count_n is null or (v_ord >= 0 and v_ord < p.count_n))
         and v_start < p_to
         and v_start + v_dur > p_from then
        return next v_start;
      end if;
    end loop;

  else
    -- WEEKLY. Offsets are 0 = Monday .. 6 = Sunday, matching the WEEKDAYS array
    -- order in src/types/recurrence.ts, and are SORTED ASCENDING.
    if p.byday is null then
      v_offs := array[ extract(isodow from v_d0)::integer - 1 ];
    else
      select array_agg(o.idx order by o.idx)
        into v_offs
      from (
        select array_position(array['MO','TU','WE','TH','FR','SA','SU'], tok) - 1 as idx
        from unnest(p.byday) as tok
      ) o;
    end if;
    v_k := array_length(v_offs, 1);
    -- DTSTART's weekday IN THE MASTER ZONE, like every other calendar field here.
    v_s := extract(isodow from v_d0)::integer - 1;
    select count(*) into v_pw0 from unnest(v_offs) as o where o >= v_s;

    v_w0 := v_d0 - (extract(isodow from v_d0)::integer - 1);
    v_lo := greatest(0, floor((v_fromd - v_durd - 7 - v_w0)::numeric / (7 * v_n)))::bigint;
    v_hi := (floor((v_tod - v_w0)::numeric / (7 * v_n)) + 1)::bigint;
    if v_untild is not null then
      v_hi := least(v_hi, floor((v_untild - v_w0)::numeric / (7 * v_n))::bigint);
    end if;
    if p.count_n is not null then
      if p.count_n <= v_pw0 then
        v_hi := least(v_hi, 0::bigint);
      else
        v_hi := least(v_hi, (1 + floor((p.count_n - 1 - v_pw0)::numeric / v_k))::bigint);
      end if;
    end if;

    for v_i in v_lo .. v_hi loop
      for v_j in 1 .. v_k loop
        v_off := v_offs[v_j];
        if v_i = 0 then
          v_ord := (v_j - 1) - (v_k - v_pw0);
        else
          v_ord := v_pw0 + (v_i - 1) * v_k + (v_j - 1);
        end if;
        v_cl := (v_w0 + (v_i * 7 * v_n + v_off)::integer) + v_tod0;
        if v_cl = v_dtl then
          v_start := p_start_at;
        else
          v_start := v_cl at time zone p_timezone;
        end if;
        if v_start >= p_start_at
           and (p.until_ts is null or v_start <= p.until_ts)
           and (p.count_n is null or (v_ord >= 0 and v_ord < p.count_n))
           and v_start < p_to
           and v_start + v_dur > p_from then
          return next v_start;
        end if;
      end loop;
    end loop;
  end if;

  return;
end;
$fn$;

-- ============================================================================
-- 3. public.rrule_timed_occurrence_count: same signature, attributes, owner and
--    ACL. A self-validating wrapper over section 1.
-- ============================================================================
create or replace function public.rrule_timed_occurrence_count(
  p_rrule    text,
  p_all_day  boolean,
  p_start_at timestamptz,
  p_end_at   timestamptz,
  p_timezone text,
  p_from     timestamptz,
  p_to       timestamptz
)
returns bigint
language plpgsql
stable
set search_path = ''
as $fn$
begin
  if p_all_day is not false then return null; end if;
  if p_start_at is null or p_end_at is null
     or p_from is null or p_to is null then
    return null;
  end if;
  -- Data drift, not a caller fault: a zone stored when it was valid can stop
  -- resolving. NULL is the fail-closed answer, and the caller's
  -- coalesce(count, cap + 1) rule turns it into complete=false. No exception
  -- handler is added anywhere below: an invalid_parameter_value that is NOT
  -- about the zone would be a programming fault and must stay visible.
  if p_timezone is null or not public.timezone_is_resolvable(p_timezone) then
    return null;
  end if;
  -- 0018: every check above is the pre-0018 body, verbatim and in order, so a
  -- direct caller is validated exactly as before. What follows the zone guard
  -- is the shared arithmetic, run with the one zone this call just resolved.
  return timeweave_private.rrule_timed_occurrence_count_in_zones(
           p_rrule, p_all_day, p_start_at, p_end_at, p_timezone, p_from, p_to,
           array[p_timezone]);
end;
$fn$;

-- ============================================================================
-- 4. public.rrule_timed_occurrence_starts: same signature, attributes, owner
--    and ACL. A self-validating wrapper over section 2.
-- ============================================================================
create or replace function public.rrule_timed_occurrence_starts(
  p_rrule    text,
  p_all_day  boolean,
  p_start_at timestamptz,
  p_end_at   timestamptz,
  p_timezone text,
  p_from     timestamptz,
  p_to       timestamptz
)
returns setof timestamptz
language plpgsql
stable
set search_path = ''
as $fn$
begin
  -- CLASS 1 -- caller wiring. Returning an empty set for these would be
  -- indistinguishable from "this series has no busy here", i.e. a silent
  -- false-free, so they fail loudly.
  if p_all_day is not false
     or p_start_at is null or p_end_at is null
     or p_from is null or p_to is null
     or not public.rrule_timed_sql_subset(p_rrule, p_all_day) then
    raise exception
      'rrule_timed_occurrence_starts: precondition violated (timed row with non-null instants and rrule_timed_sql_subset = true required)';
  end if;

  -- CLASS 2 -- data or environment drift. A zone that was storable when the row
  -- was written can stop resolving later, and a legacy M0 master carries none at
  -- all. Neither is a fault, and neither may take the anonymous Free/Busy RPC
  -- down, so this returns NO ROWS instead of raising.
  if p_timezone is null or not public.timezone_is_resolvable(p_timezone) then
    return;
  end if;
  -- 0018: CLASS 1 and CLASS 2 above are the pre-0018 body, verbatim and in
  -- order, so a direct caller is validated exactly as before. The cap probe and
  -- the expansion follow in the shared private body, run with the one zone this
  -- call just resolved; their exception texts are unchanged.
  return query
    select s.t
    from timeweave_private.rrule_timed_occurrence_starts_in_zones(
           p_rrule, p_all_day, p_start_at, p_end_at, p_timezone, p_from, p_to,
           array[p_timezone]) as s(t);
  return;
end;
$fn$;

-- ============================================================================
-- 5. get_free_busy: the 0009 body with exactly three changes -- the v_tz_all
--    declaration, step 2b (A1a), and the six timed helper calls (A1b), which
--    now go to the *_in_zones helpers with v_ok_tz. Signature, STABLE,
--    SECURITY DEFINER, search_path, owner and the anon/authenticated grant
--    from 0005 are unchanged (CREATE OR REPLACE keeps ownership and privileges).
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
stable
security definer
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
  where s.token_hash = encode(extensions.digest(p_token, 'sha256'), 'hex')
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
-- 6. EXECUTE. The two new functions: owner only, revoked explicitly from every
--    role that could otherwise hold it. Nothing is granted. Existing objects
--    keep their privileges and none are re-issued here.
-- ============================================================================
revoke all on function timeweave_private.rrule_timed_occurrence_count_in_zones(
  text, boolean, timestamptz, timestamptz, text, timestamptz, timestamptz, text[]
) from public, anon, authenticated, service_role;
revoke all on function timeweave_private.rrule_timed_occurrence_starts_in_zones(
  text, boolean, timestamptz, timestamptz, text, timestamptz, timestamptz, text[]
) from public, anon, authenticated, service_role;

commit;
