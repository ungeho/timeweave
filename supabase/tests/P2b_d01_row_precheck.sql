-- ============================================================================
-- TimeWeave -- PRECHECK P2b: is the ONE share_links row behind P2's D01 FAIL
-- safe to delete?
--
-- NOT A MIGRATION AND NOT A TEST SUITE. Run by hand, once, before any deletion
-- is proposed. READ-ONLY: no DDL, no DML, no SET, no temp table. One statement
-- inside a read-only transaction that ends in ROLLBACK.
--
-- BACKGROUND. P2 reported D01 = 1: one share link whose expires_at is at or
-- before its created_at, i.e. a link that was already dead the moment it was
-- made. P2 named it only by pseudonym, b8c3a3d722. The decision taken was NOT
-- to move expires_at into the future -- that could silently bring a link back
-- to life -- but to delete the row, and only after proving the deletion is
-- inert. This script is that proof. It deletes nothing.
--
-- THE PSEUDONYM IS THE SAME FUNCTION P2 USED, character for character:
--
--   substring(encode(sha256(uuid_send(id)), 'hex') from 1 for 10)
--
-- so a row matching here is the same row P2 pointed at. M01 asserts the match
-- is EXACTLY ONE row: a 10-hex-character prefix is not unique by construction,
-- and deleting on an ambiguous match would be indefensible. If M01 is not 1,
-- stop and do not delete anything.
--
-- PRIVACY. Returns counts, byte lengths, booleans and timestamps only. It never
-- returns the raw id, the raw owner_id, token_hash, the token, or the label
-- text. The owner appears only as its own sha256 pseudonym (T01), which is
-- enough to say "the same owner as X" without naming them.
--
-- WHAT "SAFE TO DELETE" MEANS HERE, and the limits of what a catalog can prove:
--   K01  no FOREIGN KEY in any table points at public.share_links, so no child
--        row is orphaned or cascaded.
--   K02  no user trigger fires on DELETE or TRUNCATE, so deleting runs no
--        application logic.
--   K04  no rewrite rule rewrites a DELETE on the table.
--   K06  no view is defined over the table.
--   K07  whether the table is in a logical replication publication, because a
--        DELETE there emits a replication/realtime event even though nothing in
--        the database depends on the row.
-- A catalog CANNOT prove there is no SOFT reference -- an application holding
-- this link's id in a config file, a log, or a bookmarked URL. The URL case is
-- the one that matters and it is already moot: the link is expired, so the URL
-- it belongs to already returns an empty Free/Busy result.
--
-- TOAST. octet_length(label) stops at the TOAST pointer and reads no chunk.
-- length(), char_length(), btrim(), substr() and convert_to() on a table column
-- all detoast and are not used on one here. substring() runs only over the
-- 64-character hex digest, never over a table's text column.
--
-- SHAPE. public.share_links is scanned once; the rest is catalog lookups on
-- three small system tables. The table held 16 rows at the last count.
--
-- READING THE OUTPUT. status is 'ok' / 'FAIL' where an expectation exists and
-- 'context' where the value informs the decision. P00 summarises. Every 'ok'
-- has to hold before a deletion is proposed.
-- ============================================================================
begin transaction read only;

with
sl as (
  select s.id,
         s.owner_id,
         substring(encode(sha256(uuid_send(s.id)), 'hex')
                   from 1 for 10) as pseud,
         substring(encode(sha256(uuid_send(s.owner_id)), 'hex')
                   from 1 for 10) as owner_pseud,
         octet_length(s.label) as lab_len,
         s.include_private,
         s.expires_at,
         s.revoked_at,
         s.created_at,
         (s.revoked_at is null
            and (s.expires_at is null or s.expires_at > now())) as is_active
  from public.share_links as s
),
hit as (
  select * from sl where pseud = 'b8c3a3d722'
),
tgt as (
  select count(*) as n_hit,
         max(owner_pseud) as owner_pseud,
         max(lab_len) as lab_len,
         count(*) filter (where lab_len is not null) as has_label,
         bool_and(include_private) as include_private,
         max(created_at) as created_at,
         max(expires_at) as expires_at,
         max(revoked_at) as revoked_at,
         count(*) filter (where revoked_at is not null) as n_revoked,
         count(*) filter (
           where expires_at <= created_at) as n_born_dead,
         count(*) filter (where expires_at <= now()) as n_expired_now,
         count(*) filter (where is_active) as n_active,
         max(extract(epoch from (expires_at - created_at))) as life_seconds
  from hit
),
owner_now as (
  select count(*) as n_total,
         count(*) filter (where is_active) as n_active,
         count(*) filter (where revoked_at is not null) as n_revoked
  from sl
  where owner_id in (select owner_id from hit)
),
all_now as (
  select count(*) as n_total from sl
),
fk_in as (
  select count(*) as n
  from pg_catalog.pg_constraint as c
  where c.contype = 'f'
    and c.confrelid = 'public.share_links'::regclass
),
fk_out as (
  select count(*) as n
  from pg_catalog.pg_constraint as c
  where c.contype = 'f'
    and c.conrelid = 'public.share_links'::regclass
),
trg as (
  select count(*) filter (
           where (t.tgtype & 40) <> 0) as on_delete_or_truncate,
         count(*) as all_user_triggers
  from pg_catalog.pg_trigger as t
  where t.tgrelid = 'public.share_links'::regclass
    and not t.tgisinternal
),
rules as (
  select count(*) as n
  from pg_catalog.pg_rewrite as r
  where r.ev_class = 'public.share_links'::regclass
    and r.rulename <> '_RETURN'
),
views as (
  select count(distinct d.refobjid) as n
  from pg_catalog.pg_depend as d
  join pg_catalog.pg_rewrite as r
    on r.oid = d.objid
  where d.refclassid = 'pg_class'::regclass
    and d.classid = 'pg_rewrite'::regclass
    and d.refobjid = 'public.share_links'::regclass
    and r.ev_class <> 'public.share_links'::regclass
),
pubs as (
  select count(*) as n
  from pg_catalog.pg_publication_tables as p
  where p.schemaname = 'public'
    and p.tablename = 'share_links'
),
res as (
  select v.ord, v.phase, v.metric, v.expected, v.value,
         case when v.expected is null then 'context'
              when v.value is not distinct from v.expected then 'ok'
              else 'FAIL'
         end as status
  from tgt as t
  cross join owner_now as o
  cross join all_now as a
  cross join fk_in
  cross join fk_out
  cross join trg
  cross join rules
  cross join views
  cross join pubs
  cross join lateral (values

    -- M. the match itself. Nothing below means anything unless M01 is 1.
    ('M01', 'match', 'rows whose pseudonym is b8c3a3d722', '1',
     t.n_hit::text),
    ('M02', 'match', 'share_links rows scanned', null, a.n_total::text),

    -- T. the target row, in non-secret terms only.
    ('T01', 'target', 'owner pseudonym (not the uuid)', null,
     coalesce(t.owner_pseud, 'no match')),
    ('T02', 'target', 'created_at', null,
     coalesce(t.created_at::text, 'no match')),
    ('T03', 'target', 'expires_at', null,
     coalesce(t.expires_at::text, 'no match')),
    ('T04', 'target', 'revoked_at', null,
     coalesce(t.revoked_at::text, 'null (never revoked)')),
    ('T05', 'target', 'expires_at <= created_at (born dead)', '1',
     t.n_born_dead::text),
    ('T06', 'target', 'expires_at <= now() (still expired today)', '1',
     t.n_expired_now::text),
    ('T07', 'target', 'counts as ACTIVE right now', '0', t.n_active::text),
    ('T08', 'target', 'revoked', null, t.n_revoked::text),
    ('T09', 'target', 'include_private', null,
     coalesce(t.include_private::text, 'no match')),
    ('T10', 'target', 'carries a label', null, t.has_label::text),
    ('T11', 'target', 'label bytes (content never shown)', null,
     coalesce(t.lab_len::text, 'no label')),
    ('T12', 'target', 'seconds of life (expires_at - created_at)', null,
     coalesce(round(t.life_seconds::numeric, 3)::text, 'no match')),

    -- K. what a DELETE would touch, from the catalog.
    ('K01', 'deps', 'foreign keys pointing AT share_links', '0',
     fk_in.n::text),
    ('K02', 'deps', 'user triggers firing on DELETE or TRUNCATE', '0',
     trg.on_delete_or_truncate::text),
    ('K03', 'deps', 'user triggers on the table, any event', null,
     trg.all_user_triggers::text),
    ('K04', 'deps', 'rewrite rules on the table', '0', rules.n::text),
    ('K05', 'deps', 'foreign keys FROM share_links (outbound, informational)',
     null, fk_out.n::text),
    ('K06', 'deps', 'views defined over the table', '0', views.n::text),
    ('K07', 'deps', 'logical replication publications carrying the table',
     null, pubs.n::text),

    -- N. the predicted effect of deleting exactly this one row.
    ('N01', 'effect', 'share_links total now', null, a.n_total::text),
    ('N02', 'effect', 'share_links total after the delete', null,
     (a.n_total - t.n_hit)::text),
    ('N03', 'effect', 'this owner total now', null, o.n_total::text),
    ('N04', 'effect', 'this owner total after the delete', null,
     (o.n_total - t.n_hit)::text),
    ('N05', 'effect', 'this owner ACTIVE now', null, o.n_active::text),
    ('N06', 'effect', 'this owner ACTIVE after the delete', null,
     (o.n_active - t.n_active)::text),
    ('N07', 'effect', 'this owner revoked now', null, o.n_revoked::text),
    ('N08', 'effect', 'this owner revoked after the delete', null,
     (o.n_revoked - t.n_revoked)::text),
    ('N09', 'effect', 'active count is unchanged by the delete', 'true',
     (t.n_active = 0)::text),
    ('N10', 'effect', 'P2 D01 would become 0 after the delete', 'true',
     (t.n_born_dead = (
        select count(*) from sl
        where expires_at <= created_at))::text)

  ) as v (ord, phase, metric, expected, value)
)
select ord, phase, metric, expected, value, status
from res
union all
select 'P00', 'summary', 'checks that FAIL', '0',
       count(*) filter (where status = 'FAIL')::text,
       case when count(*) filter (where status = 'FAIL') = 0
            then 'ok'
            else 'FAIL'
       end
from res
order by 1;

rollback;
