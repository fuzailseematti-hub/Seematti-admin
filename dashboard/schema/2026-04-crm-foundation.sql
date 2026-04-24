-- ──────────────────────────────────────────────────────────────────────
-- CRM foundation — April 2026 (Part B)
-- ──────────────────────────────────────────────────────────────────────
-- Run once in the Supabase SQL editor. Safe to re-run (idempotent).
--
-- What this adds
--   • A new 'cc' (Customer Care) role. The employees.user_type CHECK
--     constraint is widened, and the admin_change_role() RPC learns
--     about it so the Owner can grant access via Team Access.
--   • Three new tables for the retail-sarees CRM:
--       customers                — one row per customer
--       customer_preferences     — many per customer (fabric / colour / price)
--       customer_family_members  — many per customer (spouse, kids, parents)
--   • Permissive anon RLS mirroring the rest of the app.
-- ──────────────────────────────────────────────────────────────────────

-- ── Role: add 'cc' to the allowed user_type values ────────────────────
alter table public.employees
  drop constraint if exists employees_user_type_check;
alter table public.employees
  drop constraint if exists employees_user_type_chk;
alter table public.employees
  add constraint employees_user_type_chk
  check (user_type in ('owner', 'admin', 'hr', 'manager', 'supervisor', 'staff', 'cc'));

-- ── RPC: replace with one that also permits granting 'cc' ─────────────
-- Keeps the same contract as the existing admin_change_role() function,
-- just adds 'cc' to the whitelist. Matches the Part A / role-guard file.
create or replace function public.admin_change_role(
  p_actor_username        text,
  p_actor_password_sha256 text,
  p_target_employee_id    text,
  p_new_role              text
) returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actor_type text;
begin
  if p_new_role not in ('owner', 'admin', 'hr', 'manager', 'supervisor', 'staff', 'cc') then
    raise exception 'Invalid role: %', p_new_role;
  end if;

  select e.user_type
    into v_actor_type
    from public.user_access ua
    join public.employees   e on e.id = ua.employee_id
   where ua.username = lower(p_actor_username)
     and ua.password_sha256 = p_actor_password_sha256
     and coalesce(e.is_active, true) = true;

  if v_actor_type is null then
    raise exception 'Invalid credentials' using errcode = 'insufficient_privilege';
  end if;

  if p_new_role in ('owner', 'admin') and v_actor_type <> 'owner' then
    raise exception 'Only the Owner can grant Owner or Admin rights' using errcode = 'insufficient_privilege';
  end if;

  if p_new_role not in ('owner', 'admin')
     and v_actor_type not in ('owner', 'admin', 'hr') then
    raise exception 'Your role cannot change access' using errcode = 'insufficient_privilege';
  end if;

  perform set_config('app.role_change_ok', '1', true);
  update public.employees
     set user_type = p_new_role
   where id = p_target_employee_id;
  perform set_config('app.role_change_ok', '', true);
end
$$;

revoke all on function public.admin_change_role(text, text, text, text) from public;
grant execute on function public.admin_change_role(text, text, text, text) to anon, authenticated;

-- ── Customers ─────────────────────────────────────────────────────────
create table if not exists public.customers (
  id              uuid primary key default gen_random_uuid(),
  name            text not null,
  phone           text,
  alt_phone       text,
  email           text,
  address         text,
  city            text,
  pincode         text,
  birthday        date,
  anniversary     date,
  language_pref   text check (language_pref in ('ta', 'en')) default 'ta',
  source          text check (source in ('walk-in', 'referral', 'muhurtham', 'social', 'other')) default 'walk-in',
  tags            text[] not null default '{}',    -- e.g. {'vip','muhurtham','priority'}
  is_vip          boolean not null default false,
  do_not_contact  boolean not null default false,
  notes           text,
  created_by      text,    -- employees.id of the CC who added
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);

create index if not exists customers_name_idx      on public.customers (lower(name));
create index if not exists customers_phone_idx     on public.customers (phone);
create index if not exists customers_created_at_idx on public.customers (created_at desc);
create index if not exists customers_tags_idx      on public.customers using gin (tags);

-- ── Customer preferences (fabric / colour / price range) ──────────────
create table if not exists public.customer_preferences (
  id               uuid primary key default gen_random_uuid(),
  customer_id      uuid not null references public.customers(id) on delete cascade,
  category         text,           -- silk, cotton, dhoti, shirting, kurta, dress, other
  sub_category     text,           -- kanjivaram, banarasi, chiffon, linen, etc.
  color_notes      text,
  price_min        numeric(10, 2),
  price_max        numeric(10, 2),
  notes            text,
  created_at       timestamptz not null default now()
);

create index if not exists customer_preferences_customer_idx
  on public.customer_preferences (customer_id);

-- ── Customer family members ───────────────────────────────────────────
create table if not exists public.customer_family_members (
  id            uuid primary key default gen_random_uuid(),
  customer_id   uuid not null references public.customers(id) on delete cascade,
  name          text not null,
  relation      text,       -- husband, wife, son, daughter, mother, father, sister, brother, other
  age           integer,
  notes         text,
  created_at    timestamptz not null default now()
);

create index if not exists customer_family_customer_idx
  on public.customer_family_members (customer_id);

-- ── RLS (permissive anon, consistent with the rest of the app) ────────
alter table public.customers               enable row level security;
alter table public.customer_preferences    enable row level security;
alter table public.customer_family_members enable row level security;

do $$
begin
  if not exists (select 1 from pg_policies where policyname = 'customers anon all') then
    create policy "customers anon all" on public.customers for all using (true) with check (true);
  end if;
  if not exists (select 1 from pg_policies where policyname = 'customer_preferences anon all') then
    create policy "customer_preferences anon all" on public.customer_preferences for all using (true) with check (true);
  end if;
  if not exists (select 1 from pg_policies where policyname = 'customer_family_members anon all') then
    create policy "customer_family_members anon all" on public.customer_family_members for all using (true) with check (true);
  end if;
end $$;

-- ── updated_at trigger for customers ──────────────────────────────────
create or replace function public.customers_touch_updated_at()
returns trigger
language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end
$$;

drop trigger if exists customers_touch_updated_at_trg on public.customers;
create trigger customers_touch_updated_at_trg
  before update on public.customers
  for each row execute function public.customers_touch_updated_at();
