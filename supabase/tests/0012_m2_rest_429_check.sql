-- ============================================================================
-- TimeWeave -- 0012 postflight M2: a real HTTP 429 over the real REST path,
-- confined to ONE dedicated test account.
--
-- RESULT: NOT YET PERFORMED. Record the outcome here when it has been.
--
-- ============================================================================
-- WHAT THIS CHECKS
--
--   One authenticated PostgREST INSERT by the test account is refused by the
--   0012 rate trigger, and the client receives
--     HTTP 429, code PT429, details TIMEWEAVE_RATE_EVENTS,
--     hint retry_after_seconds=N
--   -- and the refused write leaves neither an event nor a charge behind.
--
--   The trigger shape was already measured through REST on a probe
--   (0012_rate_concurrency_probe.sql) and the refusal is pinned from SQL by
--   0012_rate_limit_test.sql. What neither shows is the SHIPPED trigger on
--   public.events answering a real client. That is the only thing this is for.
--
-- ============================================================================
-- HOW: PRE-SEED ONE ACCOUNT'S `tat`
--
--   The trigger, for a 1-row write at statement time t_r (T = 1 s, tau = 120 s):
--
--     tat' = greatest(tat0, t_r) + T      refuse  <=>  tat' - t_r > tau
--
--   If tat0 < t_r then tat' - t_r = T, which never exceeds tau. So:
--
--     refused  <=>  tat0 - t_r > tau - T = 119 s
--
--   The seed sets tat0 = t_s + (tau - T) + W, with t_s its own
--   statement_timestamp and W = 300 s. With delta = t_r - t_s:
--
--     refused                 <=>  delta < W            (a 300 s window)
--     hint                     =   ceil(W - delta)      (1 .. 300)
--     message overshoot        =   W - delta            (unrounded)
--     1 row writable again at      t_s + W              (self-recovery)
--     full burst again at          t_s + (tau - T) + W  = t_s + 419 s
--
--   t_s and t_r are both the DATABASE's statement_timestamp, so client clock
--   skew cannot move the decision. t_s is taken a few ms before the seed
--   commits, which makes the real window slightly SHORTER than W: fail-safe.
--
--   A refused statement rolls back its own upsert (measured), so tat stays
--   exactly at the seeded value however many refusals happen. The readout
--   asserts that directly: charged_rows = 0 and tat - last_charge_at = 419 s.
--
--   W = 300 appears in FOUR places and they must agree: BLOCK 3 (c_window),
--   BLOCK 4 (seeded_span_s = 419), BLOCK 5 ($W), BLOCK 6 (check 3 = 419).
--
-- ============================================================================
-- SAFETY MODEL
--
--   * NOTHING GLOBAL. events_rate_interval() / events_rate_burst() are never
--     redefined. BLOCK 1, BLOCK 3 and BLOCK 6 each assert they are 1 s / 120.
--
--   * NO STATE ROW BEFORE, NO STATE ROW AFTER. The test account must have no
--     row in timeweave_private.event_write_rate when M2 starts. That is a
--     PRECONDITION, checked in BLOCK 1 and again inside BLOCK 3's write -- it is
--     never satisfied by overwriting or deleting a row that was already there.
--     BLOCK 3 is a plain INSERT with NO `ON CONFLICT`: if a row appears between
--     its check and its insert, the primary key refuses it (23505) and nothing
--     is written. BLOCK 7 then deletes the one row BLOCK 3 created, so the
--     account ends in exactly the state it started in.
--
--     Since 0012 has no pruning, an absent row also means this account has not
--     made one charged write since 0012 was applied -- evidence that it is not
--     in use.
--
--   * STOPPING HALF WAY IS SAFE. After BLOCK 3, the only effect anywhere is
--     that the test account's writes are refused for at most 300 s, after which
--     it recovers arithmetically. The leftover row then makes BLOCK 1 refuse the
--     next attempt until BLOCK 7 has been run, which is the intended behaviour.
--
--   * IDENTITY IS CHECKED TWICE BEFORE ANY WRITE. The account by uuid AND email
--     in SQL (BLOCK 1, re-checked in BLOCK 3); the access token by
--     /auth/v1/user AND its own `sub` claim in PowerShell (BLOCK 2). A token for
--     a different account would create a real event for a real user, so BLOCK 2
--     is a hard gate, and BLOCK 6 / BLOCK 7 look for probe events under ANY
--     owner in case it was bypassed.
--
--   * THE STATE TABLE IS WRITTEN FROM OUTSIDE THE TRIGGER, which 0012's comment
--     forbids in general. That rule protects the lock order (advisory locks
--     first, state row last). BLOCK 3 and BLOCK 7b each run as their own short
--     statement, take no advisory lock, touch nothing else, and never wait for
--     anything while holding a lock -- so no cycle can form.
--     0012_rate_limit_test.sql already deletes a state row on the same argument.
--     Run them as separate executions and do not add statements to them.
--
--   * THE ACCESS TOKEN IS NEVER WRITTEN DOWN. The REST legs run in the
--     operator's local PowerShell. The password is read with -AsSecureString,
--     the token is kept only as a SecureString and sent with
--     -Authentication Bearer, nothing secret is typed on a command line (so
--     nothing secret reaches PSReadLine history), and BLOCK 8 signs the session
--     out and clears the variables. Do not run this under Start-Transcript.
--
--   * WHAT DOES CHANGE PERMANENTLY: signing in updates the test account's
--     auth.users.last_sign_in_at and creates a session that BLOCK 8 revokes.
--     No TimeWeave table differs afterwards.
--
-- ============================================================================
-- PRE-REGISTERED EXPECTATIONS
--
--   BLOCK 1  every non-context check 'ok'
--   BLOCK 2  R0 ok: user id = sub = test uuid, email matches, role
--            authenticated, token valid for >= 900 s
--   BLOCK 4  charged_rows 0, seeded_span_s 419, refusal_window_left_s >= 60
--   BLOCK 5  P1  HTTP 429
--            P2  code    = PT429
--            P3  details = TIMEWEAVE_RATE_EVENTS
--            P4a hint    = retry_after_seconds=N with 1 <= N <= 300
--            P4b |N - ceil(300 - (sent_at - seeded_at))| <= 3
--                (depends on the local clock; a lone P4b failure means check
--                 `w32tm /query /status`, not that the limiter is wrong)
--            P5  message names the test owner's uuid
--            P6  no Retry-After header (measured: none survives the RAISE)
--   BLOCK 6  every non-context check 'ok'
--   BLOCK 7  every non-context check 'ok'
--
-- HOW TO READ A DISAGREEMENT AT BLOCK 5
--   201         the write was ACCEPTED: window expired, or the seed is not in
--               place. An event now exists -> BLOCK 7, then start over.
--   400         payload, content CHECK or 0011 quota. Nothing written -> BLOCK 7.
--   401 / 403   token problem. Nothing written -> BLOCK 7.
--   429 but code or details differ
--               NOT this limiter (e.g. a gateway limit). Not a pass -> BLOCK 7.
--   BLOCK 6 check 2 or 3 FAIL after a 429
--               a REFUSED write left a charge behind: 0012's "refused work is
--               not charged" property is broken on the real path. Stop and
--               report before cleaning up, so the row can be read.
--
-- ORDER, AND WHAT TO DO IF YOU STOP
--   1 S0 (SQL, read-only)    -> 2 R0 (PowerShell)  -> 3 S1 seed (SQL, WRITES)
--   -> 4 send gate (SQL, read-only) -> 5 R1 (PowerShell, one request)
--   -> 6 readout (SQL, read-only)   -> 7 cleanup (SQL, WRITES) -> 8 sign out
--
--   Stopped before BLOCK 3 succeeded : nothing to clean except BLOCK 8.
--   Stopped at any point after it    : run BLOCK 7, then BLOCK 8.
--
-- Running this whole file executes BLOCK 1 only. Every other block is inside a
-- comment and must be copied out and run on its own.
-- ============================================================================


-- ############################################################################
-- BLOCK 1 of 8 -- S0 PRECONDITIONS. READ-ONLY (ends in ROLLBACK).
-- Proceed only if every non-context row is 'ok'.
-- ############################################################################

begin;

with
c as (
  select '5e86935f-7661-4741-868f-0f51c4cf1727'::uuid as owner,
         'timeweave-sql-test@example.com'::text      as email,
         'zz m2 rate probe'::text                    as probe_title,
         50                                          as max_events
),
-- to_jsonb(u) rather than named columns: auth.users is Supabase's table and its
-- column set changes between platform versions. A column that does not exist
-- reads as NULL here instead of failing the whole preflight.
acct as (
  select to_jsonb(u) as j
  from auth.users u
  where u.id = (select owner from c)
),
same_email as (
  select u.id
  from auth.users u
  where lower(u.email) = lower((select email from c))
),
ev as (
  select count(*)                                                        as n,
         count(*) filter (where e.title = (select probe_title from c))    as probe,
         count(*) filter (where e.updated_at > pg_catalog.clock_timestamp()
                                               - interval '15 minutes')   as recent,
         max(e.updated_at)                                               as last_write
  from public.events e
  where e.owner_id = (select owner from c)
),
st as (
  select count(*) as n
  from timeweave_private.event_write_rate w
  where w.owner_id = (select owner from c)
),
trg as (
  select count(*) filter (where t.tgname like 'events_rate_%'
                            and t.tgenabled::text = 'O')  as rate_enabled,
         count(*)                                         as all_triggers
  from pg_trigger t
  where t.tgrelid = 'public.events'::regclass and not t.tgisinternal
)
select ord, name, got, want,
       case when want = '(context)' then 'context'
            when got is not distinct from want then 'ok'
            else 'FAIL' end as verdict
from (
  -- 1x  is it the account we think it is ------------------------------------
  select 10 as ord, 'an account with uuid 5e86935f-... exists' as name,
         (select count(*)::text from acct) as got, '1' as want
  union all
  select 11, 'its email is timeweave-sql-test@example.com',
         (select (lower(j ->> 'email') = lower((select email from c)))::text from acct), 'true'
  union all
  select 12, 'no OTHER account carries that email',
         (select (count(*) = 1 and bool_and(id = (select owner from c)))::text from same_email), 'true'
  -- 2x  can it sign in (BLOCK 2 uses the password grant) --------------------
  union all
  select 20, 'not soft-deleted',
         (select coalesce(j ->> 'deleted_at', '<null>') from acct), '<null>'
  union all
  select 21, 'not banned now',
         (select ((j ->> 'banned_until') is null
                  or (j ->> 'banned_until')::timestamptz <= pg_catalog.clock_timestamp())::text
            from acct), 'true'
  union all
  select 22, 'not an anonymous account',
         (select coalesce(j ->> 'is_anonymous', 'false') from acct), 'false'
  union all
  select 23, 'email is confirmed',
         (select ((j ->> 'email_confirmed_at') is not null)::text from acct), 'true'
  union all
  select 24, 'a password is set (only whether one exists is shown)',
         (select (coalesce(j ->> 'encrypted_password', '') <> '')::text from acct), 'true'
  -- 3x  is it safe to use for M2 --------------------------------------------
  union all
  select 30, 'NO rate state row exists for it (M2 precondition)',
         (select n::text from st), '0'
  union all
  select 31, 'no leftover probe event',
         (select probe::text from ev), '0'
  union all
  select 32, 'at most 50 events (looks like a dedicated test account)',
         (select (n <= (select max_events from c))::text from ev), 'true'
  union all
  select 33, 'no event of it written in the last 15 minutes (not in use)',
         (select recent::text from ev), '0'
  union all
  select 34, 'room for one more row under the 0011 owner quota '
             '(otherwise the quota trigger answers 400 before the rate trigger)',
         (select (n + 1 <= public.events_max_per_owner())::text from ev), 'true'
  -- 4x  is the limiter what this procedure assumes --------------------------
  union all
  select 40, 'events_rate_interval() is 1 second',
         public.events_rate_interval()::text, '00:00:01'
  union all
  select 41, 'events_rate_burst() is 120',
         public.events_rate_burst()::text, '120'
  union all
  select 42, 'both events_rate_% triggers exist and are enabled',
         (select rate_enabled::text from trg), '2'
  -- 5x  context -------------------------------------------------------------
  union all
  select 50, 'events owned by the account (BLOCK 7 compares against this)',
         (select n::text from ev), '(context)'
  union all
  select 51, 'its most recent event write',
         (select coalesce(last_write::text, '<none>') from ev), '(context)'
  union all
  select 52, 'its last sign-in',
         (select coalesce(j ->> 'last_sign_in_at', '<never>') from acct), '(context)'
  union all
  select 53, 'account created at',
         (select j ->> 'created_at' from acct), '(context)'
  union all
  select 54, 'its active share links (the probe creates no event, so none is affected)',
         (select count(*)::text from public.share_links s
           where s.owner_id = (select owner from c) and s.revoked_at is null), '(context)'
  union all
  select 55, 'triggers on public.events',
         (select all_triggers::text from trg), '(context)'
) s
order by ord;

rollback;


-- ############################################################################
-- BLOCK 2 of 8 -- R0 SIGN IN AND IDENTITY GATE. LOCAL POWERSHELL 7+.
-- Run BEFORE the seed, so the 300 s window is not spent signing in.
-- Use a fresh window, not under Start-Transcript. Nothing secret is typed on a
-- command line: the password is read with -AsSecureString, and the token is
-- held only as a SecureString.
-- ############################################################################
/*
if ($PSVersionTable.PSVersion.Major -lt 7) { throw 'PowerShell 7+ is required' }

# Not secrets. The anon key ships in the browser bundle; RLS is the defence.
$M2 = @{
  Url   = 'https://<project-ref>.supabase.co'     # VITE_SUPABASE_URL
  Anon  = '<VITE_SUPABASE_ANON_KEY>'
  Owner = '5e86935f-7661-4741-868f-0f51c4cf1727'
  Email = 'timeweave-sql-test@example.com'
}

$pw   = Read-Host -AsSecureString "Password for $($M2.Email)"
$auth = Invoke-RestMethod -Method Post `
          -Uri "$($M2.Url)/auth/v1/token?grant_type=password" `
          -Headers @{ apikey = $M2.Anon } -ContentType 'application/json' `
          -Body (@{ email = $M2.Email; password = (ConvertFrom-SecureString $pw -AsPlainText) } | ConvertTo-Json -Compress)
$tok  = ConvertTo-SecureString $auth.access_token -AsPlainText -Force
Remove-Variable auth, pw          # drops the plaintext tokens and the password

$me     = Invoke-RestMethod -Uri "$($M2.Url)/auth/v1/user" `
            -Headers @{ apikey = $M2.Anon } -Authentication Bearer -Token $tok
# The JWT payload is not secret (it is signed, not encrypted); only the whole
# token is. It is decoded without ever storing the token as plain text.
$claims = & {
  $p = (ConvertFrom-SecureString $tok -AsPlainText).Split('.')[1].Replace('-', '+').Replace('_', '/')
  $p += '=' * ((4 - $p.Length % 4) % 4)
  [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($p)) | ConvertFrom-Json
}
$left = $claims.exp - [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()

[pscustomobject]@{ user_id = $me.id; email = $me.email; sub = $claims.sub; role = $claims.role; seconds_left = $left } | Format-List

if ($me.id -ne $M2.Owner -or $claims.sub -ne $M2.Owner -or $me.email -ne $M2.Email `
    -or $claims.role -ne 'authenticated' -or $left -lt 900) {
  throw 'R0 FAILED -- do not run BLOCK 3. Run BLOCK 8.'
}
'R0 ok -- proceed to BLOCK 3'
*/


-- ############################################################################
-- BLOCK 3 of 8 -- S1 SEED. WRITES ONE ROW. Run on its own, add nothing to it.
-- Re-checks every precondition at write time; any failure writes nothing.
-- ############################################################################
/*
do $m2_seed$
declare
  c_owner  constant uuid        := '5e86935f-7661-4741-868f-0f51c4cf1727';
  c_email  constant text        := 'timeweave-sql-test@example.com';
  c_title  constant text        := 'zz m2 rate probe';
  c_window constant interval    := interval '300 seconds';          -- W
  c_max_ev constant int         := 50;
  c_t      constant interval    := public.events_rate_interval();
  c_burst  constant int         := public.events_rate_burst();
  v_now    constant timestamptz := pg_catalog.statement_timestamp();
  v_n      bigint;
begin
  if c_t <> interval '1 second' or c_burst <> 120 then
    raise exception 'M2 seed refused: rate parameters are % / %, this procedure assumes 1 s / 120',
                    c_t, c_burst
      using hint = 'Nothing was written.';
  end if;

  select count(*) into v_n
  from auth.users u
  where u.id = c_owner
    and lower(u.email) = lower(c_email)
    and (to_jsonb(u) ->> 'deleted_at') is null;
  if v_n <> 1 then
    raise exception 'M2 seed refused: uuid and email do not identify one live account'
      using hint = 'Nothing was written.';
  end if;

  select count(*) into v_n from auth.users u where lower(u.email) = lower(c_email);
  if v_n <> 1 then
    raise exception 'M2 seed refused: % accounts carry that email', v_n
      using hint = 'Nothing was written.';
  end if;

  -- THE PRECONDITION. Never satisfied by overwriting or deleting.
  if exists (select 1 from timeweave_private.event_write_rate w where w.owner_id = c_owner) then
    raise exception 'M2 seed refused: the test account already has a rate state row'
      using detail = 'M2 requires the account to start with NO state row, so that cleanup '
                     'returns it to exactly that state. The existing row was not changed.',
            hint   = 'Nothing was written. Do not delete the row to make this pass. Only if it is '
                     'provably left over from an earlier M2 run (charged_rows = 0 and '
                     'tat - last_charge_at = 419 s) is BLOCK 7 the right next step.';
  end if;

  select count(*) into v_n from public.events e where e.owner_id = c_owner;
  if v_n > c_max_ev then
    raise exception 'M2 seed refused: % events -- does not look like a dedicated test account', v_n
      using hint = 'Nothing was written.';
  end if;
  if v_n + 1 > public.events_max_per_owner() then
    raise exception 'M2 seed refused: the 0011 owner quota would answer before the rate trigger'
      using hint = 'Nothing was written.';
  end if;

  if exists (select 1 from public.events e where e.owner_id = c_owner and e.title = c_title) then
    raise exception 'M2 seed refused: a probe event is left over'
      using hint = 'Nothing was written. Run BLOCK 7 first.';
  end if;

  if exists (select 1 from public.events e
              where e.owner_id = c_owner
                and e.updated_at > pg_catalog.clock_timestamp() - interval '15 minutes') then
    raise exception 'M2 seed refused: the account wrote an event in the last 15 minutes'
      using hint = 'Nothing was written. It may be in use.';
  end if;

  -- Plain INSERT, deliberately WITHOUT `on conflict`: a row that appeared since
  -- the check above makes this fail on the primary key (23505), writing nothing.
  --
  -- charged_rows = 0 and last_charge_at = t_s are the markers BLOCK 6 reads: any
  -- charge that survives -- accepted OR refused -- moves both.
  insert into timeweave_private.event_write_rate (owner_id, tat, charged_rows, last_charge_at)
  values (c_owner, v_now + (c_burst * c_t - c_t) + c_window, 0, v_now);
end;
$m2_seed$;
*/


-- ############################################################################
-- BLOCK 4 of 8 -- SEND GATE. READ-ONLY. Run on its own, immediately before
-- BLOCK 5. Send only if ok_to_send is true; copy seeded_at_utc into BLOCK 5.
--
-- clock_timestamp(), not statement_timestamp(): the SQL editor can send several
-- statements as one message, in which case statement_timestamp() is identical
-- for all of them and the window would always read as a full 300 s.
-- ############################################################################
/*
select to_char(w.last_charge_at at time zone 'UTC',
               'YYYY-MM-DD"T"HH24:MI:SS.US"Z"')                        as seeded_at_utc,
       w.charged_rows,                                                    -- 0
       extract(epoch from w.tat - w.last_charge_at)                       as seeded_span_s,          -- 419
       round(extract(epoch from w.tat - pg_catalog.clock_timestamp())
             - extract(epoch from public.events_rate_burst() * public.events_rate_interval()
                                  - public.events_rate_interval()), 1)    as refusal_window_left_s,  -- >= 60
       (w.charged_rows = 0
        and extract(epoch from w.tat - w.last_charge_at) = 419
        and extract(epoch from w.tat - pg_catalog.clock_timestamp()) - 119 >= 60) as ok_to_send
from timeweave_private.event_write_rate w
where w.owner_id = '5e86935f-7661-4741-868f-0f51c4cf1727';

-- No row: BLOCK 3 did not write. ok_to_send false with a short window: the
-- window is too far gone -- run BLOCK 7, then start again from BLOCK 1.
*/


-- ############################################################################
-- BLOCK 5 of 8 -- R1 ONE REQUEST. SAME POWERSHELL WINDOW AS BLOCK 2.
-- The request is the app's create() exactly: eventToInsert's columns,
-- Prefer: return=representation (.select()) and the object Accept (.single()).
-- Dated 2031 so that, if it were ever accepted, it would not appear in normal use.
-- ############################################################################
/*
$W         = 300
$seededAt  = [DateTimeOffset]::Parse('<seeded_at_utc from BLOCK 4>')
$body      = '{"title":"zz m2 rate probe","description":null,"category":null,"visibility":"private","rrule":null,"recurrence_id":null,"recurrence_slot_start":null,"recurrence_slot_date":null,"is_cancelled":false,"all_day":true,"start_at":null,"end_at":null,"start_date":"2031-01-01","end_date":"2031-01-02","timezone":null}'

$sentAt = [DateTimeOffset]::UtcNow
$r = Invoke-WebRequest -Method Post -Uri "$($M2.Url)/rest/v1/events" `
       -Headers @{ apikey = $M2.Anon; Prefer = 'return=representation'; Accept = 'application/vnd.pgrst.object+json' } `
       -Authentication Bearer -Token $tok `
       -ContentType 'application/json' -Body $body -SkipHttpErrorCheck

$j        = try { $r.Content | ConvertFrom-Json } catch { $null }
$n        = if ([string]$j.hint -match '^retry_after_seconds=([1-9][0-9]*)$') { [int]$Matches[1] } else { $null }
$expected = [math]::Ceiling($W - ($sentAt - $seededAt).TotalSeconds)
$retryHdr = @($r.Headers.Keys | Where-Object { $_ -ieq 'Retry-After' })

[pscustomobject]@{
  P1_status_429        = ($r.StatusCode -eq 429)
  P2_code_PT429        = ($j.code -ceq 'PT429')
  P3_details_token     = ($j.details -ceq 'TIMEWEAVE_RATE_EVENTS')
  P4a_hint_1_to_300    = ($null -ne $n -and $n -ge 1 -and $n -le $W)
  P4b_hint_vs_clock    = ($null -ne $n -and [math]::Abs($n - $expected) -le 3)
  P5_owner_in_message  = ([string]$j.message -like "*owner $($M2.Owner) is *")
  P6_no_retry_after    = ($retryHdr.Count -eq 0)
} | Format-List

"status      : $($r.StatusCode)"
"sent_at     : $($sentAt.ToString('o'))"
"hint        : $($j.hint)   (expected about $expected)"
"body        : $($r.Content)"     # the 429 body carries no secret; a 201 body carries the new row's id
*/


-- ############################################################################
-- BLOCK 6 of 8 -- S2 READOUT. READ-ONLY. Run after BLOCK 5, whatever it said.
-- ############################################################################
/*
with
c as (
  select '5e86935f-7661-4741-868f-0f51c4cf1727'::uuid as owner,
         'zz m2 rate probe'::text                    as probe_title
),
w as (
  select * from timeweave_private.event_write_rate
  where owner_id = (select owner from c)
)
select ord, name, got, want,
       case when want = '(context)' then 'context'
            when got is not distinct from want then 'ok'
            else 'FAIL' end as verdict
from (
  select 1 as ord, 'the seeded state row is still there' as name,
         (select count(*)::text from w) as got, '1' as want
  union all
  select 2, 'REFUSED WORK WAS NOT CHARGED: charged_rows still 0',
         (select charged_rows::text from w), '0'
  union all
  select 3, 'tat untouched since the seed: tat - seeded_at = (tau - T) + W = 419 s',
         (select (extract(epoch from tat - last_charge_at) = 419)::text from w), 'true'
  union all
  select 4, 'no probe event for the test account',
         (select count(*)::text from public.events e
           where e.owner_id = (select owner from c) and e.title = (select probe_title from c)), '0'
  union all
  select 5, 'no probe event under ANY owner (a wrong token would show here)',
         (select count(*)::text from public.events e
           where e.title = (select probe_title from c)), '0'
  union all
  select 6, 'no row of the test account written since the seed',
         (select count(*)::text from public.events e
           where e.owner_id = (select owner from c)
             and e.updated_at >= (select last_charge_at from w)), '0'
  union all
  select 7, 'nothing global changed: parameters still 1 s / 120',
         (public.events_rate_interval() = interval '1 second'
          and public.events_rate_burst() = 120)::text, 'true'
  union all
  select 8, 'refusal window left, seconds',
         (select round(extract(epoch from tat - pg_catalog.clock_timestamp()) - 119, 1)::text from w),
         '(context)'
) s
order by ord;
*/


-- ############################################################################
-- BLOCK 7 of 8 -- S3 CLEANUP. WRITES. Run 7a, then 7b, as SEPARATE executions,
-- then 7c. Each is idempotent: safe to run twice, and safe after a partial run.
-- Both deletes are fenced to the test account by uuid AND email.
-- ############################################################################
/*
-- 7a. Normally deletes 0 rows. Deletes 1 if BLOCK 5 was accepted (201).
delete from public.events e
 where e.owner_id = '5e86935f-7661-4741-868f-0f51c4cf1727'::uuid
   and e.title    = 'zz m2 rate probe'
   and exists (select 1 from auth.users u
                where u.id = e.owner_id
                  and lower(u.email) = lower('timeweave-sql-test@example.com'));
*/
/*
-- 7b. Deletes the row BLOCK 3 created. BLOCK 1 and BLOCK 3 proved no row
-- existed before, so whatever is here was born in this run.
delete from timeweave_private.event_write_rate w
 where w.owner_id = '5e86935f-7661-4741-868f-0f51c4cf1727'::uuid
   and exists (select 1 from auth.users u
                where u.id = w.owner_id
                  and lower(u.email) = lower('timeweave-sql-test@example.com'));
*/
/*
-- 7c. Proof. READ-ONLY.
select ord, name, got, want,
       case when want = '(context)' then 'context'
            when got is not distinct from want then 'ok'
            else 'FAIL' end as verdict
from (
  select 1 as ord, 'test account has NO state row again (its state before BLOCK 3)' as name,
         (select count(*)::text from timeweave_private.event_write_rate
           where owner_id = '5e86935f-7661-4741-868f-0f51c4cf1727'::uuid) as got, '0' as want
  union all
  select 2, 'probe events under ANY owner',
         (select count(*)::text from public.events where title = 'zz m2 rate probe'), '0'
  union all
  select 3, 'test account events -- must equal BLOCK 1 check 50',
         (select count(*)::text from public.events
           where owner_id = '5e86935f-7661-4741-868f-0f51c4cf1727'::uuid), '(context)'
  union all
  select 4, 'parameters still 1 s / 120',
         (public.events_rate_interval() = interval '1 second'
          and public.events_rate_burst() = 120)::text, 'true'
  union all
  select 5, 'both events_rate_% triggers still enabled',
         (select count(*)::text from pg_trigger t
           where t.tgrelid = 'public.events'::regclass and not t.tgisinternal
             and t.tgname like 'events_rate_%' and t.tgenabled::text = 'O'), '2'
) s
order by ord;
*/


-- ############################################################################
-- BLOCK 8 of 8 -- SIGN OUT AND FORGET. SAME POWERSHELL WINDOW. Always run it,
-- including after an abort. Then close the window.
-- ############################################################################
/*
if ($tok) {
  Invoke-RestMethod -Method Post -Uri "$($M2.Url)/auth/v1/logout?scope=local" `
    -Headers @{ apikey = $M2.Anon } -Authentication Bearer -Token $tok | Out-Null
}
Remove-Variable tok, me, claims, left, r, j, n, body, seededAt, sentAt, expected, retryHdr -ErrorAction SilentlyContinue
'signed out; token variables cleared'
*/
