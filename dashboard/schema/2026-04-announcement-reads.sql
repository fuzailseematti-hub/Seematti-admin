-- ──────────────────────────────────────────────────────────────────────
-- Announcement read receipts + acknowledgements — April 2026
-- ──────────────────────────────────────────────────────────────────────
-- Run once in the Supabase SQL editor. Safe to re-run (idempotent).
--
-- Adds a per-employee row each time someone reads or acknowledges an
-- announcement in the PWA. The dashboard Announcements page uses these
-- to show 'N of M read · K acknowledged' so the Owner can see whether
-- staff actually saw the notice.
-- ──────────────────────────────────────────────────────────────────────

create table if not exists public.announcement_reads (
  announcement_id uuid not null references public.announcements(id) on delete cascade,
  employee_id     text not null references public.employees(id)    on delete cascade,
  read_at         timestamptz not null default now(),
  acknowledged    boolean     not null default false,
  acked_at        timestamptz,
  primary key (announcement_id, employee_id)
);

create index if not exists announcement_reads_announcement_id_idx
  on public.announcement_reads (announcement_id);
create index if not exists announcement_reads_employee_id_idx
  on public.announcement_reads (employee_id);

-- Mirror the permissive anon policies used across the rest of the
-- app. Tighten later when we move to signed-in Supabase users.
alter table public.announcement_reads enable row level security;

do $$
begin
  if not exists (select 1 from pg_policies where policyname = 'announcement_reads anon all') then
    create policy "announcement_reads anon all"
      on public.announcement_reads
      for all using (true) with check (true);
  end if;
end $$;
