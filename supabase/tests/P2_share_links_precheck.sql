-- ============================================================================
-- TimeWeave -- PRECHECK P2 for the planned share_links constraints, quota and
-- rate limit.
--
-- NOT A MIGRATION AND NOT A TEST SUITE. Run by hand, once, against the project
-- the changes will be applied to, BEFORE any migration is written.
--
-- READ-ONLY: no DDL, no DML, no SET, no temp table, no function creation. One
-- statement inside a read-only transaction that ends in ROLLBACK.
--
-- WHAT IT GATES:
--
--   CHECK      octet_length(label) <= 200                        -> C01-C03
--   CHECK      expires_at > created_at (no born-dead link)        -> D01-D03
--   CHECK      expires_at inside the technical date range         -> D04-D06
--   trigger    active share links <= 25 per owner                 -> Q01-Q04
--   trigger    total share-link rows <= 200 per owner             -> Q05-Q08
--   RPC        delete_share_link, needed to escape the total quota-> R01-R05
--
-- THE TECHNICAL DATE RANGE tested here is [0100-01-01, 9999-12-31], which is
-- NOT a product opinion. It is where TimeWeave's own implementation stops
-- working, established by measurement:
--   * above 9999-12-31 the RRULE UNTIL grammar cannot express the year at all
--     (TS /^(\d{4})(\d{2})(\d{2})$/ and SQL '^[0-9]{8}$' both require exactly
--     four digits), and Date#toISOString switches to the +NNNNNN extended form,
--     which breaks the localeCompare ordering that occurrences.ts and
--     dayAgenda.ts rely on to sort occurrences.
--   * below 0100-01-01 the two-digit-year rule of the Date constructor makes
--     isoFromDateString('0050-06-15') silently return 1950, with no error.
-- The JS Date absolute limit (275760-09-13) and the ISO extended-year boundary
-- (10000-01-01) are both OUTSIDE this range, so this is the binding one.
--
-- PRIVACY. Counts, byte lengths and timestamps only. It never returns a label,
-- a token, a token_hash or an id. Rows that need to stay identifiable are named
-- by the same pseudonym P1 used:
--
--   substring(encode(sha256(uuid_send(id)), 'hex') from 1 for 10)
--
-- At most 5 per finding. The digest is stable, so the same expression run later
-- maps a pseudonym back to its row. substring() runs over a 64-character hex
-- digest held in memory, never over a table's text column.
--
-- TOAST. octet_length(label) stops at the TOAST pointer and reads no chunk.
-- length(), char_length(), btrim(), substr() and convert_to() on a table column
-- all detoast and are not used on one here.
--
-- SHAPE. public.share_links is scanned exactly once (the sl CTE is referenced
-- more than once, so it materialises). No join to any other table, no
-- self-join, no catalog scan. share_links held 16 rows at the last count, so
-- this is far lighter than P1.
--
-- READING THE OUTPUT. status is 'ok' / 'FAIL' where an expectation exists and
-- 'context' where the value is a measurement. P00 summarises. The quota rows
-- Q01-Q08 are deliberately EXPECTATIONS, not context: a FAIL there means the
-- proposed number would refuse an owner who is already over it, which is the
-- one thing the delta rule must be designed around.
-- ============================================================================
begin transaction read only;

with
sl as (
  select s.id,
         s.owner_id,
         octet_length(s.label) as lab_len,
         s.expires_at,
         s.revoked_at,
         s.created_at,
         (s.revoked_at is null
            and (s.expires_at is null or s.expires_at > now())) as is_active,
         coalesce(s.expires_at <= s.created_at, false) as born_dead,
         coalesce(s.expires_at > timestamptz '9999-12-31 00:00:00+00'
               or s.expires_at < timestamptz '0100-01-01 00:00:00+00',
                  false) as exp_out_of_range
  from public.share_links as s
),
per_owner as (
  select owner_id,
         count(*) as n_total,
         count(*) filter (where is_active) as n_active,
         count(*) filter (where revoked_at is not null) as n_revoked
  from sl
  group by owner_id
),
agg as (
  select count(*) as n_rows,
         count(*) filter (where lab_len is not null) as n_labelled,
         max(lab_len) as lab_max,
         count(*) filter (where lab_len > 200) as lab_over_200,
         count(*) filter (where lab_len > 100) as lab_over_100,
         count(*) filter (where is_active) as n_active,
         count(*) filter (where revoked_at is not null) as n_revoked,
         count(*) filter (where expires_at is null) as n_no_expiry,
         count(*) filter (where born_dead) as n_born_dead,
         count(*) filter (where exp_out_of_range) as n_exp_out,
         min(created_at) as created_min,
         max(created_at) as created_max,
         min(expires_at) as exp_min,
         max(expires_at) as exp_max,
         min(revoked_at) as revoked_min,
         max(revoked_at) as revoked_max,
         min(created_at) filter (
           where revoked_at is not null) as revoked_created_min,
         max(created_at) filter (
           where revoked_at is not null) as revoked_created_max
  from sl
),
owners as (
  select count(*) as n_owners,
         coalesce(max(n_total), 0) as max_total,
         coalesce(max(n_active), 0) as max_active,
         coalesce(max(n_revoked), 0) as max_revoked,
         count(*) filter (where n_active > 25) as over_active_quota,
         count(*) filter (where n_total > 200) as over_total_quota,
         count(*) filter (where n_active > 20) as near_active_quota,
         count(*) filter (where n_total > 160) as near_total_quota
  from per_owner
),
res as (
  select v.ord, v.phase, v.metric, v.expected, v.value,
         case when v.expected is null then 'context'
              when v.value is not distinct from v.expected then 'ok'
              else 'FAIL'
         end as status
  from agg as g
  cross join owners as o
  cross join lateral (values

    -- A. shape of the table right now.
    ('A01', 'baseline', 'share_links rows', null, g.n_rows::text),
    ('A02', 'baseline', 'distinct owners', null, o.n_owners::text),
    ('A03', 'baseline', 'rows carrying a label', null, g.n_labelled::text),
    ('A04', 'baseline', 'active rows (not revoked, not expired)', null,
     g.n_active::text),
    ('A05', 'baseline', 'revoked rows', null, g.n_revoked::text),
    ('A06', 'baseline', 'rows with no expiry', null, g.n_no_expiry::text),

    -- C. label byte length -> the octet_length(label) <= 200 CHECK.
    ('C01', 'label', 'max octet_length(label)', null,
     coalesce(g.lab_max::text, 'no labels')),
    ('C02', 'label', 'labels over the proposed 200 bytes', '0',
     g.lab_over_200::text),
    ('C03', 'label', 'labels over 100 bytes (half the limit)', null,
     g.lab_over_100::text),

    -- D. expires_at sanity -> two separate CHECKs.
    ('D01', 'expiry', 'links whose expires_at <= created_at', '0',
     g.n_born_dead::text),
    ('D02', 'expiry', 'min expires_at', null,
     coalesce(g.exp_min::text, 'none set')),
    ('D03', 'expiry', 'max expires_at', null,
     coalesce(g.exp_max::text, 'none set')),
    ('D04', 'expiry',
     'expires_at outside [0100-01-01, 9999-12-31] (technical range)', '0',
     g.n_exp_out::text),
    ('D05', 'expiry', 'pseudonyms of up to 5 born-dead links', null,
     coalesce((
       select string_agg(x.h, ' ')
       from (
         select substring(encode(sha256(uuid_send(v.id)), 'hex')
                          from 1 for 10) as h
         from sl as v
         where v.born_dead
         order by v.id
         limit 5
       ) as x
     ), 'none')),
    ('D06', 'expiry',
     'pseudonyms of up to 5 links with an out-of-range expires_at', null,
     coalesce((
       select string_agg(x.h, ' ')
       from (
         select substring(encode(sha256(uuid_send(v.id)), 'hex')
                          from 1 for 10) as h
         from sl as v
         where v.exp_out_of_range
         order by v.id
         limit 5
       ) as x
     ), 'none')),

    -- Q. the two quotas. Expectations, not context: see the header.
    ('Q01', 'quota', 'owners over the proposed ACTIVE quota of 25', '0',
     o.over_active_quota::text),
    ('Q02', 'quota', 'largest ACTIVE count held by one owner', null,
     o.max_active::text),
    ('Q03', 'quota', 'owners already past 20 active (80% of the quota)', null,
     o.near_active_quota::text),
    ('Q04', 'quota', 'headroom: 25 minus the largest active count', null,
     (25 - o.max_active)::text),
    ('Q05', 'quota', 'owners over the proposed TOTAL quota of 200', '0',
     o.over_total_quota::text),
    ('Q06', 'quota', 'largest TOTAL row count held by one owner', null,
     o.max_total::text),
    ('Q07', 'quota', 'owners already past 160 total (80% of the quota)', null,
     o.near_total_quota::text),
    ('Q08', 'quota', 'headroom: 200 minus the largest total count', null,
     (200 - o.max_total)::text),

    -- R. revoked rows. These are what the total quota accumulates and what
    -- delete_share_link has to be able to clear. The age spread says how much
    -- history a deletion would actually be discarding.
    ('R01', 'revoked', 'revoked rows in total', null, g.n_revoked::text),
    ('R02', 'revoked', 'largest revoked count held by one owner', null,
     o.max_revoked::text),
    ('R03', 'revoked', 'oldest revoked_at', null,
     coalesce(g.revoked_min::text, 'none revoked')),
    ('R04', 'revoked', 'newest revoked_at', null,
     coalesce(g.revoked_max::text, 'none revoked')),
    ('R05', 'revoked', 'oldest created_at among revoked rows', null,
     coalesce(g.revoked_created_min::text, 'none revoked')),
    ('R06', 'revoked', 'newest created_at among revoked rows', null,
     coalesce(g.revoked_created_max::text, 'none revoked')),

    -- X. context for the rate limiter. There is no share-link rate state to
    -- read yet; created_at spread is the only evidence of real creation pace.
    ('X01', 'rate', 'oldest created_at', null,
     coalesce(g.created_min::text, 'no rows')),
    ('X02', 'rate', 'newest created_at', null,
     coalesce(g.created_max::text, 'no rows')),
    ('X03', 'rate', 'days spanned by all share-link creation', null,
     coalesce(round(extract(epoch from (g.created_max - g.created_min))
              / 86400.0, 2)::text, 'n/a')),
    -- Guarded at one hour, not at created_max > created_min. A span of a few
    -- microseconds is arithmetically a span but divides into a meaningless
    -- rate (a local fixture whose rows shared one timestamp reported
    -- 276,480,000 links per day). Under an hour there is nothing to average.
    ('X04', 'rate', 'links per day over that span', null,
     case when g.created_max - g.created_min >= interval '1 hour'
          then round(g.n_rows / (extract(epoch from
               (g.created_max - g.created_min)) / 86400.0), 3)::text
          else 'n/a (span under an hour)'
     end)

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
