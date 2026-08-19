-- Minimal pre-auth Joe's Kitchen schema used only by the disposable local test.
-- This deliberately represents the legacy state expected by the first migration.

create or replace function public.update_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create table public.inventory (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  category text not null default 'Other',
  store text not null default 'Other',
  unit text not null default 'ct',
  current_qty numeric not null default 0,
  par_level numeric not null default 0,
  price numeric not null default 0,
  note text default '',
  created_at timestamptz default now(),
  updated_at timestamptz default now(),
  shopper_note text default '',
  checked_at timestamptz,
  session_id uuid,
  pack_size numeric default 1,
  photo_url text
);

create table public.shopping_sessions (
  id uuid primary key default gen_random_uuid(),
  started_at timestamptz default now(),
  ended_at timestamptz,
  total_spent numeric default 0,
  item_count integer default 0,
  notes_summary text default '',
  status text default 'active',
  driver_role text default 'shopper',
  actual_total numeric default 0,
  receipt_count integer default 0,
  start_miles numeric,
  end_miles numeric,
  driver_name text
);

create table public.session_notes (
  id uuid primary key default gen_random_uuid(),
  session_id uuid references public.shopping_sessions(id) on delete cascade,
  item_name text,
  store text,
  note text,
  created_at timestamptz default now()
);

create table public.purchase_log (
  id uuid primary key default gen_random_uuid(),
  session_id uuid,
  item_id uuid,
  item_name text not null,
  category text,
  store text,
  unit text,
  qty numeric default 1,
  price numeric default 0,
  purchased_at timestamptz default now()
);

create table public.rider_payments (
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz default now()
);

create table public.receipt_aliases (
  id uuid primary key default gen_random_uuid(),
  inventory_id uuid references public.inventory(id) on delete set null,
  store text not null,
  raw_name text not null,
  inventory_name text,
  add_config jsonb,
  created_at timestamptz default now(),
  updated_at timestamptz default now(),
  unique (store, raw_name)
);

create table public.meals (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  portions integer default 4,
  note text,
  created_at timestamptz default now(),
  updated_at timestamptz default now()
);

create table public.meal_ingredients (
  meal_id uuid not null references public.meals(id) on delete cascade,
  item_id uuid not null references public.inventory(id) on delete cascade,
  qty_per_batch numeric not null default 1,
  unit text,
  primary key (meal_id, item_id)
);

create table public.shop_quantities (
  session_id uuid not null references public.shopping_sessions(id) on delete cascade,
  item_id uuid not null references public.inventory(id) on delete cascade,
  qty numeric not null default 1,
  primary key (session_id, item_id)
);

create table public.session_receipts (
  id uuid primary key default gen_random_uuid(),
  session_id uuid not null references public.shopping_sessions(id) on delete cascade,
  store_guess text,
  total numeric default 0,
  item_count integer default 0,
  photo_url text,
  uploaded_at timestamptz default now(),
  raw_items jsonb,
  subtotal numeric,
  tax numeric,
  linked_purchase_ids jsonb default '[]'::jsonb,
  is_manual boolean default false
);

insert into storage.buckets (id, name, public)
values ('receipts', 'receipts', true), ('item-photos', 'item-photos', true)
on conflict (id) do nothing;

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password,
  email_confirmed_at, created_at, updated_at,
  raw_app_meta_data, raw_user_meta_data
)
values (
  '00000000-0000-0000-0000-000000000000',
  '10000000-0000-0000-0000-000000000001',
  'authenticated', 'authenticated', 'local-test@example.com', '',
  now(), now(), now(),
  '{"provider":"email","providers":["email"]}'::jsonb,
  '{"display_name":"Local Test Owner"}'::jsonb
);

insert into public.inventory (id, name, unit, current_qty, par_level, price)
values ('20000000-0000-0000-0000-000000000001', 'Test Rice', 'lb', 2, 10, 1.50);

insert into public.meals (id, name, portions, note)
values ('30000000-0000-0000-0000-000000000001', 'Legacy Rice', 4, 'Migration test meal');

insert into public.meal_ingredients (meal_id, item_id, qty_per_batch, unit)
values (
  '30000000-0000-0000-0000-000000000001',
  '20000000-0000-0000-0000-000000000001',
  2,
  'lb'
);
