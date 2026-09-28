-- ============================================================================
-- TimeWeave -- [STAGE 4 of 4] POSTFLIGHT for 0021_freebusy_busy_only.sql
--
-- NOT A MIGRATION AND NOT A TEST SUITE. Run by hand, once, IMMEDIATELY AFTER
-- applying 0021 and BEFORE any deploy. Valid only for the frozen file:
--
--   sha256 c0ab2b9879a327373fce44a8d1fdd290fc32a899a9a700450639457537030b63
--                                              (35,616 bytes, 766 lines)
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
--   AUTOMATIC GATE    C01-C10, G02-G07, G10, G10b, G11-G20, N01-N08, J01-J04,
--                     W01-W05, W07, W08, W10, D01.
--   MANUAL COMPARISON W06 and W09 carry no expectation: they must equal,
--                     CHARACTER FOR CHARACTER, the same two rows from stage 3.
--                     That is how "0021 moved neither the wrapper nor the
--                     rate-limit parameters" is established, and nothing
--                     automates it.
--   CONTEXT ONLY      G01 (the new body md5), G10c, D02.
--
--   D02 IS NOT A GATE. The application is live; the total row count drifts with
--   ordinary use. D01 is the gate, and it is a real invariant: no deployed
--   client can write 'available' until the application ships.
--
--   SO: GO means P00 = 0 AND W06/W09 match stage 3. Only then may the
--   application be pushed and deployed, and that deploy needs its own approval.
--
-- SQL ERRORS ARE A STOP. Treat an error exactly as a FAIL.
--
-- ----------------------------------------------------------------------------
-- WHAT THIS FILE CAN AND CANNOT ESTABLISH
--
-- Everything here is STATIC: it reads the deployed function's text and its
-- catalog entries. Taken together the checks establish that the body is
-- "0019 plus ten availability predicates, in the right places, and nothing
-- else". They establish NOTHING about run time -- not the query plans, not the
-- helper functions, not the JSON any share link actually receives. A green
-- result is not a demonstration that Free/Busy is correct; that needs the
-- regression suite in an isolated environment, or an RPC call under its own
-- approval.
--
-- ----------------------------------------------------------------------------
-- THE EQUIVALENCE GATE (G10) AND WHY IT IS COMPUTED LINE BY LINE
--
-- G10 strips the lines 0021 added and requires what is left to be the 0019
-- body, md5 a7558dfa02a4ce6444d538e370eb631d -- the value the 0019 POSTFLIGHT
-- confirmed in production on 2026-09-20 (its C11).
--
-- It CANNOT produce a false pass. The target is the UNMODIFIED 0019 body: if
-- the removal leaves too much the result is longer and the md5 differs; if it
-- removes too much -- swallowing a 0019 comment -- the result is shorter and
-- the md5 differs. Removing exactly the added lines is the only way to match,
-- and that is the correct behaviour. The gate therefore fails closed.
--
-- It is computed with `unnest(string_to_array(body, E'\n')) with ordinality`
-- and two ANCHORED single-line matches, not with one multi-line greedy regular
-- expression. That keeps it clear of ARE's longest-match rules entirely.
--
-- G10b is the cross-check that keeps the removal rule honest: 0021 adds exactly
-- 28 lines to the body -- the 10 predicates and the 18 comment lines attached
-- to them. If the rule ever swallowed a 0019 comment, or a predicate went
-- missing, this number would not be 28. It is an automatic gate, not context.
--
-- G10 alone is not enough: a DUPLICATED predicate would be removed twice and
-- still reduce to the 0019 body, so G03-G07 (how many, on which alias) and
-- G11-G20 (where) are required alongside it.
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

-- ----------------------------------------------------------------------------
-- lines / nextcode / keep: the line-by-line reduction G10 and G10b read.
-- ORDER MATTERS. `lines` reads cor.body, and `res` below reads `keep`, so these
-- three must sit after `cor` and before `res`. Non-recursive CTEs may reference
-- only earlier ones.
--
-- If `cor` is empty (the function is missing), string_to_array(NULL, ...) is
-- NULL, unnest yields no rows, and both G10 and G10b fail -- the safe direction.
-- ----------------------------------------------------------------------------
lines as (
  select n, l,
         (l ~ '^\s*and [em]\.availability = ''busy''') as is_pred,
         (l ~ '^\s*--')                                as is_cmt
  from unnest(string_to_array((select body from cor), E'\n'))
       with ordinality as t(l, n)
),
nextcode as (
  select x.n, (select min(y.n) from lines y where y.n > x.n and not y.is_cmt) as nc
  from lines x
),
-- Drop a line when it IS one of the ten predicates, or when it is a comment
-- whose next non-comment line is one of them -- which is the shape of every
-- comment 0021 adds. Verified against the two local files: in all ten places
-- the line ABOVE the added block is code, never a comment, so no 0019 comment
-- can satisfy that condition. G10b is what keeps that property honest.
keep as (
  select x.n, x.l
  from lines x
  join nextcode c on c.n = x.n
  where not x.is_pred
    and not (x.is_cmt and c.nc is not null
             and (select y.is_pred from lines y where y.n = c.nc))
),

res as (
  select v.ord, v.phase, v.metric, v.expected, v.value,
         case when v.expected is null then 'context'
              when v.value is not distinct from v.expected then 'ok'
              else 'FAIL'
         end as status
  from (values

    -- C. identity, attributes, ownership, ACL -- ALL UNCHANGED -----------------
    ('C01','core','exactly one overload','1',
      (select count(*) from fn where nsp='timeweave_private' and proname='free_busy_core')::text),
    ('C02','core','identity arguments',
      'p_link_id uuid, p_from timestamp with time zone, p_to timestamp with time zone, p_from_date date, p_to_date date',
      (select args from cor)),
    ('C03','core','result type','jsonb',(select ret from cor)),
    ('C04','core','volatility is STABLE','s',(select provolatile::text from cor)),
    ('C05','core','SECURITY INVOKER','false',(select prosecdef::text from cor)),
    ('C06','core','proconfig','search_path=""',(select array_to_string(proconfig,',') from cor)),
    ('C07','core','language','plpgsql',(select lanname::text from cor)),
    -- C08 IS PORTABLE ON PURPOSE, and is the SAME invariant stage 3 checks at F08.
    -- The owner's role name is production's (`postgres`), not an invariant: 0019
    -- names only public/anon/authenticated/service_role in its REVOKEs, and the
    -- owner entry is whatever role owns the function. 0021 issues no GRANT or
    -- REVOKE, so the structure below must hold identically before and after it:
    -- exactly one explicit grantee, and it is the owner; EXECUTE only; not
    -- grantable; granted by the owner; no PUBLIC entry. A NULL proacl (PostgreSQL's
    -- default, which leaves PUBLIC able to execute) yields no rows and so fails.
    ('C08','core','GATE: explicit ACL = owner-only EXECUTE, non-grantable, no PUBLIC','true',
      (select (count(*) = 1
           and bool_and(a.grantee = c.proowner)
           and bool_and(a.grantor = c.proowner)
           and bool_and(a.privilege_type = 'EXECUTE')
           and bool_and(not a.is_grantable)
           and count(*) filter (where a.grantee = 0) = 0)::text
         from cor c, lateral pg_catalog.aclexplode(c.proacl) a)),
    ('C09','core','anon|authenticated|service_role may EXECUTE','false|false|false',
      (select pg_catalog.has_function_privilege('anon',oid,'EXECUTE')::text||'|'
           || pg_catalog.has_function_privilege('authenticated',oid,'EXECUTE')::text||'|'
           || pg_catalog.has_function_privilege('service_role',oid,'EXECUTE')::text from cor)),
    ('C10','core','owner is still get_free_busy''s owner','true',
      (select (c.proowner = g.proowner)::text from cor c, gfb g)),

    -- G. the ten predicates: how many, on which alias, and nothing else --------
    ('G01','edits','CONTEXT: new body md5', null::text,(select h from cor)),
    ('G02','edits','the body differs from the 0019 body','true',
      (select (h <> 'a7558dfa02a4ce6444d538e370eb631d')::text from cor)),
    ('G03','edits','availability predicates, exactly ten','10',
      (select count(*) from regexp_matches((select body from cor),
        '\n[ ]*and [em]\.availability = ''busy''','g'))::text),
    ('G04','edits','of which on alias e (6 busy sources + branch A)','7',
      (select count(*) from regexp_matches((select body from cor),
        '\n[ ]*and e\.availability = ''busy''','g'))::text),
    ('G05','edits','of which on alias m (branches B, C and the slot-mismatch CTE)','3',
      (select count(*) from regexp_matches((select body from cor),
        '\n[ ]*and m\.availability = ''busy''','g'))::text),
    ('G06','edits','no value other than busy is ever tested','10',
      (select count(*) from regexp_matches((select body from cor),
        'availability = ''busy''','g'))::text),
    -- G07 COUNTS CODE, NOT PROSE. A raw count over the whole body was 13, not 10:
    -- 0021 attaches explanatory comments to three of the predicates and the word
    -- `availability` appears in all three of them ("its own availability decides",
    -- "the MASTER's availability, never the exception's", "the MASTER's
    -- availability again"). Those three lines are inside the blocks G10 removes --
    -- G10b counts them among its 28 -- so they were never evidence of a stray
    -- reference, only of a gate that could not tell a comment from code.
    --
    -- Each line is stripped from its first `--` to end of line before counting.
    -- That is sound for THIS body and was checked statically against the frozen
    -- 0021: the function body contains no block comment (`/* */`) at all, and no
    -- `--` inside a string literal (the only five code lines carrying a trailing
    -- comment all have an even number of quotes before the `--`). Stripping to
    -- end of line rather than dropping whole comment lines is deliberate: it also
    -- covers a TRAILING comment, so prose cannot hide a reference behind code.
    --
    -- This stays distinct from G03-G06. Those pin the shape and the count of the
    -- ten predicates; G07 alone answers "and nothing else in the executable text
    -- mentions the column" -- a reference in a SELECT list, under a third alias,
    -- or compared to something other than 'busy' fails here and nowhere else.
    -- Reusing `lines` (G10's split) is reuse only; that CTE is untouched.
    ('G07','edits','the word availability appears ONLY in those ten predicates (comments stripped)','10',
      (select count(*) from lines x,
         lateral regexp_matches(regexp_replace(x.l,'--.*$',''),'availability','g'))::text),

    -- G10 IS THE EQUIVALENCE GATE ---------------------------------------------
    ('G10','edits','GATE: body minus the ten predicate blocks == the 0019 body',
      'a7558dfa02a4ce6444d538e370eb631d',
      (select md5(string_agg(l, E'\n' order by n)) from keep)),
    ('G10b','edits','GATE: lines removed by G10 (10 predicates + 18 attached comments)','28',
      ((select count(*) from lines) - (select count(*) from keep))::text),
    ('G10c','edits','CONTEXT: lines kept (the 0019 body splits into 522 elements)', null::text,
      (select count(*) from keep)::text),

    -- ------------------------------------------------------------------------
    -- G11-G20: each availability predicate is pinned to its own CTE / branch /
    -- alias. Existence (`body ~ pattern`), never a match count: "exactly ten,
    -- nowhere else" is already carried by G03-G07 and G10, and this group adds
    -- the one thing those cannot say -- WHERE each predicate sits.
    --
    -- HOW THE PATTERNS WORK. `\s*` between two code fragments means "adjacent
    -- apart from whitespace". It CANNOT step over a comment line, because `-` is
    -- not whitespace -- so every anchor below is a short CONTIGUOUS range of real
    -- code. Where 0021 inserted comment lines between the anchor and the
    -- predicate (G13, G15, G17, G18, G19, G20) that run is allowed explicitly and
    -- ONLY as whole comment lines, with `(\s*--[^\n]*)*`; the group can never
    -- absorb a line of code. `[^\n]*` after the literal consumes the predicate
    -- line's own trailing comment where there is one (G11, G12, G14, G16) and
    -- matches empty where there is not.
    --
    -- Every entry has an UPPER anchor, the predicate, and a LOWER anchor, so
    -- moving a predicate to another CTE, to another position inside its own CTE,
    -- or onto the wrong alias all fail the same way: the anchors close up and the
    -- pattern no longer has room for it. G17, G18 and G19 are why this group
    -- exists at all -- they reject the one plausible wrong implementation, a
    -- single gate on the OUTER completeness scan, which would leave branch (B)
    -- unable to fire and let an over-stated busy set be reported complete.
    --
    -- Only ARE constructs whose PostgreSQL support is not in question are used:
    -- `\s`, `\.`, `\(`, `\)`, `[^\n]`, `*`, `+` and a plain capturing group.
    -- No `(?:...)`, no lookahead, no lookbehind, no non-greedy quantifier.
    -- ------------------------------------------------------------------------

    ('G11','placement','timed_single gates on e, between the visibility filter and its own window test','true',
     (select (body ~ 'and e\.rrule is null\s*and e\.recurrence_id is null\s*and e\.all_day = false\s*and \(v_include_private or e\.visibility <> ''private''\)\s*and e\.availability = ''busy''[^\n]*\s*and e\.start_at < p_to\s*and e\.end_at\s+> p_from\s*\),')::text
        from cor)),

    ('G12','placement','timed_expandable_master gates on e, between the visibility filter and the zone test','true',
     (select (body ~ 'and e\.rrule is not null\s*and e\.all_day = false\s*and \(v_include_private or e\.visibility <> ''private''\)\s*and e\.availability = ''busy''[^\n]*\s*and e\.start_at < p_to\s*and e\.timezone = any\(v_ok_tz\)')::text
        from cor)),

    ('G13','placement','timed_exception_busy gates on e, beside is_cancelled and BEFORE the visibility filter','true',
     (select (body ~ 'and e\.is_cancelled = false\s*and e\.all_day = false(\s*--[^\n]*)*\s*and e\.availability = ''busy''[^\n]*\s*and \(v_include_private or e\.visibility <> ''private''\)\s*and e\.start_at < p_to')::text
        from cor)),

    ('G14','placement','expandable_master (all-day) gates on e, between the visibility filter and rrule_sql_subset','true',
     (select (body ~ 'and e\.rrule is not null\s*and e\.all_day = true\s*and \(v_include_private or e\.visibility <> ''private''\)\s*and e\.availability = ''busy''[^\n]*\s*and e\.start_date < p_to_date\s*and public\.rrule_sql_subset\(')::text
        from cor)),

    ('G15','placement','exception_busy (all-day) gates on e, beside is_cancelled and BEFORE the visibility filter','true',
     (select (body ~ 'and e\.is_cancelled = false\s*and e\.all_day = true(\s*--[^\n]*)*\s*and e\.availability = ''busy''[^\n]*\s*and \(v_include_private or e\.visibility <> ''private''\)\s*and e\.start_date < p_to_date')::text
        from cor)),

    ('G16','placement','the single-event arm of allday_src gates on e, immediately before its UNION ALL','true',
     (select (body ~ 'and e\.rrule is null\s*and e\.recurrence_id is null\s*and e\.all_day = true\s*and \(v_include_private or e\.visibility <> ''private''\)\s*and e\.availability = ''busy''[^\n]*\s*and e\.start_date < p_to_date\s*and e\.end_date\s+> p_from_date\s*union all')::text
        from cor)),

    ('G17','placement','completeness branch (A) gates on e -- e IS the master there -- right after the rrule test','true',
     (select (body ~ '\( e\.rrule is not null(\s*--[^\n]*)*\s*and e\.availability = ''busy''[^\n]*\s*and \(')::text
        from cor)),

    ('G18','placement','completeness branch (B) gates on m -- the MASTER -- before the all_day mismatch test','true',
     (select (body ~ 'where m\.id = e\.recurrence_id(\s*--[^\n]*)*\s*and m\.availability = ''busy''[^\n]*\s*and e\.all_day is distinct from m\.all_day')::text
        from cor)),

    ('G19','placement','completeness branch (C) gates on m -- the MASTER -- before the window-relevance test','true',
     (select (body ~ 'where m\.id = e\.recurrence_id(\s*--[^\n]*)*\s*and m\.availability = ''busy''[^\n]*\s*and \(')::text
        from cor)),

    ('G20','placement','the slot-mismatch expandable CTE gates on m, between the visibility filter and the window test','true',
     (select (body ~ 'and m\.rrule is not null\s*and m\.all_day = false\s*and \(v_include_private or m\.visibility <> ''private''\)(\s*--[^\n]*)*\s*and m\.availability = ''busy''[^\n]*\s*and m\.start_at < p_to\s*and m\.timezone = any\(v_ok_tz\)')::text
        from cor)),

    -- N. what must have NO availability condition ------------------------------
    --    Detaching is a structural fact about the series: an available exception
    --    removes the master's occurrence exactly as a private or a cancelled one
    --    does. Filtering either anti-join would leave a BUSY master's occurrence
    --    in the busy set after an AVAILABLE exception replaced it. Filtering the
    --    slot-mismatch join would hide a mismatch that does corrupt the busy set.
    --    N05 is the counterpart of G17-G19: the OUTER scan must stay ungated.
    ('N01','structure','timed detach anti-join present and UNFILTERED','1',
      (select count(*) from regexp_matches((select body from cor),
        'where x\.recurrence_id = m\.id\s*\n\s*and x\.recurrence_slot_start = s\.t\s*\n\s*\)','g'))::text),
    ('N02','structure','all-day detach anti-join present and UNFILTERED','1',
      (select count(*) from regexp_matches((select body from cor),
        'where x\.recurrence_id = m\.id\s*\n\s*and x\.recurrence_slot_date = s\.d\s*\n\s*\)','g'))::text),
    ('N03','structure','the slot-mismatch exception join is UNFILTERED','1',
      (select count(*) from regexp_matches((select body from cor),
        'join public\.events x\s*\n\s*on x\.recurrence_id = m\.id\s*\n\s*and x\.all_day = false\s*\n\s*left join generated','g'))::text),
    ('N04','structure','v_tz_all collection unchanged (no availability in it)','1',
      (select count(*) from regexp_matches((select body from cor),
        'into v_tz_all\s*\n\s*from public\.events e\s*\n\s*where e\.owner_id = v_owner\s*\n\s*and e\.all_day = false\s*\n\s*and e\.rrule is not null\s*\n\s*and e\.timezone is not null;','g'))::text),
    ('N05','structure','the OUTER completeness scan has NO availability predicate','1',
      (select count(*) from regexp_matches((select body from cor),
        'from public\.events e\s*\n\s*where e\.owner_id = v_owner\s*\n\s*and \(v_include_private or e\.visibility <> ''private''\)\s*\n\s*and \(','g'))::text),
    ('N06','structure','include_private filters still 8','8',
      (select count(*) from regexp_matches((select body from cor),
        'v_include_private or [em]\.visibility <> ''private''','g'))::text),
    ('N07','structure','is_cancelled = false still exactly twice','2',
      (select count(*) from regexp_matches((select body from cor),'is_cancelled = false','g'))::text),
    ('N08','structure','reads public.events in 13 places','13',
      (select count(*) from regexp_matches((select body from cor),'from public\.events','g'))::text),

    -- J. the response contract ---------------------------------------------------
    ('J01','contract','the empty answer is still {complete:true, slots:[]}','1',
      (select count(*) from regexp_matches((select body from cor),
        'jsonb_build_object\(''complete'', true, ''slots'', ''\[\]''::jsonb\)','g'))::text),
    ('J02','contract','the final return is still {complete, slots}','1',
      (select count(*) from regexp_matches((select body from cor),
        'jsonb_build_object\(''complete'', v_complete, ''slots'', coalesce\(v_slots','g'))::text),
    ('J03','contract','no third top-level key','0',
      (select count(*) from regexp_matches((select body from cor),'''available'',','g'))::text),
    ('J04','contract','no share_available anywhere','0',
      (select count(*) from regexp_matches((select body from cor),'share_available','g'))::text),

    -- W. the wrapper and the limiter must be untouched -----------------------------
    ('W01','wrapper','public.get_free_busy overloads','1',
      (select count(*) from fn where nsp='public' and proname='get_free_busy')::text),
    ('W02','wrapper','SECURITY DEFINER','true',(select prosecdef::text from gfb)),
    ('W03','wrapper','volatility is VOLATILE','v',(select provolatile::text from gfb)),
    ('W04','wrapper','proconfig','search_path=""',(select array_to_string(proconfig,',') from gfb)),
    -- W05 IS PORTABLE for the same reason as C08, and is the SAME invariant stage 3
    -- checks at W05. 0005 granted EXECUTE to anon and authenticated and revoked it
    -- from PUBLIC; the third entry is the owner's own, whatever that role is called.
    -- Counting to three AND matching each expected grantee is what rejects an
    -- unexpected fourth grantee -- has_function_privilege on named roles alone
    -- cannot see one.
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
    ('W06','wrapper','MANUAL: body md5 -- MUST equal stage 3 W06', null::text,
      (select h from gfb)),
    ('W07','wrapper','calls free_busy_core exactly once','1',
      (select count(*) from regexp_matches((select body from gfb),
        'timeweave_private\.free_busy_core\(','g'))::text),
    ('W08','limits','the five 0019 parameter functions exist','5',
      (select count(*) from fn where nsp='timeweave_private'
        and proname in ('freebusy_link_rate_interval','freebusy_link_rate_burst',
                        'freebusy_owner_rate_interval','freebusy_owner_rate_burst',
                        'freebusy_concurrency_slots'))::text),
    ('W09','limits','MANUAL: md5 over those five bodies -- MUST equal stage 3 W09', null::text,
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

    -- D. data ------------------------------------------------------------------------
    ('D01','data','GATE: rows with availability <> ''busy''','0',
      (select count(*) from public.events where availability <> 'busy')::text),
    ('D02','data','CONTEXT: total rows (drift is normal; not a gate)', null::text,
      (select count(*) from public.events)::text)

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
