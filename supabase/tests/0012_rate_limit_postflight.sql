-- ============================================================================
-- TimeWeave -- POSTFLIGHT for 0012_event_write_rate_limit.sql.
--
-- Run AFTER applying 0012. READ-ONLY, wrapped in a transaction ending in
-- ROLLBACK. It asserts STRUCTURE -- that what was applied is what was designed,
-- including the properties that are easy to get wrong silently. Behaviour is
-- asserted separately by 0012_rate_limit_test.sql.
--
-- Three of these checks exist because the failure they catch is invisible:
--
--   22  VOLATILE. Marked STABLE, the function's SPI reads run read-only, the
--       command counter never advances, and the trigger stops seeing its own
--       statement's rows. Measured on this database, in both directions. Nothing
--       errors; the limiter simply stops limiting.
--   23  NO ADVISORY LOCK. The concurrency argument in 0012 is "the upsert alone
--       is sufficient, measured". If somebody later adds a lock, that argument
--       stops matching the code, so the absence is asserted against the actual
--       function body rather than against a comment.
--   24  THE CLOCK. now() and statement_timestamp() differ by milliseconds in a
--       trivial request and by minutes in a long transaction. Swapping one for
--       the other changes nothing visible until a batch job appears.
--
-- HOW TO READ THE OUTPUT
--   'ok'      -> as designed
--   'FAIL'    -> the migration is not what 0012 describes; `got` says how
--   'context' -> reported, never a gate
-- ============================================================================

begin;

with
sch as (
  select
    (to_regnamespace('timeweave_private') is not null) as schema_exists,
    (select count(*)
       from pg_namespace n
       cross join lateral aclexplode(n.nspacl) a
      where n.nspname = 'timeweave_private'
        and a.grantee <> n.nspowner)                   as schema_nonowner_grants
),
tbl as (
  select c.oid, c.relrowsecurity, c.reloptions, c.relowner, c.relacl,
         (select count(*) from pg_policy p where p.polrelid = c.oid)      as policies,
         (select count(*) from aclexplode(c.relacl) a
           where a.grantee <> c.relowner)                                 as nonowner_grants
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'timeweave_private' and c.relname = 'event_write_rate'
),
fk as (
  select con.confdeltype, con.contype,
         (select string_agg(att.attname, ',' order by att.attname)
            from unnest(con.conkey) k
            join pg_attribute att on att.attrelid = con.conrelid and att.attnum = k) as cols,
         cl.relname::text as ref_table
  from pg_constraint con
  join pg_class cl on cl.oid = con.confrelid
  where con.conrelid = (select oid from tbl) and con.contype = 'f'
),
pk as (
  select (select string_agg(att.attname, ',' order by att.attname)
            from unnest(con.conkey) k
            join pg_attribute att on att.attrelid = con.conrelid and att.attnum = k) as cols
  from pg_constraint con
  where con.conrelid = (select oid from tbl) and con.contype = 'p'
),
fn as (
  select p.proname::text as nm, p.prosecdef, p.provolatile, p.proconfig, p.proacl, p.proowner,
         pg_get_functiondef(p.oid) as src
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.proname in ('events_enforce_write_rate', 'events_rate_interval', 'events_rate_burst')
),
enf as (
  -- src_code is the function source with line comments REMOVED.
  --
  -- pg_get_functiondef() returns the source verbatim, comments and all, and this
  -- function's comments necessarily discuss the things the assertions below
  -- forbid: they explain why transaction_timestamp and now() are not used, and
  -- (in the file header) why there is no advisory lock. Matching against the raw
  -- source makes an explanation indistinguishable from a violation -- check 24
  -- failed on exactly that, against a migration that was correct.
  --
  -- Assertions about CODE must look at code. Everything after '--' on a line is
  -- prose and is stripped before matching.
  select *, regexp_replace(src, '--[^\n]*', '', 'g') as src_code
  from fn where nm = 'events_enforce_write_rate'
),
trg as (
  select t.tgname::text as nm, t.tgtype, t.tgenabled,
         t.tgoldtable::text as oldtable, t.tgnewtable::text as newtable
  from pg_trigger t
  where t.tgrelid = 'public.events'::regclass and not t.tgisinternal
),
ev as (
  select (select count(*) from trg)                                           as all_triggers,
         (select string_agg(nm, ', ' order by nm) from trg)                    as names,
         (select count(*) from trg where nm like 'events_quota_%')             as quota_triggers,
         (select count(*) from trg where nm like 'events_rate_%')              as rate_triggers,
         (select coalesce(bool_and(nm < 'events_rate_ai'), false)
            from trg where nm like 'events_quota_%')                          as order_holds,
         (select count(*) from pg_policy p
           where p.polrelid = 'public.events'::regclass)                       as event_policies,
         (select string_agg(a.privilege_type, ',' order by a.privilege_type)
            from pg_class c cross join lateral aclexplode(c.relacl) a
           where c.oid = 'public.events'::regclass
             and pg_get_userbyid(a.grantee) = 'authenticated')                 as events_auth_privs,
         (select coalesce(string_agg(a.privilege_type, ',' order by a.privilege_type), '<none>')
            from pg_class c cross join lateral aclexplode(c.relacl) a
           where c.oid = 'public.events'::regclass
             and pg_get_userbyid(a.grantee) = 'anon')                          as events_anon_privs
)
select ord, name, got, want,
       case when want = '(context)' then 'context'
            when got is not distinct from want then 'ok'
            else 'FAIL' end as verdict
from (
  -- 1x  the private schema and its state table -------------------------------
  select 10 as ord, 'schema timeweave_private exists' as name,
         (select schema_exists::text from sch) as got, 'true' as want
  union all
  select 11, 'schema has no privileges granted to anyone but its owner',
         (select schema_nonowner_grants::text from sch), '0'
  union all
  select 12, 'table timeweave_private.event_write_rate exists',
         (select (count(*) > 0)::text from tbl), 'true'
  union all
  select 13, 'row level security is enabled on it',
         (select relrowsecurity::text from tbl), 'true'
  union all
  select 14, 'it carries zero policies (RLS is defence in depth, not the defence)',
         (select policies::text from tbl), '0'
  union all
  select 15, 'nobody but the owner holds any privilege on it',
         (select nonowner_grants::text from tbl), '0'
  union all
  select 16, 'fillfactor is 70 (keeps the hot single-row updates HOT)',
         (select coalesce(array_to_string(reloptions, ','), '<none>') from tbl), 'fillfactor=70'
  union all
  select 17, 'primary key is owner_id', (select cols from pk), 'owner_id'
  union all
  select 18, 'foreign key column', (select cols from fk), 'owner_id'
  union all
  -- confdeltype is pg_constraint's internal "char" type, not text. Without the
  -- explicit cast, `text || confdeltype` is ambiguous (42725: operator is not
  -- unique) -- the parser finds several || candidates and refuses to guess.
  -- Every "char" catalogue column in this file is cast the same way; see the
  -- note above check 22 (provolatile) and check 35 (tgenabled).
  select 19, 'foreign key is ON DELETE CASCADE to auth.users',
         (select ref_table || '/' || confdeltype::text from fk), 'users/c'
  -- 2x  the enforcement function ---------------------------------------------
  union all
  select 20, 'events_enforce_write_rate is SECURITY DEFINER',
         (select prosecdef::text from enf), 'true'
  union all
  select 21, 'it pins search_path',
         (select (exists (select 1 from unnest(proconfig) x where x like 'search_path=%'))::text
            from enf), 'true'
  union all
  select 22, 'it is VOLATILE (STABLE would stop it seeing its own statement)',
         (select provolatile::text from enf), 'v'
  union all
  select 23, 'its CODE contains NO advisory lock (comments stripped first)',
         (select (src_code ilike '%advisory%')::text from enf), 'false'
  union all
  select 24, 'its CODE clock is statement_timestamp, not now/transaction_timestamp '
             '(comments stripped first -- the raw source explains at length why '
             'the other two are not used, and matching that prose is what made '
             'this check fail against a correct migration)',
         (select ((src_code like '%statement_timestamp%')
                  and (src_code not like '%transaction_timestamp%')
                  and (src_code not like '% now()%'))::text from enf), 'true'
  union all
  select 25, 'it is not executable by PUBLIC',
         (select (proacl is null
                  or exists (select 1 from aclexplode(proacl) x where x.grantee = 0))::text
            from enf), 'false'
  -- 2x  the parameters --------------------------------------------------------
  union all
  select 26, 'events_rate_interval() returns 1 second',
         public.events_rate_interval()::text, '00:00:01'
  union all
  select 27, 'events_rate_burst() returns 120',
         public.events_rate_burst()::text, '120'
  union all
  select 28, 'tau = burst * T = 120 seconds',
         (public.events_rate_burst() * public.events_rate_interval())::text, '00:02:00'
  union all
  select 29, 'both parameter functions are executable by authenticated',
         (has_function_privilege('authenticated', 'public.events_rate_interval()', 'EXECUTE')
          and has_function_privilege('authenticated', 'public.events_rate_burst()', 'EXECUTE'))::text,
         'true'
  union all
  select 30, 'neither parameter function is executable by anon',
         (has_function_privilege('anon', 'public.events_rate_interval()', 'EXECUTE')
          or has_function_privilege('anon', 'public.events_rate_burst()', 'EXECUTE'))::text,
         'false'
  -- 3x  the triggers ----------------------------------------------------------
  union all
  select 31, 'exactly two events_rate_% triggers',
         (select rate_triggers::text from ev), '2'
  union all
  select 32, 'events_rate_ai: AFTER, STATEMENT, INSERT only',
         (select ((tgtype & 1) = 0 and (tgtype & 2) = 0 and (tgtype & 64) = 0
                  and (tgtype & 4) = 4 and (tgtype & 8) = 0 and (tgtype & 16) = 0)::text
            from trg where nm = 'events_rate_ai'), 'true'
  union all
  select 33, 'events_rate_au: AFTER, STATEMENT, UPDATE only',
         (select ((tgtype & 1) = 0 and (tgtype & 2) = 0 and (tgtype & 64) = 0
                  and (tgtype & 16) = 16 and (tgtype & 4) = 0 and (tgtype & 8) = 0)::text
            from trg where nm = 'events_rate_au'), 'true'
  union all
  select 34, 'both declare NEW TABLE and neither declares OLD TABLE',
         (select (bool_and(newtable = 'new_rows') and bool_and(oldtable is null))::text
            from trg where nm like 'events_rate_%'), 'true'
  union all
  select 35, 'both are enabled',
         (select string_agg(distinct tgenabled::text, ',') from trg where nm like 'events_rate_%'), 'O'
  union all
  select 36, 'no rate trigger fires on DELETE or TRUNCATE',
         (select (bool_or((tgtype & 8) <> 0 or (tgtype & 32) <> 0))::text
            from trg where nm like 'events_rate_%'), 'false'
  -- 4x  public.events is otherwise untouched ----------------------------------
  union all
  select 40, 'public.events now carries eight triggers',
         (select all_triggers::text from ev), '8'
  union all
  select 41, 'the four 0011 quota triggers are still there',
         (select quota_triggers::text from ev), '4'
  union all
  select 42, 'quota trigger names still sort before events_rate_ai (lock order)',
         (select order_holds::text from ev), 'true'
  union all
  select 43, 'the eight trigger names', (select names from ev), '(context)'
  union all
  select 44, 'public.events still carries its four RLS policies',
         (select event_policies::text from ev), '4'
  union all
  -- What 0012 must preserve is 0002's DML grant, not the exact ACL. Measured on
  -- production 2026-09-13: public.events, public.share_links and
  -- public.events_archive_20260912 ALL carry MAINTAIN / REFERENCES / TRIGGER /
  -- TRUNCATE for anon and service_role, and the same four on top of the DML for
  -- authenticated. That is this project's default privileges, it predates 0012,
  -- and 0012 issues no GRANT or REVOKE on public.events at all -- so demanding
  -- an exact set here asserted a fact about the project, not about this
  -- migration, and failed for a reason 0012 neither caused nor can fix.
  --
  -- anon holding TRUNCATE on public.events is a real finding (TRUNCATE is not
  -- filtered by RLS) and is tracked as a separate privilege-hygiene task. It is
  -- deliberately NOT actioned here: nothing in this postflight changes a grant.
  select 45, 'the four DML privileges from 0002 are intact for authenticated',
         (select (has_table_privilege('authenticated', 'public.events', 'SELECT')
              and has_table_privilege('authenticated', 'public.events', 'INSERT')
              and has_table_privilege('authenticated', 'public.events', 'UPDATE')
              and has_table_privilege('authenticated', 'public.events', 'DELETE'))::text),
         'true'
  union all
  select 46, 'anon privileges on public.events (0002 grants none; anything here '
             'is default-privilege residue, and TRUNCATE would ignore RLS)',
         (select events_anon_privs from ev), '(context)'
  union all
  select 47, 'full privilege set authenticated holds on public.events -- anything '
             'beyond the four DML rights is default-privilege residue that '
             'predates 0012',
         (select events_auth_privs from ev), '(context)'
  -- 5x  live state ------------------------------------------------------------
  union all
  select 50, 'rows currently in the rate state table',
         (select count(*)::text from timeweave_private.event_write_rate), '(context)'
) s
order by ord;

rollback;

-- ############################################################################
-- MANUAL SECTION -- two things SQL cannot answer about itself.
--
-- M1  The state table must be invisible to PostgREST. With a real user JWT:
--       GET /rest/v1/event_write_rate?select=*
--     EXPECT 404 with code PGRST205 ("Could not find the table ... in the schema
--     cache"). A 200 means timeweave_private has been added to the project's
--     exposed schemas, which no migration can undo.
--
-- M2  A refusal must reach the client as an HTTP 429 carrying the token.
--     DEFERRED: no procedure is published here yet, on purpose.
--
--     REJECTED METHOD -- do not use it. An earlier draft of this file suggested
--     lowering the burst globally for a moment:
--
--         create or replace function public.events_rate_burst() ... select 1 ...
--         (make two writes from the app, observe the 429)
--         create or replace function public.events_rate_burst() ... select 120 ...
--
--     That is wrong for production, for three independent reasons:
--       * it changes the limit for EVERY account, not for the tester. Any real
--         user writing in that window is refused a write they had every right
--         to make, and sees a 429 nobody can explain from the logs;
--       * it cannot be made atomic from the client's side. PostgREST runs in its
--         own sessions, so the window cannot be wrapped in a transaction that
--         rolls back -- the restore is a separate, fallible step, and if it is
--         skipped or fails the product is left throttled at one write;
--       * it writes a real event row that then has to be cleaned up by hand.
--
--     WHAT A REPLACEMENT MUST SATISFY (to be designed separately, before this
--     check is performed):
--       * confined to ONE test account -- nothing global, no parameter change;
--       * reversible by construction, and unable to leave the product throttled
--         if the operator stops half way;
--       * still exercising the real PostgREST path, since that is the only thing
--         this check is about;
--       * leaving no event rows behind.
--     The obvious direction is to pre-seed that one account's `tat` in the state
--     table so the very next write is over the line; it is not written up here
--     because it has not been designed or rehearsed yet.
--
--     Until then, what IS already measured about this path: a probe carrying
--     this exact trigger shape refused 80 of 100 concurrent REST writes with
--     HTTP 429, code PT429, details TIMEWEAVE_RATE_EVENTS and a parseable
--     retry_after_seconds hint, and 0012_rate_limit_test.sql pins the same
--     refusal (PT429 + token + hint) from SQL on every run.
-- ############################################################################
