-- ============================================================================
-- TimeWeave -- POSTFLIGHT for 0022_share_link_share_available.sql
--
-- READ-ONLY. Run by hand, once, IMMEDIATELY AFTER applying 0022. It opens
-- BEGIN TRANSACTION READ ONLY and ends with ROLLBACK. No DDL, no DML, no SET,
-- no temp table, no advisory lock, no RPC call.
--
-- WHAT IT ESTABLISHES. That 0022 added exactly one column, replaced exactly
-- two functions, added exactly one, and moved nothing else -- including that
-- the anonymous Free/Busy path is byte-identical to what it was before.
--
-- HOW TO READ IT.
--   AUTOMATIC GATE    K01-K07, C01-C10, L01-L05, S01-S13, B01-B05, R01-R02
--   MANUAL COMPARISON M01-M07. They have no expectation here either. Compare
--                     each against the value 0022_preflight.sql printed for
--                     the SAME ord, CHARACTER FOR CHARACTER. M01 is expected
--                     to DIFFER -- a column was added. M02-M07 must MATCH.
--                     That comparison is not automated anywhere.
--   CONTEXT ONLY      X01-X03.
--
--   GO requires P00 = 0 AND M02-M07 equal to stage 1.
--
-- WHY M01 IS ALLOWED TO MOVE AND THE OTHERS ARE NOT. M01 hashes the column
-- list, and 0022's whole purpose is to add one column to it. The other six
-- hash things 0022 must not have touched at all: the table's CHECK/key
-- constraints, its triggers, its policies, its ACL, the two commands that
-- were not re-created, and the anonymous entry point. If any of those moved,
-- something other than this migration ran.
--
-- WHAT THIS FILE DELIBERATELY DOES NOT CHECK. Behaviour. Nothing here calls
-- create_share_link, list_share_links or set_share_available, because calling
-- them writes rows or requires a session. The runtime behaviour of the setter
-- -- ownership, active-only, idempotency, what it must not change -- lives in
-- 0022_share_available_test.sql and is asserted there.
--
-- SQL ERRORS ARE A STOP. Treat an error exactly as a FAIL.
--
-- PRIVACY. Counts, catalog text, ACLs and hashes only.
-- ============================================================================

-- ============================================================================
-- (0) PRE-CHECK. Read this row FIRST. If any column is NULL, STOP.
-- ============================================================================
select to_regclass('public.share_links')                                          as share_links,
       to_regprocedure('public.create_share_link(text, boolean, timestamptz, boolean)')
                                                                                  as create_4arg,
       to_regprocedure('public.list_share_links()')                               as list_links,
       to_regprocedure('public.set_share_available(uuid, boolean)')               as setter,
       to_regprocedure('timeweave_private.free_busy_core(uuid, timestamptz, timestamptz, date, date)')
                                                                                  as free_busy_core;


-- ============================================================================
-- MAIN CHECK.
-- ============================================================================
begin transaction read only;

with
col as (
  select a.attname, a.attnum, a.attnotnull,
         pg_catalog.format_type(a.atttypid, a.atttypmod) as typ,
         pg_catalog.pg_get_expr(d.adbin, d.adrelid) as dflt
  from pg_catalog.pg_attribute a
  left join pg_catalog.pg_attrdef d on d.adrelid = a.attrelid and d.adnum = a.attnum
  where a.attrelid = 'public.share_links'::regclass and a.attnum > 0 and not a.attisdropped
),
con as (
  select c.conname, c.contype, c.convalidated,
         pg_catalog.pg_get_constraintdef(c.oid) as def
  from pg_catalog.pg_constraint c where c.conrelid = 'public.share_links'::regclass
),
fn as (
  select n.nspname as nsp, p.proname, p.oid, p.prosecdef, p.provolatile, p.proconfig,
         pg_catalog.pg_get_function_identity_arguments(p.oid) as args,
         pg_catalog.pg_get_function_result(p.oid)             as ret,
         pg_catalog.pg_get_function_arguments(p.oid)          as argdefs,
         replace(p.prosrc, E'\r','')      as body,
         md5(replace(p.prosrc, E'\r','')) as h
  from pg_catalog.pg_proc p
  join pg_catalog.pg_namespace n on n.oid = p.pronamespace
),
sa  as (select * from col where attname = 'share_available'),
cre as (select * from fn where oid = to_regprocedure('public.create_share_link(text, boolean, timestamptz, boolean)')),
lst as (select * from fn where oid = to_regprocedure('public.list_share_links()')),
-- Named sfn, not set: SET is a reserved word and cannot name a CTE.
sfn as (select * from fn where oid = to_regprocedure('public.set_share_available(uuid, boolean)')),
rev as (select * from fn where oid = to_regprocedure('public.revoke_share_link(uuid)')),
del as (select * from fn where oid = to_regprocedure('public.delete_share_link(uuid)')),
cor as (select * from fn where oid = to_regprocedure(
          'timeweave_private.free_busy_core(uuid, timestamptz, timestamptz, date, date)')),
gfb as (select * from fn where oid = to_regprocedure(
          'public.get_free_busy(text, timestamptz, timestamptz, date, date)')),
res as (
  select v.ord, v.phase, v.metric, v.expected, v.value,
         case when v.expected is null then 'context'
              when v.value is not distinct from v.expected then 'ok'
              else 'FAIL'
         end as status
  from (values

    -- K. the column, exactly as 0022 declares it ------------------------------
    ('K01','column','GATE: share_available exists exactly once','1',
      (select count(*) from sa)::text),
    ('K02','column','GATE: type is boolean','boolean',(select typ from sa)),
    ('K03','column','GATE: NOT NULL','true',(select attnotnull::text from sa)),
    ('K04','column','GATE: DEFAULT false','false',(select dflt from sa)),
    ('K05','column','it is the last column (nothing was reordered)','true',
      (select (attnum = (select max(attnum) from col))::text from sa)),
    ('K06','column','column count is now 9','9',(select count(*) from col)::text),
    ('K07','column','the column comment is present','true',
      (select (pg_catalog.col_description('public.share_links'::regclass, attnum) is not null)::text
         from sa)),

    -- R. every existing row reads as false ------------------------------------
    ('R01','rows','GATE: rows with share_available IS NULL','0',
      (select count(*) from public.share_links where share_available is null)::text),
    ('R02','rows','GATE: rows with share_available = true','0',
      (select count(*) from public.share_links where share_available)::text),

    -- C. create_share_link is now the four-parameter function ------------------
    ('C01','create','GATE: exactly one create_share_link overload','1',
      (select count(*) from fn where nsp='public' and proname='create_share_link')::text),
    ('C02','create','GATE: the old 3-parameter signature is GONE','0',
      (select count(*) from fn where oid = to_regprocedure(
        'public.create_share_link(text, boolean, timestamptz)'))::text),
    ('C03','create','GATE: identity arguments',
      'p_label text, p_include_private boolean, p_expires_at timestamp with time zone, p_share_available boolean',
      (select args from cre)),
    ('C04','create','GATE: p_share_available DEFAULT false','1',
      (select count(*) from regexp_matches((select argdefs from cre),
        'p_share_available boolean DEFAULT false','g'))::text),
    ('C05','create','GATE: the other three defaults are unchanged','1|1|1',
      (select count(*) from regexp_matches((select argdefs from cre),'p_label text DEFAULT NULL','g'))::text ||'|'||
      (select count(*) from regexp_matches((select argdefs from cre),'p_include_private boolean DEFAULT true','g'))::text ||'|'||
      (select count(*) from regexp_matches((select argdefs from cre),'p_expires_at timestamp with time zone DEFAULT NULL','g'))::text),
    ('C06','create','GATE: the result type includes share_available','1',
      (select count(*) from regexp_matches((select ret from cre),'share_available boolean','g'))::text),
    ('C07','create','GATE: the result type still returns token exactly once','1',
      (select count(*) from regexp_matches((select ret from cre),'token text','g'))::text),
    ('C08','create','GATE: token_hash is NOT in the result type','0',
      (select count(*) from regexp_matches((select ret from cre),'token_hash','g'))::text),
    ('C09','create','GATE: SECURITY DEFINER and empty search_path','true|search_path=""',
      (select prosecdef::text || '|' || array_to_string(proconfig,',') from cre)),
    ('C10','create','GATE: PUBLIC no | authenticated yes | anon no','false|true|false',
      pg_catalog.has_function_privilege('public','public.create_share_link(text, boolean, timestamptz, boolean)','EXECUTE')::text ||'|'||
      pg_catalog.has_function_privilege('authenticated','public.create_share_link(text, boolean, timestamptz, boolean)','EXECUTE')::text ||'|'||
      pg_catalog.has_function_privilege('anon','public.create_share_link(text, boolean, timestamptz, boolean)','EXECUTE')::text),

    -- L. list_share_links carries the setting, and still no token --------------
    ('L01','list','GATE: the result type includes share_available','1',
      (select count(*) from regexp_matches((select ret from lst),'share_available boolean','g'))::text),
    ('L02','list','GATE: it returns seven columns','7',
      (select count(*) from regexp_matches((select ret from lst),'\w+ (uuid|text|boolean|timestamp with time zone)','g'))::text),
    ('L03','list','GATE: neither token nor token_hash appears','0',
      (select count(*) from regexp_matches((select ret from lst),'token','g'))::text),
    ('L04','list','GATE: still SECURITY DEFINER and STABLE','true|s',
      (select prosecdef::text || '|' || provolatile::text from lst)),
    ('L05','list','GATE: PUBLIC no | authenticated yes | anon no','false|true|false',
      pg_catalog.has_function_privilege('public','public.list_share_links()','EXECUTE')::text ||'|'||
      pg_catalog.has_function_privilege('authenticated','public.list_share_links()','EXECUTE')::text ||'|'||
      pg_catalog.has_function_privilege('anon','public.list_share_links()','EXECUTE')::text),

    -- S. the setter: shape, posture, and the predicate it is required to carry -
    ('S01','setter','GATE: set_share_available(uuid, boolean) exists','1',
      (select count(*) from sfn)::text),
    ('S02','setter','GATE: exactly one overload of that name','1',
      (select count(*) from fn where nsp='public' and proname='set_share_available')::text),
    ('S03','setter','GATE: returns boolean','boolean',(select ret from sfn)),
    ('S04','setter','GATE: SECURITY DEFINER and empty search_path','true|search_path=""',
      (select prosecdef::text || '|' || array_to_string(proconfig,',') from sfn)),
    ('S05','setter','GATE: PUBLIC no | authenticated yes | anon no','false|true|false',
      pg_catalog.has_function_privilege('public','public.set_share_available(uuid, boolean)','EXECUTE')::text ||'|'||
      pg_catalog.has_function_privilege('authenticated','public.set_share_available(uuid, boolean)','EXECUTE')::text ||'|'||
      pg_catalog.has_function_privilege('anon','public.set_share_available(uuid, boolean)','EXECUTE')::text),
    -- S06-S09 pin the predicate structurally. A future edit that drops one of
    -- these lines changes what the function is allowed to reach, and that is
    -- exactly the kind of change that must not pass silently.
    ('S06','setter','GATE: the body carries the owner predicate','1',
      (select count(*) from regexp_matches((select body from sfn),
        'owner_id = auth\.uid\(\)','g'))::text),
    ('S07','setter','GATE: the body carries the not-revoked predicate','1',
      (select count(*) from regexp_matches((select body from sfn),
        'revoked_at is null','g'))::text),
    ('S08','setter','GATE: the body carries the not-expired predicate','1',
      (select count(*) from regexp_matches((select body from sfn),
        'expires_at is null or expires_at > now\(\)','g'))::text),
    ('S09','setter','GATE: exactly one UPDATE, and it sets only share_available','1|1|0',
      (select count(*) from regexp_matches((select body from sfn),'update public\.share_links','g'))::text ||'|'||
      (select count(*) from regexp_matches((select body from sfn),'set share_available = p_enabled','g'))::text ||'|'||
      (select count(*) from regexp_matches((select body from sfn),
        'set +(id|owner_id|token_hash|label|include_private|expires_at|revoked_at|created_at) *=','g'))::text),
    -- The columns the setter must not be able to reach at all. revoked_at is
    -- the one that matters most: a settings change must never revive a link.
    ('S10','setter','GATE: revoked_at appears exactly once -- only in the predicate','1',
      (select count(*) from regexp_matches((select body from sfn),'revoked_at','g'))::text),

    -- S11-S13 CLOSE S09's ANCHORING GAP. S09's third component looks for
    -- `set <column> =`, so it only sees a forbidden column that is the FIRST
    -- target of the SET list; a second one, on its own line after a comma,
    -- would slip past it. These three isolate the SET CLAUSE ITSELF -- the text
    -- between the `set` keyword and the `where` that follows it -- and judge
    -- only that region.
    --
    -- Isolating the region is what makes a negative check possible at all.
    -- owner_id, revoked_at and expires_at all appear LEGITIMATELY in the WHERE
    -- clause, so "the body does not contain revoked_at" would be wrong; "the
    -- SET clause does not assign revoked_at" is the claim that holds. The WHERE
    -- clause is excluded by construction, not by a pattern that has to guess.
    --
    -- If the WHERE clause were ever deleted, the substring finds no match, the
    -- coalesce yields '' / the sentinel, and all three FAIL rather than passing
    -- vacuously.
    ('S11','setter','GATE: the SET clause holds exactly one assignment','1',
      (select count(*) from regexp_matches(
         coalesce(substring((select body from sfn)
                            from '\mset\M\s+(.*?)\s+\mwhere\M\s'), ''),
         '=','g'))::text),
    ('S12','setter','GATE: and that assignment is exactly share_available = p_enabled',
      'share_available = p_enabled',
      coalesce(btrim(substring((select body from sfn)
                               from '\mset\M\s+(.*?)\s+\mwhere\M\s')),
               '(no SET clause found)')),
    ('S13','setter','GATE: no forbidden column is assigned ANYWHERE in the SET clause','0',
      (select count(*) from regexp_matches(
         coalesce(substring((select body from sfn)
                            from '\mset\M\s+(.*?)\s+\mwhere\M\s'), ''),
         '\m(id|owner_id|token_hash|label|include_private|expires_at|revoked_at|created_at)\M\s*=',
         'g'))::text),

    -- B. the anonymous path 0022 must not have touched -------------------------
    --
    -- B01's expected hash is derived from repository source, NOT copied from
    -- 0021_postflight.sql -- that file's G01 is context-only and prints the
    -- value rather than containing it. The full re-derivation recipe (source
    -- file, dollar-quote boundary, \r normalization, byte count) is written out
    -- above E01 in 0022_preflight.sql; this row uses the same literal so that
    -- stage 1 and stage 3 pin the same body. Do NOT edit the expectation to
    -- agree with the database: refusing a changed core is the whole point.
    ('B01','boundary','GATE: free_busy_core body md5 is still the canonical 0021 body',
      'a9b4097e4b390cee1229709945475d2b',(select h from cor)),
    ('B02','boundary','GATE: core body does not mention share_available','0',
      (select count(*) from regexp_matches((select body from cor),'share_available','g'))::text),
    ('B03','boundary','GATE: exactly one get_free_busy overload','1',
      (select count(*) from fn where nsp='public' and proname='get_free_busy')::text),
    ('B04','boundary','GATE: wrapper body does not mention share_available or link_state','0',
      (select count(*) from regexp_matches((select body from gfb),
        '(share_available|link_state)','g'))::text),
    ('B05','boundary','GATE: anon still has get_free_busy and nothing on share_links','true|false|false|false',
      pg_catalog.has_function_privilege('anon','public.get_free_busy(text, timestamptz, timestamptz, date, date)','EXECUTE')::text ||'|'||
      pg_catalog.has_table_privilege('anon','public.share_links','SELECT')::text ||'|'||
      pg_catalog.has_table_privilege('anon','public.share_links','UPDATE')::text ||'|'||
      pg_catalog.has_table_privilege('authenticated','public.share_links','UPDATE')::text),

    -- M. MANUAL COMPARISON against stage 1. Same ords, same expressions. -------
    ('M01','baseline','MANUAL: md5 over share_links columns -- MUST DIFFER from stage 1', null::text,
      (select md5(string_agg(attname||'|'||typ||'|'||attnotnull::text||'|'||coalesce(dflt,'-'),
                    ';' order by attnum)) from col)),
    ('M02','baseline','MANUAL: md5 over share_links CHECK/PK/UNIQUE/FK -- MUST equal stage 1', null::text,
      (select md5(string_agg(conname||'|'||contype::text||'|'||def, ';' order by conname collate "C"))
         from con where contype in ('c','p','u','f'))),
    ('M03','baseline','MANUAL: md5 over share_links triggers -- MUST equal stage 1', null::text,
      (select coalesce(md5(string_agg(pg_catalog.pg_get_triggerdef(t.oid), ';' order by t.tgname collate "C")),'(none)')
         from pg_catalog.pg_trigger t
        where t.tgrelid='public.share_links'::regclass and not t.tgisinternal)),
    ('M04','baseline','MANUAL: md5 over share_links RLS policies -- MUST equal stage 1', null::text,
      (select md5(string_agg(p.polname||'|'||p.polcmd::text||'|'
                    ||coalesce(pg_catalog.pg_get_expr(p.polqual,p.polrelid),'-')||'|'
                    ||coalesce(pg_catalog.pg_get_expr(p.polwithcheck,p.polrelid),'-'),
                    ';' order by p.polname collate "C"))
         from pg_catalog.pg_policy p where p.polrelid='public.share_links'::regclass)),
    ('M05','baseline','MANUAL: share_links table ACL -- MUST equal stage 1', null::text,
      (select coalesce(array_to_string(relacl,' '),'(default)') from pg_catalog.pg_class
        where oid='public.share_links'::regclass)),
    ('M06','baseline','MANUAL: md5 over revoke+delete bodies -- MUST equal stage 1', null::text,
      (select md5((select h from rev) || '|' || (select h from del)))),
    ('M07','baseline','MANUAL: get_free_busy body md5 -- MUST equal stage 1', null::text,
      (select h from gfb)),

    -- X. CONTEXT ONLY. -----------------------------------------------------------
    ('X01','context','CONTEXT: total share_links rows', null::text,
      (select count(*)::text from public.share_links)),
    ('X02','context','CONTEXT: active share_links rows', null::text,
      (select count(*)::text from public.share_links
        where revoked_at is null and (expires_at is null or expires_at > now()))),
    ('X03','context','CONTEXT: exact column DEFAULT as PostgreSQL renders it', null::text,
      (select dflt from sa))

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
