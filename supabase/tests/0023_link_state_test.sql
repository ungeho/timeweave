-- ============================================================================
-- 0023 RUNTIME SUITE -- anonymous link_state (U2)
-- ============================================================================
-- Run AFTER 0023_freebusy_link_state.sql is applied. Everything happens inside
-- one transaction and the file ends in ROLLBACK, so no fixture and no rate-
-- bucket row survives. The canonical auth.users row is never written to.
--
-- EDIT PER ENVIRONMENT: v_owner below must be a real auth.users id. Section 0
-- asserts that before anything else runs, because share_links.owner_id and
-- events.owner_id both carry a FK to auth.users (0004/0001) and a mistyped uuid
-- would otherwise surface as a confusing FK violation halfway through.
--
-- ROLES. Fixtures and core calls run as the migration owner. WRAPPER calls run
-- as `anon`, the role the share page actually reaches public.get_free_busy
-- with. PL/pgSQL has no SET statement, so set_config('role', ..., true) is used
-- and reset with 'none' on the very next line -- the device 0008's, 0021's and
-- 0022's suites all use. Reading timeweave_private.* must happen with the role
-- reset, or it fails on privileges rather than on the thing under test.
--
-- ============================================================================
-- RATE ASSERTIONS ARE BASELINE/DELTA, NOT EXISTENCE
--
-- ROLLBACK removes only what THIS transaction did. It does not erase committed
-- rate rows an earlier run left behind, and the owner is a shared test user, so
-- "a row exists" and "charged_calls > 0" prove nothing: they can be satisfied
-- entirely by history. Every rate assertion below therefore captures a baseline
-- with coalesce(..., 0) immediately before the calls it is about and asserts a
-- DELTA afterwards. Each proof lives in the same block as the calls it measures,
-- so no state has to survive between DO blocks.
--
-- Nothing here counts rows table-wide. The buckets are shared infrastructure and
-- may legitimately hold rows for links this suite has never heard of; every
-- assertion is scoped to the suite's own link ids and owner id.
--
-- ============================================================================
-- ACTIVE-CALL RATE BUDGET  (0019: link burst 15 / T=2s, owner burst 40 / T=1s)
--
-- Charges accumulate INSIDE this transaction even though the ROLLBACK discards
-- them, so a suite that calls the wrapper too often on one link refuses itself
-- with PT429 before reaching its real assertions.
--
--   wrapper calls attempted ........................... 23
--     reach charging (active) ......................... 13
--       L1 (timed / private / contract) ............... 7   (link budget 15)
--       L0 (include_private = false) .................. 1   (link budget 15)
--       L2 (all-day / exception / mixes) .............. 5   (link budget 15)
--     fail window validation BEFORE charging ........... 2  (section 12, 22023)
--     unavailable, return before the limiter ........... 8  (section 7)
--   owner bucket total charged ....................... 13   (owner budget 40)
--
-- Worst case is L1 at 7 charges = tat +14s against tau = 30s, and the owner at
-- 13 charges = +13s against tau = 40s. Both comfortably clear. If sections are
-- added later, recount this, and put new fixtures on a NEW link rather than
-- crowding an existing one.
--
-- ============================================================================
-- CONCURRENCY IS DELIBERATELY NOT RE-TESTED HERE
--
-- pg_try_advisory_xact_lock is re-entrant for the transaction that holds it, so
-- a single SQL session always acquires slot 1 and can never observe the k=2
-- exhaustion path. A "concurrency test" written here would pass unconditionally
-- and prove nothing. Section 12 asserts only that the CONFIGURATION is still 2;
-- the genuine concurrent behaviour remains 0019's evidence.
--
-- ============================================================================
-- U2 PHASE BOUNDARY: EXACTLY THREE KEYS
--
-- Sections 8 and 9 assert that both answers carry exactly link_state, complete
-- and slots. That is how we prove no Available work leaked in early. A later
-- migration (U3) is EXPECTED to supersede this by adding an Available key to
-- ACTIVE answers; at that point these assertions become historical in the same
-- way 0022's did. They are not to be weakened now.
--
-- ============================================================================
-- R1-R18 SEMANTIC COVERAGE
--
-- 0021_freebusy_busy_only_test.sql is FROZEN and, after 0023, is historical:
-- six of its assertions (R8 P1/P2, R11, R17, R18 A/B) require
-- wrapper JSONB = core JSONB, and U2 makes the wrapper answer
-- core || {"link_state":"active"}. R18.A further requires an all-available
-- calendar to answer exactly as an expired token does -- the identity U2 exists
-- to remove. Those files are not repaired.
--
-- The Busy semantics behind R1-R18 are re-expressed here. ALL-DAY IS EXERCISED
-- ON THE ACTUAL ALL-DAY PATH: start_date/end_date and recurrence_slot_date, not
-- a timed sibling. The two shapes use different columns, a different exception
-- key and a different slot representation, so a timed test cannot stand in for
-- an all-day one.
--
--   R1  timed single, busy/available ....................... 5.1   EXACT
--   R2  all-day single, busy/available ..................... 5.2   EXACT
--   R3  timed expandable master ............................ 5.3   EXACT
--   R4  all-day expandable master (adjacent spans merge) ... 5.4   EXACT
--   R5  timed exception snapshot in isolation .............. 5.5   EXACT
--   R6  all-day exception snapshot in isolation ............ 5.6   EXACT
--   R7  completeness (A), unexpandable busy master ......... 5.7   EXACT
--   R8  completeness (B), shape-mismatched exception ....... FINGERPRINT_ONLY
--   R9  completeness (C), unexpandable available master .... 5.7   EXACT
--   R10 slot-mismatch CTE (3d) ............................. FINGERPRINT_ONLY
--   R11 busy timed master + AVAILABLE timed exception ...... 5.8   EXACT
--   R12 busy all-day master + AVAILABLE all-day exception .. 5.9   EXACT
--   R13 mismatched slot on an AVAILABLE exception .......... FINGERPRINT_ONLY
--   R14 AVAILABLE timed master + BUSY timed exception ...... 5.12  EXACT
--   R15 AVAILABLE all-day master + BUSY all-day exception .. 5.13  EXACT
--   R16 cancelled exception is availability-independent .... 5.10  EXACT
--   R17 private x availability x include_private ........... 5.11  EXACT
--   R18 public wrapper contract ............................ 6, 5.1 EQUIVALENT
--
-- R8, R10 and R13 are FINGERPRINT_ONLY and are NOT claimed as behavioural
-- coverage. Each asserts on an internal branch of free_busy_core (a
-- shape-mismatched exception, the slot-mismatch CTE) that produces no distinct
-- wrapper-visible answer, so there is nothing for a wrapper-level test to
-- observe. 0023 does not modify the core, and 0023_postflight.sql C01 gates its
-- body md5 byte-for-byte. That proves the CODE IS IDENTICAL. It is not the same
-- thing as executing those branches, and it is not described as such.
-- ============================================================================

begin;

-- ============================================================================
-- Section 0. The owner must exist BEFORE anything is inserted.
-- ============================================================================
do $$
declare
  v_owner constant uuid := '5e86935f-7661-4741-868f-0f51c4cf1727';  -- <<< EDIT per environment
  v_exists boolean;
begin
  select exists(select 1 from auth.users u where u.id = v_owner) into v_exists;
  assert v_exists,
    format('0.0 the test owner %s does not exist in auth.users. Create the test '
           'user first, or edit v_owner in every section of this file. This '
           'suite never inserts into, updates or deletes auth.users.', v_owner);

  select count(*) = 0 into v_exists from public.events e where e.owner_id = v_owner;
  assert v_exists, '0.1 the test owner must start with no events';

  select count(*) = 0 into v_exists from public.share_links s where s.owner_id = v_owner;
  assert v_exists, '0.2 the test owner must start with no share links';

  raise notice 'Section 0 OK: owner exists, no leftover fixtures';
end $$;


-- ============================================================================
-- Section 1. Links.
--
--   L1  include_private = true   timed, private and wrapper-contract sections
--   L0  include_private = false  R17 only
--   L2  include_private = true   all-day, exception and mixed sections
--   LE  expired        LR  revoked        LD  deleted below
--
-- Three active links rather than one so no single link approaches 0019's burst
-- of 15; see the budget in the header.
--
-- Tokens are plain text here and hashed on the way in, exactly as 0005 stores
-- them. They never leave this transaction.
--
-- The expired link's created_at is pushed back two days: 0014's
-- share_links_expiry_after_created CHECK requires expires_at > created_at, and
-- now() is frozen for the whole transaction, so an expiry in the past cannot
-- also be after a created_at of "now".
--
-- 0016's share_links_rate_ai does not fire for these: it returns early when
-- auth.uid() is null, and these inserts carry no JWT claims.
-- ============================================================================
insert into public.share_links
  (id, owner_id, token_hash, label, include_private, expires_at, revoked_at, created_at)
values
  ('0023b001-0000-4000-8000-000000000001',
   '5e86935f-7661-4741-868f-0f51c4cf1727',
   encode(extensions.digest('tw-0023-active-include-private-true','sha256'),'hex'),
   '0023 active (include_private=true)',  true,  null, null, now()),
  ('0023b001-0000-4000-8000-000000000000',
   '5e86935f-7661-4741-868f-0f51c4cf1727',
   encode(extensions.digest('tw-0023-active-include-private-false','sha256'),'hex'),
   '0023 active (include_private=false)', false, null, null, now()),
  ('0023b001-0000-4000-8000-000000000002',
   '5e86935f-7661-4741-868f-0f51c4cf1727',
   encode(extensions.digest('tw-0023-active-allday','sha256'),'hex'),
   '0023 active (all-day sections)',      true,  null, null, now()),
  ('0023b001-0000-4000-8000-0000000000e0',
   '5e86935f-7661-4741-868f-0f51c4cf1727',
   encode(extensions.digest('tw-0023-expired','sha256'),'hex'),
   '0023 expired', true, now() - interval '1 day', null, now() - interval '2 days'),
  ('0023b001-0000-4000-8000-0000000000e1',
   '5e86935f-7661-4741-868f-0f51c4cf1727',
   encode(extensions.digest('tw-0023-revoked','sha256'),'hex'),
   '0023 revoked', true, null, now(), now()),
  ('0023b001-0000-4000-8000-0000000000e2',
   '5e86935f-7661-4741-868f-0f51c4cf1727',
   encode(extensions.digest('tw-0023-to-be-deleted','sha256'),'hex'),
   '0023 deleted', true, null, null, now());

do $$
declare
  v_n bigint;
begin
  select count(*) into v_n from public.share_links s
   where s.owner_id = '5e86935f-7661-4741-868f-0f51c4cf1727';
  assert v_n = 6, format('1.1 expected exactly six suite links, found %s', v_n);

  -- The deleted case must be a link that genuinely no longer exists.
  delete from public.share_links where id = '0023b001-0000-4000-8000-0000000000e2';
  select count(*) into v_n from public.share_links s
   where s.owner_id = '5e86935f-7661-4741-868f-0f51c4cf1727';
  assert v_n = 5, format('1.2 after deleting one link, five must remain, found %s', v_n);

  raise notice 'Section 1 OK: five live links, one deleted';
end $$;


-- ============================================================================
-- BLOCK A -- sections 2, 5.1, 5.7, 5.11, 6, 8.
-- Timed events, private visibility, the wrapper contract, and the ACTIVE
-- charging proof for L1 and L0.
-- ============================================================================
do $$
declare
  v_owner constant uuid := '5e86935f-7661-4741-868f-0f51c4cf1727';
  v_l1    constant uuid := '0023b001-0000-4000-8000-000000000001';
  v_l0    constant uuid := '0023b001-0000-4000-8000-000000000000';
  v_t1    constant text := 'tw-0023-active-include-private-true';
  v_t0    constant text := 'tw-0023-active-include-private-false';
  v_from  constant timestamptz := timestamptz '2026-06-01 00:00:00+00';
  v_to    constant timestamptz := timestamptz '2026-06-08 00:00:00+00';
  v_fd    constant date := date '2026-06-01';
  v_td    constant date := date '2026-06-08';
  v_a     constant uuid := '0023c001-0000-4000-8000-00000000000a';
  v_b     constant uuid := '0023c001-0000-4000-8000-00000000000b';
  v_m     constant uuid := '0023c001-0000-4000-8000-00000000000c';
  -- Rate baselines, captured BEFORE the first wrapper call in this block.
  b_l1    bigint;
  b_l0    bigint;
  b_own   bigint;
  b_own_tat timestamptz;
  v_core  jsonb;
  v_wrap  jsonb;
  v_n     bigint;
begin
  select coalesce((select w.charged_calls from timeweave_private.freebusy_link_rate w
                    where w.link_id = v_l1), 0) into b_l1;
  select coalesce((select w.charged_calls from timeweave_private.freebusy_link_rate w
                    where w.link_id = v_l0), 0) into b_l0;
  select coalesce((select w.charged_calls from timeweave_private.freebusy_owner_rate w
                    where w.owner_id = v_owner), 0) into b_own;
  select (select w.tat from timeweave_private.freebusy_owner_rate w
           where w.owner_id = v_owner) into b_own_tat;

  -------------------------------------------------------------------- 2. empty
  raise notice 'Section 2: active link, empty window';
  perform set_config('role', 'anon', true);
  v_wrap := public.get_free_busy(v_t1, v_from, v_to, v_fd, v_td);   -- L1 #1
  perform set_config('role', 'none', true);

  assert v_wrap = jsonb_build_object('link_state','active','complete',true,
                                     'slots','[]'::jsonb),
    '2.1 an active link with nothing in the window must answer active/empty, got '
    || v_wrap::text;
  assert v_wrap->>'link_state' = 'active',
    '2.2 link_state must be active even when nothing is disclosed; that is the
     distinction U2 exists to make. Got ' || v_wrap::text;

  --------------------------------------------------- 5.1 (R1) timed, busy/avail
  raise notice 'Section 5.1 (R1): timed single event, busy vs available';
  insert into public.events (id, owner_id, title, visibility, all_day, start_at, end_at, availability)
  values (v_a, v_owner, '', 'busy_only', false,
          timestamptz '2026-06-02 09:00:00+00', timestamptz '2026-06-02 10:00:00+00', 'busy');

  v_core := timeweave_private.free_busy_core(v_l1, v_from, v_to, v_fd, v_td);
  perform set_config('role', 'anon', true);
  v_wrap := public.get_free_busy(v_t1, v_from, v_to, v_fd, v_td);   -- L1 #2
  perform set_config('role', 'none', true);

  assert (v_wrap->>'complete')::boolean = true, '5.1 complete, got ' || v_wrap::text;
  assert jsonb_array_length(v_wrap->'slots') = 1,
    format('5.1 expected exactly one slot, got %s', jsonb_array_length(v_wrap->'slots'));
  assert v_wrap->'slots'->0 = jsonb_build_object(
           'all_day', false,
           'start', to_jsonb(timestamptz '2026-06-02 09:00:00+00'),
           'end',   to_jsonb(timestamptz '2026-06-02 10:00:00+00')),
    '5.1 the busy interval must be the event itself, got ' || (v_wrap->'slots'->0)::text;
  -- R18.B's invariant in its U2 form.
  assert v_wrap = v_core || jsonb_build_object('link_state','active'),
    '5.1/R18.B the wrapper must be exactly core || link_state=active. core='
    || v_core::text || ' wrapper=' || v_wrap::text;

  update public.events set availability = 'available' where id = v_a;
  perform set_config('role', 'anon', true);
  v_wrap := public.get_free_busy(v_t1, v_from, v_to, v_fd, v_td);   -- L1 #3
  perform set_config('role', 'none', true);
  assert v_wrap = jsonb_build_object('link_state','active','complete',true,
                                     'slots','[]'::jsonb),
    '5.1/R1.P2 an available single timed event must disclose nothing, got ' || v_wrap::text;
  -- R18.A ADAPTED: an all-available calendar still discloses nothing, but it is
  -- no longer indistinguishable from an expired token. Section 7 pins the other
  -- side of that distinction.
  assert v_wrap->>'link_state' = 'active',
    '5.1/R18.A an all-available calendar is still an ACTIVE link, got ' || v_wrap::text;
  delete from public.events where id = v_a;

  ------------------------------------------------- 5.7 (R7,R9) completeness
  raise notice 'Section 5.7 (R7,R9): completeness with an unexpandable master';
  -- FREQ=MONTHLY is the documented unexpandable case (Phase 5b residue).
  insert into public.events (id, owner_id, title, visibility, all_day, start_at, end_at,
                             rrule, timezone, availability)
  values (v_m, v_owner, '', 'busy_only', false,
          timestamptz '2026-06-02 09:00:00+00', timestamptz '2026-06-02 10:00:00+00',
          'FREQ=MONTHLY', 'UTC', 'busy');

  perform set_config('role', 'anon', true);
  v_wrap := public.get_free_busy(v_t1, v_from, v_to, v_fd, v_td);   -- L1 #4
  perform set_config('role', 'none', true);
  assert (v_wrap->>'complete')::boolean = false,
    '5.7/R7 an unexpandable BUSY master must make the answer incomplete, got '
    || v_wrap::text;
  assert v_wrap->>'link_state' = 'active',
    '5.7 an incomplete answer is still an ACTIVE link, got ' || v_wrap::text;

  update public.events set availability = 'available' where id = v_m;
  perform set_config('role', 'anon', true);
  v_wrap := public.get_free_busy(v_t1, v_from, v_to, v_fd, v_td);   -- L1 #5
  perform set_config('role', 'none', true);
  assert v_wrap = jsonb_build_object('link_state','active','complete',true,
                                     'slots','[]'::jsonb),
    '5.7/R9 an unexpandable AVAILABLE master must leave the answer complete and empty, got '
    || v_wrap::text;
  delete from public.events where id = v_m;

  ------------------------------- 5.11 (R17) private x avail x include_private
  raise notice 'Section 5.11 (R17): private x availability x include_private';
  insert into public.events (id, owner_id, title, visibility, all_day, start_at, end_at, availability)
  values (v_a, v_owner, '', 'private', false,
          timestamptz '2026-06-02 09:00:00+00', timestamptz '2026-06-02 10:00:00+00', 'busy'),
         (v_b, v_owner, '', 'private', false,
          timestamptz '2026-06-05 09:00:00+00', timestamptz '2026-06-05 10:00:00+00', 'available');

  -- O1: include_private = false removes BOTH rows.
  perform set_config('role', 'anon', true);
  v_wrap := public.get_free_busy(v_t0, v_from, v_to, v_fd, v_td);   -- L0 #1
  perform set_config('role', 'none', true);
  assert v_wrap = jsonb_build_object('link_state','active','complete',true,
                                     'slots','[]'::jsonb),
    '5.11/R17.O1 include_private=false must disclose no private row at all, got '
    || v_wrap::text;

  -- O2: include_private = true admits the BUSY private row only.
  v_core := timeweave_private.free_busy_core(v_l1, v_from, v_to, v_fd, v_td);
  perform set_config('role', 'anon', true);
  v_wrap := public.get_free_busy(v_t1, v_from, v_to, v_fd, v_td);   -- L1 #6
  perform set_config('role', 'none', true);
  assert jsonb_array_length(v_wrap->'slots') = 1,
    format('5.11/R17.O2 exactly the busy private row must appear, got %s slot(s): %s',
           jsonb_array_length(v_wrap->'slots'), v_wrap::text);
  assert v_wrap->'slots'->0 = jsonb_build_object(
           'all_day', false,
           'start', to_jsonb(timestamptz '2026-06-02 09:00:00+00'),
           'end',   to_jsonb(timestamptz '2026-06-02 10:00:00+00')),
    '5.11/R17.O2 the disclosed row must be the BUSY one, got ' || (v_wrap->'slots'->0)::text;
  assert v_wrap = v_core || jsonb_build_object('link_state','active'),
    '5.11/R17 wrapper must be core || link_state=active, got ' || v_wrap::text;
  delete from public.events where id in (v_a, v_b);

  ------------------------------------- 6 + 8. wrapper/core, three-key boundary
  raise notice 'Section 6 (R18) and 8: wrapper = core || link_state=active';
  insert into public.events (id, owner_id, title, visibility, all_day, start_at, end_at, availability)
  values (v_a, v_owner, '', 'busy_only', false,
          timestamptz '2026-06-04 13:00:00+00', timestamptz '2026-06-04 14:30:00+00', 'busy');

  v_core := timeweave_private.free_busy_core(v_l1, v_from, v_to, v_fd, v_td);
  perform set_config('role', 'anon', true);
  v_wrap := public.get_free_busy(v_t1, v_from, v_to, v_fd, v_td);   -- L1 #7
  perform set_config('role', 'none', true);

  assert v_wrap = v_core || jsonb_build_object('link_state','active'),
    '6.1 wrapper must equal core || link_state=active. core=' || v_core::text
    || ' wrapper=' || v_wrap::text;
  assert v_wrap - 'link_state' = v_core,
    '6.2 stripping link_state must give back the core answer exactly, got '
    || (v_wrap - 'link_state')::text;
  assert v_wrap->'complete' = v_core->'complete' and v_wrap->'slots' = v_core->'slots',
    '6.3 the wrapper must not reshape complete or slots';

  select count(*) into v_n from jsonb_object_keys(v_wrap) k;
  assert v_n = 3, format('8.1 an active answer must carry exactly three keys, got %s: %s',
                         v_n, v_wrap::text);
  assert v_wrap ? 'link_state' and v_wrap ? 'complete' and v_wrap ? 'slots',
    '8.2 the three keys must be link_state, complete and slots, got ' || v_wrap::text;
  assert not (v_wrap ? 'available') and not (v_wrap ? 'reason')
     and not (v_wrap ? 'status')    and not (v_wrap ? 'share_available'),
    '8.3 U2 must publish no Available, reason, status or share_available key, got '
    || v_wrap::text;
  delete from public.events where id = v_a;

  ------------------------------------------- ACTIVE CHARGING PROOF (block A)
  -- Seven charged calls on L1, one on L0, eight on the owner bucket. Asserted as
  -- DELTAS against the baselines captured at the top of this block, so the proof
  -- holds on a database that already carries committed rows for this owner.
  select coalesce((select w.charged_calls from timeweave_private.freebusy_link_rate w
                    where w.link_id = v_l1), 0) - b_l1 into v_n;
  assert v_n = 7,
    format('10A.1 L1 must have been charged exactly 7 times in this block, delta=%s', v_n);

  select coalesce((select w.charged_calls from timeweave_private.freebusy_link_rate w
                    where w.link_id = v_l0), 0) - b_l0 into v_n;
  assert v_n = 1,
    format('10A.2 L0 must have been charged exactly once, delta=%s', v_n);

  select coalesce((select w.charged_calls from timeweave_private.freebusy_owner_rate w
                    where w.owner_id = v_owner), 0) - b_own into v_n;
  assert v_n = 8,
    format('10A.3 the owner bucket must have been charged 8 times, delta=%s', v_n);

  -- tat must have MOVED FORWARD too: charged_calls alone would not catch a
  -- limiter that counted calls but stopped advancing the theoretical arrival
  -- time, which is the value the refusal decision actually reads.
  assert (select w.tat from timeweave_private.freebusy_owner_rate w
           where w.owner_id = v_owner) > coalesce(b_own_tat, '-infinity'::timestamptz),
    '10A.4 the owner tat must have advanced, not merely the call counter';

  select count(*) into v_n from public.events e where e.owner_id = v_owner;
  assert v_n = 0, format('Block A cleanup: %s event(s) left behind', v_n);
  raise notice 'Block A OK (sections 2, 5.1, 5.7, 5.11, 6, 8 + active charging proof)';
end $$;


-- ============================================================================
-- BLOCK B -- sections 5.2-5.6, 5.8-5.10, 5.12, 5.13.
--
-- All-day events, recurrence, exception snapshots and the master x exception
-- availability mixes. ALL-DAY USES THE REAL ALL-DAY COLUMNS: start_date and
-- end_date with start_at/end_at NULL (events_time_shape, 0013), and all-day
-- exceptions key on recurrence_slot_date (events_exception_slot, 0001). A timed
-- fixture cannot stand in for any of these.
-- ============================================================================
do $$
declare
  v_owner constant uuid := '5e86935f-7661-4741-868f-0f51c4cf1727';
  v_l2    constant uuid := '0023b001-0000-4000-8000-000000000002';
  v_t2    constant text := 'tw-0023-active-allday';
  v_from  constant timestamptz := timestamptz '2026-06-01 00:00:00+00';
  v_to    constant timestamptz := timestamptz '2026-06-08 00:00:00+00';
  v_fd    constant date := date '2026-06-01';
  v_td    constant date := date '2026-06-08';
  v_ad    constant uuid := '0023c002-0000-4000-8000-000000000001';  -- all-day single
  v_tm    constant uuid := '0023c002-0000-4000-8000-000000000002';  -- timed master
  v_am    constant uuid := '0023c002-0000-4000-8000-000000000003';  -- all-day master
  v_tx    constant uuid := '0023c002-0000-4000-8000-000000000004';  -- timed exception
  v_ax    constant uuid := '0023c002-0000-4000-8000-000000000005';  -- all-day exception
  b_l2    bigint;
  v_core  jsonb;
  v_wrap  jsonb;
  v_n     bigint;
begin
  select coalesce((select w.charged_calls from timeweave_private.freebusy_link_rate w
                    where w.link_id = v_l2), 0) into b_l2;

  --------------------------------------------- 5.2 (R2) all-day single event
  raise notice 'Section 5.2 (R2): all-day single event, busy vs available';
  insert into public.events (id, owner_id, title, visibility, all_day, start_date, end_date, availability)
  values (v_ad, v_owner, '', 'busy_only', true, date '2026-06-03', date '2026-06-04', 'busy');

  perform set_config('role', 'anon', true);
  v_wrap := public.get_free_busy(v_t2, v_from, v_to, v_fd, v_td);   -- L2 #1
  perform set_config('role', 'none', true);
  assert (v_wrap->>'complete')::boolean = true, '5.2 complete, got ' || v_wrap::text;
  assert jsonb_array_length(v_wrap->'slots') = 1,
    format('5.2/R2.P1 expected exactly one span, got %s', jsonb_array_length(v_wrap->'slots'));
  assert v_wrap->'slots'->0 = jsonb_build_object(
           'all_day', true,
           'start_date', to_jsonb(date '2026-06-03'),
           'end_date',   to_jsonb(date '2026-06-04')),
    '5.2/R2.P1 the span must be the all-day event itself (end_date exclusive), got '
    || (v_wrap->'slots'->0)::text;
  assert v_wrap->>'link_state' = 'active', '5.2 link_state, got ' || v_wrap::text;

  update public.events set availability = 'available' where id = v_ad;
  v_core := timeweave_private.free_busy_core(v_l2, v_from, v_to, v_fd, v_td);
  assert v_core = '{"complete": true, "slots": []}'::jsonb,
    '5.2/R2.P2 an available all-day event must disclose nothing, got ' || v_core::text;
  delete from public.events where id = v_ad;

  -------------------------------------------- 5.3 (R3) timed expandable master
  raise notice 'Section 5.3 (R3): timed expandable master, busy vs available';
  insert into public.events (id, owner_id, title, visibility, all_day, start_at, end_at,
                             rrule, timezone, availability)
  values (v_tm, v_owner, '', 'busy_only', false,
          timestamptz '2026-06-02 09:00:00+00', timestamptz '2026-06-02 10:00:00+00',
          'FREQ=DAILY;COUNT=3', 'UTC', 'busy');

  v_core := timeweave_private.free_busy_core(v_l2, v_from, v_to, v_fd, v_td);
  assert (v_core->>'complete')::boolean = true, '5.3 complete, got ' || v_core::text;
  assert jsonb_array_length(v_core->'slots') = 3,
    format('5.3/R3.P1 expected three occurrences, got %s', jsonb_array_length(v_core->'slots'));
  assert v_core->'slots'->0 = jsonb_build_object(
           'all_day', false,
           'start', to_jsonb(timestamptz '2026-06-02 09:00:00+00'),
           'end',   to_jsonb(timestamptz '2026-06-02 10:00:00+00')),
    '5.3/R3.P1 slot 0, got ' || (v_core->'slots'->0)::text;

  update public.events set availability = 'available' where id = v_tm;
  v_core := timeweave_private.free_busy_core(v_l2, v_from, v_to, v_fd, v_td);
  assert v_core = '{"complete": true, "slots": []}'::jsonb,
    '5.3/R3.P2 an available timed master must generate nothing AND stay complete, got '
    || v_core::text;
  delete from public.events where id = v_tm;

  ------------------------------------------ 5.4 (R4) all-day expandable master
  raise notice 'Section 5.4 (R4): all-day expandable master, busy vs available';
  -- Occurrences on 06-02, 06-03, 06-04, each [d, d+1) -- adjacent, so they
  -- collapse to the single span [06-02, 06-05). An implementation that failed to
  -- stop the series would run on to the window edge instead.
  insert into public.events (id, owner_id, title, visibility, all_day, start_date, end_date,
                             rrule, availability)
  values (v_am, v_owner, '', 'busy_only', true,
          date '2026-06-02', date '2026-06-03', 'FREQ=DAILY;COUNT=3', 'busy');

  perform set_config('role', 'anon', true);
  v_wrap := public.get_free_busy(v_t2, v_from, v_to, v_fd, v_td);   -- L2 #2
  perform set_config('role', 'none', true);
  assert (v_wrap->>'complete')::boolean = true, '5.4 complete, got ' || v_wrap::text;
  assert jsonb_array_length(v_wrap->'slots') = 1,
    format('5.4/R4.P1 three adjacent all-day occurrences must merge into one span, got %s',
           jsonb_array_length(v_wrap->'slots'));
  assert v_wrap->'slots'->0 = jsonb_build_object(
           'all_day', true,
           'start_date', to_jsonb(date '2026-06-02'),
           'end_date',   to_jsonb(date '2026-06-05')),
    '5.4/R4.P1 the merged span must END at 06-05, got ' || (v_wrap->'slots'->0)::text;

  update public.events set availability = 'available' where id = v_am;
  v_core := timeweave_private.free_busy_core(v_l2, v_from, v_to, v_fd, v_td);
  assert v_core = '{"complete": true, "slots": []}'::jsonb,
    '5.4/R4.P2 an available all-day master must generate nothing AND stay complete, got '
    || v_core::text;
  delete from public.events where id = v_am;

  ------------------------------------ 5.5 (R5) timed exception in isolation
  raise notice 'Section 5.5 (R5): timed exception snapshot in isolation';
  insert into public.events (id, owner_id, title, visibility, all_day, start_at, end_at,
                             rrule, timezone, availability)
  values (v_tm, v_owner, '', 'busy_only', false,
          timestamptz '2026-05-20 09:00:00+00', timestamptz '2026-05-20 10:00:00+00',
          'FREQ=DAILY;COUNT=3', 'UTC', 'busy');
  insert into public.events (id, owner_id, title, visibility, all_day, start_at, end_at,
                             recurrence_id, recurrence_slot_start, is_cancelled, availability)
  values (v_tx, v_owner, '', 'busy_only', false,
          timestamptz '2026-06-03 14:00:00+00', timestamptz '2026-06-03 15:00:00+00',
          v_tm, timestamptz '2026-05-21 09:00:00+00', false, 'busy');

  v_core := timeweave_private.free_busy_core(v_l2, v_from, v_to, v_fd, v_td);
  assert jsonb_array_length(v_core->'slots') = 1,
    format('5.5/R5.P1 only the exception snapshot may reach this window, got %s',
           jsonb_array_length(v_core->'slots'));
  assert v_core->'slots'->0 = jsonb_build_object(
           'all_day', false,
           'start', to_jsonb(timestamptz '2026-06-03 14:00:00+00'),
           'end',   to_jsonb(timestamptz '2026-06-03 15:00:00+00')),
    '5.5/R5.P1 the snapshot itself, got ' || (v_core->'slots'->0)::text;

  -- The SNAPSHOT's own availability decides, not the master's.
  update public.events set availability = 'available' where id = v_tx;
  v_core := timeweave_private.free_busy_core(v_l2, v_from, v_to, v_fd, v_td);
  assert v_core = '{"complete": true, "slots": []}'::jsonb,
    '5.5/R5.P2 an available timed exception snapshot must disclose nothing, got '
    || v_core::text;
  delete from public.events where id = v_tx;
  delete from public.events where id = v_tm;

  ---------------------------------- 5.6 (R6) all-day exception in isolation
  raise notice 'Section 5.6 (R6): all-day exception snapshot in isolation';
  -- The real all-day exception path: all-day master, all-day snapshot, and the
  -- slot keyed by recurrence_slot_DATE. The timed case above cannot exercise
  -- this: different columns, different slot key, different slot shape out.
  insert into public.events (id, owner_id, title, visibility, all_day, start_date, end_date,
                             rrule, availability)
  values (v_am, v_owner, '', 'busy_only', true,
          date '2026-05-20', date '2026-05-21', 'FREQ=DAILY;COUNT=3', 'busy');
  insert into public.events (id, owner_id, title, visibility, all_day, start_date, end_date,
                             recurrence_id, recurrence_slot_date, is_cancelled, availability)
  values (v_ax, v_owner, '', 'busy_only', true,
          date '2026-06-04', date '2026-06-05',
          v_am, date '2026-05-21', false, 'busy');

  perform set_config('role', 'anon', true);
  v_wrap := public.get_free_busy(v_t2, v_from, v_to, v_fd, v_td);   -- L2 #3
  perform set_config('role', 'none', true);
  assert jsonb_array_length(v_wrap->'slots') = 1,
    format('5.6/R6.P1 only the all-day snapshot may reach this window, got %s',
           jsonb_array_length(v_wrap->'slots'));
  assert v_wrap->'slots'->0 = jsonb_build_object(
           'all_day', true,
           'start_date', to_jsonb(date '2026-06-04'),
           'end_date',   to_jsonb(date '2026-06-05')),
    '5.6/R6.P1 the all-day snapshot itself, got ' || (v_wrap->'slots'->0)::text;

  update public.events set availability = 'available' where id = v_ax;
  v_core := timeweave_private.free_busy_core(v_l2, v_from, v_to, v_fd, v_td);
  assert v_core = '{"complete": true, "slots": []}'::jsonb,
    '5.6/R6.P2 an available ALL-DAY exception snapshot must disclose nothing, got '
    || v_core::text;
  delete from public.events where id = v_ax;
  delete from public.events where id = v_am;

  ------------------- 5.8 (R11) busy TIMED master + AVAILABLE timed exception
  raise notice 'Section 5.8 (R11): busy timed master + available timed exception';
  -- The master's occurrences fall INSIDE the window on purpose: 06-02, 06-03 and
  -- 06-04. The exception overrides the 06-03 slot and is available. A correct
  -- implementation therefore discloses 06-02 and 06-04 and suppresses 06-03.
  --
  -- Asserting only "0 slots" here would be vacuous -- it would also pass if the
  -- implementation dropped EVERY occurrence. The count and both surviving
  -- intervals are checked, so this fails in either direction.
  insert into public.events (id, owner_id, title, visibility, all_day, start_at, end_at,
                             rrule, timezone, availability)
  values (v_tm, v_owner, '', 'busy_only', false,
          timestamptz '2026-06-02 09:00:00+00', timestamptz '2026-06-02 10:00:00+00',
          'FREQ=DAILY;COUNT=3', 'UTC', 'busy');
  insert into public.events (id, owner_id, title, visibility, all_day, start_at, end_at,
                             recurrence_id, recurrence_slot_start, is_cancelled, availability)
  values (v_tx, v_owner, '', 'busy_only', false,
          timestamptz '2026-06-03 09:00:00+00', timestamptz '2026-06-03 10:00:00+00',
          v_tm, timestamptz '2026-06-03 09:00:00+00', false, 'available');

  perform set_config('role', 'anon', true);
  v_wrap := public.get_free_busy(v_t2, v_from, v_to, v_fd, v_td);   -- L2 #4
  perform set_config('role', 'none', true);
  assert (v_wrap->>'complete')::boolean = true, '5.8 complete, got ' || v_wrap::text;
  assert jsonb_array_length(v_wrap->'slots') = 2,
    format('5.8/R11 the available exception must suppress ONLY its own occurrence: '
           'expected 2 surviving slots (06-02 and 06-04), got %s -- %s',
           jsonb_array_length(v_wrap->'slots'), (v_wrap->'slots')::text);
  assert v_wrap->'slots'->0 = jsonb_build_object(
           'all_day', false,
           'start', to_jsonb(timestamptz '2026-06-02 09:00:00+00'),
           'end',   to_jsonb(timestamptz '2026-06-02 10:00:00+00')),
    '5.8/R11 the first surviving occurrence must be 06-02, got ' || (v_wrap->'slots'->0)::text;
  assert v_wrap->'slots'->1 = jsonb_build_object(
           'all_day', false,
           'start', to_jsonb(timestamptz '2026-06-04 09:00:00+00'),
           'end',   to_jsonb(timestamptz '2026-06-04 10:00:00+00')),
    '5.8/R11 the second surviving occurrence must be 06-04, got ' || (v_wrap->'slots'->1)::text;

  ------------------------------- 5.12 (R14) AVAILABLE master + BUSY exception
  raise notice 'Section 5.12 (R14): available timed master + busy timed exception';
  update public.events set availability = 'available' where id = v_tm;
  update public.events set availability = 'busy'      where id = v_tx;
  v_core := timeweave_private.free_busy_core(v_l2, v_from, v_to, v_fd, v_td);
  assert jsonb_array_length(v_core->'slots') = 1,
    format('5.12/R14 a busy exception of an available master must still disclose, got %s -- %s',
           jsonb_array_length(v_core->'slots'), (v_core->'slots')::text);
  assert v_core->'slots'->0 = jsonb_build_object(
           'all_day', false,
           'start', to_jsonb(timestamptz '2026-06-03 09:00:00+00'),
           'end',   to_jsonb(timestamptz '2026-06-03 10:00:00+00')),
    '5.12/R14 the disclosed slot must be the busy exception, got ' || (v_core->'slots'->0)::text;

  ---------------------------------------------------- 5.10 (R16) cancelled
  raise notice 'Section 5.10 (R16): cancelled exception is availability-independent';
  update public.events set is_cancelled = true where id = v_tx;
  v_core := timeweave_private.free_busy_core(v_l2, v_from, v_to, v_fd, v_td);
  assert jsonb_array_length(v_core->'slots') = 0,
    format('5.10/R16 a cancelled BUSY exception of an available master discloses nothing, got %s',
           jsonb_array_length(v_core->'slots'));
  update public.events set availability = 'available' where id = v_tx;
  v_core := timeweave_private.free_busy_core(v_l2, v_from, v_to, v_fd, v_td);
  assert jsonb_array_length(v_core->'slots') = 0,
    '5.10/R16 cancellation is availability-independent, got ' || v_core::text;
  delete from public.events where id = v_tx;
  delete from public.events where id = v_tm;

  ------------- 5.9 (R12) busy ALL-DAY master + AVAILABLE all-day exception
  raise notice 'Section 5.9 (R12): busy all-day master + available all-day exception';
  -- Occurrences 06-02, 06-03, 06-04, each [d, d+1). All busy they merge into one
  -- span [06-02, 06-05). With the 06-03 slot overridden by an AVAILABLE all-day
  -- exception, the survivors are 06-02 and 06-04 -- no longer adjacent, so they
  -- must appear as TWO spans. That is what makes this test discriminating: a
  -- broken suppression yields one merged span, and over-suppression yields none.
  insert into public.events (id, owner_id, title, visibility, all_day, start_date, end_date,
                             rrule, availability)
  values (v_am, v_owner, '', 'busy_only', true,
          date '2026-06-02', date '2026-06-03', 'FREQ=DAILY;COUNT=3', 'busy');
  insert into public.events (id, owner_id, title, visibility, all_day, start_date, end_date,
                             recurrence_id, recurrence_slot_date, is_cancelled, availability)
  values (v_ax, v_owner, '', 'busy_only', true,
          date '2026-06-03', date '2026-06-04',
          v_am, date '2026-06-03', false, 'available');

  perform set_config('role', 'anon', true);
  v_wrap := public.get_free_busy(v_t2, v_from, v_to, v_fd, v_td);   -- L2 #5
  perform set_config('role', 'none', true);
  assert (v_wrap->>'complete')::boolean = true, '5.9 complete, got ' || v_wrap::text;
  assert jsonb_array_length(v_wrap->'slots') = 2,
    format('5.9/R12 the available all-day exception must suppress ONLY 06-03, leaving '
           'two non-adjacent spans, got %s -- %s',
           jsonb_array_length(v_wrap->'slots'), (v_wrap->'slots')::text);
  assert v_wrap->'slots'->0 = jsonb_build_object(
           'all_day', true,
           'start_date', to_jsonb(date '2026-06-02'),
           'end_date',   to_jsonb(date '2026-06-03')),
    '5.9/R12 the first surviving span must be [06-02, 06-03), got ' || (v_wrap->'slots'->0)::text;
  assert v_wrap->'slots'->1 = jsonb_build_object(
           'all_day', true,
           'start_date', to_jsonb(date '2026-06-04'),
           'end_date',   to_jsonb(date '2026-06-05')),
    '5.9/R12 the second surviving span must be [06-04, 06-05), got ' || (v_wrap->'slots'->1)::text;

  ------------- 5.13 (R15) AVAILABLE all-day master + BUSY all-day exception
  raise notice 'Section 5.13 (R15): available all-day master + busy all-day exception';
  update public.events set availability = 'available' where id = v_am;
  update public.events set availability = 'busy'      where id = v_ax;
  v_core := timeweave_private.free_busy_core(v_l2, v_from, v_to, v_fd, v_td);
  assert jsonb_array_length(v_core->'slots') = 1,
    format('5.13/R15 a busy all-day exception of an available all-day master must still '
           'disclose, got %s -- %s', jsonb_array_length(v_core->'slots'), (v_core->'slots')::text);
  assert v_core->'slots'->0 = jsonb_build_object(
           'all_day', true,
           'start_date', to_jsonb(date '2026-06-03'),
           'end_date',   to_jsonb(date '2026-06-04')),
    '5.13/R15 the disclosed span must be the busy exception, got ' || (v_core->'slots'->0)::text;
  delete from public.events where id = v_ax;
  delete from public.events where id = v_am;

  ------------------------------------------- ACTIVE CHARGING PROOF (block B)
  select coalesce((select w.charged_calls from timeweave_private.freebusy_link_rate w
                    where w.link_id = v_l2), 0) - b_l2 into v_n;
  assert v_n = 5,
    format('10B.1 L2 must have been charged exactly 5 times in this block, delta=%s', v_n);

  select count(*) into v_n from public.events e where e.owner_id = v_owner;
  assert v_n = 0, format('Block B cleanup: %s event(s) left behind', v_n);
  raise notice 'Block B OK (all-day, exception and mixed sections + L2 charging proof)';
end $$;


-- ============================================================================
-- Section 7 + 9. THE UNAVAILABLE PATH. Every reason, one answer, no charge.
-- ============================================================================
do $$
declare
  v_owner constant uuid := '5e86935f-7661-4741-868f-0f51c4cf1727';
  v_le    constant uuid := '0023b001-0000-4000-8000-0000000000e0';  -- expired
  v_lr    constant uuid := '0023b001-0000-4000-8000-0000000000e1';  -- revoked
  v_from  constant timestamptz := timestamptz '2026-06-01 00:00:00+00';
  v_to    constant timestamptz := timestamptz '2026-06-08 00:00:00+00';
  v_fd    constant date := date '2026-06-01';
  v_td    constant date := date '2026-06-08';
  v_want  constant jsonb := jsonb_build_object('link_state','unavailable',
                                               'complete',true,
                                               'slots','[]'::jsonb);
  -- Baselines captured AFTER blocks A and B, immediately before the probes, so
  -- the delta below is attributable to the unavailable calls alone.
  b_own   bigint;
  b_own_t timestamptz;
  b_le    bigint;
  b_lr    bigint;
  v_expired jsonb; v_revoked jsonb; v_deleted jsonb; v_unknown jsonb;
  v_empty   jsonb; v_junk    jsonb; v_long    jsonb; v_null    jsonb;
  v_n bigint;
begin
  select coalesce((select w.charged_calls from timeweave_private.freebusy_owner_rate w
                    where w.owner_id = v_owner), 0) into b_own;
  select (select w.tat from timeweave_private.freebusy_owner_rate w
           where w.owner_id = v_owner) into b_own_t;
  select coalesce((select w.charged_calls from timeweave_private.freebusy_link_rate w
                    where w.link_id = v_le), 0) into b_le;
  select coalesce((select w.charged_calls from timeweave_private.freebusy_link_rate w
                    where w.link_id = v_lr), 0) into b_lr;

  perform set_config('role', 'anon', true);
  v_expired := public.get_free_busy('tw-0023-expired',       v_from, v_to, v_fd, v_td);
  v_revoked := public.get_free_busy('tw-0023-revoked',       v_from, v_to, v_fd, v_td);
  v_deleted := public.get_free_busy('tw-0023-to-be-deleted', v_from, v_to, v_fd, v_td);
  v_unknown := public.get_free_busy('tw-0023-never-existed', v_from, v_to, v_fd, v_td);
  v_empty   := public.get_free_busy('',                      v_from, v_to, v_fd, v_td);
  v_junk    := public.get_free_busy('!!! not base64url %%% ',v_from, v_to, v_fd, v_td);
  v_long    := public.get_free_busy(repeat('z', 100000),     v_from, v_to, v_fd, v_td);
  v_null    := public.get_free_busy(null::text,              v_from, v_to, v_fd, v_td);
  perform set_config('role', 'none', true);

  assert v_expired = v_want, '7.1 expired, got '       || v_expired::text;
  assert v_revoked = v_want, '7.2 revoked, got '       || v_revoked::text;
  assert v_deleted = v_want, '7.3 deleted, got '       || v_deleted::text;
  assert v_unknown = v_want, '7.4 unknown token, got ' || v_unknown::text;
  assert v_empty   = v_want, '7.5 empty token, got '   || v_empty::text;
  assert v_junk    = v_want, '7.6 junk token, got '    || v_junk::text;
  assert v_long    = v_want, '7.7 very long token, got'|| v_long::text;
  assert v_null    = v_want, '7.8 NULL token, got '    || v_null::text;

  -- 7.9 THE REASON ORACLE TEST. Not "each equals the constant" -- each equals
  -- EVERY OTHER, so no reason can be inferred by comparing two responses.
  assert v_expired = v_revoked and v_revoked = v_deleted and v_deleted = v_unknown
     and v_unknown = v_empty   and v_empty   = v_junk    and v_junk    = v_long
     and v_long    = v_null,
    '7.9 every unavailable reason must produce a byte-identical answer';

  -- 9. UNAVAILABLE answers carry exactly three keys (U2 phase boundary).
  select count(*) into v_n from jsonb_object_keys(v_expired) k;
  assert v_n = 3, format('9.1 an unavailable answer must carry exactly three keys, got %s: %s',
                         v_n, v_expired::text);
  assert not (v_expired ? 'available') and not (v_expired ? 'reason')
     and not (v_expired ? 'status')    and not (v_expired ? 'share_available')
     and not (v_expired ? 'error')     and not (v_expired ? 'code'),
    '9.2 an unavailable answer must name no reason, got ' || v_expired::text;
  assert v_expired->>'complete' = 'true' and v_expired->'slots' = '[]'::jsonb,
    '9.3 unavailable must be complete=true with an empty slot list, got ' || v_expired::text;

  ------------------------------------------- UNAVAILABLE-UNCHARGED PROOF
  -- Eight unavailable calls just happened. The owner bucket must not have moved
  -- at all -- neither the counter nor the theoretical arrival time. This is the
  -- evidence for Decision 2, and it is a DELTA, so a database that already held
  -- committed rows for this owner cannot make it pass by accident.
  select coalesce((select w.charged_calls from timeweave_private.freebusy_owner_rate w
                    where w.owner_id = v_owner), 0) - b_own into v_n;
  assert v_n = 0,
    format('10U.1 unavailable calls must charge the OWNER bucket nothing, delta=%s', v_n);

  assert (select w.tat from timeweave_private.freebusy_owner_rate w
           where w.owner_id = v_owner) is not distinct from b_own_t,
    '10U.2 unavailable calls must not advance the owner tat';

  -- The expired and revoked links resolve to real rows, so a bucket COULD have
  -- been keyed on them; it must not have been.
  select coalesce((select w.charged_calls from timeweave_private.freebusy_link_rate w
                    where w.link_id = v_le), 0) - b_le into v_n;
  assert v_n = 0,
    format('10U.3 the expired link must charge nothing, delta=%s', v_n);
  select coalesce((select w.charged_calls from timeweave_private.freebusy_link_rate w
                    where w.link_id = v_lr), 0) - b_lr into v_n;
  assert v_n = 0,
    format('10U.4 the revoked link must charge nothing, delta=%s', v_n);

  -- Scoped, not table-wide: no rate row may exist for ANY of the suite's
  -- unavailable links. Rows for links this suite never touched are none of its
  -- business and are not counted.
  select count(*) into v_n from timeweave_private.freebusy_link_rate w
   where w.link_id in (v_le, v_lr);
  assert v_n = 0,
    format('10U.5 no rate row may exist for the suite unavailable links, found %s', v_n);

  raise notice 'Sections 7 and 9 OK: eight reasons, one answer, nothing charged';
end $$;


-- ============================================================================
-- Section 11. Scoped rate-state summary for the suite's own links.
-- ============================================================================
do $$
declare
  v_l1 constant uuid := '0023b001-0000-4000-8000-000000000001';
  v_l0 constant uuid := '0023b001-0000-4000-8000-000000000000';
  v_l2 constant uuid := '0023b001-0000-4000-8000-000000000002';
  v_le constant uuid := '0023b001-0000-4000-8000-0000000000e0';
  v_lr constant uuid := '0023b001-0000-4000-8000-0000000000e1';
  v_n  bigint;
begin
  -- Exactly the three ACTIVE links hold rate rows among the suite's own links.
  -- Deliberately NOT a table-wide count: the buckets are shared infrastructure
  -- and may hold committed rows for links this suite has never heard of.
  select count(*) into v_n from timeweave_private.freebusy_link_rate w
   where w.link_id in (v_l1, v_l0, v_l2, v_le, v_lr);
  assert v_n = 3,
    format('11.1 exactly the three active suite links may hold rate rows, found %s', v_n);

  raise notice 'Section 11 OK: rate rows scoped to the suite''s own links';
end $$;


-- ============================================================================
-- Section 12. Window validation, grants, core reachability, concurrency config.
-- ============================================================================
do $$
declare
  v_from  constant timestamptz := timestamptz '2026-06-01 00:00:00+00';
  v_fd    constant date := date '2026-06-01';
  v_td    constant date := date '2026-06-08';
  v_raised boolean;
begin
  -- 12.1 window validation still fires for an ACTIVE token ...
  v_raised := false;
  begin
    perform set_config('role', 'anon', true);
    perform public.get_free_busy('tw-0023-active-include-private-true',
                                 v_from, v_from + interval '100 days', v_fd, v_td);
    perform set_config('role', 'none', true);
  exception when sqlstate '22023' then
    v_raised := true;
    perform set_config('role', 'none', true);
  end;
  assert v_raised, '12.1 an over-long window must still raise 22023 for an active link';

  -- 12.2 ... and identically for an UNAVAILABLE one, BEFORE link_state is known.
  --      This is what keeps the error contract from becoming a reason oracle.
  v_raised := false;
  begin
    perform set_config('role', 'anon', true);
    perform public.get_free_busy('tw-0023-never-existed',
                                 v_from, v_from + interval '100 days', v_fd, v_td);
    perform set_config('role', 'none', true);
  exception when sqlstate '22023' then
    v_raised := true;
    perform set_config('role', 'none', true);
  end;
  assert v_raised,
    '12.2 window validation must be link-state independent: an unknown token must
     raise the SAME 22023 rather than quietly returning unavailable';

  -- 12.3 grants
  assert pg_catalog.has_function_privilege('anon',
           'public.get_free_busy(text, timestamptz, timestamptz, date, date)','EXECUTE'),
    '12.3 anon must still hold EXECUTE on get_free_busy';
  assert pg_catalog.has_function_privilege('authenticated',
           'public.get_free_busy(text, timestamptz, timestamptz, date, date)','EXECUTE'),
    '12.3 authenticated must still hold EXECUTE on get_free_busy';

  -- 12.4 the private core is still unreachable anonymously
  assert not pg_catalog.has_function_privilege('anon',
           'timeweave_private.free_busy_core(uuid, timestamptz, timestamptz, date, date)','EXECUTE'),
    '12.4 anon must NOT be able to call free_busy_core directly';
  assert not pg_catalog.has_function_privilege('public',
           'timeweave_private.free_busy_core(uuid, timestamptz, timestamptz, date, date)','EXECUTE'),
    '12.4 PUBLIC must NOT be able to call free_busy_core directly';

  -- 12.5 concurrency CONFIGURATION only -- see this file's header for why a
  --      genuine k=2 contention test cannot be written from one session.
  assert timeweave_private.freebusy_concurrency_slots() = 2,
    '12.5 the concurrency slot count must still be 2';

  raise notice 'Section 12 OK';
end $$;


-- ============================================================================
-- FINAL CLEANUP AND WHOLE-SUITE ASSERTIONS
--
-- The canonical auth.users row is NOT touched: this file did not create it and
-- does not remove it. The ROLLBACK below discards everything anyway, including
-- every rate-bucket row this suite created or advanced.
-- ============================================================================
do $$
declare
  v_owner constant uuid := '5e86935f-7661-4741-868f-0f51c4cf1727';
  v_n     bigint;
begin
  raise notice 'Final cleanup';

  delete from public.share_links where owner_id = v_owner;

  select count(*) into v_n from public.events e where e.owner_id = v_owner;
  assert v_n = 0, format('FINAL fixtures leaked: %s event(s) remain', v_n);

  select count(*) into v_n from public.share_links s where s.owner_id = v_owner;
  assert v_n = 0, format('FINAL fixtures leaked: %s share link(s) remain', v_n);

  select count(*) into v_n from auth.users u where u.id = v_owner;
  assert v_n = 1,
    format('FINAL the canonical test user must still exist exactly once, found %s. This '
           'suite must never write to auth.users.', v_n);

  raise notice '0023 RUNTIME SUITE PASSED -- link_state active/unavailable, R1-R18 '
               'semantics re-expressed on both the timed AND all-day paths -- rolling back.';
end $$;


rollback;
