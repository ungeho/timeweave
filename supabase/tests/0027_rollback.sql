-- ============================================================================
-- 0027 ROLLBACK -- restores the 0025 helper and removes zoned_day_start.
-- NOT a test; run only to undo 0027, as the helper's owner (as 0027 itself).
--
-- ORDER IS NOT OPTIONAL. PL/pgSQL bodies are not dependency-tracked, so
-- DROP FUNCTION zoned_day_start would succeed while the 0027 helper still
-- calls it, and every cross-model Available request would then fail with
-- "function does not exist" (the 6b call is caught and turns into
-- indeterminate; 6c and 7B are not, and would fail the whole response).
-- So: step 1 puts 0025's body back, step 2 drops the function.
--
-- No data is touched by 0027 or by this file: no table, row, default or
-- share-link setting. CREATE OR REPLACE keeps the helper's owner and ACL.
-- Afterwards the helper's CR-stripped md5 reads 23f069bd792768f9279f5308e3edbaaf
-- again (0025 postflight F03), and 0025_postflight.sql passes again.
--
-- What rolling back gives up: R1-S comes back (docs/p8-datetime-contract.md
-- §10.3/§11) -- on doubled-midnight dates in an owner's zone, all-day Busy can
-- again let Available through in the first 00:xx hour.
-- ============================================================================

begin;

do $guard$
declare
  v_helper_owner text;
begin
  select pg_catalog.pg_get_userbyid(p.proowner) into v_helper_owner
  from pg_catalog.pg_proc p
  where p.oid = pg_catalog.to_regprocedure(
          'timeweave_private.free_busy_available(uuid, timestamptz, timestamptz, date, date, jsonb)');
  if v_helper_owner is distinct from current_user then
    raise exception '0027 rollback must run as % (owner of free_busy_available), not %',
      v_helper_owner, current_user;
  end if;
end
$guard$;

-- step 1: 0025's helper, copied verbatim from 0025_freebusy_crossmodel.sql
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
  -- 0025. Everything below this line is new; nothing above it moved.
  v_cross           boolean;
  v_tz              text;
  v_tz_ok           boolean;
  v_busy_d_t        tstzmultirange;   -- all-day Busy, converted to instants
  v_avail_d_rest    datemultirange;
  v_avail_t_rest    tstzmultirange;
  v_avail_d_keep    datemultirange;   -- all-day Available nothing timed touched
  -- INITIALISED AT DECLARATION, and that is load-bearing rather than tidy.
  -- Section 7 emits `v_avail_t_rest + v_avail_d_frag`, and multirange union
  -- with NULL is NULL -- so leaving this unset on the non-cross-model path
  -- silently erased every timed Available slot. The regression matrix caught
  -- it (timed Busy x timed Available returned 0 slots instead of 1), which is
  -- exactly what those cases are for: this branch is the one 0024 already
  -- handled correctly and must keep handling byte-identically.
  v_avail_d_frag    tstzmultirange := '{}'::tstzmultirange;  -- all-day Available that timed Busy bit into
  v_r_d             daterange;
  v_r_t             tstzrange;
  v_kept            tstzmultirange;
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


  -- 6. CROSS-MODEL. 0024 returned `indeterminate` here whenever both models
  --    carried material. This version asks for a zone FIRST, and only when the
  --    clash is real.
  --
  --    THE GUARD IS UNCHANGED IN SHAPE: the same presence test on the same four
  --    multiranges. What changes is what happens when it fires.
  --
  --    WHY "ONLY WHEN THE CLASH IS REAL" MATTERS. Timed Available against timed
  --    Busy, or all-day against all-day, never needed a zone and must not start
  --    needing one -- an owner who declares nothing has to keep the answers
  --    0024 gave them. So v_cross is computed before anything is read from
  --    owner_settings, and an owner with no row is refused only on the windows
  --    0024 refused too.
  v_cross := (v_avail_t <> '{}'::tstzmultirange and v_busy_d <> '{}'::datemultirange)
          or (v_avail_d <> '{}'::datemultirange and v_busy_t <> '{}'::tstzmultirange);

  if v_cross then
    -- 6a. The zone is the OWNER's declaration and nothing else.
    --
    --     NOT the viewer's. The client builds p_from as local midnight of
    --     p_from_date, so an offset could be read back out of the arguments.
    --     Doing that would hand the conversion zone to the caller: a viewer
    --     could claim an offset that slides an all-day Busy day off a timed
    --     Available block and have that block disclosed. The window is used for
    --     clipping and for nothing else, here as everywhere else in this file.
    --
    --     NOT inferred from the owner's timed recurrence masters either, though
    --     v_ok_tz is sitting right there. That set says which zones this server
    --     can resolve for expansion; it is not a statement by the owner about
    --     what their all-day events mean, and a wrong guess over-discloses by
    --     up to the offset difference.
    select s.timezone into v_tz
    from public.owner_settings s
    where s.owner_id = v_owner
    limit 1;

    -- Unset, blank, or unresolvable: answer exactly what 0024 answered. A value
    -- that passed the write-time trigger can still stop resolving if this
    -- server's tzdata changes, so it is re-checked here rather than trusted.
    if v_tz is null or btrim(v_tz) = ''
       or not public.timezone_is_resolvable(v_tz) then
      return c_indet;
    end if;

    -- 6b. Convert every date boundary this window needs, and REFUSE any that
    --     does not round-trip.
    --
    --     `d::timestamp at time zone Z` is the instant of local midnight on d.
    --     Where a DST jump lands on 00:00 that local time does not exist, and
    --     PostgreSQL resolves it forward instead of failing -- moving the
    --     boundary by an hour without saying so. Silent boundary motion is
    --     exactly what over-discloses, so the instant is sent back through the
    --     zone and required to name the original date. One comparison per
    --     boundary.
    --
    --     An AMBIGUOUS midnight (fall-back) does round-trip, since both
    --     candidate instants map back to the same local date, and is accepted:
    --     either choice names the same calendar day, which is all this
    --     conversion claims.
    begin
      select bool_and(
               ((b.d::timestamp at time zone v_tz) at time zone v_tz)::date = b.d)
        into v_tz_ok
      from (
        select lower(r) as d from unnest(v_busy_d)  as r
        union all select upper(r) from unnest(v_busy_d)  as r
        union all select lower(r) from unnest(v_avail_d) as r
        union all select upper(r) from unnest(v_avail_d) as r
      ) as b(d);
    exception
      when invalid_datetime_format or datetime_field_overflow
        or invalid_text_representation or invalid_parameter_value then
        return c_indet;
    end;

    if coalesce(v_tz_ok, true) is not true then
      return c_indet;
    end if;

    -- 6c. All-day BUSY as instants, built from the multirange the core handed
    --     over and never from the events table again -- so it cannot disagree
    --     with the Busy answer the same response is carrying.
    select coalesce(
             range_agg(tstzrange(lower(r)::timestamp at time zone v_tz,
                                 upper(r)::timestamp at time zone v_tz, '[)')),
             '{}'::tstzmultirange)
      into v_busy_d_t
    from unnest(v_busy_d) as r;
  end if;

  -- 7. Subtraction and emission.
  --
  --    SAME-MODEL FIRST, exactly as 0024 did, so a window that never reaches
  --    the cross-model branch produces identical bytes.
  v_avail_d_rest := v_avail_d - v_busy_d;
  v_avail_t_rest := v_avail_t - v_busy_t;

  if v_cross then
    -- (A) All-day Busy also removes timed Available. Without this, an owner
    --     blocked out for the whole of Thursday would still publish Thursday
    --     afternoon as open.
    v_avail_t_rest := v_avail_t_rest - v_busy_d_t;

    -- (B) Timed Busy against all-day Available, per U2. The day must not be
    --     published as all-day, but the hours the Busy block does not touch are
    --     genuinely open and are published as TIMED fragments. Dropping the
    --     whole day instead would spend twenty-four hours to pay for a
    --     one-minute meeting, which is why B-1 was rejected in the design.
    --
    --     SHAPE IS PRESERVED WHERE NOTHING TOUCHES IT. Each surviving all-day
    --     range is converted and trimmed; if the trim changed nothing it is
    --     emitted as all-day exactly as 0024 would have. Only a range that
    --     timed Busy actually bit into becomes fragments. Declaring a zone can
    --     therefore never reshape an answer that was already correct.
    --
    --     v_busy_d is NOT subtracted again here: the date-space subtraction
    --     above already removed those whole days, so the converted remainder
    --     and v_busy_d_t are disjoint by construction.
    v_avail_d_keep := '{}'::datemultirange;
    v_avail_d_frag := '{}'::tstzmultirange;

    for v_r_d in select u from unnest(v_avail_d_rest) as u loop
      v_r_t  := tstzrange(lower(v_r_d)::timestamp at time zone v_tz,
                          upper(v_r_d)::timestamp at time zone v_tz, '[)');
      v_kept := tstzmultirange(v_r_t) - v_busy_t;

      if v_kept = tstzmultirange(v_r_t) then
        v_avail_d_keep := v_avail_d_keep + datemultirange(v_r_d);
      else
        v_avail_d_frag := v_avail_d_frag + v_kept;
      end if;
    end loop;

    v_avail_d_rest := v_avail_d_keep;
  end if;

  --    Ordering repeats the core's: all-day first by date, timed second by
  --    instant, with a fixed rank. The emitted VALUES still carry no
  --    date -> timestamptz cast, so the wire format never depends on the
  --    session zone; the only conversions happened above, against a zone the
  --    owner declared.
  with d as (select r from unnest(v_avail_d_rest) as r),
       t as (select r from unnest(v_avail_t_rest + v_avail_d_frag) as r),
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


-- step 2: nothing calls it any more
drop function if exists timeweave_private.zoned_day_start(date, text);

commit;
