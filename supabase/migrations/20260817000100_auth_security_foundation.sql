begin;

create schema if not exists private;
revoke all on schema private from public, anon, authenticated;

create table if not exists public.households (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.profiles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  display_name text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.household_members (
  household_id uuid not null references public.households(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  role text not null default 'member' check (role in ('owner', 'member')),
  created_at timestamptz not null default now(),
  primary key (household_id, user_id)
);

create index if not exists household_members_user_id_idx
  on public.household_members (user_id, household_id);

insert into public.households (name)
select 'Joe''s Kitchen'
where not exists (select 1 from public.households);

create or replace function public.current_household_id()
returns uuid
language sql
stable
security invoker
set search_path = ''
as $$
  select hm.household_id
  from public.household_members hm
  where hm.user_id = (select auth.uid())
  order by hm.created_at
  limit 1
$$;

revoke all on function public.current_household_id() from public, anon;
grant execute on function public.current_household_id() to authenticated;

create or replace function private.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  target_household_id uuid;
begin
  insert into public.profiles (user_id, display_name)
  values (new.id, coalesce(new.raw_user_meta_data ->> 'display_name', split_part(new.email, '@', 1)))
  on conflict (user_id) do nothing;

  select h.id into target_household_id
  from public.households h
  order by h.created_at, h.id
  limit 1;

  if target_household_id is not null
     and not exists (select 1 from public.household_members) then
    insert into public.household_members (household_id, user_id, role)
    values (target_household_id, new.id, 'owner')
    on conflict do nothing;

    update public.households
    set created_by = new.id, updated_at = now()
    where id = target_household_id and created_by is null;
  end if;

  return new;
end;
$$;

revoke all on function private.handle_new_user() from public, anon, authenticated;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function private.handle_new_user();

do $$
declare
  table_name text;
  household uuid;
begin
  select id into household from public.households order by created_at, id limit 1;

  foreach table_name in array array[
    'inventory', 'shopping_sessions', 'session_notes', 'purchase_log',
    'rider_payments', 'receipt_aliases', 'meals', 'meal_ingredients',
    'shop_quantities', 'session_receipts'
  ] loop
    execute format('alter table public.%I add column if not exists household_id uuid', table_name);
    execute format('update public.%I set household_id = $1 where household_id is null', table_name) using household;
    execute format('alter table public.%I alter column household_id set default public.current_household_id()', table_name);
    execute format('alter table public.%I alter column household_id set not null', table_name);

    if not exists (
      select 1 from pg_constraint
      where conname = table_name || '_household_id_fkey'
        and conrelid = format('public.%I', table_name)::regclass
    ) then
      execute format(
        'alter table public.%I add constraint %I foreign key (household_id) references public.households(id) on delete restrict',
        table_name, table_name || '_household_id_fkey'
      );
    end if;

    execute format('create index if not exists %I on public.%I (household_id)', table_name || '_household_id_idx', table_name);
  end loop;
end;
$$;

create index if not exists meal_ingredients_item_id_idx on public.meal_ingredients (item_id);
create index if not exists receipt_aliases_inventory_id_idx on public.receipt_aliases (inventory_id);
create index if not exists session_notes_session_id_idx on public.session_notes (session_id);
create index if not exists session_receipts_session_id_idx on public.session_receipts (session_id);
create index if not exists shop_quantities_item_id_idx on public.shop_quantities (item_id);

alter function public.update_updated_at() set search_path = '';

alter table public.households enable row level security;
alter table public.profiles enable row level security;
alter table public.household_members enable row level security;

drop policy if exists households_member_access on public.households;
create policy households_member_access on public.households
  for select to authenticated
  using (id = public.current_household_id());

drop policy if exists households_owner_update on public.households;
create policy households_owner_update on public.households
  for update to authenticated
  using (exists (
    select 1 from public.household_members hm
    where hm.household_id = id
      and hm.user_id = (select auth.uid())
      and hm.role = 'owner'
  ))
  with check (exists (
    select 1 from public.household_members hm
    where hm.household_id = id
      and hm.user_id = (select auth.uid())
      and hm.role = 'owner'
  ));

drop policy if exists profiles_self_access on public.profiles;
create policy profiles_self_access on public.profiles
  for all to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));

drop policy if exists household_members_self_select on public.household_members;
create policy household_members_self_select on public.household_members
  for select to authenticated
  using (user_id = (select auth.uid()));

do $$
declare
  table_name text;
  policy_name text;
  existing_policy record;
begin
  foreach table_name in array array[
    'inventory', 'shopping_sessions', 'session_notes', 'purchase_log',
    'rider_payments', 'receipt_aliases', 'meals', 'meal_ingredients',
    'shop_quantities', 'session_receipts'
  ] loop
    execute format('alter table public.%I enable row level security', table_name);

    for existing_policy in
      select polname from pg_policy
      where polrelid = format('public.%I', table_name)::regclass
    loop
      execute format('drop policy if exists %I on public.%I', existing_policy.polname, table_name);
    end loop;

    policy_name := table_name || '_household_access';
    execute format(
      'create policy %I on public.%I for all to authenticated using (household_id = public.current_household_id()) with check (household_id = public.current_household_id())',
      policy_name, table_name
    );

    execute format('revoke all on table public.%I from anon', table_name);
    execute format('revoke all on table public.%I from authenticated', table_name);
    execute format('grant select, insert, update, delete on table public.%I to authenticated', table_name);
  end loop;
end;
$$;

revoke all on table public.households, public.profiles, public.household_members from anon;
revoke all on table public.households, public.profiles, public.household_members from authenticated;
grant select, update on table public.households to authenticated;
grant select, update on table public.profiles to authenticated;
grant select on table public.household_members to authenticated;

update storage.buckets
set public = false,
    file_size_limit = 10485760,
    allowed_mime_types = array['image/jpeg', 'image/png', 'image/webp']
where id in ('receipts', 'item-photos');

drop policy if exists "public read item-photos" on storage.objects;
drop policy if exists "public write item-photos" on storage.objects;
drop policy if exists "public update item-photos" on storage.objects;
drop policy if exists "public delete item-photos" on storage.objects;
drop policy if exists "public read receipts" on storage.objects;
drop policy if exists "public write receipts" on storage.objects;
drop policy if exists "public update receipts" on storage.objects;
drop policy if exists "public delete receipts" on storage.objects;

drop policy if exists household_storage_select on storage.objects;
create policy household_storage_select on storage.objects
  for select to authenticated
  using (
    bucket_id in ('receipts', 'item-photos')
    and (storage.foldername(name))[1] = public.current_household_id()::text
  );

drop policy if exists household_storage_insert on storage.objects;
create policy household_storage_insert on storage.objects
  for insert to authenticated
  with check (
    bucket_id in ('receipts', 'item-photos')
    and (storage.foldername(name))[1] = public.current_household_id()::text
  );

drop policy if exists household_storage_update on storage.objects;
create policy household_storage_update on storage.objects
  for update to authenticated
  using (
    bucket_id in ('receipts', 'item-photos')
    and (storage.foldername(name))[1] = public.current_household_id()::text
  )
  with check (
    bucket_id in ('receipts', 'item-photos')
    and (storage.foldername(name))[1] = public.current_household_id()::text
  );

drop policy if exists household_storage_delete on storage.objects;
create policy household_storage_delete on storage.objects
  for delete to authenticated
  using (
    bucket_id in ('receipts', 'item-photos')
    and (storage.foldername(name))[1] = public.current_household_id()::text
  );

commit;
