-- ============================================================================
-- TimeWeave -- PREFLIGHT for 0022_share_link_share_available.sql
--
-- READ-ONLY. Run by hand, once, IMMEDIATELY BEFORE applying 0022. It opens
-- BEGIN TRANSACTION READ ONLY and ends with ROLLBACK. No DDL, no DML, no SET,
-- no temp table, no advisory lock, no RPC call.
--
-- WHAT IT ESTABLISHES. That the database is in the state 0022 is written
-- against: the column is absent, create_share_link still has exactly the three
-- 0005 parameters, list_share_links still returns the six 0005 columns,
-- set_share_available does not exist, and nothing 0022 must not touch has
-- drifted.
--
-- HOW TO READ IT.
--   AUTOMATIC GATE    A01-A04, B01-B08, C01-C05, D01-D04, E01-E04, G01
--   MANUAL: RECORD THIS  M01-M07. They have no expectation. Write them down;
--                     0022_postflight.sql compares its own M01-M07 against
--                     them CHARACTER FOR CHARACTER and that comparison is not
--                     automated anywhere.
--   CONTEXT ONLY      X01-X03. Recorded, never judged.
--
--   GO requires P00 = 0 AND M01-M07 recorded by hand.
--
-- SQL ERRORS ARE A STOP. Treat an error exactly as a FAIL. A missing table or
-- function fails at PARSE time, which is what the (0) pre-check below is for.
--
-- PRIVACY. Counts, catalog text, ACLs and hashes only. No label, token,
-- token_hash, owner id or event content is selected anywhere.
--
-- THIS FILE APPLIES NOTHING. Applying 0022 is a separate approval.
-- ============================================================================

-- ============================================================================
-- (0) PRE-CHECK. Read this row FIRST. If any column is NULL, STOP: the object
--     it names is missing and the main check below would fail at parse time.
-- ============================================================================
select to_regclass('public.share_links')                                  as share_links,
       to_regprocedure('public.create_share_link(text, boolean, timestamptz)')
                                                                          as create_3arg,
       to_regprocedure('public.list_share_links()')                       as list_links,
       to_regprocedure('public.revoke_share_link(uuid)')                  as revoke_link,
       to_regprocedure('public.delete_share_link(uuid)')                  as delete_link,
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
cre as (select * from fn where oid = to_regprocedure('public.create_share_link(text, boolean, timestamptz)')),
lst as (select * from fn where oid = to_regprocedure('public.list_share_links()')),
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

    -- A. the column 0022 adds is NOT there yet -------------------------------
    ('A01','column','GATE: share_available does not exist yet','0',
      (select count(*) from col where attname = 'share_available')::text),
    ('A02','column','column count is 8 (the 0004 shape)','8',
      (select count(*) from col)::text),
    ('A03','column','the 0004 columns, by name','id|owner_id|token_hash|label|include_private|expires_at|revoked_at|created_at',
      (select string_agg(attname, '|' order by attnum) from col)),
    ('A04','column','include_private is still NOT NULL DEFAULT true','true|true',
      (select attnotnull::text || '|' || (dflt = 'true')::text from col where attname='include_private')),

    -- B. create_share_link is still the 0005 three-parameter function ---------
    ('B01','create','GATE: exactly one create_share_link overload','1',
      (select count(*) from fn where nsp='public' and proname='create_share_link')::text),
    ('B02','create','GATE: its identity arguments',
      'p_label text, p_include_private boolean, p_expires_at timestamp with time zone',
      (select args from cre)),
    ('B03','create','GATE: the 4-parameter signature does NOT exist yet','0',
      (select count(*) from fn where oid = to_regprocedure(
        'public.create_share_link(text, boolean, timestamptz, boolean)'))::text),
    ('B04','create','SECURITY DEFINER','true',(select prosecdef::text from cre)),
    ('B05','create','search_path is empty','search_path=""',
      (select array_to_string(proconfig,',') from cre)),
    ('B06','create','PUBLIC has no EXECUTE','false',
      pg_catalog.has_function_privilege('public','public.create_share_link(text, boolean, timestamptz)','EXECUTE')::text),
    ('B07','create','authenticated HAS EXECUTE','true',
      pg_catalog.has_function_privilege('authenticated','public.create_share_link(text, boolean, timestamptz)','EXECUTE')::text),
    ('B08','create','anon has NO EXECUTE','false',
      pg_catalog.has_function_privilege('anon','public.create_share_link(text, boolean, timestamptz)','EXECUTE')::text),

    -- C. list_share_links is still the 0005 six-column function ---------------
    ('C01','list','GATE: it returns the six 0005 columns and no more','6',
      (select count(*) from regexp_matches((select ret from lst),'\w+ (uuid|text|boolean|timestamp with time zone)','g'))::text),
    ('C02','list','GATE: share_available is not in the result type','0',
      (select count(*) from regexp_matches((select ret from lst),'share_available','g'))::text),
    ('C03','list','token and token_hash are absent from the result type','0',
      (select count(*) from regexp_matches((select ret from lst),'token','g'))::text),
    ('C04','list','SECURITY DEFINER and STABLE','true|s',
      (select prosecdef::text || '|' || provolatile::text from lst)),
    ('C05','list','PUBLIC no EXECUTE | authenticated yes | anon no','false|true|false',
      pg_catalog.has_function_privilege('public','public.list_share_links()','EXECUTE')::text || '|' ||
      pg_catalog.has_function_privilege('authenticated','public.list_share_links()','EXECUTE')::text || '|' ||
      pg_catalog.has_function_privilege('anon','public.list_share_links()','EXECUTE')::text),

    -- D. the setter 0022 adds is NOT there yet -------------------------------
    ('D01','setter','GATE: set_share_available(uuid, boolean) does not exist','0',
      (select count(*) from fn where oid = to_regprocedure('public.set_share_available(uuid, boolean)'))::text),
    ('D02','setter','GATE: no function of that name at any signature','0',
      (select count(*) from fn where nsp='public' and proname='set_share_available')::text),
    ('D03','setter','GATE: no generic update_share_link exists','0',
      (select count(*) from fn where nsp='public' and proname='update_share_link')::text),
    ('D04','setter','GATE: no settings-patch function exists','0',
      (select count(*) from fn where nsp='public' and proname like '%share_link%settings%')::text),

    -- E. the boundary 0022 must not cross -------------------------------------
    --
    -- WHERE E01's EXPECTED HASH COMES FROM, AND HOW TO RE-DERIVE IT.
    -- It is NOT copied from 0021_postflight.sql -- that file's G01 is a
    -- CONTEXT-ONLY row (null::text expected) which PRINTS this value at run
    -- time and does not contain it. The literal is derived from repository
    -- source, and anyone can reproduce it without a database:
    --
    --   source      supabase/migrations/0021_freebusy_busy_only.sql
    --   boundary    the ONLY dollar-quoted body in that file. `as $fn$` is the
    --               whole of line 215; `$fn$;` is the whole of line 764.
    --   prosrc      exactly what lies BETWEEN the two delimiters: the newline
    --               that ends line 215, then lines 216-763 each ending in a
    --               newline. The CREATE FUNCTION header is NOT part of it.
    --   normalize   strip every \r, which is what `fn.body` above does. The
    --               file holds no \r today, so the strip is a no-op on it and
    --               the hash is line-ending independent either way.
    --   size        24263 bytes, 549 newlines
    --   md5         a9b4097e4b390cee1229709945475d2b
    --
    -- If this row ever FAILS, re-derive it from 0021 before touching anything.
    -- A mismatch means free_busy_core is not the 0021 body -- which is the one
    -- thing this gate exists to refuse. Do NOT edit the expectation to agree
    -- with the database.
    ('E01','boundary','GATE: free_busy_core body md5 == the canonical 0021 body',
      'a9b4097e4b390cee1229709945475d2b',(select h from cor)),
    ('E02','boundary','GATE: core body does not mention share_available','0',
      (select count(*) from regexp_matches((select body from cor),'share_available','g'))::text),
    ('E03','boundary','GATE: exactly one get_free_busy overload','1',
      (select count(*) from fn where nsp='public' and proname='get_free_busy')::text),
    ('E04','boundary','anon still has EXECUTE on get_free_busy only','true|false|false',
      pg_catalog.has_function_privilege('anon','public.get_free_busy(text, timestamptz, timestamptz, date, date)','EXECUTE')::text || '|' ||
      pg_catalog.has_table_privilege('anon','public.share_links','SELECT')::text || '|' ||
      pg_catalog.has_table_privilege('anon','public.share_links','UPDATE')::text),

    -- G. RLS is still on, still owner-only -------------------------------------
    ('G01','rls','row level security enabled on share_links','true',
      (select relrowsecurity::text from pg_catalog.pg_class where oid='public.share_links'::regclass)),

    -- M. MANUAL: RECORD THESE. Stage 2 compares its own M01-M07 against them. --
    ('M01','baseline','MANUAL: RECORD THIS -- md5 over the 8 share_links columns', null::text,
      (select md5(string_agg(attname||'|'||typ||'|'||attnotnull::text||'|'||coalesce(dflt,'-'),
                    ';' order by attnum)) from col)),
    -- contype 'n' is EXCLUDED on purpose. PostgreSQL 17 records NOT NULL in
    -- pg_constraint and earlier versions do not, so including it would make
    -- this hash mean different things on different servers -- and 0022 adds a
    -- NOT NULL column, which would move it for that reason alone rather than
    -- because a CHECK, key or FK changed. Those four are what this pins.
    ('M02','baseline','MANUAL: RECORD THIS -- md5 over share_links CHECK/PK/UNIQUE/FK', null::text,
      (select md5(string_agg(conname||'|'||contype::text||'|'||def, ';' order by conname collate "C"))
         from con where contype in ('c','p','u','f'))),
    ('M03','baseline','MANUAL: RECORD THIS -- md5 over share_links triggers', null::text,
      (select coalesce(md5(string_agg(pg_catalog.pg_get_triggerdef(t.oid), ';' order by t.tgname collate "C")),'(none)')
         from pg_catalog.pg_trigger t
        where t.tgrelid='public.share_links'::regclass and not t.tgisinternal)),
    ('M04','baseline','MANUAL: RECORD THIS -- md5 over share_links RLS policies', null::text,
      (select md5(string_agg(p.polname||'|'||p.polcmd::text||'|'
                    ||coalesce(pg_catalog.pg_get_expr(p.polqual,p.polrelid),'-')||'|'
                    ||coalesce(pg_catalog.pg_get_expr(p.polwithcheck,p.polrelid),'-'),
                    ';' order by p.polname collate "C"))
         from pg_catalog.pg_policy p where p.polrelid='public.share_links'::regclass)),
    ('M05','baseline','MANUAL: RECORD THIS -- share_links table ACL', null::text,
      (select coalesce(array_to_string(relacl,' '),'(default)') from pg_catalog.pg_class
        where oid='public.share_links'::regclass)),
    ('M06','baseline','MANUAL: RECORD THIS -- md5 over revoke+delete bodies', null::text,
      (select md5((select h from rev) || '|' || (select h from del)))),
    ('M07','baseline','MANUAL: RECORD THIS -- get_free_busy body md5', null::text,
      (select h from gfb)),

    -- X. CONTEXT ONLY. Recorded, not judged. -----------------------------------
    ('X01','context','CONTEXT: total share_links rows', null::text,
      (select count(*)::text from public.share_links)),
    ('X02','context','CONTEXT: active share_links rows', null::text,
      (select count(*)::text from public.share_links
        where revoked_at is null and (expires_at is null or expires_at > now()))),
    ('X03','context','CONTEXT: distinct include_private values present', null::text,
      (select coalesce(array_agg(distinct include_private order by include_private)::text,'{}')
         from public.share_links))

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
