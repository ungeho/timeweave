-- ============================================================================
-- TimeWeave -- share_available: persistence and the owner-side API.
--
-- WHAT THIS IS. One column on public.share_links, the two owner RPCs that must
-- carry it (create_share_link, list_share_links), and one narrow setter so an
-- owner can change the setting on a link they already handed out.
--
-- WHAT THIS IS NOT. No change to timeweave_private.free_busy_core, to
-- public.get_free_busy, to any anonymous response, to revoke_share_link, to
-- delete_share_link, to RLS, to any index, or to public.events. Nothing reads
-- share_available yet: the Free/Busy path does not know the column exists.
--
-- ANONYMOUS BEHAVIOUR IS INTENTIONALLY UNCHANGED. After this file is applied,
-- the same token over the same window returns the same jsonb it returned
-- before -- {"complete": ..., "slots": ...} and nothing else -- whatever
-- share_available is set to. Storing `true` has no effect on what anyone can
-- see. The computation that gives the setting meaning is a separate change.
--
-- ============================================================================
-- WHY false IS THE DEFAULT, AND WHY THAT IS NOT 0020's ARGUMENT
--
-- 0020 could default availability to 'busy' because every existing row already
-- MEANT busy: the default restated what the data said. Nothing of the sort is
-- true here. No existing share link has ever expressed a preference about
-- sharing open time, because there was nothing to express it with.
--
-- So false is a POLICY, not a restatement: a link that was created before this
-- setting existed must not start disclosing anything new the moment a
-- migration runs. The owner has to ask for it. That is the whole reason the
-- setter below exists -- without it, "default off" would mean "off forever for
-- every link already in someone else's hands".
--
-- ============================================================================
-- WHY THIS IS INDEPENDENT OF include_private
--
-- include_private answers "may this link disclose PRIVATE events at all?".
-- share_available answers "may this link disclose OPEN time at all?". They
-- select on different columns of different tables and neither implies the
-- other, so all four combinations are legal and NO constraint ties them
-- together. A CHECK of the shape `not share_available or include_private`
-- would silently make one setting a precondition of the other, and an owner
-- who wanted to share open time from a link that hides private events could
-- not say so.
--
-- ============================================================================
-- WHY create_share_link IS DROPPED AND RE-CREATED, NOT REPLACED
--
-- Adding a parameter does not replace a function; it declares a second one.
-- Every parameter of the 0005 signature has a DEFAULT, and the new one would
-- too, so the client's existing three-named-argument call would match BOTH
-- candidates and PostgreSQL would refuse it as ambiguous. The old signature is
-- therefore dropped in the same transaction that creates the new one, and the
-- two never coexist.
--
-- That also loses the old signature's GRANTs -- privileges are per signature,
-- not per name -- so section 5 re-establishes them. Leaving that out would not
-- fail here; it would fail later, as a permission denied on the client.
--
-- list_share_links is dropped for a different reason: adding a column to a
-- RETURNS TABLE changes the function's result type, and CREATE OR REPLACE
-- cannot do that. Its signature is unchanged, so its GRANT is re-established
-- for the same name rather than a new one.
--
-- ============================================================================
-- WHY THE SETTER IS NARROW
--
-- set_share_available changes one column and takes no argument that could
-- reach another. revoked_at in particular is not addressable from it, so no
-- settings change can revive a revoked link -- that is a property of the
-- signature, not of a rule someone has to remember. label, include_private and
-- expires_at stay creation-only, exactly as they are today; this file adds no
-- way to edit them.
--
-- The authorisation decision lives in the UPDATE's own WHERE clause, following
-- 0015: owner, not revoked, not expired. Reading the row first and deciding
-- afterwards would leave a window in which a concurrent revoke lands between
-- the two statements. Here the row lock orders the two writers and the loser
-- re-reads, finds no row matching the predicate, and returns false.
--
-- ============================================================================
-- WHAT THE UPDATE TOUCHES BESIDES THE COLUMN
--
-- 0016's share_links_quota_au fires AFTER UPDATE for each statement. It runs,
-- and it does nothing: it aggregates the SIGNED delta of new_rows against
-- old_rows and keeps only owners whose active or total count ROSE (0016:317-
-- 335). This statement changes neither revoked_at nor expires_at and inserts
-- no row, so both deltas are zero and no owner is selected. The create-rate
-- trigger is INSERT-only and does not fire at all.
--
-- ============================================================================
-- ORDER
--
--   0022  this file (the column, the two RPCs, the setter)
--   then  the owner-facing control that calls the setter, and -- separately --
--         the Free/Busy change that finally reads the column.
--
-- Nothing depends on this file being applied before the application is
-- deployed, because no client code path requires the new parameter: the
-- existing three-argument create call keeps working through the new signature's
-- DEFAULT. A client that sends the fourth argument before this is applied would
-- fail, which is the usual DB-first ordering and not special to this change.
-- ============================================================================

begin;

-- ============================================================================
-- 1. The column.
--
-- `if not exists` matches 0008 and 0020 and keeps a second run from erroring on
-- the NAME. That is all it checks: a column already called share_available is
-- left alone whatever its type, default or nullability. This file is written
-- for a first application, not as an idempotent repair -- establishing what the
-- database actually holds is the preflight's job.
-- ============================================================================
alter table public.share_links
  add column if not exists share_available boolean not null default false;

comment on column public.share_links.share_available is
  'Whether this link may disclose the owner''s AVAILABLE time, in addition to '
  'the busy time it has always disclosed. Independent of include_private: that '
  'one decides whether private events participate at all, this one decides '
  'whether open time is shared. Default false, for existing and new links '
  'alike -- a link never starts sharing something new on its own.';

-- ============================================================================
-- 2. create_share_link.
--
-- The 0005 body, with the new column carried into the INSERT and the returned
-- row. coalesce(p_share_available, false) mirrors how the same body already
-- treats p_include_private: an explicit NULL from a client is read as "use the
-- default" rather than reaching a NOT NULL column and failing.
--
-- The plaintext token is still returned exactly once, here, and by nothing
-- else.
-- ============================================================================
drop function if exists public.create_share_link(text, boolean, timestamptz);

create or replace function public.create_share_link(
  p_label           text        default null,
  p_include_private boolean     default true,
  p_expires_at      timestamptz default null,
  p_share_available boolean     default false
)
returns table (
  id              uuid,
  token           text,
  label           text,
  include_private boolean,
  expires_at      timestamptz,
  created_at      timestamptz,
  share_available boolean
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_owner uuid := auth.uid();
  v_token text;
  v_hash  text;
begin
  if v_owner is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;

  -- URL-safe base64 of 32 random bytes (256-bit); strip '=' padding.
  v_token := translate(encode(extensions.gen_random_bytes(32), 'base64'), '+/=', '-_');
  v_hash  := encode(extensions.digest(v_token, 'sha256'), 'hex');

  return query
  with ins as (
    insert into public.share_links
      (owner_id, token_hash, label, include_private, expires_at, share_available)
    values
      (v_owner, v_hash, p_label, coalesce(p_include_private, true), p_expires_at,
       coalesce(p_share_available, false))
    returning share_links.id,
              share_links.label,
              share_links.include_private,
              share_links.expires_at,
              share_links.created_at,
              share_links.share_available
  )
  select ins.id, v_token, ins.label, ins.include_private, ins.expires_at,
         ins.created_at, ins.share_available
  from ins;
end;
$$;

-- ============================================================================
-- 3. list_share_links.
--
-- The 0005 body with one more column. token_hash is still never returned, and
-- neither is the plaintext token -- an existing link's URL cannot be recovered
-- from this function, which is what makes "revoke and re-issue" the only route
-- back when an owner loses it.
-- ============================================================================
drop function if exists public.list_share_links();

create or replace function public.list_share_links()
returns table (
  id              uuid,
  label           text,
  include_private boolean,
  expires_at      timestamptz,
  revoked_at      timestamptz,
  created_at      timestamptz,
  share_available boolean
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  return query
  select s.id, s.label, s.include_private, s.expires_at, s.revoked_at,
         s.created_at, s.share_available
  from public.share_links s
  where s.owner_id = auth.uid()
  order by s.created_at desc;
end;
$$;

-- ============================================================================
-- 4. set_share_available: the only way to change the setting after creation.
--
-- THE PREDICATE IS THE AUTHORISATION. owner_id, revoked_at and expires_at are
-- part of the UPDATE, not of an earlier SELECT, for the reason 0015 gives about
-- its own DELETE: this statement IS the decision. A link that is revoked or
-- past its expiry is not an eligible target, so a settings change can neither
-- revive nor extend one.
--
-- WHAT false MEANS. Absent, not yours, revoked, or expired -- one value for
-- every refusal, as in revoke_share_link and delete_share_link. The owner can
-- see which of those it was in list_share_links; the RPC does not need to say.
--
-- IDEMPOTENT ON PURPOSE. The current value is NOT part of the predicate, so
-- setting true over true returns true. The boolean answers "was an eligible
-- target set to this value", not "did a byte change". Including the current
-- value would make false mean two unrelated things -- refused, and already
-- there -- and the caller could not tell them apart.
--
-- p_enabled HAS NO DEFAULT and NULL is rejected outright. share_available is
-- NOT NULL, so a NULL argument would otherwise reach the column and surface as
-- 23502 from inside a function whose contract says nothing about it. This is
-- NOT "NULL means unchanged": there is no partial-update semantics here, and
-- adding one would turn a one-column setter into a patch API.
--
-- p_id NULL needs no such check: `id = p_id` is never true for NULL, so it
-- lands on the ordinary "no eligible target" answer.
-- ============================================================================
create or replace function public.set_share_available(
  p_id      uuid,
  p_enabled boolean
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_done boolean;
begin
  if auth.uid() is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;

  if p_enabled is null then
    raise exception 'share_available must be true or false'
      using errcode = '22004';
  end if;

  update public.share_links
     set share_available = p_enabled
   where id = p_id
     and owner_id = auth.uid()
     and revoked_at is null
     and (expires_at is null or expires_at > now())
  returning true into v_done;

  return coalesce(v_done, false);
end;
$$;

-- ============================================================================
-- 5. EXECUTE privileges.
--
-- create_share_link's old signature took its GRANT with it when it was dropped,
-- so the new one is granted from scratch, and PostgreSQL's default PUBLIC grant
-- on a freshly created function is revoked first -- the same two lines 0005 and
-- 0015 write for every function they add. list_share_links keeps its name but
-- was also dropped, so it is treated the same way.
--
-- anon is given nothing here. Every function in this file writes or reads an
-- owner's own rows and is reachable only with a session.
-- ============================================================================
revoke execute on function public.create_share_link(text, boolean, timestamptz, boolean) from public;
revoke execute on function public.list_share_links()                                     from public;
revoke execute on function public.set_share_available(uuid, boolean)                     from public;

grant execute on function public.create_share_link(text, boolean, timestamptz, boolean) to authenticated;
grant execute on function public.list_share_links()                                     to authenticated;
grant execute on function public.set_share_available(uuid, boolean)                     to authenticated;

commit;
