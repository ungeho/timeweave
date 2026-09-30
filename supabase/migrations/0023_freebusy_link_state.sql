-- ============================================================================
-- 0023 -- anonymous share-link link_state (U2)
-- ============================================================================
-- WHAT THIS IS. public.get_free_busy, replaced in place, with one new key in
-- its answer:
--
--     link_state  'active' | 'unavailable'
--
-- An ACTIVE link answers exactly as it always has, plus link_state='active'.
-- An UNAVAILABLE link answers
--
--     {"link_state":"unavailable","complete":true,"slots":[]}
--
-- and every reason it might be unavailable -- expired, revoked, deleted, never
-- existed, unknown token, malformed token, NULL token -- produces that one
-- object, byte for byte. The REASON is not disclosed and must never be.
--
-- WHAT THIS IS NOT. timeweave_private.free_busy_core is NOT touched. Its body
-- md5 must still be a9b4097e4b390cee1229709945475d2b after this file runs; the
-- 0023 postflight gates exactly that. No change to share_links, to the owner
-- RPCs, to the rate limiter, to the concurrency slots, or to what counts as
-- Busy. No Available computation, no Available publication, and
-- share_available is NOT read here -- it stays an owner-side setting that the
-- anonymous path ignores, exactly as 0022 left it.
--
-- THE ONE ACCEPTED DISCLOSURE. Before this migration an unavailable link and an
-- active link with nothing in the window returned the SAME object, so a holder
-- of a revoked token could not tell the two apart. U2 separates them on
-- purpose: that is the whole point of link_state. What remains secret is WHICH
-- reason applies. Tokens are 256-bit random (0005), so this is not a usable
-- oracle for guessing one.
--
-- RATE LIMITING IS UNCHANGED, INCLUDING FOR UNAVAILABLE LINKS. The unavailable
-- branch returns before the GCRA pre-check, so such a request still charges
-- nothing -- as it did before. That is not an oversight: both buckets are keyed
-- on link_id and owner_id, and an unavailable request has resolved neither.
-- Charging it would need a new bucket dimension, which U2 deliberately does not
-- add.
--
-- HOW THE BODY WAS PRODUCED. Copied verbatim from 0019_freebusy_rate_limit.sql
-- lines 785-910 -- the canonical wrapper body, md5
-- 162c218d890630c6478c6e26638c2ca9 -- with exactly three edits:
--
--   1. the step-2 comment, which claimed "no existence oracle"; that is no
--      longer true and saying so would be misleading;
--   2. the unavailable return, which now names link_state;
--   3. the final return, which appends link_state='active'.
--
-- Nothing else moved: window validation, token hashing, the active predicate,
-- the rate pre-check, the concurrency slot, the core call and the charging are
-- character-for-character what 0019 shipped.
--
-- WHY `v_result || jsonb_build_object(...)`. Both operands are jsonb OBJECTS,
-- so || is a merge in which the RIGHT operand wins a key collision. link_state
-- is therefore owned by this wrapper and cannot be forged by the core. NULL is
-- unreachable: the core's last statement is a jsonb_build_object with literal
-- keys, which is never SQL NULL, and a core that raised never reaches here.
--
-- SIGNATURE UNCHANGED, SO NO DROP. Same five parameters, so CREATE OR REPLACE
-- keeps the EXECUTE grants 0005 gave anon and authenticated. Dropping would
-- discard them and is not done here. The postflight re-checks both grants
-- rather than trusting that.
--
-- HISTORICAL ASSERTIONS THIS MIGRATION SUPERSEDES. These were correct when
-- written and are NOT defects. They are point-in-time evidence and the files
-- holding them stay frozen and must not be re-run as current-state gates:
--
--   0021_freebusy_busy_only_test.sql  R8 P1, R8 P2, R11, R17, R18 A, R18 B
--       required wrapper JSONB = core JSONB. After U2 the wrapper answer is
--       core || {"link_state":"active"}. R18.A additionally asserted that an
--       all-available calendar returns "the same one an expired or unknown
--       token returns" -- precisely the identity U2 removes.
--   0022_postflight.sql  B04
--       required the wrapper body to mention neither share_available nor
--       link_state. The share_available half still holds and is re-gated here.
--   0022_share_available_test.sql  assertion 8.5
--       required the anonymous answer to carry no link_state key.
--
-- Every still-valid Busy invariant behind R1-R18 is re-expressed in
-- 0023_link_state_test.sql; see the mapping table in that file's header.
--
-- APPLYING THIS FILE VALIDATES NOTHING. 0023_preflight.sql before,
-- 0023_postflight.sql and 0023_link_state_test.sql after.
-- ============================================================================

begin;

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

  -- 2. Resolve an ACTIVE token (hash compare). Invalid, expired, revoked and
  --    deleted all fall to ONE answer, link_state = 'unavailable', and nothing
  --    is charged: the predicate is 0018's, only the selected columns differ (the
  --    link id is needed as a key). U2: the REASON stays secret, but this answer
  --    is no longer byte-identical to an active link with an empty window. That
  --    distinguishability is deliberate -- see this file's header.
  select s.id, s.owner_id
    into v_link, v_owner
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

  return v_result || jsonb_build_object('link_state', 'active');
end;
$fn$;

-- ============================================================================
-- EXECUTE privileges.
--
-- Deliberately NOT restated. The signature is unchanged, so CREATE OR REPLACE
-- preserved what 0005 granted (anon, authenticated) and what 0019 left alone.
-- Re-issuing the grants here would be a change to something this migration is
-- supposed to leave exactly as it found it, and it would hide a real failure:
-- if the grants were somehow lost, the postflight's W04 gate must say so rather
-- than this file quietly putting them back.
--
-- timeweave_private.free_busy_core keeps 0019's revokes untouched, for the same
-- reason -- it is not replaced here at all.
-- ============================================================================

commit;
