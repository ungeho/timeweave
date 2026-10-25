-- ============================================================================
-- 0024 RUNTIME TEST -- what Available sharing actually answers
-- ============================================================================
-- ISOLATED DATABASE ONLY. This file INSERTS, UPDATES and DELETES events, share
-- links and rate rows. It must never be run against production. It runs inside
-- one transaction and ends with ROLLBACK, and section 15 proves zero residue.
--
-- WHAT THIS FILE IS. The behavioural half of 0024. The catalog/structural half
-- -- signatures, grants, body fingerprints, the frozen core md5 and the
-- one-core-call reference count -- is 0024_postflight.sql's job and is not
-- duplicated here.
--
-- ============================================================================
-- WHAT THE SUBTRACTION SECTIONS DO AND DO NOT PROVE
--
-- Sections 3, 4 and 5 prove BUSY/AVAILABLE SEPARATION AND SUBTRACTION
-- CORRECTNESS: that Available ranges are explicit, that Busy is removed from
-- them, that top-level `slots` and `complete` stay Busy-only. They do NOT prove
-- how many times free_busy_core executed, and nothing here is labelled as if
-- they did. That invariant is structural -- postflight W08 (exactly one core
-- reference in the wrapper) and A06 (zero in the helper) -- plus static review
-- of both wrapper branches. No instrumentation is added to count calls.
--
-- ============================================================================
-- WHY THE RATE ROWS ARE RESET BETWEEN SECTIONS
--
-- 0019's limiter is 40 owner calls per burst window and 15 per link. A matrix
-- this size would exhaust the owner bucket partway through and start raising
-- PT429 about nothing. pg_temp.reset_rate() clears the buckets between
-- sections so the limiter caps 0019's contract, not this file's coverage.
-- Section 14 is the one place the limiter itself is asserted, with a
-- baseline/delta measurement rather than an existence check.
--
-- The event write-rate row (0012) is cleared for the same reason: this suite
-- writes far more events in a second than a human ever would.
--
-- ============================================================================
-- SUPERSEDED HISTORICAL ARTIFACTS -- recorded, NOT repaired, NOT re-run
--
--   0021_freebusy_busy_only_test.sql R8 P1/P2, R11, R17, R18 A/B
--   0022_postflight.sql B04 · 0022_share_available_test.sql 8.5
--   0023_postflight.sql W10/W11/W12 and 0023_link_state_test.sql's
--     exactly-three-keys assertions
--
-- 0023's own header predicted that a later migration would add an Available key
-- to ACTIVE answers and supersede its key-count boundary. This is that
-- migration. Those files stay byte-for-byte frozen.
-- ============================================================================

begin;

-- ============================================================================
-- Section 0. Preconditions. The owner must exist and start clean.
-- ============================================================================
do $$
declare
  v_owner constant uuid := '5e86935f-7661-4741-868f-0f51c4cf1727';  -- <<< EDIT per environment
  v_ok boolean;
begin
  select exists(select 1 from auth.users u where u.id = v_owner) into v_ok;
  assert v_ok, format('0.0 test owner %s missing from auth.users. This suite '
                      'never writes to auth.users.', v_owner);

  select count(*) = 0 into v_ok from public.events e where e.owner_id = v_owner;
  assert v_ok, '0.1 the test owner must start with no events';

  select count(*) = 0 into v_ok from public.share_links s where s.owner_id = v_owner;
  assert v_ok, '0.2 the test owner must start with no share links';

  assert to_regprocedure('timeweave_private.free_busy_available('
                         'uuid, timestamptz, timestamptz, date, date, jsonb)') is not null,
    '0.3 the 0024 helper is not installed -- apply the migration first';

  assert to_regtype('tstzmultirange') is not null
     and to_regtype('datemultirange') is not null,
    '0.4 native multiranges are absent -- 0024 has no fallback and must not be applied here';

  raise notice 'Section 0 OK';
end $$;


-- ============================================================================
-- Section 1. Local helpers and the link fixtures.
--
-- Four links cover the privacy matrix; LX is expired and is the unavailable
-- probe. Tokens are plaintext here and hashed into token_hash exactly as
-- create_share_link does, so the wrapper's lookup is exercised for real.
-- ============================================================================
create function pg_temp.fb(p_token text) returns jsonb
language sql as $$
  select public.get_free_busy(
    p_token,
    timestamptz '2026-06-01 00:00:00+00',
    timestamptz '2026-06-08 00:00:00+00',
    date '2026-06-01',
    date '2026-06-08');
$$;

create function pg_temp.reset_rate() returns void
language sql as $$
  delete from timeweave_private.freebusy_owner_rate
   where owner_id = '5e86935f-7661-4741-868f-0f51c4cf1727'::uuid;
  delete from timeweave_private.freebusy_link_rate
   where link_id in (select s.id from public.share_links s
                      where s.owner_id = '5e86935f-7661-4741-868f-0f51c4cf1727'::uuid);
  delete from timeweave_private.event_write_rate
   where owner_id = '5e86935f-7661-4741-868f-0f51c4cf1727'::uuid;
$$;

create function pg_temp.wipe_events() returns void
language sql as $$
  delete from public.events
   where owner_id = '5e86935f-7661-4741-868f-0f51c4cf1727'::uuid;
$$;

/** The key set of one slot object, sorted -- used by the metadata-leak gate. */
create function pg_temp.keyset(p_obj jsonb) returns text
language sql immutable as $$
  select string_agg(k, ',' order by k) from jsonb_object_keys(p_obj) as k;
$$;

do $$
declare
  v_owner constant uuid := '5e86935f-7661-4741-868f-0f51c4cf1727';
begin
  -- created_at is explicit because of the expired row. 0014's
  -- share_links_expiry_after_created requires `expires_at > created_at`, and
  -- now() is frozen for the whole transaction, so a link cannot be BORN
  -- expired. X must therefore be a link that was valid when created and has
  -- since lapsed: created two days ago, expired one day ago. The four active
  -- rows pass now(), which is exactly what the column default would have
  -- supplied, so their semantics are unchanged. Same shape as 0023's fixture.
  insert into public.share_links (owner_id, token_hash, label, include_private,
                                  expires_at, share_available, created_at)
  values
    (v_owner, encode(extensions.digest('tok_a','sha256'),'hex'), 'A', true,  null, true,  now()),
    (v_owner, encode(extensions.digest('tok_b','sha256'),'hex'), 'B', true,  null, false, now()),
    (v_owner, encode(extensions.digest('tok_c','sha256'),'hex'), 'C', false, null, true,  now()),
    (v_owner, encode(extensions.digest('tok_d','sha256'),'hex'), 'D', false, null, false, now()),
    (v_owner, encode(extensions.digest('tok_x','sha256'),'hex'), 'X', true,
       now() - interval '1 day', true, now() - interval '2 days');
  perform pg_temp.reset_rate();
  raise notice 'Section 1 OK: 5 links';
end $$;


-- ============================================================================
-- Section 2. CONTROL FLOW.
-- ============================================================================
do $$
declare
  v_res jsonb;
begin
  perform pg_temp.wipe_events();
  perform pg_temp.reset_rate();

  -- 2.1 An unavailable link keeps the EXACT pre-0024 three-key object and
  --     carries NO available key. This is the compatibility boundary.
  v_res := pg_temp.fb('tok_x');
  assert v_res = jsonb_build_object('link_state','unavailable',
                                    'complete', true, 'slots','[]'::jsonb),
    '2.1 unavailable answer changed: ' || v_res::text;
  assert not (v_res ? 'available'),
    '2.1b an unavailable answer must NOT carry an available key: ' || v_res::text;

  -- 2.2 An unknown token answers identically -- no reason oracle.
  assert pg_temp.fb('tok_nonexistent') = v_res,
    '2.2 an unknown token must answer exactly as an expired one does';

  -- 2.3 share_available = false: not_requested, and it is NOT an incomplete
  --     result. No Available work happens on this branch at all.
  v_res := pg_temp.fb('tok_b');
  assert v_res -> 'available' = jsonb_build_object('status','not_requested'),
    '2.3 share_available=false must yield not_requested, got ' || v_res::text;
  assert v_res ->> 'link_state' = 'active' and (v_res -> 'complete') = 'true'::jsonb,
    '2.3b busy fields must be unaffected: ' || v_res::text;

  -- 2.4 share_available = true with nothing available: exact and EMPTY, never
  --     indeterminate.
  v_res := pg_temp.fb('tok_a');
  assert v_res -> 'available' = jsonb_build_object('status','complete','slots','[]'::jsonb),
    '2.4 an empty calendar must be complete with [], got ' || v_res::text;

  raise notice 'Section 2 OK: control flow';
end $$;


-- ============================================================================
-- Section 3. SAME-MODEL TIMED SUBTRACTION.
--
-- One available window 06-02 09:00..17:00 throughout; the busy event moves.
-- No all-day row exists in this section, so the cross-model rule cannot fire
-- (section 10 proves it fires when it should).
-- ============================================================================
do $$
declare
  v_owner constant uuid := '5e86935f-7661-4741-868f-0f51c4cf1727';
  v_res jsonb;
  v_av  jsonb;

begin
  -- 3.1 Available only, no busy at all.
  perform pg_temp.wipe_events(); perform pg_temp.reset_rate();
  insert into public.events (owner_id, title, visibility, availability, all_day, start_at, end_at)
  values (v_owner, '', 'public', 'available', false,
          timestamptz '2026-06-02 09:00:00+00', timestamptz '2026-06-02 17:00:00+00');
  v_av := pg_temp.fb('tok_a') -> 'available';
  assert v_av = jsonb_build_object('status','complete','slots', jsonb_build_array(
            jsonb_build_object('all_day', false,
              'start', to_jsonb(timestamptz '2026-06-02 09:00:00+00'),
              'end',   to_jsonb(timestamptz '2026-06-02 17:00:00+00')))),
    '3.1 available-only: ' || v_av::text;

  -- 3.2 Busy overlaps the BEGINNING -> front trimmed.
  perform pg_temp.reset_rate();
  insert into public.events (owner_id, title, visibility, availability, all_day, start_at, end_at)
  values (v_owner, '', 'public', 'busy', false,
          timestamptz '2026-06-02 08:00:00+00', timestamptz '2026-06-02 10:00:00+00');
  v_av := pg_temp.fb('tok_a') -> 'available';
  assert v_av -> 'slots' = jsonb_build_array(
            jsonb_build_object('all_day', false,
              'start', to_jsonb(timestamptz '2026-06-02 10:00:00+00'),
              'end',   to_jsonb(timestamptz '2026-06-02 17:00:00+00'))),
    '3.2 busy over the start must trim the front: ' || v_av::text;

  -- 3.3 Busy strictly INSIDE -> the available range SPLITS in two.
  perform pg_temp.wipe_events(); perform pg_temp.reset_rate();
  insert into public.events (owner_id, title, visibility, availability, all_day, start_at, end_at)
  values (v_owner, '', 'public', 'available', false,
          timestamptz '2026-06-02 09:00:00+00', timestamptz '2026-06-02 17:00:00+00'),
         (v_owner, '', 'public', 'busy', false,
          timestamptz '2026-06-02 12:00:00+00', timestamptz '2026-06-02 13:00:00+00');
  v_av := pg_temp.fb('tok_a') -> 'available';
  assert v_av -> 'slots' = jsonb_build_array(
            jsonb_build_object('all_day', false,
              'start', to_jsonb(timestamptz '2026-06-02 09:00:00+00'),
              'end',   to_jsonb(timestamptz '2026-06-02 12:00:00+00')),
            jsonb_build_object('all_day', false,
              'start', to_jsonb(timestamptz '2026-06-02 13:00:00+00'),
              'end',   to_jsonb(timestamptz '2026-06-02 17:00:00+00'))),
    '3.3 busy inside must SPLIT the available range: ' || v_av::text;

  -- 3.4 Busy overlaps the END -> back trimmed.
  perform pg_temp.wipe_events(); perform pg_temp.reset_rate();
  insert into public.events (owner_id, title, visibility, availability, all_day, start_at, end_at)
  values (v_owner, '', 'public', 'available', false,
          timestamptz '2026-06-02 09:00:00+00', timestamptz '2026-06-02 17:00:00+00'),
         (v_owner, '', 'public', 'busy', false,
          timestamptz '2026-06-02 16:00:00+00', timestamptz '2026-06-02 18:00:00+00');
  v_av := pg_temp.fb('tok_a') -> 'available';
  assert v_av -> 'slots' = jsonb_build_array(
            jsonb_build_object('all_day', false,
              'start', to_jsonb(timestamptz '2026-06-02 09:00:00+00'),
              'end',   to_jsonb(timestamptz '2026-06-02 16:00:00+00'))),
    '3.4 busy over the end must trim the back: ' || v_av::text;

  -- 3.5 MULTIPLE busy intervals -> three fragments.
  perform pg_temp.wipe_events(); perform pg_temp.reset_rate();
  insert into public.events (owner_id, title, visibility, availability, all_day, start_at, end_at)
  values (v_owner, '', 'public', 'available', false,
          timestamptz '2026-06-02 09:00:00+00', timestamptz '2026-06-02 17:00:00+00'),
         (v_owner, '', 'public', 'busy', false,
          timestamptz '2026-06-02 11:00:00+00', timestamptz '2026-06-02 12:00:00+00'),
         (v_owner, '', 'public', 'busy', false,
          timestamptz '2026-06-02 14:00:00+00', timestamptz '2026-06-02 15:00:00+00');
  v_av := pg_temp.fb('tok_a') -> 'available';
  assert jsonb_array_length(v_av -> 'slots') = 3,
    '3.5 two interior busy blocks must leave three fragments: ' || v_av::text;
  assert (v_av -> 'slots' -> 0 ->> 'end')::timestamptz = timestamptz '2026-06-02 11:00:00+00'
     and (v_av -> 'slots' -> 2 ->> 'start')::timestamptz = timestamptz '2026-06-02 15:00:00+00',
    '3.5b fragment boundaries wrong: ' || v_av::text;

  -- 3.6 OVERLAPPING available inputs normalise together BEFORE subtraction.
  perform pg_temp.wipe_events(); perform pg_temp.reset_rate();
  insert into public.events (owner_id, title, visibility, availability, all_day, start_at, end_at)
  values (v_owner, '', 'public', 'available', false,
          timestamptz '2026-06-02 09:00:00+00', timestamptz '2026-06-02 13:00:00+00'),
         (v_owner, '', 'public', 'available', false,
          timestamptz '2026-06-02 11:00:00+00', timestamptz '2026-06-02 17:00:00+00');
  v_av := pg_temp.fb('tok_a') -> 'available';
  assert v_av -> 'slots' = jsonb_build_array(
            jsonb_build_object('all_day', false,
              'start', to_jsonb(timestamptz '2026-06-02 09:00:00+00'),
              'end',   to_jsonb(timestamptz '2026-06-02 17:00:00+00'))),
    '3.6 overlapping available ranges must merge: ' || v_av::text;

  -- 3.7 ADJACENT available inputs (end = start) merge too, matching the busy
  --     path's own `prev_end < s` semantics.
  perform pg_temp.wipe_events(); perform pg_temp.reset_rate();
  insert into public.events (owner_id, title, visibility, availability, all_day, start_at, end_at)
  values (v_owner, '', 'public', 'available', false,
          timestamptz '2026-06-02 09:00:00+00', timestamptz '2026-06-02 12:00:00+00'),
         (v_owner, '', 'public', 'available', false,
          timestamptz '2026-06-02 12:00:00+00', timestamptz '2026-06-02 17:00:00+00');
  v_av := pg_temp.fb('tok_a') -> 'available';
  assert jsonb_array_length(v_av -> 'slots') = 1,
    '3.7 touching available ranges must merge into one: ' || v_av::text;

  -- 3.8 Busy exactly equal to Available -> removed entirely, and that is
  --     COMPLETE with an empty array, never indeterminate.
  perform pg_temp.wipe_events(); perform pg_temp.reset_rate();
  insert into public.events (owner_id, title, visibility, availability, all_day, start_at, end_at)
  values (v_owner, '', 'public', 'available', false,
          timestamptz '2026-06-02 09:00:00+00', timestamptz '2026-06-02 17:00:00+00'),
         (v_owner, '', 'public', 'busy', false,
          timestamptz '2026-06-02 09:00:00+00', timestamptz '2026-06-02 17:00:00+00');
  v_av := pg_temp.fb('tok_a') -> 'available';
  assert v_av = jsonb_build_object('status','complete','slots','[]'::jsonb),
    '3.8 fully consumed available must be complete+[]: ' || v_av::text;

  raise notice 'Section 3 OK: timed subtraction';
end $$;


-- ============================================================================
-- Section 4. SAME-MODEL ALL-DAY SUBTRACTION, on the real all-day columns.
-- ============================================================================
do $$
declare
  v_owner constant uuid := '5e86935f-7661-4741-868f-0f51c4cf1727';
  v_av jsonb;
begin
  -- 4.1 Available only.
  perform pg_temp.wipe_events(); perform pg_temp.reset_rate();
  insert into public.events (owner_id, title, visibility, availability, all_day, start_date, end_date)
  values (v_owner, '', 'public', 'available', true, date '2026-06-02', date '2026-06-06');
  v_av := pg_temp.fb('tok_a') -> 'available';
  assert v_av -> 'slots' = jsonb_build_array(
            jsonb_build_object('all_day', true,
              'start_date', to_jsonb(date '2026-06-02'),
              'end_date',   to_jsonb(date '2026-06-06'))),
    '4.1 all-day available-only: ' || v_av::text;

  -- 4.2 Busy over the first day -> front trimmed.
  perform pg_temp.reset_rate();
  insert into public.events (owner_id, title, visibility, availability, all_day, start_date, end_date)
  values (v_owner, '', 'public', 'busy', true, date '2026-06-02', date '2026-06-03');
  v_av := pg_temp.fb('tok_a') -> 'available';
  assert v_av -> 'slots' = jsonb_build_array(
            jsonb_build_object('all_day', true,
              'start_date', to_jsonb(date '2026-06-03'),
              'end_date',   to_jsonb(date '2026-06-06'))),
    '4.2 all-day front trim: ' || v_av::text;

  -- 4.3 Busy strictly inside -> SPLIT.
  perform pg_temp.wipe_events(); perform pg_temp.reset_rate();
  insert into public.events (owner_id, title, visibility, availability, all_day, start_date, end_date)
  values (v_owner, '', 'public', 'available', true, date '2026-06-02', date '2026-06-06'),
         (v_owner, '', 'public', 'busy',      true, date '2026-06-03', date '2026-06-04');
  v_av := pg_temp.fb('tok_a') -> 'available';
  assert v_av -> 'slots' = jsonb_build_array(
            jsonb_build_object('all_day', true,
              'start_date', to_jsonb(date '2026-06-02'), 'end_date', to_jsonb(date '2026-06-03')),
            jsonb_build_object('all_day', true,
              'start_date', to_jsonb(date '2026-06-04'), 'end_date', to_jsonb(date '2026-06-06'))),
    '4.3 all-day split: ' || v_av::text;

  -- 4.4 Busy over the last day -> back trimmed.
  perform pg_temp.wipe_events(); perform pg_temp.reset_rate();
  insert into public.events (owner_id, title, visibility, availability, all_day, start_date, end_date)
  values (v_owner, '', 'public', 'available', true, date '2026-06-02', date '2026-06-06'),
         (v_owner, '', 'public', 'busy',      true, date '2026-06-05', date '2026-06-06');
  v_av := pg_temp.fb('tok_a') -> 'available';
  assert v_av -> 'slots' = jsonb_build_array(
            jsonb_build_object('all_day', true,
              'start_date', to_jsonb(date '2026-06-02'), 'end_date', to_jsonb(date '2026-06-05'))),
    '4.4 all-day back trim: ' || v_av::text;

  -- 4.5 ADJACENT available dates merge -- consecutive one-day rows become one
  --     span, exactly as the busy all-day path already behaves.
  perform pg_temp.wipe_events(); perform pg_temp.reset_rate();
  insert into public.events (owner_id, title, visibility, availability, all_day, start_date, end_date)
  values (v_owner, '', 'public', 'available', true, date '2026-06-02', date '2026-06-03'),
         (v_owner, '', 'public', 'available', true, date '2026-06-03', date '2026-06-04'),
         (v_owner, '', 'public', 'available', true, date '2026-06-04', date '2026-06-05');
  v_av := pg_temp.fb('tok_a') -> 'available';
  assert v_av -> 'slots' = jsonb_build_array(
            jsonb_build_object('all_day', true,
              'start_date', to_jsonb(date '2026-06-02'), 'end_date', to_jsonb(date '2026-06-05'))),
    '4.5 three adjacent available days must merge into one span: ' || v_av::text;

  -- 4.6 Exactly consumed -> complete + [].
  perform pg_temp.wipe_events(); perform pg_temp.reset_rate();
  insert into public.events (owner_id, title, visibility, availability, all_day, start_date, end_date)
  values (v_owner, '', 'public', 'available', true, date '2026-06-02', date '2026-06-04'),
         (v_owner, '', 'public', 'busy',      true, date '2026-06-02', date '2026-06-04');
  v_av := pg_temp.fb('tok_a') -> 'available';
  assert v_av = jsonb_build_object('status','complete','slots','[]'::jsonb),
    '4.6 fully consumed all-day: ' || v_av::text;

  raise notice 'Section 4 OK: all-day subtraction';
end $$;


-- ============================================================================
-- Section 5. PRIORITY: Busy > Available, and top-level output is untouched.
-- ============================================================================
do $$
declare
  v_owner constant uuid := '5e86935f-7661-4741-868f-0f51c4cf1727';
  v_on jsonb; v_off jsonb;
begin
  perform pg_temp.wipe_events(); perform pg_temp.reset_rate();
  insert into public.events (owner_id, title, visibility, availability, all_day, start_at, end_at)
  values (v_owner, 'secret title', 'public', 'available', false,
          timestamptz '2026-06-02 09:00:00+00', timestamptz '2026-06-02 17:00:00+00'),
         (v_owner, 'secret title', 'public', 'busy', false,
          timestamptz '2026-06-02 12:00:00+00', timestamptz '2026-06-02 13:00:00+00');

  v_on  := pg_temp.fb('tok_a');   -- share_available = true
  perform pg_temp.reset_rate();
  v_off := pg_temp.fb('tok_b');   -- share_available = false, same calendar

  -- 5.1 Enabling Available sharing changes NOTHING about the Busy answer.
  assert (v_on -> 'slots') = (v_off -> 'slots'),
    '5.1 top-level slots changed when Available was enabled: '
      || (v_on -> 'slots')::text || ' vs ' || (v_off -> 'slots')::text;
  assert (v_on -> 'complete') = (v_off -> 'complete'),
    '5.1b top-level complete changed when Available was enabled';

  -- 5.2 slots is BUSY-only: the busy block is there and the available window
  --     is not, even though the owner marked a much larger range available.
  assert v_on -> 'slots' = jsonb_build_array(
            jsonb_build_object('all_day', false,
              'start', to_jsonb(timestamptz '2026-06-02 12:00:00+00'),
              'end',   to_jsonb(timestamptz '2026-06-02 13:00:00+00'))),
    '5.2 top-level slots must contain the BUSY block only: ' || (v_on -> 'slots')::text;

  -- 5.3 Busy won where they overlap: the available answer is split around it.
  assert jsonb_array_length(v_on -> 'available' -> 'slots') = 2,
    '5.3 Busy must be subtracted from Available: ' || (v_on -> 'available')::text;

  raise notice 'Section 5 OK: Busy > Available, Busy output unchanged';
end $$;


-- ============================================================================
-- Section 6. PRIVACY. All four flag combinations, plus the leak gate.
-- ============================================================================
do $$
declare
  v_owner constant uuid := '5e86935f-7661-4741-868f-0f51c4cf1727';
  v_res jsonb; v_av jsonb; v_bad int;
begin
  perform pg_temp.wipe_events(); perform pg_temp.reset_rate();
  -- One PRIVATE available window and one PUBLIC available window.
  insert into public.events (owner_id, title, description, category,
                             visibility, availability, all_day, start_at, end_at)
  values (v_owner, 'private title', 'private note', 'private-cat',
          'private', 'available', false,
          timestamptz '2026-06-03 09:00:00+00', timestamptz '2026-06-03 12:00:00+00'),
         (v_owner, 'public title', 'public note', 'public-cat',
          'public',  'available', false,
          timestamptz '2026-06-04 09:00:00+00', timestamptz '2026-06-04 12:00:00+00');

  -- 6.1 share_available=F / include_private=T -> not_requested
  v_res := pg_temp.fb('tok_b');
  assert v_res -> 'available' = jsonb_build_object('status','not_requested'),
    '6.1 F/T must be not_requested: ' || v_res::text;

  -- 6.2 share_available=F / include_private=F -> not_requested
  perform pg_temp.reset_rate();
  v_res := pg_temp.fb('tok_d');
  assert v_res -> 'available' = jsonb_build_object('status','not_requested'),
    '6.2 F/F must be not_requested: ' || v_res::text;

  -- 6.3 share_available=T / include_private=T -> BOTH windows disclosed
  perform pg_temp.reset_rate();
  v_av := pg_temp.fb('tok_a') -> 'available';
  assert jsonb_array_length(v_av -> 'slots') = 2,
    '6.3 T/T must disclose both available windows: ' || v_av::text;

  -- 6.4 share_available=T / include_private=F -> only the public one. The
  --     private event's TIME must not leak, which is the whole point.
  perform pg_temp.reset_rate();
  v_av := pg_temp.fb('tok_c') -> 'available';
  assert v_av -> 'slots' = jsonb_build_array(
            jsonb_build_object('all_day', false,
              'start', to_jsonb(timestamptz '2026-06-04 09:00:00+00'),
              'end',   to_jsonb(timestamptz '2026-06-04 12:00:00+00'))),
    '6.4 T/F must disclose the public window only: ' || v_av::text;

  -- 6.5 The two flags are independent: F/T and F/F agree, T/T and T/F differ
  --     only by the private row. Nothing couples them.
  assert jsonb_array_length((pg_temp.fb('tok_a') -> 'available' -> 'slots')) = 2;
  perform pg_temp.reset_rate();

  -- 6.6 METADATA LEAK GATE: every available slot carries exactly the allowed
  --     key set and nothing else.
  v_av := pg_temp.fb('tok_a') -> 'available';
  select count(*) into v_bad
  from jsonb_array_elements(v_av -> 'slots') as s
  where pg_temp.keyset(s) not in ('all_day,end,start', 'all_day,end_date,start_date');
  assert v_bad = 0,
    '6.6 an available slot carried an unexpected key set: ' || v_av::text;

  -- and the serialised answer mentions none of the fixture's metadata.
  assert v_av::text not like '%title%'
     and v_av::text not like '%note%'
     and v_av::text not like '%cat%',
    '6.6b available output leaked metadata: ' || v_av::text;

  raise notice 'Section 6 OK: privacy matrix and leak gate';
end $$;


-- ============================================================================
-- Section 7. RECURRENCE and DETACH.
--
-- The anti-joins are ungated by availability, visibility and is_cancelled, so
-- an exception detaches its master occurrence whatever it says about itself.
-- 7.4 and 7.5 are the cases that would silently over-disclose if they were
-- gated -- the mirror of the bug 0021's header warns about.
-- ============================================================================
do $$
declare
  v_owner constant uuid := '5e86935f-7661-4741-868f-0f51c4cf1727';
  v_m uuid; v_av jsonb;
begin
  -- 7.1 Timed recurring AVAILABLE master: three occurrences, all disclosed.
  perform pg_temp.wipe_events(); perform pg_temp.reset_rate();
  insert into public.events (owner_id, title, visibility, availability, all_day,
                             start_at, end_at, rrule, timezone)
  values (v_owner, '', 'public', 'available', false,
          timestamptz '2026-06-02 09:00:00+00', timestamptz '2026-06-02 11:00:00+00',
          'FREQ=DAILY;COUNT=3', 'UTC')
  returning id into v_m;
  v_av := pg_temp.fb('tok_a') -> 'available';
  assert v_av ->> 'status' = 'complete' and jsonb_array_length(v_av -> 'slots') = 3,
    '7.1 a daily available master must yield three ranges: ' || v_av::text;

  -- 7.2 CANCELLED available exception: contributes nothing, but still DETACHES
  --     its occurrence -> two ranges remain, not three.
  perform pg_temp.reset_rate();
  insert into public.events (owner_id, title, visibility, availability, all_day,
                             start_at, end_at, recurrence_id, recurrence_slot_start, is_cancelled)
  values (v_owner, '', 'public', 'available', false,
          timestamptz '2026-06-03 09:00:00+00', timestamptz '2026-06-03 11:00:00+00',
          v_m, timestamptz '2026-06-03 09:00:00+00', true);
  v_av := pg_temp.fb('tok_a') -> 'available';
  assert jsonb_array_length(v_av -> 'slots') = 2,
    '7.2 a cancelled available exception must detach and contribute nothing: ' || v_av::text;

  -- 7.3 Available exception SNAPSHOT replaces the occurrence at a new time.
  perform pg_temp.wipe_events(); perform pg_temp.reset_rate();
  insert into public.events (owner_id, title, visibility, availability, all_day,
                             start_at, end_at, rrule, timezone)
  values (v_owner, '', 'public', 'available', false,
          timestamptz '2026-06-02 09:00:00+00', timestamptz '2026-06-02 11:00:00+00',
          'FREQ=DAILY;COUNT=3', 'UTC')
  returning id into v_m;
  insert into public.events (owner_id, title, visibility, availability, all_day,
                             start_at, end_at, recurrence_id, recurrence_slot_start)
  values (v_owner, '', 'public', 'available', false,
          timestamptz '2026-06-03 14:00:00+00', timestamptz '2026-06-03 16:00:00+00',
          v_m, timestamptz '2026-06-03 09:00:00+00');
  v_av := pg_temp.fb('tok_a') -> 'available';
  assert jsonb_array_length(v_av -> 'slots') = 3,
    '7.3 a moved available exception must still yield three ranges: ' || v_av::text;
  assert (v_av -> 'slots' -> 1 ->> 'start')::timestamptz = timestamptz '2026-06-03 14:00:00+00',
    '7.3b the moved occurrence must appear at its new time: ' || v_av::text;

  -- 7.4 BUSY exception over an AVAILABLE master: the occurrence is detached
  --     AND contributes busy. The owner filled that slot, so it must NOT be
  --     disclosed as open.
  perform pg_temp.wipe_events(); perform pg_temp.reset_rate();
  insert into public.events (owner_id, title, visibility, availability, all_day,
                             start_at, end_at, rrule, timezone)
  values (v_owner, '', 'public', 'available', false,
          timestamptz '2026-06-02 09:00:00+00', timestamptz '2026-06-02 11:00:00+00',
          'FREQ=DAILY;COUNT=3', 'UTC')
  returning id into v_m;
  insert into public.events (owner_id, title, visibility, availability, all_day,
                             start_at, end_at, recurrence_id, recurrence_slot_start)
  values (v_owner, '', 'public', 'busy', false,
          timestamptz '2026-06-03 09:00:00+00', timestamptz '2026-06-03 11:00:00+00',
          v_m, timestamptz '2026-06-03 09:00:00+00');
  v_av := pg_temp.fb('tok_a') -> 'available';
  assert jsonb_array_length(v_av -> 'slots') = 2,
    '7.4 a busy exception over an available master must remove that occurrence: ' || v_av::text;
  assert v_av::text not like '%2026-06-03%',
    '7.4b the filled slot must not be disclosed as available: ' || v_av::text;

  -- 7.5 AVAILABLE exception over a BUSY master: the busy occurrence is
  --     detached and the available snapshot appears instead.
  perform pg_temp.wipe_events(); perform pg_temp.reset_rate();
  insert into public.events (owner_id, title, visibility, availability, all_day,
                             start_at, end_at, rrule, timezone)
  values (v_owner, '', 'public', 'busy', false,
          timestamptz '2026-06-02 09:00:00+00', timestamptz '2026-06-02 11:00:00+00',
          'FREQ=DAILY;COUNT=3', 'UTC')
  returning id into v_m;
  insert into public.events (owner_id, title, visibility, availability, all_day,
                             start_at, end_at, recurrence_id, recurrence_slot_start)
  values (v_owner, '', 'public', 'available', false,
          timestamptz '2026-06-03 09:00:00+00', timestamptz '2026-06-03 11:00:00+00',
          v_m, timestamptz '2026-06-03 09:00:00+00');
  v_av := pg_temp.fb('tok_a') -> 'available';
  assert jsonb_array_length(v_av -> 'slots') = 1,
    '7.5 an available exception over a busy master must be disclosed: ' || v_av::text;

  -- 7.6 All-day recurring AVAILABLE master.
  perform pg_temp.wipe_events(); perform pg_temp.reset_rate();
  insert into public.events (owner_id, title, visibility, availability, all_day,
                             start_date, end_date, rrule)
  values (v_owner, '', 'public', 'available', true,
          date '2026-06-02', date '2026-06-03', 'FREQ=DAILY;COUNT=3');
  v_av := pg_temp.fb('tok_a') -> 'available';
  -- Three consecutive one-day occurrences merge into a single span.
  assert v_av -> 'slots' = jsonb_build_array(
            jsonb_build_object('all_day', true,
              'start_date', to_jsonb(date '2026-06-02'), 'end_date', to_jsonb(date '2026-06-05'))),
    '7.6 three adjacent all-day occurrences must merge: ' || v_av::text;

  -- 7.7 PRIVATE exception detaching an AVAILABLE master occurrence, read
  --     through a link with include_private = FALSE (tok_c).
  --
  --     THIS IS THE CASE THAT PROVES THE ANTI-JOIN IS STRUCTURAL. Detach and
  --     disclosure are different questions: the private exception must REMOVE
  --     the master's occurrence (the owner replaced it) while contributing
  --     nothing itself (the viewer may not see private rows). If the anti-join
  --     ever acquired a visibility predicate, 7.2 and 7.4 would both still pass
  --     -- their exceptions are public -- and the only visible symptom would be
  --     here: an occurrence the owner has already moved would be disclosed as
  --     still open.
  perform pg_temp.wipe_events(); perform pg_temp.reset_rate();
  insert into public.events (owner_id, title, visibility, availability, all_day,
                             start_at, end_at, rrule, timezone)
  values (v_owner, '', 'public', 'available', false,
          timestamptz '2026-06-02 09:00:00+00', timestamptz '2026-06-02 11:00:00+00',
          'FREQ=DAILY;COUNT=3', 'UTC')
  returning id into v_m;

  -- BEFORE: the 06-03 occurrence demonstrably exists, so the assertion after
  -- the insert is about removal rather than about something never generated.
  v_av := pg_temp.fb('tok_c') -> 'available';
  assert jsonb_array_length(v_av -> 'slots') = 3,
    '7.7a the master must generate three occurrences first: ' || v_av::text;
  assert exists (select 1 from jsonb_array_elements(v_av -> 'slots') s
                  where (s ->> 'start')::timestamptz = timestamptz '2026-06-03 09:00:00+00'),
    '7.7b the occurrence about to be replaced must exist first: ' || v_av::text;

  perform pg_temp.reset_rate();
  insert into public.events (owner_id, title, description, category,
                             visibility, availability, all_day,
                             start_at, end_at, recurrence_id, recurrence_slot_start)
  values (v_owner, 'private replacement', 'private note', 'private-cat',
          'private', 'available', false,
          timestamptz '2026-06-03 20:00:00+00', timestamptz '2026-06-03 22:00:00+00',
          v_m, timestamptz '2026-06-03 09:00:00+00');

  v_av := pg_temp.fb('tok_c') -> 'available';
  assert v_av ->> 'status' = 'complete',
    '7.7c the answer must still be exact: ' || v_av::text;
  assert jsonb_array_length(v_av -> 'slots') = 2,
    '7.7d the detached occurrence must be gone, leaving two: ' || v_av::text;
  assert not exists (select 1 from jsonb_array_elements(v_av -> 'slots') s
                      where (s ->> 'start')::timestamptz = timestamptz '2026-06-03 09:00:00+00'),
    '7.7e a PRIVATE exception must still DETACH its master occurrence: ' || v_av::text;
  assert not exists (select 1 from jsonb_array_elements(v_av -> 'slots') s
                      where (s ->> 'start')::timestamptz = timestamptz '2026-06-03 20:00:00+00'),
    '7.7f the private replacement time must NOT be disclosed: ' || v_av::text;
  assert exists (select 1 from jsonb_array_elements(v_av -> 'slots') s
                  where (s ->> 'start')::timestamptz = timestamptz '2026-06-02 09:00:00+00')
     and exists (select 1 from jsonb_array_elements(v_av -> 'slots') s
                  where (s ->> 'start')::timestamptz = timestamptz '2026-06-04 09:00:00+00'),
    '7.7g the untouched occurrences must remain: ' || v_av::text;
  assert v_av::text not like '%private%',
    '7.7h no metadata from the private exception may appear: ' || v_av::text;

  -- 7.7i the SAME fixture with include_private = TRUE (tok_a) discloses the
  --      replacement instead -- so 7.7e is about visibility, not about the
  --      exception being invisible to the pipeline altogether.
  perform pg_temp.reset_rate();
  v_av := pg_temp.fb('tok_a') -> 'available';
  assert exists (select 1 from jsonb_array_elements(v_av -> 'slots') s
                  where (s ->> 'start')::timestamptz = timestamptz '2026-06-03 20:00:00+00'),
    '7.7i with include_private the replacement must be disclosed: ' || v_av::text;

  raise notice 'Section 7 OK: recurrence and detach';
end $$;


-- ============================================================================
-- Section 8. AVAILABLE EXACTNESS -> indeterminate, Busy complete UNCHANGED.
--
-- Every case here must leave top-level complete = true: an available row can
-- never make the Busy answer incomplete. That is 0021's deliberate design and
-- 0024 must not disturb it.
-- ============================================================================
do $$
declare
  v_owner constant uuid := '5e86935f-7661-4741-868f-0f51c4cf1727';
  v_m uuid; v_res jsonb;
begin
  -- 8.1 Unsupported recurrence on an AVAILABLE master (MONTHLY is outside the
  --     SQL subset) -> (A').
  perform pg_temp.wipe_events(); perform pg_temp.reset_rate();
  insert into public.events (owner_id, title, visibility, availability, all_day,
                             start_date, end_date, rrule)
  values (v_owner, '', 'public', 'available', true,
          date '2026-06-02', date '2026-06-03', 'FREQ=MONTHLY');
  v_res := pg_temp.fb('tok_a');
  assert v_res -> 'available' = jsonb_build_object('status','indeterminate'),
    '8.1 an unexpandable available master must yield indeterminate: ' || v_res::text;
  assert (v_res -> 'complete') = 'true'::jsonb,
    '8.1b an AVAILABLE row must NEVER make the Busy answer incomplete: ' || v_res::text;
  assert not (v_res -> 'available' ? 'slots'),
    '8.1c indeterminate must carry no slots: ' || v_res::text;

  -- 8.2 IS DELIBERATELY ABSENT -- COVERAGE DEBT, NOT A PASSING ASSERTION.
  --     (A') carries an expansion-cap safety arm, and it is UNREACHABLE through
  --     public.get_free_busy today:
  --
  --       * the occurrence count the cap is compared against is scoped to the
  --         REQUESTED WINDOW, not to the rule's lifetime, so a huge COUNT does
  --         not by itself exceed it;
  --       * the public wrapper refuses any window longer than 92 days;
  --       * neither supported SQL recurrence subset is denser than DAILY --
  --         rrule_timed_sql_subset rejects FREQ=HOURLY and FREQ=MINUTELY, and
  --         all-day has no sub-daily frequency at all;
  --       * the expansion cap is 5000.
  --
  --     So the most occurrences a master can contribute to one request is 92,
  --     against a cap of 5000. The branch cannot fire. An earlier version of
  --     this section asserted it anyway, using FREQ=DAILY;COUNT=cap+50, and
  --     failed at runtime because that rule yields 8 occurrences in the window
  --     and expands correctly -- the implementation was right and the test was
  --     wrong.
  --
  --     Reaching it would mean lowering the cap, bypassing the 92-day limit or
  --     calling the helper directly to manufacture a state the public contract
  --     cannot produce. None of those would be evidence about the shipped path,
  --     so the arm is left behaviourally untested and recorded here.

  -- 8.3 IS DELIBERATELY ABSENT. It was to cover (A')'s timezone gate with a
  --     zone-less timed recurring master (state M0). THAT ROW CANNOT BE CREATED
  --     on a post-0008 schema: events_validate_timezone raises 23514 /
  --     TIMEWEAVE_TZ_REQUIRED for exactly this shape on INSERT
  --     (events_timezone_transition_error returns it unconditionally when
  --     p_is_insert is true). M0 exists only for rows written before 0008, and
  --     manufacturing one would mean disabling a trigger -- fabricating an
  --     unreachable state to test it.
  --
  --     The reachable part of (A') IS covered, by 8.1 alone: a rule outside the
  --     SQL subset. The zone arm here and the cap arm in 8.2 are both
  --     unreachable, and both are identical in text to the frozen core's branch
  --     (A), whose own evidence is 0021's; 0024_postflight A07 pins that the
  --     predicates are present. Recorded as known gaps rather than faked.

  -- 8.4 IS DELIBERATELY ABSENT -- UNREACHABLE_COVERAGE_DEBT, NOT A PASSING
  --     ASSERTION. (B') fires on a MODEL MISMATCH between a recurring master
  --     and its exception -- one all-day, the other timed.
  --
  --     THE CURRENT NORMAL WRITE PATH REJECTS THAT STATE. 0017's
  --     public.events_enforce_recurrence_graph requires `p.all_day = c.all_day`
  --     for every exception and its master, so the insert fails with 23514 /
  --     TIMEWEAVE_RECURRENCE_GRAPH before free_busy_available can observe
  --     anything. An earlier version of this section attempted exactly that and
  --     died on the second INSERT.
  --
  --     0021's own (B) comment says the shape is reachable because "the DB
  --     CHECKs constrain each row alone, not the pair". That is true of the
  --     CHECKs and incomplete about the schema: 0017 added a TRIGGER that does
  --     constrain the pair.
  --
  --     So (B') is defence in depth for rows written before 0017, or written
  --     with enforcement bypassed (session_replication_role = 'replica'
  --     disables triggers but not CHECKs). Keeping the guard is right; driving
  --     it from a fixture is not possible without disabling that trigger, which
  --     would test a state the product cannot produce.

  -- 8.5 UNMATCHED exception slot on an AVAILABLE timed master -> (D').
  perform pg_temp.wipe_events(); perform pg_temp.reset_rate();
  insert into public.events (owner_id, title, visibility, availability, all_day,
                             start_at, end_at, rrule, timezone)
  values (v_owner, '', 'public', 'available', false,
          timestamptz '2026-06-02 09:00:00+00', timestamptz '2026-06-02 11:00:00+00',
          'FREQ=DAILY;COUNT=3', 'UTC')
  returning id into v_m;
  insert into public.events (owner_id, title, visibility, availability, all_day,
                             start_at, end_at, recurrence_id, recurrence_slot_start)
  values (v_owner, '', 'public', 'available', false,
          timestamptz '2026-06-03 14:00:00+00', timestamptz '2026-06-03 16:00:00+00',
          v_m, timestamptz '2026-06-03 09:30:00+00');   -- matches no generated start
  v_res := pg_temp.fb('tok_a');
  assert v_res -> 'available' ->> 'status' = 'indeterminate',
    '8.5 an unmatched slot on an available master -> indeterminate: ' || v_res::text;
  assert (v_res -> 'complete') = 'true'::jsonb, '8.5b Busy complete must stay true';

  raise notice 'Section 8 OK: available exactness';
end $$;


-- ============================================================================
-- Section 9. BUSY INCOMPLETENESS fast-fails Available.
-- ============================================================================
do $$
declare
  v_owner constant uuid := '5e86935f-7661-4741-868f-0f51c4cf1727';
  v_res jsonb;
begin
  perform pg_temp.wipe_events(); perform pg_temp.reset_rate();
  -- An unexpandable BUSY master makes the Busy answer incomplete...
  insert into public.events (owner_id, title, visibility, availability, all_day,
                             start_date, end_date, rrule)
  values (v_owner, '', 'public', 'busy', true,
          date '2026-06-02', date '2026-06-03', 'FREQ=MONTHLY');
  -- ...while a perfectly exact all-day available window also exists.
  insert into public.events (owner_id, title, visibility, availability, all_day,
                             start_date, end_date)
  values (v_owner, '', 'public', 'available', true, date '2026-06-05', date '2026-06-06');

  v_res := pg_temp.fb('tok_a');
  assert (v_res -> 'complete') = 'false'::jsonb,
    '9.0 the fixture must actually make Busy incomplete: ' || v_res::text;
  assert v_res -> 'available' = jsonb_build_object('status','indeterminate'),
    '9.1 incomplete Busy must force Available to indeterminate: ' || v_res::text;
  assert not (v_res -> 'available' ? 'slots'),
    '9.2 no Available slots may be disclosed when Busy is incomplete: ' || v_res::text;

  raise notice 'Section 9 OK: busy incompleteness';
end $$;


-- ============================================================================
-- Section 10. CROSS-MODEL -> indeterminate, with a single-model control.
-- ============================================================================
do $$
declare
  v_owner constant uuid := '5e86935f-7661-4741-868f-0f51c4cf1727';
  v_m uuid; v_res jsonb;
begin
  -- 10.1 TIMED available + ALL-DAY busy.
  perform pg_temp.wipe_events(); perform pg_temp.reset_rate();
  insert into public.events (owner_id, title, visibility, availability, all_day, start_at, end_at)
  values (v_owner, '', 'public', 'available', false,
          timestamptz '2026-06-02 09:00:00+00', timestamptz '2026-06-02 17:00:00+00');
  insert into public.events (owner_id, title, visibility, availability, all_day, start_date, end_date)
  values (v_owner, '', 'public', 'busy', true, date '2026-06-04', date '2026-06-05');
  v_res := pg_temp.fb('tok_a');
  assert v_res -> 'available' = jsonb_build_object('status','indeterminate'),
    '10.1 timed available + all-day busy must be indeterminate: ' || v_res::text;
  assert (v_res -> 'complete') = 'true'::jsonb,
    '10.1b the cross-model rule must not touch Busy complete';

  -- 10.2 ALL-DAY available + TIMED busy.
  perform pg_temp.wipe_events(); perform pg_temp.reset_rate();
  insert into public.events (owner_id, title, visibility, availability, all_day, start_date, end_date)
  values (v_owner, '', 'public', 'available', true, date '2026-06-02', date '2026-06-04');
  insert into public.events (owner_id, title, visibility, availability, all_day, start_at, end_at)
  values (v_owner, '', 'public', 'busy', false,
          timestamptz '2026-06-06 09:00:00+00', timestamptz '2026-06-06 10:00:00+00');
  v_res := pg_temp.fb('tok_a');
  assert v_res -> 'available' = jsonb_build_object('status','indeterminate'),
    '10.2 all-day available + timed busy must be indeterminate: ' || v_res::text;

  -- 10.3 SAME-SERIES cross-model exception: an all-day master with a timed
  --      exception.
  --
  --      §10.3 IS DELIBERATELY ABSENT -- UNREACHABLE_COVERAGE_DEBT, NOT PASS.
  --
  --      The same-series cross-model state needs an exception whose all_day
  --      differs from its recurring master. 0017's
  --      public.events_enforce_recurrence_graph requires
  --      `p.all_day = c.all_day`, so the current normal write path rejects it
  --      with 23514 / TIMEWEAVE_RECURRENCE_GRAPH before free_busy_available
  --      can observe anything -- the identical blocker that removed §8.4.
  --      The exception's availability value is irrelevant to that trigger.
  --
  --      The guard stays as defence in depth for rows written before 0017 or
  --      with enforcement bypassed (session_replication_role = 'replica'
  --      disables triggers but not CHECKs). It is simply not drivable from a
  --      fixture, so it is deliberately not behaviourally exercised.
  --
  --      10.1 and 10.2 remain the reachable cross-model evidence: they use
  --      INDEPENDENT timed and all-day events, which the recurrence graph does
  --      not constrain at all.

  -- 10.4 CONTROL: a single-model calendar must NOT trip the rule. This guards
  --      against over-detection making the feature useless.
  perform pg_temp.wipe_events(); perform pg_temp.reset_rate();
  insert into public.events (owner_id, title, visibility, availability, all_day, start_at, end_at)
  values (v_owner, '', 'public', 'available', false,
          timestamptz '2026-06-02 09:00:00+00', timestamptz '2026-06-02 17:00:00+00'),
         (v_owner, '', 'public', 'busy', false,
          timestamptz '2026-06-02 12:00:00+00', timestamptz '2026-06-02 13:00:00+00');
  v_res := pg_temp.fb('tok_a');
  assert v_res -> 'available' ->> 'status' = 'complete',
    '10.4 a purely timed calendar must NOT be indeterminate: ' || v_res::text;

  -- 10.5 CONTROL: available in one model with NO busy in the other is fine.
  perform pg_temp.wipe_events(); perform pg_temp.reset_rate();
  insert into public.events (owner_id, title, visibility, availability, all_day, start_at, end_at)
  values (v_owner, '', 'public', 'available', false,
          timestamptz '2026-06-02 09:00:00+00', timestamptz '2026-06-02 17:00:00+00');
  insert into public.events (owner_id, title, visibility, availability, all_day, start_date, end_date)
  values (v_owner, '', 'public', 'available', true, date '2026-06-04', date '2026-06-05');
  v_res := pg_temp.fb('tok_a');
  assert v_res -> 'available' ->> 'status' = 'complete'
     and jsonb_array_length(v_res -> 'available' -> 'slots') = 2,
    '10.5 available in BOTH models with no busy must still be exact: ' || v_res::text;
  -- all-day sorts first, timed second, with no cross-model cast
  assert (v_res -> 'available' -> 'slots' -> 0 ->> 'all_day')::boolean = true
     and (v_res -> 'available' -> 'slots' -> 1 ->> 'all_day')::boolean = false,
    '10.5b emission order must be all-day first, then timed: ' || v_res::text;

  raise notice 'Section 10 OK: cross-model';
end $$;


-- ============================================================================
-- Section 11. COMPATIBILITY: the shape of the whole answer.
-- ============================================================================
do $$
declare
  v_owner constant uuid := '5e86935f-7661-4741-868f-0f51c4cf1727';
  v_res jsonb;
begin
  perform pg_temp.wipe_events(); perform pg_temp.reset_rate();
  insert into public.events (owner_id, title, visibility, availability, all_day, start_at, end_at)
  values (v_owner, '', 'public', 'available', false,
          timestamptz '2026-06-02 09:00:00+00', timestamptz '2026-06-02 17:00:00+00');

  -- 11.1 An ACTIVE answer now carries exactly four keys.
  v_res := pg_temp.fb('tok_a');
  assert (select string_agg(k, ',' order by k) from jsonb_object_keys(v_res) as k)
         = 'available,complete,link_state,slots',
    '11.1 unexpected active key set: ' || v_res::text;

  -- 11.2 An UNAVAILABLE answer still carries exactly three, and no available.
  perform pg_temp.reset_rate();
  v_res := pg_temp.fb('tok_x');
  assert (select string_agg(k, ',' order by k) from jsonb_object_keys(v_res) as k)
         = 'complete,link_state,slots',
    '11.2 unavailable key set changed: ' || v_res::text;

  -- 11.3 The nested object carries only status, or status+slots.
  perform pg_temp.reset_rate();
  v_res := pg_temp.fb('tok_a') -> 'available';
  assert (select string_agg(k, ',' order by k) from jsonb_object_keys(v_res) as k)
         in ('status', 'slots,status'),
    '11.3 unexpected available key set: ' || v_res::text;

  raise notice 'Section 11 OK: compatibility';
end $$;


-- ============================================================================
-- Section 12. TIMEZONE ROUND-TRIP.
--
-- The helper reads the Busy set back out of the core's jsonb. to_jsonb renders
-- timestamptz as ISO 8601 WITH its offset and ignores DateStyle, so the round
-- trip must recover the same instant under any session TimeZone. This section
-- re-runs the split case under a non-UTC zone to prove that rather than assume
-- it. SET LOCAL reverts at the transaction end.
-- ============================================================================
do $$
declare
  v_owner constant uuid := '5e86935f-7661-4741-868f-0f51c4cf1727';
  v_av jsonb;
begin
  perform pg_temp.wipe_events(); perform pg_temp.reset_rate();
  set local timezone = 'Asia/Tokyo';

  insert into public.events (owner_id, title, visibility, availability, all_day, start_at, end_at)
  values (v_owner, '', 'public', 'available', false,
          timestamptz '2026-06-02 09:00:00+00', timestamptz '2026-06-02 17:00:00+00'),
         (v_owner, '', 'public', 'busy', false,
          timestamptz '2026-06-02 12:00:00+00', timestamptz '2026-06-02 13:00:00+00');

  v_av := pg_temp.fb('tok_a') -> 'available';
  assert jsonb_array_length(v_av -> 'slots') = 2,
    '12.1 the split must survive a non-UTC session timezone: ' || v_av::text;
  assert (v_av -> 'slots' -> 0 ->> 'end')::timestamptz   = timestamptz '2026-06-02 12:00:00+00'
     and (v_av -> 'slots' -> 1 ->> 'start')::timestamptz = timestamptz '2026-06-02 13:00:00+00',
    '12.2 instants changed under a non-UTC session timezone: ' || v_av::text;

  -- The all-day path must be unaffected too: dates are never zone-converted.
  perform pg_temp.wipe_events(); perform pg_temp.reset_rate();
  insert into public.events (owner_id, title, visibility, availability, all_day, start_date, end_date)
  values (v_owner, '', 'public', 'available', true, date '2026-06-02', date '2026-06-06'),
         (v_owner, '', 'public', 'busy',      true, date '2026-06-03', date '2026-06-04');
  v_av := pg_temp.fb('tok_a') -> 'available';
  assert (v_av -> 'slots' -> 0 ->> 'end_date')::date = date '2026-06-03'
     and (v_av -> 'slots' -> 1 ->> 'start_date')::date = date '2026-06-04',
    '12.3 all-day dates shifted under a non-UTC session timezone: ' || v_av::text;

  set local timezone = 'UTC';
  raise notice 'Section 12 OK: timezone round-trip';
end $$;


-- ============================================================================
-- Section 13. DEFENSIVE DIRECT-HELPER INPUT.
--
-- These shapes are unreachable through the wrapper -- the core never produces
-- them -- so the helper is called directly, with the exact six-argument
-- signature. Each must RETURN indeterminate rather than raise: a corrupt
-- private handoff must never turn a valid Busy answer into an RPC error, and
-- must never produce Available output either.
-- ============================================================================
do $$
declare
  v_owner constant uuid := '5e86935f-7661-4741-868f-0f51c4cf1727';
  v_link uuid;
  v_indet constant jsonb := jsonb_build_object('status','indeterminate');

begin
  perform pg_temp.wipe_events(); perform pg_temp.reset_rate();
  -- A calendar that WOULD disclose something, so a leak would be visible.
  insert into public.events (owner_id, title, visibility, availability, all_day, start_at, end_at)
  values (v_owner, '', 'public', 'available', false,
          timestamptz '2026-06-02 09:00:00+00', timestamptz '2026-06-02 17:00:00+00');
  select s.id into v_link from public.share_links s
   where s.token_hash = encode(extensions.digest('tok_a','sha256'),'hex');

  -- 13.0 control: a well-formed handoff DOES disclose, so the cases below are
  --      failing closed rather than finding nothing to say.
  assert timeweave_private.free_busy_available(
           v_link, timestamptz '2026-06-01 00:00:00+00', timestamptz '2026-06-08 00:00:00+00',
           date '2026-06-01', date '2026-06-08',
           jsonb_build_object('complete', true, 'slots', '[]'::jsonb)) ->> 'status' = 'complete',
    '13.0 the control handoff must disclose';

  -- 13.1 NULL
  assert timeweave_private.free_busy_available(
           v_link, timestamptz '2026-06-01 00:00:00+00', timestamptz '2026-06-08 00:00:00+00',
           date '2026-06-01', date '2026-06-08', null) = v_indet,
    '13.1 a null busy handoff must be indeterminate';

  -- 13.2 complete = false
  assert timeweave_private.free_busy_available(
           v_link, timestamptz '2026-06-01 00:00:00+00', timestamptz '2026-06-08 00:00:00+00',
           date '2026-06-01', date '2026-06-08',
           jsonb_build_object('complete', false, 'slots', '[]'::jsonb)) = v_indet,
    '13.2 complete=false must be indeterminate';

  -- 13.3 complete missing
  assert timeweave_private.free_busy_available(
           v_link, timestamptz '2026-06-01 00:00:00+00', timestamptz '2026-06-08 00:00:00+00',
           date '2026-06-01', date '2026-06-08',
           jsonb_build_object('slots', '[]'::jsonb)) = v_indet,
    '13.3 a missing complete must be indeterminate';

  -- 13.3a slots MISSING. The sibling of 13.3: `p_busy_result -> 'slots'` is
  --       SQL NULL for an absent key, so a null-unsafe jsonb_typeof test would
  --       yield NULL and fall through exactly as the `complete` test did.
  assert timeweave_private.free_busy_available(
           v_link, timestamptz '2026-06-01 00:00:00+00', timestamptz '2026-06-08 00:00:00+00',
           date '2026-06-01', date '2026-06-08',
           jsonb_build_object('complete', true)) = v_indet,
    '13.3a a missing slots must be indeterminate';

  -- 13.4 slots not an array
  assert timeweave_private.free_busy_available(
           v_link, timestamptz '2026-06-01 00:00:00+00', timestamptz '2026-06-08 00:00:00+00',
           date '2026-06-01', date '2026-06-08',
           jsonb_build_object('complete', true, 'slots', jsonb_build_object())) = v_indet,
    '13.4 a non-array slots must be indeterminate';

  -- 13.5 malformed slot element
  assert timeweave_private.free_busy_available(
           v_link, timestamptz '2026-06-01 00:00:00+00', timestamptz '2026-06-08 00:00:00+00',
           date '2026-06-01', date '2026-06-08',
           jsonb_build_object('complete', true, 'slots',
             jsonb_build_array(jsonb_build_object('all_day', false)))) = v_indet,
    '13.5 a slot missing its time keys must be indeterminate';

  -- 13.6 unparseable instant inside a well-shaped element
  assert timeweave_private.free_busy_available(
           v_link, timestamptz '2026-06-01 00:00:00+00', timestamptz '2026-06-08 00:00:00+00',
           date '2026-06-01', date '2026-06-08',
           jsonb_build_object('complete', true, 'slots',
             jsonb_build_array(jsonb_build_object(
               'all_day', false, 'start', 'not-a-timestamp', 'end', 'also-not')))) = v_indet,
    '13.6 an unparseable instant must be indeterminate, not an error';

  -- 13.8-13.11 NON-POSITIVE RANGES, with ONE deliberate exception.
  --
  --     A range whose end PRECEDES its start is malformed and fails CLOSED:
  --     dropping it would subtract less Busy than the handoff described, the
  --     over-disclosing direction.
  --
  --     A ZERO-LENGTH TIMED RANGE IS NOT MALFORMED. events_time_shape permits
  --     end_at >= start_at for timed rows, so such an event is legal and the
  --     frozen core emits it as {start: T, end: T}. Rejecting it would disable
  --     Available sharing for any owner with one stray zero-length event --
  --     a change to normal Busy semantics. It occupies no time, so it subtracts
  --     nothing. All-day has no equivalent: events_time_shape requires
  --     end_date > start_date, so equality there means the handoff is corrupt.

  -- 13.8 POSITIVE: a legal zero-length timed Busy slot must NOT suppress
  --      Available, and must remove no Available time. The fixture's available
  --      window is 06-02 09:00-17:00 and the zero-length busy sits inside it,
  --      so a wrongly-rejected or wrongly-subtracted slot is immediately visible.
  declare
    v_zero jsonb;
  begin
    v_zero := timeweave_private.free_busy_available(
                v_link, timestamptz '2026-06-01 00:00:00+00',
                timestamptz '2026-06-08 00:00:00+00',
                date '2026-06-01', date '2026-06-08',
                jsonb_build_object('complete', true, 'slots', jsonb_build_array(
                  jsonb_build_object('all_day', false,
                    'start', to_jsonb(timestamptz '2026-06-02 12:00:00+00'),
                    'end',   to_jsonb(timestamptz '2026-06-02 12:00:00+00')))));
    assert v_zero ->> 'status' = 'complete',
      '13.8a a zero-length timed busy slot must NOT make Available indeterminate: '
        || v_zero::text;
    assert v_zero -> 'slots' = jsonb_build_array(
             jsonb_build_object('all_day', false,
               'start', to_jsonb(timestamptz '2026-06-02 09:00:00+00'),
               'end',   to_jsonb(timestamptz '2026-06-02 17:00:00+00'))),
      '13.8b a zero-length timed busy slot must remove NO Available time: '
        || v_zero::text;
    -- and it is identical to passing no busy slots at all
    assert v_zero = timeweave_private.free_busy_available(
             v_link, timestamptz '2026-06-01 00:00:00+00',
             timestamptz '2026-06-08 00:00:00+00',
             date '2026-06-01', date '2026-06-08',
             jsonb_build_object('complete', true, 'slots', '[]'::jsonb)),
      '13.8c a zero-length busy slot must answer exactly as an empty busy set does';
  end;

  assert timeweave_private.free_busy_available(
           v_link, timestamptz '2026-06-01 00:00:00+00', timestamptz '2026-06-08 00:00:00+00',
           date '2026-06-01', date '2026-06-08',
           jsonb_build_object('complete', true, 'slots', jsonb_build_array(
             jsonb_build_object('all_day', false,
               'start', to_jsonb(timestamptz '2026-06-02 17:00:00+00'),
               'end',   to_jsonb(timestamptz '2026-06-02 09:00:00+00'))))) = v_indet,
    '13.9 a timed range with start > end must be indeterminate';

  assert timeweave_private.free_busy_available(
           v_link, timestamptz '2026-06-01 00:00:00+00', timestamptz '2026-06-08 00:00:00+00',
           date '2026-06-01', date '2026-06-08',
           jsonb_build_object('complete', true, 'slots', jsonb_build_array(
             jsonb_build_object('all_day', true,
               'start_date', to_jsonb(date '2026-06-02'),
               'end_date',   to_jsonb(date '2026-06-02'))))) = v_indet,
    '13.10 an all-day range with start_date = end_date must be indeterminate';

  assert timeweave_private.free_busy_available(
           v_link, timestamptz '2026-06-01 00:00:00+00', timestamptz '2026-06-08 00:00:00+00',
           date '2026-06-01', date '2026-06-08',
           jsonb_build_object('complete', true, 'slots', jsonb_build_array(
             jsonb_build_object('all_day', true,
               'start_date', to_jsonb(date '2026-06-05'),
               'end_date',   to_jsonb(date '2026-06-02'))))) = v_indet,
    '13.11 an all-day range with start_date > end_date must be indeterminate';

  -- 13.12 CONTROL for 13.9-13.11: one WELL-FORMED busy range over the same
  --       calendar still discloses AND subtracts, so those three are failing
  --       closed rather than the fixture having nothing to say. (13.8 needs no
  --       such control -- it is itself a positive assertion.)
  assert timeweave_private.free_busy_available(
           v_link, timestamptz '2026-06-01 00:00:00+00', timestamptz '2026-06-08 00:00:00+00',
           date '2026-06-01', date '2026-06-08',
           jsonb_build_object('complete', true, 'slots', jsonb_build_array(
             jsonb_build_object('all_day', false,
               'start', to_jsonb(timestamptz '2026-06-02 12:00:00+00'),
               'end',   to_jsonb(timestamptz '2026-06-02 13:00:00+00'))))) ->> 'status'
         = 'complete',
    '13.12 a well-formed busy range must still disclose';

  -- 13.7 a link id that resolves to nothing
  assert timeweave_private.free_busy_available(
           '00000000-0000-0000-0000-000000000000'::uuid,
           timestamptz '2026-06-01 00:00:00+00', timestamptz '2026-06-08 00:00:00+00',
           date '2026-06-01', date '2026-06-08',
           jsonb_build_object('complete', true, 'slots', '[]'::jsonb)) = v_indet,
    '13.7 an unresolvable link must be indeterminate';

  raise notice 'Section 13 OK: defensive direct-helper input';
end $$;


-- ============================================================================
-- Section 14. RATE AND CONCURRENCY ARE UNCHANGED.
--
-- Baseline/delta, never existence. The limiter's own semantics are 0019's
-- evidence; what is asserted here is that 0024 did not alter the identities,
-- the order or the charge count, and that an Available request costs the same
-- as a Busy-only one.
-- ============================================================================
do $$
declare
  v_owner constant uuid := '5e86935f-7661-4741-868f-0f51c4cf1727';
  v_link_a uuid; v_link_b uuid;
  v_o0 bigint; v_o1 bigint; v_a0 bigint; v_a1 bigint; v_b0 bigint; v_b1 bigint;
  v_tat0 timestamptz; v_tat1 timestamptz;
begin
  perform pg_temp.wipe_events(); perform pg_temp.reset_rate();
  select s.id into v_link_a from public.share_links s
   where s.token_hash = encode(extensions.digest('tok_a','sha256'),'hex');
  select s.id into v_link_b from public.share_links s
   where s.token_hash = encode(extensions.digest('tok_b','sha256'),'hex');

  select coalesce((select w.charged_calls from timeweave_private.freebusy_owner_rate w
                    where w.owner_id = v_owner), 0) into v_o0;
  select coalesce((select w.charged_calls from timeweave_private.freebusy_link_rate w
                    where w.link_id = v_link_a), 0) into v_a0;
  select coalesce((select w.charged_calls from timeweave_private.freebusy_link_rate w
                    where w.link_id = v_link_b), 0) into v_b0;

  perform pg_temp.fb('tok_a');   -- Available requested
  perform pg_temp.fb('tok_b');   -- Available not requested

  select w.charged_calls, w.tat into v_o1, v_tat1
    from timeweave_private.freebusy_owner_rate w where w.owner_id = v_owner;
  select w.charged_calls into v_a1
    from timeweave_private.freebusy_link_rate w where w.link_id = v_link_a;
  select w.charged_calls into v_b1
    from timeweave_private.freebusy_link_rate w where w.link_id = v_link_b;

  -- 14.1 Two successful calls charge the owner twice, and each link once --
  --      an Available request costs exactly what a Busy-only one costs.
  assert v_o1 - v_o0 = 2, format('14.1 owner delta expected 2, got %s', v_o1 - v_o0);
  assert v_a1 - v_a0 = 1, format('14.2 link A delta expected 1, got %s', v_a1 - v_a0);
  assert v_b1 - v_b0 = 1, format('14.3 link B delta expected 1, got %s', v_b1 - v_b0);

  -- 14.4 An UNAVAILABLE link is still charged NOTHING, on either bucket.
  perform pg_temp.reset_rate();
  perform pg_temp.fb('tok_x');
  assert not exists (select 1 from timeweave_private.freebusy_owner_rate w
                      where w.owner_id = v_owner),
    '14.4 an unavailable link must not touch the owner bucket';
  assert not exists (select 1 from timeweave_private.freebusy_link_rate w
                      where w.link_id in (select s.id from public.share_links s
                                           where s.owner_id = v_owner)),
    '14.5 an unavailable link must not touch any link bucket';

  -- 14.6 The concurrency configuration is unchanged. A single session always
  --      takes slot 1, so the k=2 exhaustion path cannot be observed here;
  --      only the CONFIGURATION is asserted. 0019 holds the real evidence.
  assert timeweave_private.freebusy_concurrency_slots() = 2,
    '14.6 concurrency slot count changed';

  raise notice 'Section 14 OK: rate and concurrency';
end $$;


-- ============================================================================
-- Section 15. RESIDUE. Everything this suite wrote is accounted for, and the
-- ROLLBACK below removes all of it.
-- ============================================================================
do $$
declare
  v_owner constant uuid := '5e86935f-7661-4741-868f-0f51c4cf1727';
  v_n bigint;
begin
  select count(*) into v_n from public.share_links s where s.owner_id = v_owner;
  assert v_n = 5, format('15.1 expected exactly the 5 fixture links, found %s', v_n);

  select count(*) into v_n from timeweave_private.freebusy_link_rate w
   where w.link_id not in (select s.id from public.share_links s where s.owner_id = v_owner);
  assert v_n = 0, '15.2 this suite must not have touched another owner''s link buckets';

  select count(*) into v_n from public.events e where e.owner_id <> v_owner;
  assert v_n = 0, '15.3 this suite must not have created events for another owner';

  raise notice 'Section 15 OK: residue accounted for';
  raise notice '0024 RUNTIME SUITE PASSED -- rolling back, nothing is kept';
end $$;

rollback;
