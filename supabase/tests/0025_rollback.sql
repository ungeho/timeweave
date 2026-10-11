-- ============================================================================
-- 0025 ROLLBACK -- restores the 0024 helper. NOT a test; run only to undo 0025.
--
-- ORDER IS NOT OPTIONAL, and this file is step 1 of two.
--
--   step 1 (this file)  put 0024's free_busy_available back.
--   step 2 (optional)   remove public.owner_settings and the trigger function.
--
-- Doing step 2 first BREAKS BUSY SHARING, not just Available. Measured: with
-- the 0025 helper still installed and the table gone, public.get_free_busy
-- raises 42P01 "relation public.owner_settings does not exist", and the whole
-- anonymous response fails -- the share page shows an error instead of the
-- owner's busy blocks. After step 1 the helper no longer names the table at
-- all, so step 2 becomes safe and, in fact, optional.
--
-- WHAT STEP 2 COSTS IF YOU SKIP IT. Leaving the table is not free, three ways:
--   * a deployed settings UI keeps saving values that now do nothing, so it
--     reports success for a setting with no effect. Roll the app back too, or
--     accept that.
--   * 0025_preflight gate D01 requires owner_settings NOT to exist, so a later
--     re-apply will FAIL that gate until the table is gone.
--   * the stored zones come back into force the moment 0025 is re-applied,
--     without the owner touching anything.
--
-- CREATE OR REPLACE preserves the owner and the ACL, so 0024's REVOKE (A04)
-- and the wrapper-owner EXECUTE (A14) are restored along with the body without
-- being restated here. The wrapper and the core are not touched by either step.
--
-- The body below is 0024's, copied verbatim. After running this, the helper's
-- CR-stripped md5 must read ac87ef2526ab12f0f7c4d8c2142bcbd0 again.
-- ============================================================================

begin;

create or replace function timeweave_private.free_busy_available(
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

commit;

-- Verify: this must print ac87ef2526ab12f0f7c4d8c2142bcbd0 and true.
select pg_catalog.md5(pg_catalog.replace(prosrc, E'\r','')) as helper_md5,
       (pg_catalog.md5(pg_catalog.replace(prosrc, E'\r',''))
         = 'ac87ef2526ab12f0f7c4d8c2142bcbd0') as restored_to_0024
from pg_catalog.pg_proc
where oid = to_regprocedure(
  'timeweave_private.free_busy_available(uuid, timestamptz, timestamptz, date, date, jsonb)');
