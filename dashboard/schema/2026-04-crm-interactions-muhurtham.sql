-- ──────────────────────────────────────────────────────────────────────
-- CRM Part C — Interactions + Muhurtham — April 2026
-- ──────────────────────────────────────────────────────────────────────
-- Run once in the Supabase SQL editor. Safe to re-run (idempotent).
--
-- Adds the two tables behind the Customer Care team's daily workflow:
--
--   customer_interactions   — one row per call / store visit / home
--                             visit / WhatsApp. Tracks topic, outcome,
--                             and an optional follow-up date so the CC
--                             dashboard can surface "due today".
--
--   muhurtham_visits        — one row per home invite. Pre-visit
--                             preferences captured before the CC /
--                             stylist leaves; post-visit outcome
--                             captured after. A 2-day follow-up
--                             reminder auto-surfaces in the CC inbox.
-- ──────────────────────────────────────────────────────────────────────

-- ── Interactions ──────────────────────────────────────────────────────
create table if not exists public.customer_interactions (
  id               uuid primary key default gen_random_uuid(),
  customer_id      uuid not null references public.customers(id) on delete cascade,
  type             text not null check (type in ('call-out','call-in','store-visit','home-visit','whatsapp','sms','other')),
  occurred_at      timestamptz not null default now(),
  duration_min     integer,   -- for calls
  topic            text,      -- greeting, follow-up, new-collection, offer, appointment, complaint, feedback, muhurtham, other
  outcome          text,      -- short phrase: "ordered", "interested", "not now", "callback in a week"
  follow_up_date   date,
  follow_up_note   text,
  follow_up_done   boolean not null default false,
  logged_by        text,      -- employees.id of the CC who logged it
  logged_by_name   text,      -- snapshot so display survives renames
  notes            text,
  created_at       timestamptz not null default now()
);

create index if not exists customer_interactions_customer_idx
  on public.customer_interactions (customer_id, occurred_at desc);
create index if not exists customer_interactions_followup_idx
  on public.customer_interactions (follow_up_date)
  where follow_up_done = false and follow_up_date is not null;
create index if not exists customer_interactions_occurred_idx
  on public.customer_interactions (occurred_at desc);

-- ── Muhurtham visits ──────────────────────────────────────────────────
create table if not exists public.muhurtham_visits (
  id                  uuid primary key default gen_random_uuid(),
  customer_id         uuid not null references public.customers(id) on delete cascade,
  wedding_date        date,
  visit_date          date,            -- when CC/stylist visits the home
  visit_time          text,            -- optional, e.g. "10:30 AM"
  address             text,            -- may differ from customer.address
  budget_min          numeric(12, 2),
  budget_max          numeric(12, 2),
  color_theme         text,            -- muhurtham colours / festival theme
  family_joining      integer,         -- headcount
  special_requests    text,
  pre_visit_done      boolean not null default false,
  pre_visit_done_at   timestamptz,
  post_visit_outcome  text check (post_visit_outcome in
    ('ordered','deciding','wants-store-visit','not-interested','rescheduled','other')),
  post_visit_notes    text,
  post_visit_done     boolean not null default false,
  post_visit_done_at  timestamptz,
  reminder_due_on     date,            -- auto-set to visit_date + 2 on insert
  reminder_resolved   boolean not null default false,
  status              text not null default 'scheduled' check (status in
    ('scheduled','pre-captured','visited','completed','cancelled')),
  created_by          text,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);

create index if not exists muhurtham_visits_customer_idx
  on public.muhurtham_visits (customer_id, visit_date);
create index if not exists muhurtham_visits_visit_date_idx
  on public.muhurtham_visits (visit_date);
create index if not exists muhurtham_visits_reminder_idx
  on public.muhurtham_visits (reminder_due_on)
  where reminder_resolved = false and reminder_due_on is not null;
create index if not exists muhurtham_visits_status_idx
  on public.muhurtham_visits (status);

-- Default reminder to visit_date + 2 days when the caller doesn't set it.
create or replace function public.muhurtham_default_reminder()
returns trigger language plpgsql as $$
begin
  if new.reminder_due_on is null and new.visit_date is not null then
    new.reminder_due_on := new.visit_date + 2;
  end if;
  new.updated_at := now();
  return new;
end
$$;

drop trigger if exists muhurtham_visits_touch_trg on public.muhurtham_visits;
create trigger muhurtham_visits_touch_trg
  before insert or update on public.muhurtham_visits
  for each row execute function public.muhurtham_default_reminder();

-- ── RLS (permissive anon, consistent with the rest of the app) ────────
alter table public.customer_interactions enable row level security;
alter table public.muhurtham_visits      enable row level security;

do $$
begin
  if not exists (select 1 from pg_policies where policyname = 'customer_interactions anon all') then
    create policy "customer_interactions anon all"
      on public.customer_interactions for all using (true) with check (true);
  end if;
  if not exists (select 1 from pg_policies where policyname = 'muhurtham_visits anon all') then
    create policy "muhurtham_visits anon all"
      on public.muhurtham_visits for all using (true) with check (true);
  end if;
end $$;
