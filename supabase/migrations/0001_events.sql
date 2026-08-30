-- TimeWeave Phase 2: events table, indexes, updated_at trigger, and RLS.
-- Apply via the Supabase SQL editor or the Supabase CLI.
--
-- Design decisions (see README):
--   * All instants are timestamptz (stored UTC). All-day events use date
--     columns instead, with end_date EXCLUSIVE so both representations share
--     the half-open [start, end) semantics.
--   * Recurrence exceptions live in this same table (recurrence_id -> master).
--     The overridden occurrence is identified type-safely by EITHER
--     recurrence_slot_start (timed masters) OR recurrence_slot_date (all-day
--     masters), never both.
--   * RLS: owner-only CRUD. Sharing is NOT exposed here; a SECURITY DEFINER
--     RPC is added and reviewed separately in Phase 5.

create extension if not exists pgcrypto;

create table public.events (
  id            uuid primary key default gen_random_uuid(),
  owner_id      uuid not null default auth.uid()
                  references auth.users (id) on delete cascade,

  title         text not null default '',
  description   text,
  category      text,
  visibility    text not null default 'private'
                  check (visibility in ('private', 'busy_only', 'public')),

  all_day       boolean not null default false,

  -- Timed events (all_day = false). end_at is exclusive.
  start_at      timestamptz,
  end_at        timestamptz,

  -- All-day events (all_day = true). end_date is EXCLUSIVE
  -- (a single day 2026-08-29 => start_date 2026-08-29, end_date 2026-08-30).
  start_date    date,
  end_date      date,

  -- Recurrence
  rrule                 text,  -- master only, e.g. 'FREQ=WEEKLY;BYDAY=MO'
  recurrence_id         uuid references public.events (id) on delete cascade, -- exception -> master
  recurrence_slot_start timestamptz, -- RECURRENCE-ID for a TIMED master's occurrence
  recurrence_slot_date  date,        -- RECURRENCE-ID for an ALL-DAY master's occurrence
  is_cancelled          boolean not null default false, -- "delete this occurrence" tombstone

  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),

  -- Exactly one time representation, matching all_day; both ends half-open.
  constraint events_time_shape check (
    (all_day = false
       and start_at is not null and end_at is not null and end_at >= start_at
       and start_date is null and end_date is null)
    or
    (all_day = true
       and start_date is not null and end_date is not null and end_date > start_date
       and start_at is null and end_at is null)
  ),

  -- A recurring master cannot itself be an exception.
  constraint events_master_not_exception check (
    not (rrule is not null and recurrence_id is not null)
  ),

  -- Exception rows identify their overridden slot with exactly one slot key,
  -- and that key's type must match the row's all_day flag.
  constraint events_exception_slot check (
    (recurrence_id is null
       and recurrence_slot_start is null and recurrence_slot_date is null)
    or
    (recurrence_id is not null and all_day = false
       and recurrence_slot_start is not null and recurrence_slot_date is null)
    or
    (recurrence_id is not null and all_day = true
       and recurrence_slot_date is not null and recurrence_slot_start is null)
  ),

  -- Cancellation tombstones only make sense on exception rows.
  constraint events_cancel_only_on_exception check (
    is_cancelled = false or recurrence_id is not null
  )
);

-- Indexes: owner-scoped range lookups and exception collection.
create index events_owner_start_idx      on public.events (owner_id, start_at);
create index events_owner_start_date_idx on public.events (owner_id, start_date);
create index events_owner_recurrence_idx on public.events (owner_id, recurrence_id);

-- Keep updated_at fresh on every UPDATE.
create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create trigger events_set_updated_at
  before update on public.events
  for each row execute function public.set_updated_at();

-- Row Level Security: owner-only CRUD. owner_id is filled by DEFAULT auth.uid()
-- on insert; WITH CHECK forbids spoofing another user's id.
alter table public.events enable row level security;

create policy events_select_own on public.events
  for select using (owner_id = auth.uid());

create policy events_insert_own on public.events
  for insert with check (owner_id = auth.uid());

create policy events_update_own on public.events
  for update using (owner_id = auth.uid())
  with check (owner_id = auth.uid());

create policy events_delete_own on public.events
  for delete using (owner_id = auth.uid());
