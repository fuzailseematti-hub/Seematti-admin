-- ──────────────────────────────────────────────────────────────────────
-- Tasks upgrade — sub-tasks + comments — April 2026
-- ──────────────────────────────────────────────────────────────────────
-- Run once in the Supabase SQL editor. Safe to re-run (idempotent).
--
-- - tasks.parent_task_id: a task can now nest under another task, so
--   the Owner's daily checklist supports "open the store -> lights,
--   till float, door unlock" as a parent + sub-tasks.
-- - task_comments: a lightweight threaded comment table so HR and the
--   assignee can discuss a task in-app instead of over WhatsApp.
-- ──────────────────────────────────────────────────────────────────────

alter table public.tasks
  add column if not exists parent_task_id uuid references public.tasks(id) on delete cascade;

create index if not exists tasks_parent_task_id_idx
  on public.tasks (parent_task_id);

create table if not exists public.task_comments (
  id          uuid primary key default gen_random_uuid(),
  task_id     uuid not null references public.tasks(id) on delete cascade,
  author_id   text,    -- employees.id (nullable for bootstrap owner sessions)
  author_name text not null,   -- snapshot so display survives employee renames
  body        text not null,
  created_at  timestamptz not null default now()
);

create index if not exists task_comments_task_id_idx
  on public.task_comments (task_id, created_at);

alter table public.task_comments enable row level security;

do $$
begin
  if not exists (select 1 from pg_policies where policyname = 'task_comments anon all') then
    create policy "task_comments anon all"
      on public.task_comments
      for all using (true) with check (true);
  end if;
end $$;
