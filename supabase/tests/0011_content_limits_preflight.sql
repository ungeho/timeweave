-- ============================================================================
-- TimeWeave -- PREFLIGHT for the planned content-length constraints on
-- public.events (title / category / description).
--
-- NOT A MIGRATION AND NOT A TEST SUITE. Run BEFORE writing or applying any
-- constraint, by hand, against the project the constraint will be applied to.
-- READ-ONLY: no DDL, no DML, no SET, no function creation. Wrapped in a
-- transaction ending in ROLLBACK as a belt-and-braces guarantee that nothing
-- can persist -- there is nothing in here that could, but the wrapper means a
-- reader does not have to take that on trust.
--
-- WHAT IT ANSWERS, and why each answer matters:
--   Does any existing row already exceed the limits we intend to impose?
--   A plain `ALTER TABLE ... ADD CONSTRAINT` validates immediately and FAILS on
--   the first offending row, so this is the difference between a migration that
--   applies and one that aborts. If rows do exist, the count and their kind
--   decide whether to clean up first or to add the constraint NOT VALID.
--
-- THE LIMITS BEING TESTED (mirrored from src/services/contentLimits.ts, which
-- is the TypeScript side's single definition):
--   title 200, category 50, description 2000.
--
-- A NOTE ON COUNTING, because the two sides do not count alike:
--   `char_length` here counts Unicode CODE POINTS. The application counts UTF-16
--   CODE UNITS (String.length, matching the HTML maxlength attribute), and a
--   non-BMP character -- most emoji, some kanji -- is two units but one code
--   point. So char_length <= String.length always. A row the application would
--   accept can therefore never be reported over-limit here, and anything this
--   file does report predates the application limits or was written around them.
--
-- PRIVACY: this file NEVER selects title, category or description themselves.
--   Only their lengths, plus the identifiers needed to find a row again. There
--   is no reason to put event titles or notes on screen to count them, and every
--   reason not to.
--
-- WHAT IT DELIBERATELY DOES NOT COVER:
--   share_links.label is also unconstrained text and is also displayed, but it
--   is not part of the events constraint being prepared; it gets its own
--   preflight if and when it gets its own constraint. The blank-title question
--   (title = '' is permitted by the schema's DEFAULT but refused by the dialog)
--   is reported here as a COUNT only -- it is a separate decision from length
--   and nothing below proposes acting on it.
--
-- HOW TO READ THE OUTPUT:
--   Section A writes to the NOTICE channel: environment, and the visibility
--   guard described below. Section B returns ONE result grid: summary rows
--   first, then one row per offending event.
--
--   If your client shows no grid (some editors display only the last statement,
--   and that is the ROLLBACK), run section B on its own. It is a bare SELECT and
--   is read-only with or without the transaction around it.
--
-- READ SECTION A BEFORE TRUSTING A ZERO IN SECTION B:
--   public.events has RLS enabled with owner-only policies. Run as a role that
--   does not bypass RLS and the survey silently narrows to that role's own rows
--   -- an empty result then means "nothing of MINE is over the limit", which is
--   not the question being asked. Section A reports whether the current role
--   bypasses RLS and how many rows it can actually see, so a zero can be told
--   apart from a filter. The Supabase SQL Editor runs as the table owner and
--   sees everything; a PostgREST session does not.
-- ============================================================================

begin;

-- ============================================================================
-- Section A. Environment, and the RLS visibility guard.
--
-- Reads catalogs and a count. Writes nothing.
-- ============================================================================
do $$
declare
  v_bypass    boolean;
  v_is_owner  boolean;
  v_rls_on    boolean;
  v_forced    boolean;
  v_visible   bigint;
  v_trusted   boolean;
begin
  select r.rolbypassrls into v_bypass
  from pg_catalog.pg_roles r where r.rolname = current_user;

  select c.relrowsecurity, c.relforcerowsecurity,
         pg_catalog.pg_get_userbyid(c.relowner) = current_user
    into v_rls_on, v_forced, v_is_owner
  from pg_catalog.pg_class c
  join pg_catalog.pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public' and c.relname = 'events';

  select count(*) into v_visible from public.events;

  -- The table owner is exempt from its own policies unless FORCE is set, and a
  -- BYPASSRLS role is exempt outright. Either one makes the count below the
  -- whole table; anything else makes it a slice, and a zero meaningless.
  v_trusted := coalesce(v_bypass, false)
               or not coalesce(v_rls_on, false)
               or (coalesce(v_is_owner, false) and not coalesce(v_forced, false));

  raise notice 'Section A: environment';
  raise notice '  version           : %', version();
  raise notice '  current_user      : %', current_user;
  raise notice '  session_user      : %', session_user;
  raise notice '  events RLS enabled: %', v_rls_on;
  raise notice '  events RLS forced : %', v_forced;
  raise notice '  current_user owns events : %', v_is_owner;
  raise notice '  current_user BYPASSRLS   : %', v_bypass;
  raise notice '  events rows VISIBLE here : %', v_visible;

  if v_trusted then
    raise notice '  VERDICT: this role sees the whole table. A zero in section B is a real zero.';
  else
    raise warning '  VERDICT: RLS is filtering this role. Section B surveys only the rows it '
                  'can see, so a zero here does NOT clear the table. Re-run as the table '
                  'owner (the Supabase SQL Editor does this) before trusting the result.';
  end if;

  if v_visible = 0 then
    raise notice '  NOTE: zero rows visible -- either the table is empty or the verdict above '
                 'explains it. Section B will be empty either way.';
  end if;
end;
$$;

-- ============================================================================
-- Section B. The survey. One grid: summary rows, then offending rows.
--
-- Columns
--   section        'A. summary' or 'B. over-limit row'
--   field          which column the row is about
--   max_or_len     summary: the longest value in that column (code points)
--                  detail : that row's length
--   lim            the limit being prepared
--   row_kind       one-off / master / exception / tombstone (detail rows only)
--   event_id       events.id
--   owner_id       events.owner_id
--   rrule          non-null only on a recurrence master
--   recurrence_id  non-null only on an exception or tombstone
--   is_cancelled   true only on a tombstone
--   note           summary: the counts. detail: what the constraint would block.
--
-- No branch selects title, category or description. Lengths only.
-- ============================================================================
with classified as (
  select
    e.id,
    e.owner_id,
    e.rrule,
    e.recurrence_id,
    e.is_cancelled,
    char_length(e.title)       as title_len,
    char_length(e.category)    as category_len,
    char_length(e.description) as description_len,
    -- events_master_not_exception guarantees rrule and recurrence_id are never
    -- both set, so these four cases are exclusive and exhaustive.
    case
      when e.rrule is not null                         then 'recurrence master'
      when e.recurrence_id is not null and e.is_cancelled then 'cancelled tombstone'
      when e.recurrence_id is not null                 then 'recurrence exception'
      else 'one-off event'
    end as row_kind,
    -- What a validated CHECK would refuse for this row. A CHECK is evaluated
    -- against the whole new row on every UPDATE, so an over-limit row is frozen
    -- even for an update that does not touch the offending column.
    case
      when e.rrule is not null
        then 'edit and set-series-timezone fail until shortened'
      when e.recurrence_id is not null and e.is_cancelled
        then 'inert: no UI path updates a tombstone'
      when e.recurrence_id is not null
        then 'edit and delete-this-occurrence fail until shortened'
      else 'any edit fails until shortened (fixable in the dialog)'
    end as impact
  from public.events e
),
report as (
  -- ---- summary -----------------------------------------------------------
  select
    0                                                        as ord,
    'A. summary'::text                                       as section,
    'title'::text                                            as field,
    max(c.title_len)                                         as max_or_len,
    200::int                                                 as lim,
    null::text                                               as row_kind,
    null::uuid                                               as event_id,
    null::uuid                                               as owner_id,
    null::text                                               as rrule,
    null::uuid                                               as recurrence_id,
    null::boolean                                            as is_cancelled,
    format('rows=%s, over_limit=%s, empty_string=%s',
           count(*),
           count(*) filter (where c.title_len > 200),
           count(*) filter (where c.title_len = 0))          as note
  from classified c

  union all
  select
    1, 'A. summary', 'category',
    max(c.category_len), 50,
    null, null, null, null, null, null,
    format('non_null=%s, over_limit=%s',
           count(c.category_len),
           count(*) filter (where c.category_len > 50))
  from classified c

  union all
  select
    2, 'A. summary', 'description',
    max(c.description_len), 2000,
    null, null, null, null, null, null,
    format('non_null=%s, over_limit=%s',
           count(c.description_len),
           count(*) filter (where c.description_len > 2000))
  from classified c

  -- ---- offending rows, one per (row, column) over its limit ---------------
  union all
  select
    3, 'B. over-limit row', 'title',
    c.title_len, 200,
    c.row_kind, c.id, c.owner_id, c.rrule, c.recurrence_id, c.is_cancelled, c.impact
  from classified c
  where c.title_len > 200

  union all
  select
    4, 'B. over-limit row', 'category',
    c.category_len, 50,
    c.row_kind, c.id, c.owner_id, c.rrule, c.recurrence_id, c.is_cancelled, c.impact
  from classified c
  where c.category_len > 50

  union all
  select
    5, 'B. over-limit row', 'description',
    c.description_len, 2000,
    c.row_kind, c.id, c.owner_id, c.rrule, c.recurrence_id, c.is_cancelled, c.impact
  from classified c
  where c.description_len > 2000
)
select
  r.section,
  r.field,
  r.max_or_len,
  r.lim,
  r.row_kind,
  r.event_id,
  r.owner_id,
  r.rrule,
  r.recurrence_id,
  r.is_cancelled,
  r.note
from report r
order by r.ord, r.max_or_len desc nulls last, r.event_id;

rollback;
