-- Reusable physical-count lists and resumable count sessions. Inventory is
-- changed only when a count is completed, and each submitted value is written
-- to the append-only inventory transaction ledger in the same transaction.

create table public.inventory_count_lists (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null default public.current_household_id()
    references public.households(id) on delete restrict,
  name text not null,
  count_type text not null default 'quick',
  storage_locations text[] not null default '{}'::text[],
  is_reusable boolean not null default true,
  archived_at timestamptz,
  created_by uuid not null default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint inventory_count_lists_household_id_id_key unique (household_id, id),
  constraint inventory_count_lists_name_check check (length(trim(name)) between 1 and 120),
  constraint inventory_count_lists_type_check check (count_type in ('quick', 'weekly_full', 'custom'))
);

create table public.inventory_count_list_items (
  household_id uuid not null default public.current_household_id(),
  count_list_id uuid not null,
  inventory_item_id uuid not null,
  position integer not null default 0 check (position >= 0),
  created_at timestamptz not null default now(),
  primary key (count_list_id, inventory_item_id),
  constraint inventory_count_list_items_list_fkey
    foreign key (household_id, count_list_id)
    references public.inventory_count_lists(household_id, id) on delete cascade,
  constraint inventory_count_list_items_inventory_fkey
    foreign key (household_id, inventory_item_id)
    references public.inventory(household_id, id) on delete restrict
);

create table public.inventory_count_sessions (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null default public.current_household_id()
    references public.households(id) on delete restrict,
  count_list_id uuid,
  count_type text not null,
  status text not null default 'active',
  storage_locations text[] not null default '{}'::text[],
  notes text,
  started_at timestamptz not null default now(),
  completed_at timestamptz,
  cancelled_at timestamptz,
  created_by uuid not null default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint inventory_count_sessions_household_id_id_key unique (household_id, id),
  constraint inventory_count_sessions_list_fkey
    foreign key (household_id, count_list_id)
    references public.inventory_count_lists(household_id, id) on delete restrict,
  constraint inventory_count_sessions_type_check check (count_type in ('quick', 'weekly_full', 'custom')),
  constraint inventory_count_sessions_status_check check (status in ('active', 'completed', 'cancelled'))
);

create table public.inventory_count_entries (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null default public.current_household_id(),
  count_session_id uuid not null,
  inventory_item_id uuid not null,
  expected_quantity numeric not null,
  counted_quantity numeric check (counted_quantity >= 0),
  unit text not null,
  position integer not null default 0 check (position >= 0),
  counted_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (count_session_id, inventory_item_id),
  constraint inventory_count_entries_session_fkey
    foreign key (household_id, count_session_id)
    references public.inventory_count_sessions(household_id, id) on delete cascade,
  constraint inventory_count_entries_inventory_fkey
    foreign key (household_id, inventory_item_id)
    references public.inventory(household_id, id) on delete restrict
);

create index inventory_count_lists_household_active_idx
  on public.inventory_count_lists (household_id, updated_at desc)
  where archived_at is null;
create index inventory_count_list_items_household_list_idx
  on public.inventory_count_list_items (household_id, count_list_id);
create index inventory_count_list_items_household_inventory_idx
  on public.inventory_count_list_items (household_id, inventory_item_id);
create index inventory_count_sessions_household_status_idx
  on public.inventory_count_sessions (household_id, status, started_at desc);
create index inventory_count_sessions_household_list_idx
  on public.inventory_count_sessions (household_id, count_list_id)
  where count_list_id is not null;
create index inventory_count_entries_household_session_idx
  on public.inventory_count_entries (household_id, count_session_id, position, inventory_item_id);
create index inventory_count_entries_household_inventory_idx
  on public.inventory_count_entries (household_id, inventory_item_id, counted_at desc);

create trigger inventory_count_lists_set_updated_at
  before update on public.inventory_count_lists
  for each row execute function public.update_updated_at();
create trigger inventory_count_sessions_set_updated_at
  before update on public.inventory_count_sessions
  for each row execute function public.update_updated_at();
create trigger inventory_count_entries_set_updated_at
  before update on public.inventory_count_entries
  for each row execute function public.update_updated_at();

alter table public.inventory_count_lists enable row level security;
alter table public.inventory_count_list_items enable row level security;
alter table public.inventory_count_sessions enable row level security;
alter table public.inventory_count_entries enable row level security;

create policy inventory_count_lists_household_select
  on public.inventory_count_lists for select to authenticated
  using (household_id = public.current_household_id());
create policy inventory_count_list_items_household_select
  on public.inventory_count_list_items for select to authenticated
  using (household_id = public.current_household_id());
create policy inventory_count_sessions_household_select
  on public.inventory_count_sessions for select to authenticated
  using (household_id = public.current_household_id());
create policy inventory_count_entries_household_select
  on public.inventory_count_entries for select to authenticated
  using (household_id = public.current_household_id());

revoke all on public.inventory_count_lists from anon, authenticated;
revoke all on public.inventory_count_list_items from anon, authenticated;
revoke all on public.inventory_count_sessions from anon, authenticated;
revoke all on public.inventory_count_entries from anon, authenticated;
grant select on public.inventory_count_lists to authenticated;
grant select on public.inventory_count_list_items to authenticated;
grant select on public.inventory_count_sessions to authenticated;
grant select on public.inventory_count_entries to authenticated;

create or replace function public.save_inventory_count_list(
  p_count_list_id uuid,
  p_name text,
  p_count_type text,
  p_inventory_item_ids jsonb,
  p_storage_locations text[] default '{}'::text[]
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_household_id uuid := public.current_household_id();
  v_count_list_id uuid;
  v_requested_count integer;
  v_inserted_count integer;
begin
  if (select auth.uid()) is null then raise exception 'Authentication required'; end if;
  if v_household_id is null then raise exception 'No household access'; end if;
  if nullif(trim(p_name), '') is null then raise exception 'Count list name is required'; end if;
  if p_count_type not in ('quick', 'weekly_full', 'custom') then raise exception 'Unsupported count type'; end if;
  if jsonb_typeof(p_inventory_item_ids) <> 'array' then raise exception 'Inventory item IDs must be an array'; end if;
  v_requested_count := jsonb_array_length(p_inventory_item_ids);
  if v_requested_count = 0 then raise exception 'A count list needs at least one item'; end if;

  if p_count_list_id is null then
    insert into public.inventory_count_lists (
      household_id, name, count_type, storage_locations, created_by
    ) values (
      v_household_id, trim(p_name), p_count_type,
      coalesce(p_storage_locations, '{}'::text[]), (select auth.uid())
    ) returning id into v_count_list_id;
  else
    update public.inventory_count_lists
    set name = trim(p_name), count_type = p_count_type,
        storage_locations = coalesce(p_storage_locations, '{}'::text[]),
        archived_at = null
    where id = p_count_list_id and household_id = v_household_id
    returning id into v_count_list_id;
    if v_count_list_id is null then raise exception 'Count list not found'; end if;
    delete from public.inventory_count_list_items
    where count_list_id = v_count_list_id and household_id = v_household_id;
  end if;

  insert into public.inventory_count_list_items (
    household_id, count_list_id, inventory_item_id, position
  )
  select v_household_id, v_count_list_id, i.id, (requested.ordinality - 1)::integer
  from jsonb_array_elements_text(p_inventory_item_ids) with ordinality as requested(item_id, ordinality)
  join public.inventory i
    on i.id = requested.item_id::uuid and i.household_id = v_household_id;
  get diagnostics v_inserted_count = row_count;

  if v_inserted_count <> v_requested_count then
    raise exception 'One or more count-list items are invalid or duplicated';
  end if;
  return v_count_list_id;
end;
$$;

create or replace function public.start_inventory_count(
  p_count_type text,
  p_count_list_id uuid default null,
  p_inventory_item_ids jsonb default '[]'::jsonb,
  p_storage_locations text[] default '{}'::text[]
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_household_id uuid := public.current_household_id();
  v_session_id uuid;
  v_requested_count integer;
  v_inserted_count integer;
begin
  if (select auth.uid()) is null then raise exception 'Authentication required'; end if;
  if v_household_id is null then raise exception 'No household access'; end if;
  if p_count_type not in ('quick', 'weekly_full', 'custom') then raise exception 'Unsupported count type'; end if;
  if p_count_list_id is null and jsonb_typeof(p_inventory_item_ids) <> 'array' then
    raise exception 'Inventory item IDs must be an array';
  end if;

  if p_count_list_id is not null then
    if not exists (
      select 1 from public.inventory_count_lists
      where id = p_count_list_id and household_id = v_household_id and archived_at is null
    ) then raise exception 'Count list not found'; end if;
    select count(*) into v_requested_count
    from public.inventory_count_list_items
    where count_list_id = p_count_list_id and household_id = v_household_id;
  else
    v_requested_count := jsonb_array_length(p_inventory_item_ids);
  end if;
  if v_requested_count = 0 then raise exception 'A count needs at least one item'; end if;

  insert into public.inventory_count_sessions (
    household_id, count_list_id, count_type, storage_locations, created_by
  ) values (
    v_household_id, p_count_list_id, p_count_type,
    coalesce(p_storage_locations, '{}'::text[]), (select auth.uid())
  ) returning id into v_session_id;

  if p_count_list_id is not null then
    insert into public.inventory_count_entries (
      household_id, count_session_id, inventory_item_id,
      expected_quantity, unit, position
    )
    select v_household_id, v_session_id, i.id, i.current_qty, i.unit, li.position
    from public.inventory_count_list_items li
    join public.inventory i
      on i.id = li.inventory_item_id and i.household_id = v_household_id
    where li.count_list_id = p_count_list_id and li.household_id = v_household_id
    order by li.position, i.name;
  else
    insert into public.inventory_count_entries (
      household_id, count_session_id, inventory_item_id,
      expected_quantity, unit, position
    )
    select v_household_id, v_session_id, i.id, i.current_qty, i.unit,
           (requested.ordinality - 1)::integer
    from jsonb_array_elements_text(p_inventory_item_ids) with ordinality as requested(item_id, ordinality)
    join public.inventory i
      on i.id = requested.item_id::uuid and i.household_id = v_household_id;
  end if;
  get diagnostics v_inserted_count = row_count;
  if v_inserted_count <> v_requested_count then
    raise exception 'One or more inventory items are invalid or duplicated';
  end if;
  return v_session_id;
end;
$$;

create or replace function public.record_inventory_count_entry(
  p_count_session_id uuid,
  p_inventory_item_id uuid,
  p_counted_quantity numeric
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_household_id uuid := public.current_household_id();
begin
  if (select auth.uid()) is null then raise exception 'Authentication required'; end if;
  if v_household_id is null then raise exception 'No household access'; end if;
  if p_counted_quantity is null or p_counted_quantity < 0 then
    raise exception 'Counted quantity must be zero or greater';
  end if;
  if not exists (
    select 1 from public.inventory_count_sessions
    where id = p_count_session_id and household_id = v_household_id and status = 'active'
    for update
  ) then raise exception 'Active count session not found'; end if;

  update public.inventory_count_entries
  set counted_quantity = p_counted_quantity, counted_at = now()
  where count_session_id = p_count_session_id
    and inventory_item_id = p_inventory_item_id
    and household_id = v_household_id;
  if not found then raise exception 'Count entry not found'; end if;
end;
$$;

create or replace function public.complete_inventory_count(
  p_count_session_id uuid,
  p_notes text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_household_id uuid := public.current_household_id();
  v_session public.inventory_count_sessions%rowtype;
  v_entry record;
  v_item public.inventory%rowtype;
  v_counted integer;
  v_total integer;
begin
  if (select auth.uid()) is null then raise exception 'Authentication required'; end if;
  if v_household_id is null then raise exception 'No household access'; end if;
  select * into v_session
  from public.inventory_count_sessions
  where id = p_count_session_id and household_id = v_household_id
  for update;
  if not found or v_session.status <> 'active' then raise exception 'Active count session not found'; end if;

  select count(*), count(counted_quantity) into v_total, v_counted
  from public.inventory_count_entries
  where count_session_id = v_session.id and household_id = v_household_id;
  if v_counted = 0 then raise exception 'Enter at least one physical count'; end if;
  if v_session.count_type = 'weekly_full' and v_counted <> v_total then
    raise exception 'Weekly full counts require every item';
  end if;

  perform i.id
  from public.inventory i
  join public.inventory_count_entries e on e.inventory_item_id = i.id
  where e.count_session_id = v_session.id
    and e.household_id = v_household_id
    and e.counted_quantity is not null
    and i.household_id = v_household_id
  order by i.id
  for update of i;

  for v_entry in
    select * from public.inventory_count_entries
    where count_session_id = v_session.id
      and household_id = v_household_id
      and counted_quantity is not null
    order by inventory_item_id
  loop
    select * into strict v_item
    from public.inventory
    where id = v_entry.inventory_item_id and household_id = v_household_id;

    update public.inventory
    set current_qty = v_entry.counted_quantity,
        quantity_source = 'counted',
        last_verified_at = coalesce(v_entry.counted_at, now())
    where id = v_item.id and household_id = v_household_id;

    perform private.record_inventory_transaction(
      v_household_id, v_item.id, 'physical_count',
      v_entry.counted_quantity - v_item.current_qty,
      v_item.current_qty, v_entry.counted_quantity, v_item.unit,
      null, null, 'Inventory count completed',
      jsonb_build_object(
        'count_session_id', v_session.id,
        'count_type', v_session.count_type,
        'count_list_id', v_session.count_list_id
      ),
      coalesce(v_entry.counted_at, now())
    );
  end loop;

  update public.inventory_count_sessions
  set status = 'completed', completed_at = now(), notes = nullif(trim(p_notes), '')
  where id = v_session.id and household_id = v_household_id;

  return jsonb_build_object(
    'count_session_id', v_session.id,
    'counted_items', v_counted,
    'total_items', v_total,
    'status', 'completed'
  );
end;
$$;

create or replace function public.cancel_inventory_count(p_count_session_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_household_id uuid := public.current_household_id();
begin
  if (select auth.uid()) is null then raise exception 'Authentication required'; end if;
  if v_household_id is null then raise exception 'No household access'; end if;
  update public.inventory_count_sessions
  set status = 'cancelled', cancelled_at = now()
  where id = p_count_session_id and household_id = v_household_id and status = 'active';
  if not found then raise exception 'Active count session not found'; end if;
end;
$$;

revoke all on function public.save_inventory_count_list(uuid, text, text, jsonb, text[]) from public, anon;
revoke all on function public.start_inventory_count(text, uuid, jsonb, text[]) from public, anon;
revoke all on function public.record_inventory_count_entry(uuid, uuid, numeric) from public, anon;
revoke all on function public.complete_inventory_count(uuid, text) from public, anon;
revoke all on function public.cancel_inventory_count(uuid) from public, anon;
grant execute on function public.save_inventory_count_list(uuid, text, text, jsonb, text[]) to authenticated;
grant execute on function public.start_inventory_count(text, uuid, jsonb, text[]) to authenticated;
grant execute on function public.record_inventory_count_entry(uuid, uuid, numeric) to authenticated;
grant execute on function public.complete_inventory_count(uuid, text) to authenticated;
grant execute on function public.cancel_inventory_count(uuid) to authenticated;
