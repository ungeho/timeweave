-- ============================================================================
-- 0024 POSTFLIGHT -- the database as it must look AFTER 0024 is applied
-- ============================================================================
-- READ THIS ROW FIRST: E01. GO requires E01 = ok and P00 = 0.
--
-- SCOPE. CATALOG/STRUCTURAL and read-only: signatures, grants, volatility,
-- search_path, body fingerprints and the presence or absence of particular
-- identifiers in the source text. It calls NO application function and creates
-- no fixture, so it is runnable read-only against production. What an active
-- link actually ANSWERS is 0024_available_test.sql's job, in an isolated
-- database.
--
-- ============================================================================
-- E01 IS THE POINT OF THIS FILE
--
-- 0024 adds a sibling helper instead of extending free_busy_core precisely so
-- that the core stays byte-identical. E01 re-asserts
--
--   a9b4097e4b390cee1229709945475d2b
--
-- the same literal the 0024 preflight gated before the migration ran. If this
-- row FAILs, the migration touched something it was written not to touch and
-- 0021's ten availability predicates are back under review.
--
-- ============================================================================
-- HOW THE ONE-CORE-CALL INVARIANT IS PROVED
--
-- Structurally, here, and nowhere else:
--
--   W08  the wrapper holds exactly TWO core call sites -- one in each arm of a
--        single if/else. Two sites, not one, is the approved design: the
--        share_available=false arm must reach the core WITHOUT the helper.
--   W08b exactly ONE branch guard chooses between those arms, so exactly one
--        call site executes per request.
--   A06  free_busy_available contains ZERO references to the core, so the
--        helper cannot add a second call.
--   plus static review of both wrapper branches
--
-- No runtime assertion proves an execution count, and none is attempted. The
-- subtraction cases in the runtime suite prove Busy/Available separation and
-- subtraction correctness only -- that is what they are labelled.
--
-- ============================================================================
-- HISTORICAL ASSERTIONS 0024 SUPERSEDES (recorded, NOT repaired)
--
--   0021_freebusy_busy_only_test.sql R8 P1/P2, R11, R17, R18 A/B -- required
--       wrapper JSONB = core JSONB. Already untrue since 0023 added link_state;
--       0024 adds `available` to active answers and widens the gap further.
--   0022_postflight.sql B04, 0022_share_available_test.sql 8.5 -- 0023 already
--       superseded these.
--   0023_postflight.sql W10/W11/W12 and the runtime key-count assertions --
--       they pinned the active answer to EXACTLY link_state, complete and
--       slots. That was U2's phase boundary and 0023's own header says a later
--       migration is expected to supersede it deliberately. This is that
--       migration.
--
-- Those files stay byte-for-byte frozen and must NOT be re-run as current-state
-- gates, and must not be edited to match the new shape.
--
-- THIS FILE CHANGES NOTHING.
-- ============================================================================

select to_regprocedure('public.get_free_busy(text, timestamptz, timestamptz, date, date)')
                                                                    as wrapper,
       to_regprocedure('timeweave_private.free_busy_core(uuid, timestamptz, timestamptz, date, date)')
                                                                    as core,
       to_regprocedure('timeweave_private.free_busy_available(uuid, timestamptz, timestamptz, date, date, jsonb)')
                                                                    as helper;

begin transaction read only;

with
fn as (
  select p.oid,
         n.nspname                                              as nsp,
         p.proname,
         pg_catalog.pg_get_function_identity_arguments(p.oid)   as args,
         pg_catalog.pg_get_function_result(p.oid)               as ret,
         l.lanname                                              as lang,
         p.provolatile::text                                    as vol,
         p.prosecdef                                            as secdef,
         pg_catalog.array_to_string(p.proconfig, ',')           as cfg,
         p.prosrc                                               as body,
         pg_catalog.md5(pg_catalog.replace(p.prosrc, E'\r', '')) as h
  from pg_catalog.pg_proc p
  join pg_catalog.pg_namespace n on n.oid = p.pronamespace
  join pg_catalog.pg_language  l on l.oid = p.prolang
),
wrp as (select * from fn where oid = to_regprocedure(
          'public.get_free_busy(text, timestamptz, timestamptz, date, date)')),
cor as (select * from fn where oid = to_regprocedure(
          'timeweave_private.free_busy_core(uuid, timestamptz, timestamptz, date, date)')),
hlp as (select * from fn where oid = to_regprocedure(
          'timeweave_private.free_busy_available(uuid, timestamptz, timestamptz, date, date, jsonb)')),
res as (
  select v.ord, v.phase, v.metric, v.expected, v.value,
         case when v.expected is null then 'context'
              when v.value is not distinct from v.expected then 'ok'
              else 'FAIL'
         end as status
  from (values

    -- E. THE FROZEN CORE -- the decisive rows ---------------------------------
    ('E01','core','GATE: FROZEN body md5 STILL EXACTLY UNCHANGED',
      'a9b4097e4b390cee1229709945475d2b', (select h from cor)),
    ('E02','core','GATE: identity arguments unchanged',
      'p_link_id uuid, p_from timestamp with time zone, p_to timestamp with time zone, p_from_date date, p_to_date date',
      (select args from cor)),
    ('E03','core','GATE: result|language|volatility|security|search_path unchanged',
      'jsonb|plpgsql|s|INVOKER|search_path=""',
      (select ret ||'|'|| lang ||'|'|| vol ||'|'||
              (case when secdef then 'DEFINER' else 'INVOKER' end) ||'|'|| coalesce(cfg,'-')
         from cor)),
    ('E04','core','GATE: still exactly one free_busy_core overload','1',
      (select count(*) from fn where nsp='timeweave_private' and proname='free_busy_core')::text),
    ('E05','core','GATE: still not executable by public|anon|authenticated|service_role',
      'false|false|false|false',
      pg_catalog.has_function_privilege('public',
        'timeweave_private.free_busy_core(uuid, timestamptz, timestamptz, date, date)','EXECUTE')::text ||'|'||
      pg_catalog.has_function_privilege('anon',
        'timeweave_private.free_busy_core(uuid, timestamptz, timestamptz, date, date)','EXECUTE')::text ||'|'||
      pg_catalog.has_function_privilege('authenticated',
        'timeweave_private.free_busy_core(uuid, timestamptz, timestamptz, date, date)','EXECUTE')::text ||'|'||
      pg_catalog.has_function_privilege('service_role',
        'timeweave_private.free_busy_core(uuid, timestamptz, timestamptz, date, date)','EXECUTE')::text),

    -- A. the new helper -------------------------------------------------------
    ('A01','helper','GATE: exact six-arg signature exists',
      'p_link_id uuid, p_from timestamp with time zone, p_to timestamp with time zone, p_from_date date, p_to_date date, p_busy_result jsonb',
      (select args from hlp)),
    ('A02','helper','GATE: EXACTLY ONE free_busy_available overload -- no alternate','1',
      (select count(*) from fn where nsp='timeweave_private' and proname='free_busy_available')::text),
    ('A03','helper','GATE: result|language|volatility|security|search_path',
      'jsonb|plpgsql|s|INVOKER|search_path=""',
      (select ret ||'|'|| lang ||'|'|| vol ||'|'||
              (case when secdef then 'DEFINER' else 'INVOKER' end) ||'|'|| coalesce(cfg,'-')
         from hlp)),
    ('A04','helper','GATE: NOT executable by public|anon|authenticated|service_role',
      'false|false|false|false',
      pg_catalog.has_function_privilege('public',
        'timeweave_private.free_busy_available(uuid, timestamptz, timestamptz, date, date, jsonb)','EXECUTE')::text ||'|'||
      pg_catalog.has_function_privilege('anon',
        'timeweave_private.free_busy_available(uuid, timestamptz, timestamptz, date, date, jsonb)','EXECUTE')::text ||'|'||
      pg_catalog.has_function_privilege('authenticated',
        'timeweave_private.free_busy_available(uuid, timestamptz, timestamptz, date, date, jsonb)','EXECUTE')::text ||'|'||
      pg_catalog.has_function_privilege('service_role',
        'timeweave_private.free_busy_available(uuid, timestamptz, timestamptz, date, date, jsonb)','EXECUTE')::text),
    ('A05','helper','GATE: lives in timeweave_private, not public','timeweave_private',
      (select nsp from hlp)),

    -- A06-A10. helper body structure -----------------------------------------
    ('A06','helper','GATE: ZERO references to free_busy_core -- it cannot call the core','0',
      coalesce((select count(*) from pg_catalog.regexp_matches((select body from hlp),
        'free_busy_core','g')), 0)::text),
    -- 10 = the six contribution sources (timed/all-day x single, master,
    -- exception) plus the four exactness gates (A') (B') (C') (D').
    ('A07','helper','GATE: ten availability=''available'' predicates (6 sources + 4 gates)','10',
      coalesce((select count(*) from pg_catalog.regexp_matches((select body from hlp),
        'availability = ''available''','g')), 0)::text),
    ('A08','helper','GATE: both detach anti-joins present and slot-keyed','1|1',
      coalesce((select count(*) from pg_catalog.regexp_matches((select body from hlp),
        'x\.recurrence_slot_start = s\.t','g')), 0)::text ||'|'||
      coalesce((select count(*) from pg_catalog.regexp_matches((select body from hlp),
        'x\.recurrence_slot_date = s\.d','g')), 0)::text),
    ('A09','helper','GATE: multirange subtraction present for both models','1|1',
      coalesce((select count(*) from pg_catalog.regexp_matches((select body from hlp),
        'v_avail_t - v_busy_t','g')), 0)::text ||'|'||
      coalesce((select count(*) from pg_catalog.regexp_matches((select body from hlp),
        'v_avail_d - v_busy_d','g')), 0)::text),
    ('A10','helper','GATE: the three public statuses, and ONLY those, are constructed',
      '1|1|0',
      coalesce((select count(*) from pg_catalog.regexp_matches((select body from hlp),
        '''status'', ''indeterminate''','g')), 0)::text ||'|'||
      coalesce((select count(*) from pg_catalog.regexp_matches((select body from hlp),
        '''status'', ''complete''','g')), 0)::text ||'|'||
      coalesce((select count(*) from pg_catalog.regexp_matches((select body from hlp),
        'blocked_by_busy|timezone_unknown|cross_model|''status'', ''partial''','g')), 0)::text),
    -- 2 timed call sites: the (D') slot-mismatch expansion and the source
    -- expansion. 1 all-day call site. Both reuse the shipped helpers.
    ('A11','helper','GATE: reuses the recurrence helpers -- no second engine','2|1',
      coalesce((select count(*) from pg_catalog.regexp_matches((select body from hlp),
        'rrule_timed_occurrence_starts_in_zones','g')), 0)::text ||'|'||
      coalesce((select count(*) from pg_catalog.regexp_matches((select body from hlp),
        'public\.rrule_allday_occurrence_starts','g')), 0)::text),
    ('A12','helper','GATE: never reads share_available -- no second source of truth','0',
      coalesce((select count(*) from pg_catalog.regexp_matches((select body from hlp),
        'share_available','g')), 0)::text),
    ('A13','helper','GATE: emits time fields only -- no metadata key is built','0',
      coalesce((select count(*) from pg_catalog.regexp_matches((select body from hlp),
        '''title''|''category''|''description''|''visibility''|''id''','g')), 0)::text),

    -- A14. THE EXECUTION COUPLING. A04 proves the helper is unreachable by
    --      PUBLIC, anon, authenticated and service_role; it does NOT prove the
    --      one role that MUST reach it can. The wrapper is SECURITY DEFINER, so
    --      it runs as its OWNER, and the helper is granted to nobody -- the
    --      wrapper gets in only because the owner is the helper's owner too.
    --      Nothing enforced that, and in isolated Phase B the two owners
    --      diverged: the wrapper ran as one role while the helper belonged to
    --      another, and every active request died with 42501. This postflight
    --      passed that state. A14 is the gate that would not have.
    --
    --      The owner is READ FROM THE CATALOG, never named here: the legitimate
    --      owner differs between the isolated database and production, so a
    --      hard-coded role would be wrong in one of them. has_function_privilege
    --      is asked rather than proacl parsed, so ownership and legitimate role
    --      membership both count -- the question is "would PostgreSQL let this
    --      identity execute it", not "does an ACL entry happen to say so".
    --
    --      FAIL-CLOSED: a missing wrapper or helper yields no row, the scalar
    --      subquery is NULL, and the coalesce turns that into a value that is
    --      not 'true'. Only a literal true passes -- the same discipline the
    --      0024 helper's own guards had to learn.
    ('A14','helper','GATE: the wrapper''s SECURITY DEFINER owner CAN execute the helper',
      'true',
      coalesce((
        select pg_catalog.has_function_privilege(w.proowner, h.oid, 'EXECUTE')::text
        from pg_catalog.pg_proc w, pg_catalog.pg_proc h
        where w.oid = to_regprocedure(
                'public.get_free_busy(text, timestamptz, timestamptz, date, date)')
          and h.oid = to_regprocedure(
                'timeweave_private.free_busy_available('
                'uuid, timestamptz, timestamptz, date, date, jsonb)')
      ), 'UNRESOLVED')),
    ('A14b','helper','CONTEXT: wrapper owner | helper owner -- equal is the usual case',
      null::text,
      coalesce(
        (select pg_catalog.pg_get_userbyid(proowner) from pg_catalog.pg_proc
          where oid = to_regprocedure(
            'public.get_free_busy(text, timestamptz, timestamptz, date, date)')),
        '(wrapper unresolved)')
      ||' | '||
      coalesce(
        (select pg_catalog.pg_get_userbyid(proowner) from pg_catalog.pg_proc
          where oid = to_regprocedure(
            'timeweave_private.free_busy_available('
            'uuid, timestamptz, timestamptz, date, date, jsonb)')),
        '(helper unresolved)')),

    -- W. the wrapper ----------------------------------------------------------
    ('W01','wrapper','GATE: public signature UNCHANGED',
      'p_token text, p_from timestamp with time zone, p_to timestamp with time zone, p_from_date date, p_to_date date',
      (select args from wrp)),
    ('W02','wrapper','GATE: still exactly one get_free_busy overload','1',
      (select count(*) from fn where nsp='public' and proname='get_free_busy')::text),
    ('W03','wrapper','GATE: result|language|volatility|security|search_path UNCHANGED',
      'jsonb|plpgsql|v|DEFINER|search_path=""',
      (select ret ||'|'|| lang ||'|'|| vol ||'|'||
              (case when secdef then 'DEFINER' else 'INVOKER' end) ||'|'|| coalesce(cfg,'-')
         from wrp)),
    ('W04','wrapper','GATE: anon EXECUTE | authenticated EXECUTE preserved','true|true',
      pg_catalog.has_function_privilege('anon',
        'public.get_free_busy(text, timestamptz, timestamptz, date, date)','EXECUTE')::text ||'|'||
      pg_catalog.has_function_privilege('authenticated',
        'public.get_free_busy(text, timestamptz, timestamptz, date, date)','EXECUTE')::text),
    ('W05','wrapper','CONTEXT: PUBLIC EXECUTE -- must equal the preflight W06 value',
      null::text,
      pg_catalog.has_function_privilege('public',
        'public.get_free_busy(text, timestamptz, timestamptz, date, date)','EXECUTE')::text),

    -- W06-W11. wrapper body structure ----------------------------------------
    ('W06','wrapper','GATE: the token lookup now selects share_available','1',
      coalesce((select count(*) from pg_catalog.regexp_matches((select body from wrp),
        's\.share_available','g')), 0)::text),
    ('W07','wrapper','GATE: not_requested is constructed exactly once','1',
      coalesce((select count(*) from pg_catalog.regexp_matches((select body from wrp),
        '''status'', ''not_requested''','g')), 0)::text),
    -- TWO call sites, not one, and that is the approved design: the
    -- share_available=false branch must reach the core WITHOUT the helper,
    -- while the enabled branch must reach both in ONE statement. They sit in
    -- the two arms of a single if/else (W08b), so exactly one executes per
    -- request. Counting the call pattern rather than the bare name keeps the
    -- prose mention in the step-5 comment out of the number.
    ('W08','wrapper','GATE: exactly two free_busy_core CALL SITES, one per branch','2',
      coalesce((select count(*) from pg_catalog.regexp_matches((select body from wrp),
        'timeweave_private\.free_busy_core\(','g')), 0)::text),
    ('W08b','wrapper','GATE: exactly one share_available branch guard selects between them','1',
      coalesce((select count(*) from pg_catalog.regexp_matches((select body from wrp),
        'if coalesce\(v_share, false\) then','g')), 0)::text),
    ('W09','wrapper','GATE: exactly one free_busy_available call site','1',
      coalesce((select count(*) from pg_catalog.regexp_matches((select body from wrp),
        'free_busy_available','g')), 0)::text),
    -- Three separate counts rather than one multi-line pattern: whitespace in
    -- prosrc must not decide whether this gate passes.
    ('W10','wrapper','GATE: the unavailable return still builds the exact 3-key object',
      '1|1|1',
      coalesce((select count(*) from pg_catalog.regexp_matches((select body from wrp),
        'jsonb_build_object\(''link_state'', ''unavailable''','g')), 0)::text ||'|'||
      coalesce((select count(*) from pg_catalog.regexp_matches((select body from wrp),
        '''complete'', true,','g')), 0)::text ||'|'||
      coalesce((select count(*) from pg_catalog.regexp_matches((select body from wrp),
        '''slots'', ''\[\]''::jsonb\)','g')), 0)::text),
    ('W11','wrapper','GATE: the active return merges link_state AND available','1|1',
      coalesce((select count(*) from pg_catalog.regexp_matches((select body from wrp),
        'jsonb_build_object\(''link_state'', ''active''\)','g')), 0)::text ||'|'||
      coalesce((select count(*) from pg_catalog.regexp_matches((select body from wrp),
        'jsonb_build_object\(''available'', v_avail\)','g')), 0)::text),
    ('W12','wrapper','GATE: LATERAL single-statement shape present','1',
      coalesce((select count(*) from pg_catalog.regexp_matches((select body from wrp),
        'lateral timeweave_private\.free_busy_available','g')), 0)::text),
    ('W13','wrapper','GATE: both 92-day range guards still in the body','1|1',
      coalesce((select count(*) from pg_catalog.regexp_matches((select body from wrp),
        'p_to > p_from \+ interval ''92 days''','g')), 0)::text ||'|'||
      coalesce((select count(*) from pg_catalog.regexp_matches((select body from wrp),
        'p_to_date - p_from_date > 92','g')), 0)::text),
    -- Presence, not counts: these identifiers appear in the pre-check, the
    -- charge and their comments, so a count would pin incidental prose.
    ('W14','wrapper','GATE: both rate buckets, the concurrency gate and both PT429 raises',
      'true|true|true|true',
      ((select body from wrp) like '%freebusy_owner_rate%')::text ||'|'||
      ((select body from wrp) like '%freebusy_link_rate%')::text ||'|'||
      ((select body from wrp) like '%pg_try_advisory_xact_lock%')::text ||'|'||
      ((select body from wrp) like '%TIMEWEAVE_RATE_FREEBUSY_BUSY%')::text),
    ('W15','wrapper','GATE: the charge still happens once per bucket, owner then link','1|1',
      coalesce((select count(*) from pg_catalog.regexp_matches((select body from wrp),
        'insert into timeweave_private\.freebusy_owner_rate','g')), 0)::text ||'|'||
      coalesce((select count(*) from pg_catalog.regexp_matches((select body from wrp),
        'insert into timeweave_private\.freebusy_link_rate','g')), 0)::text),

    -- B. informational baseline for a LATER migration to freeze against -------
    ('B01','baseline','CONTEXT: NEW wrapper body md5 -- record it', null::text,
      (select h from wrp)),
    ('B02','baseline','CONTEXT: NEW helper body md5 -- record it', null::text,
      (select h from hlp)),
    ('B03','baseline','CONTEXT: wrapper | helper body bytes', null::text,
      (select pg_catalog.length(body) from wrp)::text ||'|'||
      (select pg_catalog.length(body) from hlp)::text),

    -- Z. context --------------------------------------------------------------
    ('Z01','context','CONTEXT: server version', null::text,
      pg_catalog.current_setting('server_version')),
    ('Z02','context','CONTEXT: current database', null::text,
      pg_catalog.current_database()::text)

  ) as v(ord, phase, metric, expected, value)
)
select ord, phase, metric, expected, value, status
from res
order by ord;

-- P00: GO requires 0.
select count(*) filter (where status = 'FAIL') as p00_fail_count
from (
  select case when pg_catalog.md5(pg_catalog.replace(
                 (select prosrc from pg_catalog.pg_proc
                  where oid = to_regprocedure(
                    'timeweave_private.free_busy_core(uuid, timestamptz, timestamptz, date, date)')),
                 E'\r','')) = 'a9b4097e4b390cee1229709945475d2b'
              then 'ok' else 'FAIL' end as status
  union all
  select case when to_regprocedure(
                 'timeweave_private.free_busy_available(uuid, timestamptz, timestamptz, date, date, jsonb)'
               ) is not null then 'ok' else 'FAIL' end
  union all
  select case when (select count(*) from pg_catalog.pg_proc p
                    join pg_catalog.pg_namespace n on n.oid = p.pronamespace
                    where n.nspname='timeweave_private' and p.proname='free_busy_available') = 1
              then 'ok' else 'FAIL' end
) s;

rollback;
