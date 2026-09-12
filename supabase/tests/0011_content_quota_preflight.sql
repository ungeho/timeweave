-- ============================================================================
-- TimeWeave -- PREFLIGHT for 0011_content_and_quota_limits.sql.
--
-- NOT A MIGRATION AND NOT A TEST SUITE. Run BEFORE applying 0011, by hand,
-- against the database 0011 will be applied to.
--
-- READ-ONLY: no DDL, no DML, no SET. Wrapped in a transaction ending in
-- ROLLBACK as a belt-and-braces guarantee -- there is nothing in here that
-- could persist, but the wrapper means a reader does not have to take that on
-- trust. Same shape as 0008's and 0011's content preflight.
--
-- PRIVACY: never selects title, category or description. Lengths and counts
-- only, plus the ids needed to find an offending row again.
--
-- ============================================================================
-- WHAT IT ANSWERS
--
-- 0011 does four things that can each fail at APPLY time against live data.
-- This file asks, for each, "would it fail, and on which rows?" -- because
-- every one of them takes ACCESS EXCLUSIVE on public.events, and finding out by
-- running the migration means finding out while holding that lock.
--
--   A  the three CHECK constraints are added VALIDATED. Any over-limit row
--      aborts the ALTER. Checks 10-12.
--   B  `unique (id, owner_id)` must succeed. It is trivially satisfiable
--      because id is the primary key -- check 20 confirms the premise rather
--      than assuming it, since a NULL owner_id would break the FK that depends
--      on it.
--   C  the composite FK (recurrence_id, owner_id) -> (id, owner_id) is
--      validated on add. An exception whose master has a DIFFERENT owner aborts
--      it, and so does an exception whose master does not exist. Checks 30-32.
--   D  the two quotas are NOT enforced retroactively -- 0011's delta rule means
--      an existing over-quota owner is never refused an edit. But an owner
--      already near or past a ceiling is worth KNOWING about before the ceiling
--      exists, so checks 40-43 report the extremes.
--
-- THE ONE THING THIS FILE CANNOT ANSWER:
--   whether a SECURITY DEFINER function with `set search_path = ''` can read
--   its transition tables. That is a behavioural question about the server, not
--   a question about the data, and it is measured separately by
--   tmp_probe_enr_security_definer.sql on a dev database. Run that first.
--
-- ============================================================================
-- HOW TO READ THE OUTPUT
--
--   Section A writes to the NOTICE channel: environment and the RLS visibility
--   guard. Section B returns ONE result grid.
--
--   If your client shows no grid (some editors display only the last statement,
--   and that is the ROLLBACK), run section B on its own -- it is a bare SELECT
--   and is read-only with or without the transaction around it.
--
-- READ SECTION A BEFORE TRUSTING A ZERO IN SECTION B:
--   public.events has RLS with owner-only policies. Run as a role that does not
--   bypass RLS and every count below silently narrows to that role's own rows,
--   so a zero means "none of MINE", which is not the question. The Supabase SQL
--   Editor runs as the table owner and sees everything.
--
--   verdict = BLOCKER  -> applying 0011 WILL abort. Fix the rows first.
--   verdict = review   -> will not abort, but you are being told something.
--   verdict = ok       -> nothing to do.
-- ============================================================================

begin;

-- ============================================================================
-- Section A. Environment, and the RLS visibility guard. Reads catalogs and a
-- count. Writes nothing.
-- ============================================================================
do $$
declare
  v_bypass   boolean;
  v_is_owner boolean;
  v_rls_on   boolean;
  v_forced   boolean;
  v_visible  bigint;
  v_trusted  boolean;
  v_applied  boolean;
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

  v_trusted := coalesce(v_bypass, false)
               or not coalesce(v_rls_on, false)
               or (coalesce(v_is_owner, false) and not coalesce(v_forced, false));

  -- Has 0011 already been applied? Re-running a migration is the other way to
  -- get a confusing result out of this file.
  select exists (
    select 1 from pg_catalog.pg_constraint con
    join pg_catalog.pg_class c on c.oid = con.conrelid
    join pg_catalog.pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relname = 'events'
      and con.conname = 'events_title_len'
  ) into v_applied;

  raise notice 'Section A: environment';
  raise notice '  version           : %', version();
  raise notice '  current_user      : %', current_user;
  raise notice '  events RLS enabled: %', v_rls_on;
  raise notice '  events RLS forced : %', v_forced;
  raise notice '  owns events       : %', v_is_owner;
  raise notice '  BYPASSRLS         : %', v_bypass;
  raise notice '  events rows VISIBLE here : %', v_visible;

  if v_trusted then
    raise notice '  VERDICT: this role sees the whole table. A zero below is a real zero.';
  else
    raise warning '  VERDICT: RLS is filtering this role. Every count below covers only '
                  'the rows it can see. Re-run as the table owner before trusting it.';
  end if;

  if v_applied then
    raise warning '  NOTE: events_title_len ALREADY EXISTS -- 0011 looks applied. This '
                  'preflight describes a pre-0011 database; read it as a postflight '
                  'or use 0011_content_quota_postflight.sql instead.';
  end if;
end;
$$;

-- ============================================================================
-- Section B. The survey. One grid.
--
-- Columns
--   ord        stable sort key
--   topic      which part of 0011 the row is about
--   check_name what is being counted
--   value      the count, or the extreme value
--   threshold  the number 0011 will impose, where there is one
--   verdict    ok / review / BLOCKER
--   detail     the ids to look at, capped so one bad row cannot flood the grid
-- ============================================================================
with
-- --------------------------------------------------------------------------
-- A. CONTENT LENGTH -- would `add constraint ... check (...)` validate?
-- --------------------------------------------------------------------------
content as (
  select
    count(*) filter (where char_length(e.title) > 200)                  as over_title,
    count(*) filter (where char_length(e.category) > 50)                as over_category,
    count(*) filter (where char_length(e.description) > 2000)           as over_description,
    max(char_length(e.title))                                           as max_title,
    max(char_length(e.category))                                        as max_category,
    max(char_length(e.description))                                     as max_description
  from public.events e
),
-- --------------------------------------------------------------------------
-- B. THE UNIQUE KEY the composite FK will reference.
-- --------------------------------------------------------------------------
uniq as (
  select
    count(*)                                  as rows_total,
    count(*) filter (where e.owner_id is null) as null_owner
  from public.events e
),
-- --------------------------------------------------------------------------
-- C. THE COMPOSITE FK -- would it validate?
--
-- Both failure modes are checked separately because they need different fixes:
-- a mismatched owner is a data-repair job, a dangling recurrence_id means the
-- existing single-column FK is not doing its job and something is badly wrong.
-- --------------------------------------------------------------------------
fk as (
  select
    count(*) filter (
      where c.recurrence_id is not null and m.id is not null
        and m.owner_id is distinct from c.owner_id
    ) as owner_mismatch,
    count(*) filter (
      where c.recurrence_id is not null and m.id is null
    ) as dangling,
    count(*) filter (where c.recurrence_id is not null) as exceptions_total
  from public.events c
  left join public.events m on m.id = c.recurrence_id
),
fk_ids as (
  select string_agg(x.id::text, ', ' order by x.id) as ids
  from (
    select c.id
    from public.events c
    left join public.events m on m.id = c.recurrence_id
    where c.recurrence_id is not null
      and (m.id is null or m.owner_id is distinct from c.owner_id)
    limit 10
  ) x
),
-- --------------------------------------------------------------------------
-- D. THE QUOTAS -- not retroactive, but the extremes are worth seeing.
--
-- 0011's delta rule means an owner already above a ceiling keeps full edit and
-- delete rights and is blocked only from GROWING. So none of these can be a
-- BLOCKER. They are 'review' when a real account would meet the limit the day
-- the migration lands, which is a product decision, not a migration failure.
-- --------------------------------------------------------------------------
per_owner as (
  select e.owner_id, count(*) as n
  from public.events e
  group by e.owner_id
),
per_master as (
  select e.recurrence_id, count(*) as n
  from public.events e
  where e.recurrence_id is not null
  group by e.recurrence_id
),
report as (
  select 10 as ord, 'content'::text as topic,
         'rows with title over 200 code points'::text as check_name,
         c.over_title::text as value, '0'::text as threshold,
         case when c.over_title = 0 then 'ok' else 'BLOCKER' end as verdict,
         format('longest title is %s', coalesce(c.max_title::text, 'n/a')) as detail
  from content c
  union all
  select 11, 'content', 'rows with category over 50 code points',
         c.over_category::text, '0',
         case when c.over_category = 0 then 'ok' else 'BLOCKER' end,
         format('longest category is %s', coalesce(c.max_category::text, 'n/a'))
  from content c
  union all
  select 12, 'content', 'rows with description over 2000 code points',
         c.over_description::text, '0',
         case when c.over_description = 0 then 'ok' else 'BLOCKER' end,
         format('longest description is %s', coalesce(c.max_description::text, 'n/a'))
  from content c

  union all
  select 20, 'unique key', 'rows with a NULL owner_id (breaks the FK target)',
         u.null_owner::text, '0',
         case when u.null_owner = 0 then 'ok' else 'BLOCKER' end,
         format('%s rows in events', u.rows_total)
  from uniq u

  union all
  select 30, 'composite FK', 'exceptions whose master has a DIFFERENT owner',
         f.owner_mismatch::text, '0',
         case when f.owner_mismatch = 0 then 'ok' else 'BLOCKER' end,
         coalesce(i.ids, 'none')
  from fk f cross join fk_ids i
  union all
  select 31, 'composite FK', 'exceptions whose master row does not exist',
         f.dangling::text, '0',
         case when f.dangling = 0 then 'ok' else 'BLOCKER' end,
         coalesce(i.ids, 'none')
  from fk f cross join fk_ids i
  union all
  select 32, 'composite FK', 'exception rows in total (the FK validation set)',
         f.exceptions_total::text, null,
         'ok', 'context only'
  from fk f

  union all
  select 40, 'quota', 'owners in total', count(*)::text, null, 'ok', 'context only'
  from per_owner
  union all
  select 41, 'quota', 'largest single owner, in events',
         coalesce(max(p.n), 0)::text, '5000',
         case when coalesce(max(p.n), 0) > 5000 then 'review' else 'ok' end,
         'delta rule: an over-quota owner can still edit and delete'
  from per_owner p
  union all
  select 42, 'quota', 'owners at or above the 5000 ceiling',
         count(*) filter (where p.n >= 5000)::text, '0',
         case when count(*) filter (where p.n >= 5000) > 0 then 'review' else 'ok' end,
         coalesce(string_agg(p.owner_id::text, ', ')
                    filter (where p.n >= 5000), 'none')
  from per_owner p
  union all
  select 43, 'quota', 'largest single master, in exception rows',
         coalesce(max(p.n), 0)::text, '500',
         case when coalesce(max(p.n), 0) >= 500 then 'review' else 'ok' end,
         coalesce(string_agg(p.recurrence_id::text, ', ')
                    filter (where p.n >= 500), 'none')
  from per_master p

  -- ------------------------------------------------------------------------
  -- E. OBJECT-NAME COLLISIONS. 0011 creates six named objects. If any name is
  -- already taken the migration aborts partway, holding ACCESS EXCLUSIVE.
  -- ------------------------------------------------------------------------
  union all
  select 50, 'collision', 'names 0011 will create that already exist',
         count(*)::text, '0',
         case when count(*) = 0 then 'ok' else 'BLOCKER' end,
         coalesce(string_agg(t.name, ', ' order by t.name), 'none')
  from (
    select con.conname as name
    from pg_catalog.pg_constraint con
    join pg_catalog.pg_class c on c.oid = con.conrelid
    join pg_catalog.pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relname = 'events'
      and con.conname in ('events_title_len', 'events_category_len',
                          'events_description_len', 'events_id_owner_key',
                          'events_recurrence_owner_fkey')
    union all
    select c.relname
    from pg_catalog.pg_class c
    join pg_catalog.pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relname = 'events_recurrence_owner_idx'
    union all
    select p.proname
    from pg_catalog.pg_proc p
    join pg_catalog.pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname in ('events_max_per_owner',
                        'events_max_exceptions_per_master',
                        'events_enforce_owner_quota',
                        'events_enforce_exception_quota')
  ) t

  -- ------------------------------------------------------------------------
  -- F. THE LEGACY FK 0011 DROPS BY CATALOG LOOKUP. If this is not exactly 1,
  -- the DO block in section 2 of the migration will take a branch its author
  -- did not expect -- 0 means it silently drops nothing, >1 means it drops an
  -- arbitrary one of them.
  -- ------------------------------------------------------------------------
  union all
  select 51, 'collision', 'single-column self-FKs on recurrence_id (0011 drops one)',
         count(*)::text, '1',
         case when count(*) = 1 then 'ok' else 'review' end,
         coalesce(string_agg(con.conname, ', '), 'none')
  from pg_catalog.pg_constraint con
  join pg_catalog.pg_class c on c.oid = con.conrelid
  join pg_catalog.pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public' and c.relname = 'events'
    and con.contype = 'f'
    and con.confrelid = con.conrelid
    and con.conkey = array[
      (select a.attnum from pg_catalog.pg_attribute a
        where a.attrelid = c.oid and a.attname = 'recurrence_id'
          and not a.attisdropped)
    ]
)
select r.ord, r.topic, r.check_name, r.value, r.threshold, r.verdict, r.detail
from report r
order by r.ord;

rollback;
