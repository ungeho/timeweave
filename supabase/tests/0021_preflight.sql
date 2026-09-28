-- ============================================================================
-- TimeWeave -- [STAGE 3 of 4] PREFLIGHT for 0021_freebusy_busy_only.sql
--
-- NOT A MIGRATION AND NOT A TEST SUITE. Run by hand, once, AFTER
-- 0020_postflight.sql has passed in full, immediately BEFORE applying 0021.
-- Valid only for the frozen file:
--
--   sha256 c0ab2b9879a327373fce44a8d1fdd290fc32a899a9a700450639457537030b63
--                                              (35,616 bytes, 766 lines)
--
-- Expects 0020 applied and verified, and 0021 NOT applied.
--
-- DO NOT RUN THIS UNTIL STAGE 2 IS GO. 0020_postflight.sql must have P00 = 0,
-- its U01-U05 must have been compared by hand against stage 1, and the
-- PostgREST schema-cache probe must have come back clean. Reaching this stage
-- with any of those outstanding means the sequence was broken.
--
-- READ-ONLY: SELECT and catalog inspection only. No DDL, no DML, no SET, no
-- temp table, no advisory lock, no RPC call. The main check runs inside a
-- read-only transaction that ends in ROLLBACK.
--
-- RUNNING THIS AGAINST PRODUCTION NEEDS ITS OWN APPROVAL.
--
-- ----------------------------------------------------------------------------
-- HOW TO READ THE RESULT -- AND WHY P00 = 0 IS NOT ENOUGH
--
--   AUTOMATIC GATE    V02, V03, F01-F10, F14-F21, W01-W05, W07, W08, W10,
--                     E01-E05, D01, D02, D06.
--   MANUAL RECORDING  W06 and W09 carry no expectation: they must be written
--                     down here and compared BY HAND with the same two rows in
--                     stage 4. That is how "0021 did not move the wrapper or
--                     the rate-limit parameters" is established, and nothing
--                     automates it.
--   CONTEXT ONLY      V01, F11, F12, F13, D03.
--
--   F10 IS THE ONLY GATE ON THE FUNCTION BODY. F11, F12 and F13 exist to
--   CLASSIFY an F10 mismatch, never to excuse one: a match on any of them is
--   NOT permission to apply. If F10 fails, production's free_busy_core is not
--   the 0019 body, and applying 0021 would overwrite a change nobody has
--   accounted for. STOP and find out what happened first.
--
--   D03 IS NOT A GATE. The application is live; the total row count drifts with
--   ordinary use. D01 is the gate that matters, and it is a real invariant:
--   with the correct ordering no deployed client can write 'available', so a
--   non-zero D01 means the application was deployed after 0020 -- the exact
--   order violation this check exists to catch. THERE IS NO T0-BASED STABLE
--   SUBSET HERE, and none should be reintroduced: rows legitimately leave any
--   such subset on every ordinary UPDATE and DELETE, so it produced false
--   alarms without detecting anything 0020/0021 could actually do. Neither
--   migration contains a single DML statement; that is established by reading
--   them, not by fingerprinting rows.
--
--   SO: GO means P00 = 0 AND W06/W09 recorded AND stage 2 was GO.
--
-- SQL ERRORS ARE A STOP. Treat an error exactly as a FAIL.
--
-- NEXT STAGE: apply 0021, then run 0021_postflight.sql. Do NOT deploy the
-- application until stage 4 is GO.
--
-- ----------------------------------------------------------------------------
-- HOW THE BODY IS COMPARED, AND WHY NOT pg_get_functiondef
--
-- The comparison is against `prosrc` -- the text between the $fn$ delimiters,
-- exactly as PostgreSQL stored it. CREATE FUNCTION vs CREATE OR REPLACE
-- FUNCTION, the layout of the argument list and the attribute lines do not
-- appear in prosrc at all, so the formatting differences that would make a
-- literal comparison useless are simply not present. pg_get_functiondef is
-- REGENERATED text -- it normalises qualification, whitespace and type names
-- (timestamptz becomes timestamp with time zone) -- so it is printed as
-- context in F13 and never compared.
--
-- Only CR removal is applied before hashing, because production has shown CRLF
-- bodies before (0019's own preflight records this). Nothing else is
-- normalised: normalisation is used to CLASSIFY a mismatch, never to declare a
-- match.
--
-- The expected value is not a guess. supabase/tests/0019_freebusy_rate_limit_
-- postflight.sql asserts the same md5 at C11, and that postflight was run in
-- production on 2026-09-20.
--
-- PRIVACY. Counts, catalog text, ACLs and hashes only.
-- ============================================================================


-- ============================================================================
-- (0) PRE-CHECK. Read this row FIRST. If any column is NULL, STOP.
-- ============================================================================
select to_regclass('public.events')                                as events,
       to_regprocedure('timeweave_private.free_busy_core(uuid, timestamptz, timestamptz, date, date)')
                                                                   as free_busy_core,
       to_regprocedure('public.get_free_busy(text, timestamptz, timestamptz, date, date)')
                                                                   as get_free_busy,
       (select count(*) from pg_catalog.pg_roles where rolname = 'anon')
                                                                   as anon_role_count;


-- ============================================================================
-- MAIN CHECK.
-- ============================================================================
begin transaction read only;

with
fn as (
  select n.nspname as nsp, p.proname, p.oid, p.proowner, p.proacl, p.prosecdef,
         p.provolatile, p.proconfig, l.lanname,
         pg_catalog.pg_get_function_identity_arguments(p.oid) as args,
         pg_catalog.pg_get_function_result(p.oid) as ret,
         replace(p.prosrc, E'\r','') as body,
         md5(replace(p.prosrc, E'\r','')) as h
  from pg_catalog.pg_proc p
  join pg_catalog.pg_namespace n on n.oid = p.pronamespace
  join pg_catalog.pg_language l on l.oid = p.prolang
),
cor as (select * from fn where oid = to_regprocedure(
          'timeweave_private.free_busy_core(uuid, timestamptz, timestamptz, date, date)')),
gfb as (select * from fn where oid = to_regprocedure(
          'public.get_free_busy(text, timestamptz, timestamptz, date, date)')),
col as (
  select a.attname, a.attnotnull,
         pg_catalog.format_type(a.atttypid, a.atttypmod) as typ,
         pg_catalog.pg_get_expr(d.adbin, d.adrelid) as dflt
  from pg_catalog.pg_attribute a
  left join pg_catalog.pg_attrdef d on d.adrelid = a.attrelid and d.adnum = a.attnum
  where a.attrelid = 'public.events'::regclass and a.attname = 'availability'
    and not a.attisdropped
),
res as (
  select v.ord, v.phase, v.metric, v.expected, v.value,
         case when v.expected is null then 'context'
              when v.value is not distinct from v.expected then 'ok'
              else 'FAIL'
         end as status
  from (values

    -- V. context ---------------------------------------------------------------
    ('V01','context','role that will run the migration', null::text, current_user::text),
    ('V02','context','that role owns free_busy_core (CREATE OR REPLACE needs it)','true',
      (select (pg_catalog.pg_get_userbyid(proowner)=current_user)::text from cor)),
    ('V03','context','this transaction is read only','on',
      current_setting('transaction_read_only')),

    -- F. free_busy_core exactly as 0019 left it ----------------------------------
    ('F01','core','exactly one overload of free_busy_core','1',
      (select count(*) from fn where nsp='timeweave_private' and proname='free_busy_core')::text),
    ('F02','core','identity arguments',
      'p_link_id uuid, p_from timestamp with time zone, p_to timestamp with time zone, p_from_date date, p_to_date date',
      (select args from cor)),
    ('F03','core','result type','jsonb',(select ret from cor)),
    ('F04','core','volatility is STABLE','s',(select provolatile::text from cor)),
    ('F05','core','SECURITY INVOKER','false',(select prosecdef::text from cor)),
    ('F06','core','proconfig','search_path=""',(select array_to_string(proconfig,',') from cor)),
    ('F07','core','language','plpgsql',(select lanname::text from cor)),
    -- F08 IS PORTABLE ON PURPOSE. The owner's role name is production's
    -- (`postgres`), not an invariant: 0019 names only public/anon/authenticated/
    -- service_role in its REVOKEs, and the owner entry is whatever role owns the
    -- function. So the whole ACL is inspected structurally instead of compared as
    -- text: exactly one explicit grantee, and it is the owner; EXECUTE only; not
    -- grantable; granted by the owner; no PUBLIC entry. A NULL proacl (PostgreSQL's
    -- default, which leaves PUBLIC able to execute) yields no rows and so fails.
    ('F08','core','GATE: explicit ACL = owner-only EXECUTE, non-grantable, no PUBLIC','true',
      (select (count(*) = 1
           and bool_and(a.grantee = c.proowner)
           and bool_and(a.grantor = c.proowner)
           and bool_and(a.privilege_type = 'EXECUTE')
           and bool_and(not a.is_grantable)
           and count(*) filter (where a.grantee = 0) = 0)::text
         from cor c, lateral pg_catalog.aclexplode(c.proacl) a)),
    ('F09','core','anon|authenticated|service_role may EXECUTE','false|false|false',
      (select pg_catalog.has_function_privilege('anon',oid,'EXECUTE')::text||'|'
           || pg_catalog.has_function_privilege('authenticated',oid,'EXECUTE')::text||'|'
           || pg_catalog.has_function_privilege('service_role',oid,'EXECUTE')::text from cor)),

    -- F10 IS THE GATE ------------------------------------------------------------
    ('F10','core','GATE: body md5, CR removed (the 0019 POSTFLIGHT confirmed this value)',
      'a7558dfa02a4ce6444d538e370eb631d',(select h from cor)),

    -- F11-F13: CLASSIFIERS. A match here is NOT permission to apply. -------------
    ('F11','core','CLASSIFIER: md5 after stripping comments and folding whitespace', null::text,
      (select md5(regexp_replace(regexp_replace(body,'--[^\n]*','','g'),'\s+',' ','g')) from cor)),
    ('F12','core','CLASSIFIER: body length in characters', null::text,
      (select length(body)::text from cor)),
    ('F13','core','CONTEXT ONLY: pg_get_functiondef head (regenerated -- never compared)',
      null::text, left(pg_catalog.pg_get_functiondef((select oid from cor)), 200)),

    -- F14-F21: structural fingerprints. Read these when F10 fails. ---------------
    ('F14','core','reads public.events in 13 places','13',
      (select count(*) from regexp_matches((select body from cor),'from public\.events','g'))::text),
    ('F15','core','include_private filters','8',
      (select count(*) from regexp_matches((select body from cor),
        'v_include_private or [em]\.visibility <> ''private''','g'))::text),
    ('F16','core','timed detach anti-join present once','1',
      (select count(*) from regexp_matches((select body from cor),
        'x\.recurrence_slot_start = s\.t','g'))::text),
    ('F17','core','all-day detach anti-join present once','1',
      (select count(*) from regexp_matches((select body from cor),
        'x\.recurrence_slot_date = s\.d','g'))::text),
    ('F18','core','is_cancelled = false appears exactly twice','2',
      (select count(*) from regexp_matches((select body from cor),'is_cancelled = false','g'))::text),
    ('F19','core','the body does NOT mention availability yet','0',
      (select count(*) from regexp_matches((select body from cor),'availability','g'))::text),
    ('F20','core','two jsonb_build_object(complete, ...) returns','2',
      (select count(*) from regexp_matches((select body from cor),
        'jsonb_build_object\(''complete''','g'))::text),
    ('F21','core','no share_available and no ''available'' key','0',
      (select count(*) from regexp_matches((select body from cor),
        '(share_available|''available'')','g'))::text),

    -- W. the wrapper 0021 must NOT touch, plus rate limit / concurrency ----------
    ('W01','wrapper','public.get_free_busy overloads','1',
      (select count(*) from fn where nsp='public' and proname='get_free_busy')::text),
    ('W02','wrapper','SECURITY DEFINER','true',(select prosecdef::text from gfb)),
    ('W03','wrapper','volatility is VOLATILE','v',(select provolatile::text from gfb)),
    ('W04','wrapper','proconfig','search_path=""',(select array_to_string(proconfig,',') from gfb)),
    -- W05 IS PORTABLE for the same reason as F08. 0005 granted EXECUTE to anon and
    -- authenticated and revoked it from PUBLIC; the third entry is the owner's own,
    -- whatever that role is called. Counting to three AND matching each expected
    -- grantee is what rejects an unexpected fourth grantee -- has_function_privilege
    -- on named roles alone (F09) cannot see one.
    ('W05','wrapper','GATE: explicit ACL = owner+anon+authenticated EXECUTE only, no PUBLIC','true',
      (select (count(*) = 3
           and bool_and(a.grantor = g.proowner)
           and bool_and(a.privilege_type = 'EXECUTE')
           and bool_and(not a.is_grantable)
           and count(*) filter (where a.grantee = 0) = 0
           and count(*) filter (where a.grantee = g.proowner) = 1
           and count(*) filter (where a.grantee = pg_catalog.to_regrole('anon')::oid) = 1
           and count(*) filter (where a.grantee = pg_catalog.to_regrole('authenticated')::oid) = 1)::text
         from gfb g, lateral pg_catalog.aclexplode(g.proacl) a)),
    ('W06','wrapper','MANUAL: RECORD THIS -- body md5 (stage 4 W06 must equal it)', null::text,
      (select h from gfb)),
    ('W07','wrapper','calls free_busy_core exactly once','1',
      (select count(*) from regexp_matches((select body from gfb),
        'timeweave_private\.free_busy_core\(','g'))::text),
    ('W08','limits','the five 0019 parameter functions exist','5',
      (select count(*) from fn where nsp='timeweave_private'
        and proname in ('freebusy_link_rate_interval','freebusy_link_rate_burst',
                        'freebusy_owner_rate_interval','freebusy_owner_rate_burst',
                        'freebusy_concurrency_slots'))::text),
    ('W09','limits','MANUAL: RECORD THIS -- md5 over those five bodies (stage 4 W09 must equal it)',
      null::text,
      (select md5(string_agg(h, ';' order by proname collate "C")) from fn
        where nsp='timeweave_private'
          and proname in ('freebusy_link_rate_interval','freebusy_link_rate_burst',
                          'freebusy_owner_rate_interval','freebusy_owner_rate_burst',
                          'freebusy_concurrency_slots'))),
    ('W10','limits','the two rate tables exist','2',
      (select count(*) from pg_catalog.pg_class c
         join pg_catalog.pg_namespace n on n.oid=c.relnamespace
        where n.nspname='timeweave_private'
          and c.relname in ('freebusy_owner_rate','freebusy_link_rate'))::text),

    -- E. 0020 is in place exactly as declared ------------------------------------
    ('E01','column','availability exists','1',(select count(*) from col)::text),
    ('E02','column','type text','text',(select typ from col)),
    ('E03','column','NOT NULL','true',(select attnotnull::text from col)),
    ('E04','column','DEFAULT','''busy''::text',(select dflt from col)),
    ('E05','column','events_availability_values is a validated CHECK','1',
      (select count(*) from pg_catalog.pg_constraint
        where conrelid='public.events'::regclass and conname='events_availability_values'
          and contype='c' and convalidated)::text),

    -- D. the no-op precondition -- measured, never assumed ------------------------
    ('D01','data','GATE: rows with availability <> ''busy'' (MUST be zero)','0',
      (select count(*) from public.events where availability <> 'busy')::text),
    ('D02','data','rows with availability IS NULL (MUST be zero)','0',
      (select count(*) from public.events where availability is null)::text),
    ('D03','data','CONTEXT: total rows (drift is normal; not a gate)', null::text,
      (select count(*) from public.events)::text),
    ('D06','data','no other backend holds a lock on public.events','0',
      (select count(*) from pg_catalog.pg_locks
        where relation='public.events'::regclass and pid <> pg_backend_pid())::text)

  ) as v (ord, phase, metric, expected, value)
)
select ord, phase, metric, expected, value, status from res
union all
select 'P00','summary','checks that FAIL (necessary for GO, not sufficient -- see header)','0',
       count(*) filter (where status='FAIL')::text,
       case when count(*) filter (where status='FAIL')=0 then 'ok' else 'FAIL' end
from res
order by 1;

rollback;
