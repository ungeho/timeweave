-- ============================================================================
-- TimeWeave -- PRECHECK P1 for the planned DB-invariant constraints.
--
-- NOT A MIGRATION AND NOT A TEST SUITE. Run by hand, once, against the project
-- the constraints will be applied to, BEFORE any migration is written.
--
-- READ-ONLY: no DDL, no DML, no SET, no temp table, no function creation. The
-- whole script is one statement inside a read-only transaction that ends in
-- ROLLBACK, so a reader does not have to take "it only reads" on trust.
--
-- WHAT IT GATES. Each of these is a CHECK constraint we intend to add in one
-- migration. A plain ADD CONSTRAINT validates immediately and ABORTS on the
-- first offending row, so this script is the difference between a migration
-- that applies and one that fails halfway:
--
--   H1   octet_length(rrule) <= 255
--   H6   every date / timestamptz inside [1900-01-01, 2200-01-01]
--   H11  recurrence_id is null or recurrence_id <> id
--   H16  octet_length of title / category / description <= 800 / 200 / 8000
--   H2   octet_length(share_links.label) <= 200
--   H8   end_at > start_at          -- MEASURED ONLY, not yet decided
--
-- DELIBERATELY NOT HERE. These cannot be fixed by a CHECK and must not be
-- confused with P1's result; they are separate follow-up work:
--   client-writable created_at / updated_at   (needs a BEFORE INSERT trigger)
--   share-link quota and rate limit           (a trigger; P1 only SIZES it)
--   get_free_busy token and response bounds   (needs the RPC body changed)
--   H7 duration limits                        (no agreed number yet)
--   H9 / H10 recurrence-graph parentage       (needs a trigger; see P3)
--
-- PRIVACY. This script returns counts, byte lengths, dates and settings only.
-- It never returns an rrule, a title, a description, a category, a share label
-- or a token. Where a row has to be identifiable so it can be looked at later,
-- it is named by a PSEUDONYM, not by its id:
--
--   substring(encode(sha256(uuid_send(id)), 'hex') from 1 for 10)
--
-- At most 5 pseudonyms per finding. To map one back to a row afterwards, run
-- that same expression over the table and match -- the digest is stable.
-- substring() here runs over a 64-character hex digest already materialised in
-- memory, never over a table's text column, so it detoasts nothing.
--
-- TOAST. octet_length(text) and pg_column_size() stop at the TOAST pointer and
-- fetch no chunk (measured: PGlite EXPLAIN BUFFERS, heap 20 pages vs 1716 for
-- length/char_length). length(), char_length(), btrim(), substr() and
-- convert_to() on a table column all detoast and are NOT used on one here.
--
-- THE ONE FUNCTION THAT MUST READ THE VALUE is public.rrule_parse(), which
-- btrims and splits its argument. It is guarded: a row is only parsed when
-- octet_length(rrule) <= 255 has already been established, and CASE guarantees
-- that order of evaluation. If a 1 MB row somehow still exists, it is counted
-- in C04 and never read. The script is therefore safe to run even if the
-- post-cleanup expectation below turns out to be wrong.
--
-- SHAPE, and why it is not the shape of the 963-row audit that timed out.
-- That one joined events to itself and to the archive. This one scans
-- public.events exactly once and public.share_links exactly once (each CTE is
-- referenced more than once, so it materialises, and the scan is not repeated),
-- then reads small aggregates. There is no self-join and no archive join.
--
-- EXPECTED STATE after the 2026-09-17 cleanup: events = 163 rows, zero rows
-- with a 1000000-byte rrule. A01 and A02 assert exactly that, so a surprise
-- shows up as a FAIL at the top rather than as a silently odd number further
-- down.
--
-- READING THE OUTPUT. status is 'ok' / 'FAIL' where an expectation exists, and
-- 'context' where the value is a measurement to be judged. P00 summarises.
-- A FAIL is not necessarily a blocker -- it means the matching constraint
-- cannot be added as-is and needs either a cleanup or NOT VALID first.
-- ============================================================================
begin transaction read only;

with
ev as (
  select e.id,
         e.owner_id,
         e.all_day,
         e.recurrence_id,
         e.start_at,
         e.end_at,
         e.start_date,
         e.end_date,
         octet_length(e.rrule)       as rr_len,
         octet_length(e.title)       as ti_len,
         octet_length(e.description) as de_len,
         octet_length(e.category)    as ca_len,
         case
           when e.rrule is null then null
           when octet_length(e.rrule) > 255 then 'over_255_not_parsed'
           else (select p.status from public.rrule_parse(e.rrule) p)
         end as rr_status,
         -- JS Date tops out at 275760-09-13; its lower bound is unreachable
         -- because date and timestamptz themselves stop at 4713 BC.
         --
         -- coalesce(..., false) on every one of these: the columns of the
         -- OTHER time model are always NULL, so an un-coalesced OR-chain
         -- evaluates to NULL rather than false for every row, and `filter
         -- (where <null>)` would quietly not count it. The counts would still
         -- come out right today, but only by accident of how NULL propagates.
         coalesce(e.start_date > date '275760-09-13'
            or e.end_date > date '275760-09-13', false) as date_past_js,
         coalesce(e.start_at > timestamptz '275760-09-13 00:00:00+00'
            or e.end_at > timestamptz '275760-09-13 00:00:00+00',
            false) as ts_past_js,
         -- Only the lower bound of the START and the upper bound of the END
         -- are tested. events_time_shape already forces end > start on the
         -- all-day arm and end >= start on the timed arm, so a start past the
         -- upper bound drags its end past it too, and an end below the lower
         -- bound drags its start below. The two tests therefore cover all four
         -- violations between them.
         coalesce(e.start_date < date '1900-01-01'
            or e.end_date > date '2200-01-01'
            or e.start_at < timestamptz '1900-01-01 00:00:00+00'
            or e.end_at > timestamptz '2200-01-01 00:00:00+00',
            false) as outside_window,
         (e.all_day = false and e.end_at = e.start_at) as zero_len
  from public.events as e
),
agg as (
  select count(*) as total,
         count(*) filter (where rr_len is not null)      as rr_rows,
         count(*) filter (where rr_len >= 1000000)       as rr_huge,
         max(rr_len)                                     as rr_max,
         count(*) filter (where rr_len > 255)            as rr_over_255,
         count(*) filter (where rr_len > 128)            as rr_over_128,
         count(*) filter (where rr_len > 75)             as rr_over_75,
         count(*) filter (where rr_status = 'ok')          as rr_ok,
         count(*) filter (where rr_status = 'unsupported') as rr_unsup,
         count(*) filter (where rr_status = 'malformed')   as rr_malformed,
         count(*) filter (
           where rr_status = 'over_255_not_parsed')        as rr_skipped,
         min(start_date) as sd_min,
         max(start_date) as sd_max,
         min(end_date)   as ed_min,
         max(end_date)   as ed_max,
         min(start_at)   as sa_min,
         max(start_at)   as sa_max,
         min(end_at)     as ea_min,
         max(end_at)     as ea_max,
         count(*) filter (where date_past_js)   as n_date_past_js,
         count(*) filter (where ts_past_js)     as n_ts_past_js,
         count(*) filter (where outside_window) as n_outside_window,
         count(*) filter (where zero_len)       as n_zero_len,
         max(ti_len) as ti_max,
         max(de_len) as de_max,
         max(ca_len) as ca_max,
         count(*) filter (where ti_len > 800)  as ti_over,
         count(*) filter (where de_len > 8000) as de_over,
         count(*) filter (where ca_len > 200)  as ca_over,
         count(*) filter (where recurrence_id = id) as n_self_parent,
         count(*) filter (where recurrence_id is not null) as n_exceptions
  from ev
),
sl as (
  select s.owner_id,
         octet_length(s.label) as lab_len,
         s.revoked_at,
         s.expires_at
  from public.share_links as s
),
sl_owner as (
  select owner_id,
         count(*) as n,
         count(*) filter (
           where revoked_at is null
             and (expires_at is null or expires_at > now())) as n_active
  from sl
  group by owner_id
),
sl_agg as (
  select count(*)                                as total,
         count(*) filter (where lab_len is not null) as labelled,
         max(lab_len)                            as lab_max,
         count(*) filter (where lab_len > 200)   as lab_over_200,
         count(*) filter (where lab_len > 100)   as lab_over_100,
         min(expires_at)                         as exp_min,
         max(expires_at)                         as exp_max,
         count(*) filter (where expires_at is null) as no_expiry
  from sl
),
sl_max as (
  select coalesce(max(n), 0)        as per_owner_max,
         coalesce(max(n_active), 0) as per_owner_active_max,
         count(*)                   as owners
  from sl_owner
),
res as (
  select v.ord, v.phase, v.metric, v.expected, v.value,
         case when v.expected is null then 'context'
              when v.value is not distinct from v.expected then 'ok'
              else 'FAIL'
         end as status
  from agg as g
  cross join sl_agg as s
  cross join sl_max as m
  cross join lateral (values

    -- A. baseline: are we looking at the state the cleanup left behind?
    ('A01', 'baseline', 'events rows', '163', g.total::text),
    ('A02', 'baseline', 'rows with rrule at 1000000 bytes', '0',
     g.rr_huge::text),
    ('A03', 'baseline', 'share_links rows', null, s.total::text),
    ('A04', 'baseline', 'exception rows (recurrence_id not null)', null,
     g.n_exceptions::text),

    -- B. H1: rrule byte length.
    ('B01', 'H1', 'rows carrying an rrule', null, g.rr_rows::text),
    ('B02', 'H1', 'max octet_length(rrule)', null,
     coalesce(g.rr_max::text, 'no rrule rows')),
    ('B03', 'H1', 'rows over the proposed 255 bytes', '0',
     g.rr_over_255::text),
    ('B04', 'H1', 'rows over 128 bytes (half the limit)', null,
     g.rr_over_128::text),
    ('B05', 'H1', 'rows over 75 bytes (the canonical maximum)', null,
     g.rr_over_75::text),
    ('B06', 'H1', 'pseudonyms of up to 5 rows over 255 bytes', null,
     coalesce((
       select string_agg(x.h, ' ')
       from (
         select substring(encode(sha256(uuid_send(v.id)), 'hex')
                          from 1 for 10) as h
         from ev as v
         where v.rr_len > 255
         order by v.id
         limit 5
       ) as x
     ), 'none')),

    -- C. H1 / H18: what the SQL parser makes of the rrules already stored.
    ('C01', 'H1', 'rrule rows the SQL parser reads as ok', null,
     g.rr_ok::text),
    ('C02', 'H1', 'rrule rows read as unsupported', '0', g.rr_unsup::text),
    ('C03', 'H1', 'rrule rows read as malformed', '0', g.rr_malformed::text),
    ('C04', 'H1', 'rrule rows too long to parse safely (not read)', '0',
     g.rr_skipped::text),
    -- C06 is the single number that answers "is any stored rrule a problem".
    -- Every row counted here forces complete=false on that owner's share page
    -- forever, and all but two kinds of them ALSO make the TypeScript parser
    -- throw out of expandEvents, which takes the whole calendar down (H12).
    -- The two that do not: SQL rejects duplicate BYDAY and out-of-range
    -- INTERVAL / COUNT where TypeScript accepts them, by design -- SQL is
    -- allowed to be the stricter side. So C06 over-reports TS breakage
    -- slightly, which is the safe direction for a precheck.
    ('C06', 'H1', 'rrule rows NOT readable as ok (the number that matters)',
     '0', (g.rr_unsup + g.rr_malformed + g.rr_skipped)::text),
    ('C05', 'H1', 'pseudonyms of up to 5 unreadable rrule rows', null,
     coalesce((
       select string_agg(x.h, ' ')
       from (
         select substring(encode(sha256(uuid_send(v.id)), 'hex')
                          from 1 for 10) as h
         from ev as v
         where v.rr_status in ('malformed', 'unsupported')
         order by v.id
         limit 5
       ) as x
     ), 'none')),

    -- D. H6: calendar range. D05/D06 are the crash boundary, D07 the CHECK.
    ('D01', 'H6', 'min start_date', null,
     coalesce(g.sd_min::text, 'no all-day rows')),
    ('D02', 'H6', 'max end_date', null,
     coalesce(g.ed_max::text, 'no all-day rows')),
    ('D03', 'H6', 'min start_at', null,
     coalesce(g.sa_min::text, 'no timed rows')),
    ('D04', 'H6', 'max end_at', null,
     coalesce(g.ea_max::text, 'no timed rows')),
    ('D05', 'H6', 'date rows past the JS Date limit 275760-09-13', '0',
     g.n_date_past_js::text),
    ('D06', 'H6', 'timestamptz rows past the JS Date limit', '0',
     g.n_ts_past_js::text),
    ('D07', 'H6', 'rows outside the proposed [1900-01-01, 2200-01-01]', '0',
     g.n_outside_window::text),
    ('D08', 'H6', 'pseudonyms of up to 5 rows outside that window', null,
     coalesce((
       select string_agg(x.h, ' ')
       from (
         select substring(encode(sha256(uuid_send(v.id)), 'hex')
                          from 1 for 10) as h
         from ev as v
         where v.outside_window
         order by v.id
         limit 5
       ) as x
     ), 'none')),
    ('D09', 'H6', 'min end_date (lower bound of the all-day span)', null,
     coalesce(g.ed_min::text, 'no all-day rows')),
    ('D10', 'H6', 'min end_at (lower bound of the timed span)', null,
     coalesce(g.ea_min::text, 'no timed rows')),
    ('D11', 'H6', 'max start_date', null,
     coalesce(g.sd_max::text, 'no all-day rows')),
    ('D12', 'H6', 'max start_at', null,
     coalesce(g.sa_max::text, 'no timed rows')),

    -- E. H8: measurement only. No expectation, because the decision is open.
    ('E01', 'H8', 'timed rows with end_at = start_at', null,
     g.n_zero_len::text),
    ('E02', 'H8', 'pseudonyms of up to 5 zero-duration timed rows', null,
     coalesce((
       select string_agg(x.h, ' ')
       from (
         select substring(encode(sha256(uuid_send(v.id)), 'hex')
                          from 1 for 10) as h
         from ev as v
         where v.zero_len
         order by v.id
         limit 5
       ) as x
     ), 'none')),

    -- F. H16: byte limits beside the existing character limits.
    --
    -- READ F04-F06 KNOWING THIS: at 4x the character limits they are VACUOUS.
    -- UTF-8 never spends more than 4 bytes on a code point and 0011's
    -- char_length constraints validated immediately rather than NOT VALID, so
    -- no row that satisfies 0011 can possibly exceed 4x, and F04-F06 can only
    -- ever report 0. They are kept because they cost nothing and they keep
    -- being true only while 0011 holds -- if the character limits are ever
    -- raised or dropped, these start to bind.
    --
    -- F01-F03 are the numbers that actually inform the decision. A BINDING
    -- byte limit has to sit below 4x, and the app is Japanese: 2000 Japanese
    -- characters is 6000 bytes, so anything under 6000 would reject ordinary
    -- content. Decide from F02 whether a 6000-8000 band is worth having at
    -- all.
    ('F01', 'H16', 'max octet_length(title)', null, g.ti_max::text),
    ('F02', 'H16', 'max octet_length(description)', null,
     coalesce(g.de_max::text, 'all null')),
    ('F03', 'H16', 'max octet_length(category)', null,
     coalesce(g.ca_max::text, 'all null')),
    ('F04', 'H16', 'title rows over the proposed 800 bytes', '0',
     g.ti_over::text),
    ('F05', 'H16', 'description rows over the proposed 8000 bytes', '0',
     g.de_over::text),
    ('F06', 'H16', 'category rows over the proposed 200 bytes', '0',
     g.ca_over::text),

    -- G. H11: no row may be its own recurrence parent.
    ('G01', 'H11', 'rows where recurrence_id = id', '0',
     g.n_self_parent::text),
    ('G02', 'H11', 'pseudonyms of up to 5 self-parent rows', null,
     coalesce((
       select string_agg(x.h, ' ')
       from (
         select substring(encode(sha256(uuid_send(v.id)), 'hex')
                          from 1 for 10) as h
         from ev as v
         where v.recurrence_id = v.id
         order by v.id
         limit 5
       ) as x
     ), 'none')),

    -- H. share_links. H01-H04 gate the H2 CHECK; H05-H09 only SIZE the future
    -- quota and rate limit, which are trigger work and not part of this
    -- migration.
    ('H01', 'H2', 'share_links rows carrying a label', null,
     s.labelled::text),
    ('H02', 'H2', 'max octet_length(label)', null,
     coalesce(s.lab_max::text, 'no labels')),
    ('H03', 'H2', 'labels over the proposed 200 bytes', '0',
     s.lab_over_200::text),
    ('H04', 'H2', 'labels over 100 bytes (half the limit)', null,
     s.lab_over_100::text),
    ('H05', 'H3', 'distinct share-link owners', null, m.owners::text),
    ('H06', 'H3', 'largest share-link count held by one owner', null,
     m.per_owner_max::text),
    ('H07', 'H3', 'largest ACTIVE share-link count for one owner', null,
     m.per_owner_active_max::text),
    ('H08', 'H3', 'share links with no expiry', null, s.no_expiry::text),
    ('H09', 'H3', 'max expires_at', null,
     coalesce(s.exp_max::text, 'none set')),
    ('H10', 'H3', 'min expires_at', null,
     coalesce(s.exp_min::text, 'none set'))

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
