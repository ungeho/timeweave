-- ============================================================================
-- TimeWeave -- runtime suite for 0022_share_link_share_available.sql
--
-- WHAT IT COVERS. The behaviour 0022_postflight.sql cannot see from the
-- catalog: what create_share_link actually writes, what set_share_available
-- actually changes and refuses, and -- the one that matters most for this
-- migration -- that storing share_available = true changes NOTHING about what
-- an anonymous viewer receives.
--
-- WHAT IT DOES NOT COVER. Available computation. There is none yet. No
-- assertion here mentions available.status, available.slots or link_state,
-- because 0022 does not create them and S8 proves the response still has
-- exactly the two keys it has always had.
--
-- ============================================================================
-- PRECONDITIONS. READ THESE BEFORE RUNNING.
--
--   1. 0022 has been applied and its postflight shows P00 = 0.
--
--   2. The test owner below is a DEDICATED user. Section 0 refuses to run if
--      it already owns share links or events, and it refuses rather than
--      deleting anything: a suite that cleans up someone's data to make room
--      for itself is a suite that can destroy it.
--
--   3. THE CREATE-RATE BUDGET. 0016 allows 5 share-link INSERTs per minute per
--      owner (share_links_rate_burst = 5, share_links_rate_interval = 1
--      minute), and charges PER ROW, not per statement (0016:158-161), so a
--      multi-row INSERT cannot dodge it. This suite performs exactly 4 rows:
--      THREE through create_share_link -- one per call shape: omitted fourth
--      argument, explicit false, explicit true -- and ONE direct INSERT, the
--      expired fixture, which needs a backdated created_at the RPC cannot
--      produce. Everything else the suite needs is reached with UPDATEs and
--      with set_share_available, which cost nothing against this budget. It
--      stays under the limit ON PURPOSE and no trigger is disabled anywhere in
--      this file. If the test owner's bucket is warm from an earlier run, wait
--      a minute rather than raising the limit or bypassing the trigger.
--
--   4. Everything runs inside ONE transaction and ends in ROLLBACK. Nothing
--      here is meant to persist, including the rate-limit state the INSERTs
--      write -- that rolls back with the rest.
--
-- HOW TO READ THE RESULT. Every check is an ASSERT. Silence plus the notices
-- is a pass; the first failure aborts the transaction, which rolls the whole
-- thing back. Run it once, read the error if there is one, and do not "fix"
-- a fixture to make an assertion pass.
--
-- ROLES. auth.uid() reads request.jwt.claims, so the owner-facing calls set
-- that GUC and switch role to `authenticated` -- which is also what makes the
-- GRANTs real rather than assumed, since a superuser session would execute
-- these functions whatever their ACL says. Fixtures that write share_links
-- directly run as the ordinary session role, because 0004 revokes every table
-- privilege from authenticated and a direct INSERT there would fail with
-- 42501 -- correctly.
-- ============================================================================

begin;

-- ============================================================================
-- Section 0 -- the suite refuses to run against a populated owner.
-- ============================================================================
do $$
declare
  v_owner  constant uuid := '5e86935f-7661-4741-868f-0f51c4cf1727';
  v_n      bigint;
  v_exists boolean;
begin
  raise notice '0022 runtime suite: section 0, preconditions';

  -- THE OWNER HAS TO EXIST BEFORE ANYTHING ELSE IS WORTH CHECKING. share_links
  -- .owner_id carries a FK to auth.users (0004), so a mistyped uuid does not
  -- fail here -- both counts below are 0 for a user that does not exist -- it
  -- fails several sections later as a bare 23503 that names no cause. Same
  -- idiom as 0006_rrule_parser_test.sql:472-475: the suite CHECKS for the user
  -- and never creates one.
  select exists(select 1 from auth.users u where u.id = v_owner) into v_exists;
  assert v_exists,
    format('0.0 the test owner %s does not exist in auth.users. Create the test '
           'user through the normal Auth path and point v_owner at it; this '
           'suite never inserts into, updates or deletes auth.users.', v_owner);

  select count(*) into v_n from public.share_links s where s.owner_id = v_owner;
  assert v_n = 0,
    format('0.1 the test owner already has %s share link(s). Point v_owner at a '
           'dedicated test user. Do NOT delete rows to satisfy this assertion.', v_n);

  select count(*) into v_n from public.events e where e.owner_id = v_owner;
  assert v_n = 0,
    format('0.2 the test owner already has %s event(s). Same rule.', v_n);

  -- The grants, checked before any role switch so that a missing GRANT is
  -- reported as itself rather than as a confusing permission error later.
  assert has_function_privilege('authenticated',
           'public.set_share_available(uuid, boolean)', 'execute'),
    '0.3 authenticated must be able to execute set_share_available';
  assert not has_function_privilege('anon',
           'public.set_share_available(uuid, boolean)', 'execute'),
    '0.4 anon must NOT be able to execute set_share_available';
  assert not has_function_privilege('anon',
           'public.create_share_link(text, boolean, timestamptz, boolean)', 'execute'),
    '0.5 anon must NOT be able to execute create_share_link';
  assert not has_table_privilege('authenticated', 'public.share_links', 'update'),
    '0.6 authenticated must have no direct UPDATE on share_links';

  raise notice '0 OK';
end $$;


-- ============================================================================
-- Section 1 -- create_share_link: the default, the explicit value, the shape.
--
-- Two of the suite's three create calls, and two of its four rows. L1 is
-- created WITHOUT the new argument: that is the compatibility case, and it must
-- come out false from the PARAMETER default, not from the column's. L2 passes
-- the argument explicitly as true. The third shape -- an explicit false -- is
-- section 2's L3, where it costs no extra row.
-- ============================================================================
do $$
declare
  v_owner constant uuid := '5e86935f-7661-4741-868f-0f51c4cf1727';
  r1      record;
  r2      record;
begin
  raise notice '1: create_share_link default and explicit value';

  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_owner::text, 'role', 'authenticated')::text,
                     true);
  perform set_config('role', 'authenticated', true);
  assert current_user = 'authenticated', '1.0 role switch did not take effect';
  assert auth.uid() = v_owner, '1.0 auth.uid() does not resolve to the test owner';

  -- L1: the three-argument call an existing client still makes.
  select * into r1 from public.create_share_link('tw0022 L1', true, null);
  assert r1.share_available = false,
    '1.1 omitting p_share_available must yield false, got ' || r1.share_available::text;
  assert r1.include_private = true,  '1.2 include_private must be unchanged by this migration';
  assert r1.token is not null and length(r1.token) > 0, '1.3 the plaintext token is returned once';

  -- L2: explicit true, and include_private false -- the combination that would
  -- be impossible if anything coupled the two settings.
  select * into r2 from public.create_share_link('tw0022 L2', false, null, true);
  assert r2.share_available = true,
    '1.4 explicit p_share_available = true must be stored';
  assert r2.include_private = false,
    '1.5 share_available = true must NOT require include_private = true';

  perform set_config('role', 'none', true);

  -- The pair an earlier design would have rejected, read back off the row
  -- rather than off the returned record. Section 5b holds all four pairs at
  -- once; this one is checked here because it is the one section 1 creates.
  assert exists (select 1 from public.share_links s
                  where s.id = r2.id and s.include_private = false and s.share_available),
    '1.6 include_private = false with share_available = true must be storable';

  raise notice '1 OK';
end $$;


-- ============================================================================
-- Section 2 -- the fixtures the setter must refuse.
--
-- L3 IS CREATED THROUGH THE RPC WITH AN EXPLICIT FOURTH ARGUMENT OF false.
-- That is the third and last shape of the create call this suite has budget
-- for, and it costs no extra row: the link had to be created somehow, and
-- revoking it afterwards is an UPDATE. Together with section 1 the three call
-- shapes are covered -- omitted (the parameter DEFAULT), explicit false here,
-- explicit true there.
--
-- The revoking UPDATE is safe to add: it LOWERS the owner's active count, and
-- 0016's quota trigger keeps only owners whose count ROSE (0016:317-335), so it
-- selects nobody; the create-rate trigger is INSERT-only and does not fire at
-- all. It runs as the session role because 0004 revokes every table privilege
-- from authenticated -- a direct UPDATE as that role would fail 42501, and
-- correctly so.
--
-- L4 (expired) MUST STAY A DIRECT INSERT, and needs an explicit created_at in
-- the INSERT itself. 0014 requires expires_at > created_at, inside one
-- transaction now() is frozen, and create_share_link cannot backdate
-- created_at -- so no row created "now" can also be past its own expiry.
-- Backdating by two days satisfies both readings at once: later than the expiry
-- the row carries is what "expired" means, earlier than it is what the
-- constraint means. A follow-up UPDATE would come too late; the INSERT itself
-- would already have been refused.
-- ============================================================================
do $$
declare
  v_owner constant uuid := '5e86935f-7661-4741-868f-0f51c4cf1727';
  v_exp   constant uuid := '0022f001-0000-4000-8000-000000000004';
  v_rev   uuid;
  r3      record;
begin
  raise notice '2: revoked and expired fixtures';

  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_owner::text, 'role', 'authenticated')::text,
                     true);
  perform set_config('role', 'authenticated', true);

  -- The 4-argument signature with an EXPLICIT false, as opposed to section 1's
  -- omitted argument. Both must land on false, by different routes.
  select * into r3 from public.create_share_link('tw0022 L3 revoked', true, null, false);
  assert r3.share_available = false,
    '2.0 an explicit fourth argument of false must be stored as false, got '
    || r3.share_available::text;
  v_rev := r3.id;

  perform set_config('role', 'none', true);

  update public.share_links set revoked_at = now() where id = v_rev;

  insert into public.share_links
    (id, owner_id, token_hash, label, include_private, created_at, expires_at,
     revoked_at, share_available)
  values
    (v_exp, v_owner, encode(extensions.digest('tw0022-expired', 'sha256'), 'hex'),
     'tw0022 L4 expired', true, now() - interval '2 days', now() - interval '1 day',
     null, false);

  assert (select revoked_at is not null from public.share_links where id = v_rev),
    '2.1 the revoked fixture must be revoked';
  assert (select expires_at < now() from public.share_links where id = v_exp),
    '2.2 the expired fixture must be past its expiry';
  assert (select revoked_at is null from public.share_links where id = v_exp),
    '2.3 the expired fixture must NOT also be revoked -- the two cases stay separate';

  raise notice '2 OK';
end $$;


-- ============================================================================
-- Section 3 -- the setter on an eligible target: both directions, and
-- idempotency.
--
-- The boolean answers "was an eligible target set to this value", so setting a
-- value the row already holds is a success. If that ever returns false, the
-- caller can no longer tell "refused" from "already there".
-- ============================================================================
do $$
declare
  v_owner constant uuid := '5e86935f-7661-4741-868f-0f51c4cf1727';
  v_l1    uuid;
  v_ok    boolean;
begin
  raise notice '3: set_share_available on an active, owned link';

  select s.id into v_l1 from public.share_links s
   where s.owner_id = v_owner and s.label = 'tw0022 L1';
  assert v_l1 is not null, '3.0 L1 fixture missing';

  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_owner::text, 'role', 'authenticated')::text,
                     true);
  perform set_config('role', 'authenticated', true);

  -- false -> true
  v_ok := public.set_share_available(v_l1, true);
  assert v_ok, '3.1 setting true on an active owned link must return true';

  -- true -> true (idempotent)
  v_ok := public.set_share_available(v_l1, true);
  assert v_ok, '3.2 setting the value it already holds must still return true';

  -- true -> false
  v_ok := public.set_share_available(v_l1, false);
  assert v_ok, '3.3 setting false must return true';

  -- false -> false (idempotent)
  v_ok := public.set_share_available(v_l1, false);
  assert v_ok, '3.4 setting false twice must still return true';

  perform set_config('role', 'none', true);

  assert (select not share_available from public.share_links where id = v_l1),
    '3.5 the final stored value must be false';

  raise notice '3 OK';
end $$;


-- ============================================================================
-- Section 4 -- the setter refuses everything that is not an eligible target,
-- and changes nothing when it does.
-- ============================================================================
do $$
declare
  v_owner  constant uuid := '5e86935f-7661-4741-868f-0f51c4cf1727';
  v_other  constant uuid := '00000000-0000-4000-8000-0000000000ff';
  v_l1     uuid;
  -- L3's id is assigned by create_share_link now, so it is looked up by label
  -- rather than carried as a constant. L4 is still a direct INSERT and keeps its
  -- fixed id.
  v_rev    uuid;
  v_exp    constant uuid := '0022f001-0000-4000-8000-000000000004';
  v_ok     boolean;
  v_before timestamptz;
begin
  raise notice '4: refusals -- other owner, revoked, expired, absent, null id';

  select s.id into v_l1 from public.share_links s
   where s.owner_id = v_owner and s.label = 'tw0022 L1';
  select s.id into v_rev from public.share_links s
   where s.owner_id = v_owner and s.label = 'tw0022 L3 revoked';
  assert v_l1 is not null and v_rev is not null, '4.0a L1/L3 fixtures missing';

  -- 4a. A DIFFERENT caller. The session claims another subject, so auth.uid()
  --     is not the owner. No second auth.users row is needed: the predicate
  --     this proves is owner_id = auth.uid(), and that is what moves.
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_other::text, 'role', 'authenticated')::text,
                     true);
  perform set_config('role', 'authenticated', true);
  assert auth.uid() = v_other, '4.0 the claim switch did not take effect';

  v_ok := public.set_share_available(v_l1, true);
  assert not v_ok, '4.1 another caller must not be able to set this link';

  -- 4b. Back to the owner: revoked and expired are refused.
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_owner::text, 'role', 'authenticated')::text,
                     true);

  -- Back to the session role BEFORE reading the table directly. 4a switched to
  -- `authenticated` for the other-caller RPC, and 0004 gives that role no
  -- privilege on share_links at all -- which is exactly what assertion 0.6
  -- asserts. Restoring the claims does not restore the role; they are separate
  -- dimensions, and only the session role may read this table.
  perform set_config('role', 'none', true);

  select revoked_at into v_before from public.share_links where id = v_rev;

  -- And back to `authenticated` for the negative API cases below. 4.2-4.5 are
  -- refusals an ordinary application caller must receive, so they should travel
  -- the same public EXECUTE path a real client does rather than arrive as the
  -- database owner. The claims set above already make auth.uid() the owner; this
  -- restores the other half of the pair.
  perform set_config('role', 'authenticated', true);

  v_ok := public.set_share_available(v_rev, true);
  assert not v_ok, '4.2 a revoked link must be refused';

  v_ok := public.set_share_available(v_exp, true);
  assert not v_ok, '4.3 an expired link must be refused';

  -- 4c. Absent and NULL identifiers land on the same answer, with no error.
  v_ok := public.set_share_available('00000000-0000-4000-8000-000000000999'::uuid, true);
  assert not v_ok, '4.4 an id that matches nothing must return false';

  v_ok := public.set_share_available(null::uuid, true);
  assert not v_ok, '4.5 a NULL id must return false, not raise';

  perform set_config('role', 'none', true);

  -- 4d. Nothing moved. The revoked link in particular must still be revoked
  --     with the SAME timestamp -- a settings call may not revive or re-stamp.
  assert (select not share_available from public.share_links where id = v_rev),
    '4.6 the revoked link must be unchanged';
  assert (select revoked_at from public.share_links where id = v_rev) = v_before,
    '4.7 revoked_at must not have been rewritten';
  assert (select not share_available from public.share_links where id = v_exp),
    '4.8 the expired link must be unchanged';
  assert (select expires_at < now() from public.share_links where id = v_exp),
    '4.9 the expired link must not have been extended';

  raise notice '4 OK';
end $$;


-- ============================================================================
-- Section 5 -- the setter touches one column and no other.
--
-- Recorded before, compared after. token_hash is included because the link's
-- identity IS its token: if that moved, every URL already handed out would
-- break, which is the one thing an owner adjusting a setting cannot be asked
-- to accept.
-- ============================================================================
do $$
declare
  v_owner constant uuid := '5e86935f-7661-4741-868f-0f51c4cf1727';
  v_l1    uuid;
  v_hash  text;
  v_label text;
  v_priv  boolean;
  v_exp   timestamptz;
  v_rev   timestamptz;
  v_made  timestamptz;
  v_own   uuid;
  v_ok    boolean;
begin
  raise notice '5: the setter changes share_available and nothing else';

  select s.id, s.token_hash, s.label, s.include_private, s.expires_at,
         s.revoked_at, s.created_at, s.owner_id
    into v_l1, v_hash, v_label, v_priv, v_exp, v_rev, v_made, v_own
  from public.share_links s
  where s.owner_id = v_owner and s.label = 'tw0022 L1';

  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_owner::text, 'role', 'authenticated')::text,
                     true);
  perform set_config('role', 'authenticated', true);
  v_ok := public.set_share_available(v_l1, true);
  assert v_ok, '5.0 the setter must succeed for this comparison to mean anything';
  perform set_config('role', 'none', true);

  assert (select share_available from public.share_links where id = v_l1),
    '5.1 share_available must now be true';
  assert (select token_hash      from public.share_links where id = v_l1) = v_hash,
    '5.2 token_hash must be untouched -- the share URL must keep working';
  assert (select label           from public.share_links where id = v_l1) is not distinct from v_label,
    '5.3 label must be untouched';
  assert (select include_private from public.share_links where id = v_l1) = v_priv,
    '5.4 include_private must be untouched';
  assert (select expires_at      from public.share_links where id = v_l1) is not distinct from v_exp,
    '5.5 expires_at must be untouched';
  assert (select revoked_at      from public.share_links where id = v_l1) is not distinct from v_rev,
    '5.6 revoked_at must be untouched';
  assert (select created_at      from public.share_links where id = v_l1) = v_made,
    '5.7 created_at must be untouched';
  assert (select owner_id        from public.share_links where id = v_l1) = v_own,
    '5.8 owner_id must be untouched';

  raise notice '5 OK';
end $$;


-- ============================================================================
-- Section 5b -- all four include_private x share_available combinations, held
-- by real rows at the same moment.
--
-- 0022 adds no CHECK tying the two settings together, which means all four
-- pairs must be reachable. "Reachable in principle" is not what this asserts:
-- each pair is read back off a row that is actually in the table here.
--
-- Two of the four are already on disk by now and cost nothing to confirm:
--   (include_private=true,  share_available=false)  L4, as section 2 created it
--   (include_private=true,  share_available=true )  L1, as section 5 left it
-- The remaining two come from L2, which section 1 created as (false, true):
--   (include_private=false, share_available=true )  L2 before the call below
--   (include_private=false, share_available=false)  L2 after it
--
-- The fourth pair is reached with the SETTER, not with another create call. The
-- create-rate budget is spent (section 2's note), and what matters here is that
-- the STATE is legal, not which statement produced it. This adds no row.
-- ============================================================================
do $$
declare
  v_owner constant uuid := '5e86935f-7661-4741-868f-0f51c4cf1727';
  v_l2    uuid;
  v_ok    boolean;
begin
  raise notice '5b: the four combinations';

  select s.id into v_l2 from public.share_links s
   where s.owner_id = v_owner and s.label = 'tw0022 L2';
  assert v_l2 is not null, '5b.0 L2 fixture missing';

  -- (include_private = true, share_available = false) -- L4, straight from
  -- section 2's INSERT. This is also the state 0022 leaves every pre-existing
  -- link in.
  assert exists (select 1 from public.share_links s
                  where s.owner_id = v_owner and s.label = 'tw0022 L4 expired'
                    and s.include_private and not s.share_available),
    '5b.1 include_private=true / share_available=false must exist (L4)';

  -- (include_private = true, share_available = true) -- L1, as section 5's
  -- setter call left it. Asserted as a PAIR here, rather than being inferred
  -- from 5.1 and 5.4 sitting in different assertions.
  assert exists (select 1 from public.share_links s
                  where s.owner_id = v_owner and s.label = 'tw0022 L1'
                    and s.include_private and s.share_available),
    '5b.2 include_private=true / share_available=true must exist (L1)';

  -- (include_private = false, share_available = true) -- L2 as created. The
  -- combination a coupling CHECK of the shape `not share_available or
  -- include_private` would have refused.
  assert exists (select 1 from public.share_links s
                  where s.id = v_l2 and not s.include_private and s.share_available),
    '5b.3 include_private=false / share_available=true must exist (L2)';

  -- (include_private = false, share_available = false) -- L2, opted back out.
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_owner::text, 'role', 'authenticated')::text,
                     true);
  perform set_config('role', 'authenticated', true);
  v_ok := public.set_share_available(v_l2, false);
  assert v_ok, '5b.4 the setter must accept L2 for the fourth pair to be reachable';
  perform set_config('role', 'none', true);

  assert exists (select 1 from public.share_links s
                  where s.id = v_l2 and not s.include_private and not s.share_available),
    '5b.5 include_private=false / share_available=false must exist (L2)';

  -- And opting out did not drag include_private along with it, which is the
  -- independence claim stated the other way round.
  assert (select not include_private from public.share_links where id = v_l2),
    '5b.6 turning share_available off must not have changed include_private';

  raise notice '5b OK';
end $$;


-- ============================================================================
-- Section 6 -- argument and caller validation.
--
-- NULL is rejected rather than coalesced. share_available is NOT NULL, so a
-- NULL argument that reached the column would surface as 23502 from inside a
-- function whose contract says nothing about it; and reading NULL as "leave it
-- alone" would quietly turn a one-column setter into a patch API.
--
-- Each expected failure is caught into a FLAG and judged afterwards, never with
-- an `assert false` inside the try block: ASSERT raises P0004, `when others`
-- would catch it, and the case that must fail loudest -- the call succeeding
-- when it should not -- would instead be reported as the wrong SQLSTATE.
-- ============================================================================
do $$
declare
  v_owner constant uuid := '5e86935f-7661-4741-868f-0f51c4cf1727';
  v_l1    uuid;
  v_state text;
  v_raised boolean;
begin
  raise notice '6: NULL value, and the unauthenticated path';

  select s.id into v_l1 from public.share_links s
   where s.owner_id = v_owner and s.label = 'tw0022 L1';

  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_owner::text, 'role', 'authenticated')::text,
                     true);
  perform set_config('role', 'authenticated', true);

  v_raised := false;
  begin
    perform public.set_share_available(v_l1, null::boolean);
  exception when others then
    v_raised := true;
    get stacked diagnostics v_state = returned_sqlstate;
  end;
  assert v_raised, '6.1 a NULL value must be rejected, not accepted silently';
  assert v_state = '22004', '6.1 a NULL value must raise 22004, got ' || v_state;

  -- No subject: auth.uid() is NULL and the function refuses before it looks at
  -- anything, exactly as create/revoke/delete do.
  --
  -- The claims are set to a VALID JSON object that simply has no `sub`, not to
  -- the empty string. auth.uid() casts this GUC to json, and whether an empty
  -- string reaches that cast as NULL or as invalid input depends on which
  -- revision of Supabase's auth schema the database carries. An object without
  -- `sub` yields NULL on every one of them, so this case tests the function's
  -- own guard rather than the platform's parsing.
  perform set_config('request.jwt.claims',
                     json_build_object('role', 'authenticated')::text, true);

  v_raised := false;
  begin
    perform public.set_share_available(v_l1, true);
  exception when others then
    v_raised := true;
    get stacked diagnostics v_state = returned_sqlstate;
  end;
  assert v_raised, '6.2 an unauthenticated caller must be refused, not served';
  assert v_state = '28000',
    '6.2 an unauthenticated caller must raise 28000, got ' || v_state;

  perform set_config('role', 'none', true);
  raise notice '6 OK';
end $$;


-- ============================================================================
-- Section 7 -- anon cannot reach the setter at all.
--
-- The grant is asserted in section 0; this is the call itself, because a GRANT
-- that is right in the catalog and wrong in effect is the failure mode worth
-- catching.
-- ============================================================================
do $$
declare
  v_owner constant uuid := '5e86935f-7661-4741-868f-0f51c4cf1727';
  v_l1     uuid;
  v_state  text;
  v_raised boolean;
begin
  raise notice '7: anon is refused by privilege';

  select s.id into v_l1 from public.share_links s
   where s.owner_id = v_owner and s.label = 'tw0022 L1';

  perform set_config('role', 'anon', true);

  v_raised := false;
  begin
    perform public.set_share_available(v_l1, true);
  exception when others then
    v_raised := true;
    get stacked diagnostics v_state = returned_sqlstate;
  end;
  assert v_raised, '7.1 anon must not be able to execute the setter';
  assert v_state = '42501', '7.1 anon must be refused with 42501, got ' || v_state;

  perform set_config('role', 'none', true);

  raise notice '7 OK';
end $$;


-- ============================================================================
-- Section 8 -- THE REGRESSION THAT MATTERS.
--
-- Storing share_available changes nothing an anonymous viewer can see. The
-- same token over the same window returns the SAME jsonb with the setting off
-- and on, and that jsonb still has exactly two keys. If a future change starts
-- reading the column, this is the assertion that will notice.
--
-- Two get_free_busy calls, against 0019's budget of 15 per link and 40 per
-- owner, so no limit is approached. Both calls share this DO block's
-- statement_timestamp() and both land in the same concurrency slot, which
-- pg_try_advisory_xact_lock re-grants to the session already holding it.
-- ============================================================================
do $$
declare
  v_owner constant uuid := '5e86935f-7661-4741-868f-0f51c4cf1727';
  v_ev    constant uuid := '0022e001-0000-4000-8000-000000000001';
  v_from  constant timestamptz := timestamptz '2026-06-01 00:00:00+00';
  v_to    constant timestamptz := timestamptz '2026-06-08 00:00:00+00';
  v_fd    constant date := date '2026-06-01';
  v_td    constant date := date '2026-06-08';
  v_l1    uuid;
  v_tok   text;
  v_off   jsonb;
  v_on    jsonb;
  v_ok    boolean;
  v_n     bigint;
begin
  raise notice '8: anonymous Free/Busy is unaffected by share_available';

  -- One ordinary busy event, so the comparison is between two NON-EMPTY
  -- answers rather than between two empty ones.
  insert into public.events (id, owner_id, title, visibility, all_day, start_at, end_at, availability)
  values (v_ev, v_owner, 'tw0022 busy', 'private', false,
          timestamptz '2026-06-02 09:00:00+00', timestamptz '2026-06-02 10:00:00+00', 'busy');

  select s.id into v_l1 from public.share_links s
   where s.owner_id = v_owner and s.label = 'tw0022 L1';

  -- A token this section can actually present. create_share_link returns the
  -- plaintext exactly once and section 1's copy died with that DO block's scope,
  -- and the table stores only the hash -- by design, since that is what stops
  -- list_share_links handing an owner's URLs back out. So L1 is given a known
  -- hash here, as the session role. This is a FIXTURE write, not something the
  -- API allows: section 5 has already proved the API leaves token_hash alone,
  -- and it ran first for exactly that reason.
  --
  -- share_available is reset to false in the same statement because section 5
  -- left it true, and this section needs to observe the off -> on transition.
  update public.share_links
     set token_hash = encode(extensions.digest('tw0022-anon-probe', 'sha256'), 'hex'),
         include_private = true,
         share_available = false
   where id = v_l1;
  v_tok := 'tw0022-anon-probe';

  perform set_config('role', 'anon', true);
  v_off := public.get_free_busy(v_tok, v_from, v_to, v_fd, v_td);
  perform set_config('role', 'none', true);

  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_owner::text, 'role', 'authenticated')::text,
                     true);
  perform set_config('role', 'authenticated', true);
  v_ok := public.set_share_available(v_l1, true);
  assert v_ok, '8.0 the setter must succeed for this comparison to mean anything';
  perform set_config('role', 'none', true);

  perform set_config('role', 'anon', true);
  v_on := public.get_free_busy(v_tok, v_from, v_to, v_fd, v_td);
  perform set_config('role', 'none', true);

  assert v_off = v_on,
    '8.1 the anonymous answer must be IDENTICAL with share_available off and on. off='
    || v_off::text || ' on=' || v_on::text;

  assert v_off = jsonb_build_object(
           'complete', true,
           'slots', jsonb_build_array(jsonb_build_object(
             'all_day', false,
             'start', to_jsonb(timestamptz '2026-06-02 09:00:00+00'),
             'end',   to_jsonb(timestamptz '2026-06-02 10:00:00+00')))),
    '8.2 the answer itself, got ' || v_off::text;

  -- Exactly two keys. Not "does not contain available" -- that would still pass
  -- if some other key appeared.
  select count(*) into v_n from jsonb_object_keys(v_on) k;
  assert v_n = 2, format('8.3 the response must have exactly two keys, got %s: %s',
                         v_n, (select string_agg(k, ',') from jsonb_object_keys(v_on) k));
  assert v_on ? 'complete' and v_on ? 'slots',
    '8.4 those two keys must be complete and slots';
  assert not (v_on ? 'available') and not (v_on ? 'link_state'),
    '8.5 0022 must not have introduced available or link_state';

  delete from public.events where id = v_ev;
  raise notice '8 OK';
end $$;


-- ============================================================================
-- Section 9 -- accounting.
--
-- The ROLLBACK below is what undoes the suite's writes; this section deletes
-- nothing, on purpose. A file that claims to change nothing has no business
-- issuing a DELETE against a live table -- if the rollback is the mechanism,
-- then the rollback should be the only mechanism.
--
-- What is checked instead is the COUNT: exactly the four fixture links and no
-- events, so a future edit that creates a fifth link or leaves an event behind
-- is noticed here rather than as a puzzling rate-limit refusal on the next run.
-- ============================================================================
do $$
declare
  v_owner constant uuid := '5e86935f-7661-4741-868f-0f51c4cf1727';
  v_n     bigint;
begin
  raise notice '9: accounting';

  select count(*) into v_n from public.share_links s where s.owner_id = v_owner;
  assert v_n = 4, format('9.1 expected exactly the 4 fixture links, found %s', v_n);

  select count(*) into v_n from public.events e where e.owner_id = v_owner;
  assert v_n = 0, format('9.2 expected no events left, found %s', v_n);

  raise notice '9 OK -- rolling back';
end $$;

rollback;
