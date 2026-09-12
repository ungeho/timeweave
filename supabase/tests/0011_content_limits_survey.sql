-- ============================================================================
-- TimeWeave -- SURVEY of the existing over-limit content in public.events.
--
-- NOT A MIGRATION, NOT A PREFLIGHT, NOT A TEST SUITE. This file exists because
-- 0011_content_limits_preflight.sql came back with 1103 of 1119 rows over the
-- title limit and a single description of 2,893,353 characters. Before anything
-- is deleted, truncated or constrained, we need to know WHAT that data is.
--
-- READ-ONLY. Every statement below is a bare SELECT. There is no DDL, no DML,
-- no SET, no function creation, and nothing that writes. Each query can be run
-- on its own and leaves the database exactly as it found it, so no transaction
-- wrapper is needed or used -- a wrapper would only obscure that each block is
-- independent.
--
-- HOW TO RUN: one block at a time. Select a single Q block and Run it, then
-- move to the next. They are separate on purpose: the answers have different
-- shapes and would be unreadable unioned together, and most SQL editors show
-- only the last result set when several statements are sent at once.
--
-- PRIVACY: no query selects title, category or description. Lengths, counts,
-- identifiers and timestamps only. auth.users is never joined -- owner_id is
-- enough to tell cohorts apart, and an email address would add nothing but
-- exposure.
--
-- THE LIMITS UNDER TEST (mirroring src/services/contentLimits.ts):
--   title 200, category 50, description 2000.
--
-- WHAT EACH QUERY IS FOR:
--   Q1  How many DISTINCT rows are over, and which fields overlap. The
--       preflight counted cells; this counts rows.
--   Q2  Who owns them, and of what kind. If one owner holds the whole cohort,
--       cleanup is a one-predicate job.
--   Q3  Frequency of each exact length. Generated data repeats a length;
--       human data does not.
--   Q4  The extremes, with their timestamps.
--   Q5  Creation over time. Test data arrives in bursts.
--   Q6  THE SAFETY QUERY: whether deleting over-limit masters would take
--       in-limit exception rows with them. recurrence_id is ON DELETE CASCADE,
--       so a master's removal is silently a subtree's removal.
--   Q7  The rows that are already clean -- the candidates for "real data".
--   Q8  What this is costing in storage.
-- ============================================================================


-- ============================================================================
-- Q1. Distinct over-limit ROWS, and the overlap between the three fields.
--
-- The preflight reported 1103 / 1103 / 1003 as per-FIELD counts, which cannot
-- be added up: one row can be over in all three. This gives the true row count
-- and shows the shape of the overlap. coalesce keeps a NULL category or
-- description out of three-valued logic, so every row lands in exactly one
-- group and the groups sum to the table.
-- ============================================================================
select
  (char_length(e.title) > 200)                        as title_over,
  (coalesce(char_length(e.category), 0) > 50)         as category_over,
  (coalesce(char_length(e.description), 0) > 2000)    as description_over,
  count(*)                                            as rows
from public.events e
group by 1, 2, 3
order by rows desc;


-- ============================================================================
-- Q2. Cohorts: owner x kind. Where the data came from and what it looks like.
--
-- If the over-limit rows all share one owner_id, that owner_id IS the cleanup
-- predicate and nothing else has to be guessed at. If they are spread across
-- the same owner as the real calendar, the predicate has to come from Q3/Q5
-- instead.
-- ============================================================================
select
  e.owner_id,
  case
    when e.rrule is not null                            then 'recurrence master'
    when e.recurrence_id is not null and e.is_cancelled then 'cancelled tombstone'
    when e.recurrence_id is not null                    then 'recurrence exception'
    else 'one-off event'
  end                                                                as row_kind,
  count(*)                                                           as rows,
  count(*) filter (
    where char_length(e.title) > 200
       or coalesce(char_length(e.category), 0) > 50
       or coalesce(char_length(e.description), 0) > 2000
  )                                                                  as rows_over,
  max(char_length(e.title))                                          as max_title,
  max(char_length(e.category))                                       as max_category,
  max(char_length(e.description))                                    as max_description,
  min(e.created_at)                                                  as first_created,
  max(e.created_at)                                                  as last_created
from public.events e
group by 1, 2
order by rows desc;


-- ============================================================================
-- Q3. Exact-length frequency. The strongest signal for generated data.
--
-- A fuzz or load test writes the same length over and over ("10000 chars"),
-- which shows up here as one length with a count in the hundreds. Real titles
-- have a near-unique length each. Only over-limit values are counted, and only
-- lengths that occur more than once are listed -- a long tail of singletons is
-- noise for this question.
-- ============================================================================
select field, len, rows
from (
  select 'title'::text as field, char_length(e.title) as len, count(*) as rows
  from public.events e
  where char_length(e.title) > 200
  group by 1, 2

  union all
  select 'category', char_length(e.category), count(*)
  from public.events e
  where coalesce(char_length(e.category), 0) > 50
  group by 1, 2

  union all
  select 'description', char_length(e.description), count(*)
  from public.events e
  where coalesce(char_length(e.description), 0) > 2000
  group by 1, 2
) f
where f.rows > 1
order by f.field, f.rows desc, f.len desc
limit 60;


-- ============================================================================
-- Q4. The extremes, with metadata. Five longest per field.
--
-- created_at / updated_at are the only provenance the schema carries. Equal
-- timestamps mean the row was never edited after it was written, which is what
-- generated data looks like.
-- ============================================================================
(
  select 'title'::text as field, char_length(e.title) as len,
         e.id, e.owner_id,
         (e.rrule is not null) as is_master, e.recurrence_id, e.is_cancelled,
         e.created_at, e.updated_at,
         (e.updated_at = e.created_at) as never_edited
  from public.events e
  where char_length(e.title) > 200
  order by len desc limit 5
)
union all
(
  select 'category', char_length(e.category),
         e.id, e.owner_id,
         (e.rrule is not null), e.recurrence_id, e.is_cancelled,
         e.created_at, e.updated_at,
         (e.updated_at = e.created_at)
  from public.events e
  where coalesce(char_length(e.category), 0) > 50
  order by 2 desc limit 5
)
union all
(
  select 'description', char_length(e.description),
         e.id, e.owner_id,
         (e.rrule is not null), e.recurrence_id, e.is_cancelled,
         e.created_at, e.updated_at,
         (e.updated_at = e.created_at)
  from public.events e
  where coalesce(char_length(e.description), 0) > 2000
  order by 2 desc limit 5
)
order by field, len desc;


-- ============================================================================
-- Q5. Creation over time. Bursts betray a script.
--
-- If the over-limit rows land in a handful of minutes and the clean rows do
-- not, created_at gives a cleanup predicate that needs no guessing about
-- lengths. Bucketed by minute; widen to hour if the output is too long.
-- ============================================================================
select
  date_trunc('minute', e.created_at)                                 as minute_bucket,
  count(*)                                                           as rows,
  count(*) filter (
    where char_length(e.title) > 200
       or coalesce(char_length(e.category), 0) > 50
       or coalesce(char_length(e.description), 0) > 2000
  )                                                                  as rows_over,
  count(distinct e.owner_id)                                         as owners
from public.events e
group by 1
order by 1;


-- ============================================================================
-- Q6. SAFETY: what a DELETE of over-limit masters would take with it.
--
-- events.recurrence_id is `references public.events (id) on delete cascade`, so
-- deleting a recurring master deletes every exception and tombstone hanging off
-- it, with no warning and no row count of its own.
--
-- The row that must be zero before any master is deleted is
--   master_over = true, exception_over = false
-- -- an over-limit master carrying an exception that is itself clean. Deleting
-- that master would destroy a row we have no reason to touch. If it is not
-- zero, those exceptions have to be examined one by one (Q6b) before anything
-- is removed.
--
-- An orphan exception is impossible (the FK guarantees it), so this join loses
-- nothing.
-- ============================================================================
with flagged as (
  select
    e.id, e.owner_id, e.rrule, e.recurrence_id, e.is_cancelled,
    (char_length(e.title) > 200
       or coalesce(char_length(e.category), 0) > 50
       or coalesce(char_length(e.description), 0) > 2000) as over
  from public.events e
)
select
  m.over                     as master_over,
  x.over                     as exception_over,
  x.is_cancelled             as exception_is_tombstone,
  count(*)                   as exception_rows,
  count(distinct m.id)       as distinct_masters
from flagged x
join flagged m on m.id = x.recurrence_id
group by 1, 2, 3
order by 1, 2, 3;


-- ============================================================================
-- Q6b. The individual rows behind the dangerous combination in Q6.
--
-- Run this ONLY if Q6 showed a non-zero count for master_over = true and
-- exception_over = false. It names the clean exceptions that a cascade would
-- remove, so they can be judged before any master is deleted.
-- ============================================================================
with flagged as (
  select
    e.id, e.owner_id, e.recurrence_id, e.is_cancelled, e.created_at,
    char_length(e.title)       as title_len,
    char_length(e.category)    as category_len,
    char_length(e.description) as description_len,
    (char_length(e.title) > 200
       or coalesce(char_length(e.category), 0) > 50
       or coalesce(char_length(e.description), 0) > 2000) as over
  from public.events e
)
select
  m.id            as master_id,
  x.id            as exception_id,
  x.owner_id,
  x.is_cancelled  as exception_is_tombstone,
  x.title_len, x.category_len, x.description_len,
  x.created_at    as exception_created_at
from flagged x
join flagged m on m.id = x.recurrence_id
where m.over and not x.over
order by m.id, x.created_at;


-- ============================================================================
-- Q7. The rows that are ALREADY within every limit.
--
-- At most 16 rows can be here (1119 total minus 1103 over on title alone), so
-- listing them whole is cheap. These are the candidates for real data: if they
-- are all one owner and the over-limit rows are another, the cleanup predicate
-- writes itself. Content is still not selected -- lengths are enough to tell a
-- real title from a generated one.
-- ============================================================================
select
  e.id,
  e.owner_id,
  case
    when e.rrule is not null                            then 'recurrence master'
    when e.recurrence_id is not null and e.is_cancelled then 'cancelled tombstone'
    when e.recurrence_id is not null                    then 'recurrence exception'
    else 'one-off event'
  end                                    as row_kind,
  char_length(e.title)                   as title_len,
  char_length(e.category)                as category_len,
  char_length(e.description)             as description_len,
  e.visibility,
  e.all_day,
  (e.rrule is not null)                  as has_rrule,
  e.created_at,
  e.updated_at
from public.events e
where char_length(e.title) <= 200
  and coalesce(char_length(e.category), 0) <= 50
  and coalesce(char_length(e.description), 0) <= 2000
order by e.created_at;


-- ============================================================================
-- Q8. Storage. What the long values are actually costing.
--
-- Long text lives in the TOAST relation, not the heap, so the table's own size
-- understates it. total - heap - indexes is the TOAST share.
-- ============================================================================
select
  pg_size_pretty(pg_total_relation_size('public.events'))     as total,
  pg_size_pretty(pg_relation_size('public.events'))           as heap,
  pg_size_pretty(pg_indexes_size('public.events'))            as indexes,
  pg_size_pretty(
    pg_total_relation_size('public.events')
    - pg_relation_size('public.events')
    - pg_indexes_size('public.events')
  )                                                           as toast,
  (select count(*) from public.events)                        as rows;
