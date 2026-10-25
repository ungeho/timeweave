-- ============================================================================
-- TimeWeave -- CLEANUP C1: delete the ONE born-dead share_links row that P2
-- found as D01, and nothing else.
--
-- ##################################################################
-- THIS FILE DELETES ONE ROW AND COMMITS. Run P2b first and confirm
-- M01 = 1 and P00 = 0. Run this once.
-- ##################################################################
--
-- WHAT IT DELETES. Exactly one row of public.share_links, identified by the
-- full fingerprint below rather than by its pseudonym alone. The pseudonym is a
-- 10-hex-character prefix -- 40 bits, not a key -- so it is a LOOKUP, never the
-- authority for a deletion.
--
-- THE FINGERPRINT, every part of which must hold on the same row:
--   substring(encode(sha256(uuid_send(id)), 'hex') from 1 for 10)
--     = 'b8c3a3d722'
--   expires_at is not null
--   expires_at <= created_at              -- born dead, the D01 condition
--   expires_at <= statement_timestamp()   -- and still expired now
--   revoked_at is null
--
-- A NOTE ON THE LAST LINE, because it was specified the other way round.
-- The cleanup request listed `revoked_at is not null`. P2b measured this row in
-- production as T04 = null (never revoked) and T08 = 0, and predicted the
-- owner's revoked count as unchanged by the delete (N07 4 -> N08 4). Written
-- as `is not null` the fingerprint would match ZERO rows and this script would
-- abort every time. It is written as `is null` to match the row that actually
-- exists. If the intent was a policy of "only ever delete already-revoked
-- rows", then this row does not qualify and it must be revoked first -- that is
-- a different, two-step operation and NOT this file.
--
-- NO SECRETS ARE EMBEDDED. The target's raw id, its owner_id, its token_hash
-- and its label text appear nowhere in this file. The pseudonym and the
-- fingerprint predicates are the only way it is named.
--
-- ORDER OF WORK, all inside one transaction:
--   1. LOCK public.share_links IN SHARE ROW EXCLUSIVE MODE NOWAIT, so no
--      concurrent write can change the count between the guard and the DELETE.
--      If another session holds a conflicting lock, stop at once.
--   2. Capture the pre-state into a temp table.
--   3. Capture the candidate ids. RAISE unless there is EXACTLY ONE.
--      This is the whole point of the file. There is no LIMIT 1 anywhere: a
--      second matching row must stop the work, never be silently spared.
--   4. DELETE the captured id, repeating the whole fingerprint in the DELETE
--      so the row still has to qualify at the moment it is removed.
--   5. Post checks: 1 row deleted, no row left matching the D01 condition, no
--      row left matching the pseudonym, the table exactly one row smaller, the
--      owner exactly one row smaller, and the owner's ACTIVE count unchanged.
--   6. RAISE unless every post check is ok. Report. COMMIT.
--
-- If any step fails, the transaction aborts and nothing is deleted. There is no
-- partial outcome: the guard, the DELETE and the post checks share one
-- transaction, so a failed postcondition un-does the DELETE.
--
-- Not done here on purpose: no VACUUM, no constraint is added, no other row is
-- touched, no setting is changed.
-- ============================================================================
begin;

lock table public.share_links in share row exclusive mode nowait;

-- 2. Pre-state. cl_owner carries the target's owner_id so the per-owner counts
--    never need a literal uuid written into this file.
create temp table cl_pre on commit drop as
with sl as (
  select s.id,
         s.owner_id,
         substring(encode(sha256(uuid_send(s.id)), 'hex')
                   from 1 for 10) as pseud,
         s.expires_at,
         s.revoked_at,
         s.created_at,
         (s.revoked_at is null
            and (s.expires_at is null
                 or s.expires_at > statement_timestamp())) as is_active
  from public.share_links as s
),
cand as (
  select * from sl
  where pseud = 'b8c3a3d722'
    and expires_at is not null
    and expires_at <= created_at
    and expires_at <= statement_timestamp()
    and revoked_at is null
),
-- There is no min(uuid) aggregate in PostgreSQL, and LIMIT is deliberately
-- not used anywhere in this file, so the owner is reduced through text. With
-- zero candidates this yields NULL and the guard below refuses; with two it
-- never matters, because the guard refuses on n_cand first.
cand_owner as (
  select max(owner_id::text)::uuid as owner_id from cand
)
select (select count(*) from cand)                      as n_cand,
       (select count(*) from sl)                        as n_total,
       (select count(*) from sl
         where pseud = 'b8c3a3d722')                    as n_pseud,
       (select count(*) from sl
         where expires_at is not null
           and expires_at <= created_at)                as n_born_dead,
       (select owner_id from cand_owner)                as owner_id,
       (select count(*) from sl
         where owner_id = (select owner_id from cand_owner))
                                                        as n_owner_total,
       (select count(*) from sl
         where owner_id = (select owner_id from cand_owner)
           and is_active)                               as n_owner_active,
       (select count(*) from sl
         where owner_id = (select owner_id from cand_owner)
           and revoked_at is not null)                  as n_owner_revoked;

-- 3. THE EXACTLY-ONE GUARD. Everything after this depends on it.
do $guard$
declare
  p record;
begin
  select * into p from cl_pre;

  if p.n_cand is distinct from 1 then
    raise exception
      'C1 STOPPED BEFORE DELETE: % rows match the fingerprint, not 1',
      p.n_cand
      using errcode = '23514', detail = 'TIMEWEAVE_C1_NOT_EXACTLY_ONE';
  end if;

  if p.n_pseud is distinct from 1 then
    raise exception
      'C1 STOPPED BEFORE DELETE: pseudonym b8c3a3d722 matches % rows, not 1',
      p.n_pseud
      using errcode = '23514', detail = 'TIMEWEAVE_C1_AMBIGUOUS_PSEUDONYM';
  end if;

  if p.n_born_dead is distinct from 1 then
    raise exception
      'C1 STOPPED BEFORE DELETE: % rows meet the D01 condition, not 1',
      p.n_born_dead
      using errcode = '23514', detail = 'TIMEWEAVE_C1_D01_COUNT';
  end if;

  if p.owner_id is null then
    raise exception 'C1 STOPPED BEFORE DELETE: no owner resolved'
      using errcode = '23514', detail = 'TIMEWEAVE_C1_NO_OWNER';
  end if;
end;
$guard$;

create temp table cl_target on commit drop as
select s.id
from public.share_links as s
where substring(encode(sha256(uuid_send(s.id)), 'hex')
                from 1 for 10) = 'b8c3a3d722'
  and s.expires_at is not null
  and s.expires_at <= s.created_at
  and s.expires_at <= statement_timestamp()
  and s.revoked_at is null;

do $cap$
declare
  v_n bigint;
begin
  select count(*) into v_n from cl_target;
  if v_n is distinct from 1 then
    raise exception 'C1 STOPPED BEFORE DELETE: captured % ids, not 1', v_n
      using errcode = '23514', detail = 'TIMEWEAVE_C1_CAPTURE';
  end if;
end;
$cap$;

create temp table cl_post (
  ord      text,
  metric   text,
  expected text,
  value    text
) on commit drop;

-- 4. The DELETE. The fingerprint is repeated here, so a row that stopped
--    qualifying between the capture and this statement is not removed.
with del as (
  delete from public.share_links as s
  where s.id in (select t.id from cl_target as t)
    and substring(encode(sha256(uuid_send(s.id)), 'hex')
                  from 1 for 10) = 'b8c3a3d722'
    and s.expires_at is not null
    and s.expires_at <= s.created_at
    and s.expires_at <= statement_timestamp()
    and s.revoked_at is null
  returning s.id
)
insert into cl_post
select 'D01', 'rows deleted by the statement', '1', count(*)::text
from del;

-- 5. Post checks, all inside the same transaction as the DELETE.
insert into cl_post
select 'D02', 'rows still matching the pseudonym', '0', count(*)::text
from public.share_links as s
where substring(encode(sha256(uuid_send(s.id)), 'hex')
                from 1 for 10) = 'b8c3a3d722';

insert into cl_post
select 'D03', 'rows still meeting the D01 condition', '0', count(*)::text
from public.share_links as s
where s.expires_at is not null
  and s.expires_at <= s.created_at;

insert into cl_post
select 'D04', 'share_links total', (p.n_total - 1)::text,
       (select count(*) from public.share_links)::text
from cl_pre as p;

insert into cl_post
select 'D05', 'owner total', (p.n_owner_total - 1)::text,
       (select count(*) from public.share_links as s
         where s.owner_id = p.owner_id)::text
from cl_pre as p;

insert into cl_post
select 'D06', 'owner ACTIVE (must be unchanged)', p.n_owner_active::text,
       (select count(*) from public.share_links as s
         where s.owner_id = p.owner_id
           and s.revoked_at is null
           and (s.expires_at is null
                or s.expires_at > statement_timestamp()))::text
from cl_pre as p;

insert into cl_post
select 'D07', 'owner revoked (must be unchanged)', p.n_owner_revoked::text,
       (select count(*) from public.share_links as s
         where s.owner_id = p.owner_id
           and s.revoked_at is not null)::text
from cl_pre as p;

insert into cl_post
select 'D08', 'net rows removed', '1',
       (p.n_total - (select count(*) from public.share_links))::text
from cl_pre as p;

-- 6. Refuse to commit unless every post check holds.
do $post$
declare
  v_fail text;
  v_n    bigint;
begin
  select string_agg(p.ord || ' ' || p.metric || ' expected ' || p.expected
           || ' got ' || coalesce(p.value, 'null'), '; ' order by p.ord)
           filter (where p.value is distinct from p.expected),
         count(*)
    into v_fail, v_n
  from cl_post as p;

  if v_fail is not null then
    raise exception 'C1 ROLLED BACK: %', v_fail
      using errcode = '23514', detail = 'TIMEWEAVE_C1_POSTCHECK';
  end if;
  if v_n is distinct from 8 then
    raise exception 'C1 ROLLED BACK: % post checks, not 8', v_n
      using errcode = '23514', detail = 'TIMEWEAVE_C1_POSTCOUNT';
  end if;
end;
$post$;

select p.ord,
       p.metric,
       p.expected,
       p.value,
       case when p.value is not distinct from p.expected
            then 'ok' else 'FAIL' end as status
from cl_post as p
order by p.ord;

commit;
