-- ============================================================================
-- TimeWeave Phase 6-x (M-E): delete_share_link, the owner-only physical delete.
--
-- WHAT THIS IS. One SECURITY DEFINER function and its two EXECUTE grants.
-- Nothing else changes: no table privilege is granted or revoked, no CHECK is
-- added or altered, no trigger is created, no existing function is redefined,
-- and public.events is not touched.
--
-- WHY IT EXISTS. share_links has one lifecycle verb today and it is a soft one:
-- revoke_share_link sets revoked_at and the row stays forever. That conflates
-- two different things an owner may want:
--
--   revoke = "this URL must stop working"      (0005, unchanged by this file)
--   delete = "this row must stop existing"     (this file)
--
-- Separating them is worth doing on its own, but the operational reason is the
-- total-row quota M-D will add. A stock quota that counts every row an owner has
-- ever created, with no way to remove a row, is a quota an owner can be locked
-- behind permanently: revoking does not help, because a revoked row still
-- occupies the count. An owner must always be able to tidy their way back under
-- a limit they have hit -- the same principle 0012 stated when it declined to
-- charge DELETE against the write-rate limiter. This function is that escape
-- route, and it ships before the quota that needs it.
--
-- WHAT IT IS NOT FOR. This is not an audit log and revoked rows are not audit
-- records. Nothing reads revoked_at except list_share_links (to render a badge)
-- and the P2 precheck. Deleting a revoked row destroys no evidence anything in
-- this system relies on. If that ever changes, this function is the place the
-- change must be argued, not worked around.
--
-- ============================================================================
-- THE RULE: OWNER AND REVOKED, BOTH INSIDE THE PREDICATE
--
-- A row may be physically deleted only when BOTH hold:
--
--   owner_id = auth.uid()        the caller owns it
--   revoked_at is not null       it is already revoked
--
-- so the lifecycle is strictly active -> revoke -> delete, and an ACTIVE link
-- can never be deleted in one step. That is not a convenience; it is what keeps
-- this function from becoming a second, quieter revoke path. Revoking is the
-- step that makes a live URL stop working, and it is the step whose timestamp
-- an owner can see in the list before they decide to discard the row. A delete
-- that skipped it would let a misclick destroy a link that is still in someone
-- else's hands with no intermediate state in which the owner could notice.
--
-- BOTH CONDITIONS LIVE IN THE DELETE'S OWN WHERE CLAUSE. Neither is checked in
-- a preceding SELECT. A DEFINER function bypasses RLS, so the statement that
-- actually removes the row has to be the statement that carries the whole rule;
-- a check-then-act pair would be two snapshots with a window between them, and
-- the check would be advisory rather than binding. Written this way the delete
-- is a single statement against a single row found by primary key, and a
-- concurrent revoke or delete cannot land between the test and the effect.
--
-- The owner is read from auth.uid() inside the function. It is NEVER taken from
-- a parameter -- there is no p_owner_id and there must never be one, because a
-- caller-supplied owner on a DEFINER function that bypasses RLS is simply an
-- authorisation bypass with extra steps.
--
-- ============================================================================
-- THE RETURN CONTRACT, AND WHY IT IS EXACTLY revoke_share_link's
--
-- 0005's revoke_share_link(p_id uuid) returns boolean, raises 28000 when
-- unauthenticated, and returns false -- indistinguishably -- for a row that does
-- not exist, a row owned by somebody else, and a row already in the target
-- state. This function copies that contract verbatim:
--
--   unauthenticated caller  raise 28000 'authentication required'
--   nonexistent id          false
--   another owner's id      false
--   own ACTIVE link         false, AND THE ROW IS NOT DELETED
--   own REVOKED link        true, row gone
--   called again on it      false (so a double call is idempotent)
--
-- The uniform false is the point. Distinguishing "no such link" from "not
-- yours" would turn this function into an existence oracle for other owners'
-- primary keys: a caller could enumerate ids and learn which ones are real.
-- Distinguishing "not yours" from "not revoked yet" would leak the state of
-- another owner's row. One value for every refusal leaks nothing that the
-- caller did not already know, and it is the behaviour revoke_share_link has
-- had since 0005, so the two verbs stay readable side by side.
--
-- The cost is that a client cannot tell "already gone" from "not revoked yet".
-- That is acceptable here and is not a new situation: shareRepository's
-- revokeShareLink already returns Boolean(data) and ShareDialog's handleRevoke
-- already discards it, refreshing the list instead and letting the refreshed
-- rows speak. A delete button would do exactly the same. Raising a distinct
-- error for the active case was considered and rejected: it would make the
-- refusal legible only by making the other refusals legible too, since a
-- client that can see "this one was active" can infer that the ids which did
-- not raise that error were either absent or someone else's.
--
-- SECURITY DEFINER with `set search_path = ''`, matching all four functions in
-- 0005: every non-catalog object is schema-qualified, so no object on a
-- caller-controlled search_path can be substituted for the ones named here.
-- No dynamic SQL is used, so there is no string for a parameter to escape into;
-- p_id is a uuid and reaches the planner as a bound parameter.
--
-- ============================================================================
-- STILL NO TABLE PRIVILEGES
--
-- 0004 revoked ALL on public.share_links from anon and from authenticated, and
-- this file does not give any of it back. In particular it does NOT grant
-- DELETE on the table. A direct grant would be a strictly wider hole than the
-- function: DELETE on the table is filtered only by the owner-only RLS policy,
-- which says nothing about revoked_at, so `delete from share_links where true`
-- over PostgREST would remove every link the caller owns including the active
-- ones -- precisely the operation this design exists to forbid. The function is
-- the only delete path, exactly as 0005 made the four RPCs the only read and
-- write paths.
--
-- EXECUTE follows 0005's pattern: revoke the grant PostgreSQL hands to PUBLIC
-- by default, then grant to `authenticated` alone. anon is granted nothing;
-- anon reaching this function would be an unauthenticated caller and would get
-- 28000 even if it could, but the grant is the boundary that matters and it is
-- simply not given.
--
-- ============================================================================
-- DELIBERATELY NOT IN THIS FILE
--
-- The active quota (25/owner) and the total quota (200/owner), the share-link
-- create rate limiter and its GCRA state, any rate charge on create, revoke or
-- delete, any change to the CHECK constraints 0014 added, anything touching
-- public.events, the recurrence-graph trigger, any FreeBusy or get_free_busy
-- change, token-length hardening, created_at/updated_at hygiene, any advisory
-- lock, and any client or UI change. Several of those are the next migrations;
-- none of them belongs in the one that defines the verb.
--
-- No advisory lock is taken. The delete is one statement finding one row by
-- primary key: PostgreSQL's own row lock orders concurrent callers, the loser
-- re-reads after waiting under READ COMMITTED and finds no row, and returns
-- false. There is nothing here for a lock to protect that the row lock does not
-- already protect, and adding one would create an ordering obligation against
-- 0011's 811002 -> 811001 contract for no gain.
-- ============================================================================
begin;

create or replace function public.delete_share_link(p_id uuid)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_owner uuid := auth.uid();
  v_done  boolean;
begin
  if v_owner is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;

  -- Both conditions are part of the DELETE itself, not of an earlier SELECT:
  -- this statement is the authorisation decision, not a consequence of one.
  -- revoked_at is not null is what makes active -> revoke -> delete the only
  -- order in which a row can leave this table.
  delete from public.share_links
   where id = p_id
     and owner_id = v_owner
     and revoked_at is not null
  returning true into v_done;

  -- One value for every refusal: absent, not yours, or not revoked yet.
  return coalesce(v_done, false);
end;
$$;

-- ============================================================================
-- EXECUTE privileges, following 0005: drop PostgreSQL's default PUBLIC grant
-- first, then grant narrowly. authenticated only; anon is given nothing.
-- ============================================================================
revoke execute on function public.delete_share_link(uuid) from public;
grant  execute on function public.delete_share_link(uuid) to authenticated;

commit;
