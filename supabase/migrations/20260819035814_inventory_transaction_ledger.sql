-- Inventory quantities remain available on public.inventory for fast reads,
-- but every approved change is also captured in an append-only ledger.
alter table public.inventory
  add column if not exists storage_location text not null default 'Unassigned',
  add column if not exists quantity_source text not null default 'unverified',
  add column if not exists last_verified_at timestamptz;

alter table public.inventory
  drop constraint if exists inventory_quantity_source_check;
alter table public.inventory
  add constraint inventory_quantity_source_check
  check (quantity_source in ('counted', 'receipt_updated', 'estimated', 'unverified'));

create table if not exists public.inventory_transactions (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null default public.current_household_id()
    references public.households(id) on delete restrict,
  inventory_item_id uuid not null,
  transaction_type text not null,
  quantity_delta numeric not null,
  quantity_before numeric not null,
  quantity_after numeric not null,
  unit text not null,
  source_receipt_id uuid references public.session_receipts(id) on delete set null,
  source_purchase_id uuid references public.purchase_log(id) on delete set null,
  reason text,
  metadata jsonb not null default '{}'::jsonb,
  occurred_at timestamptz not null default now(),
  recorded_by uuid default auth.uid(),
  created_at timestamptz not null default now(),
  constraint inventory_transactions_item_fkey
    foreign key (household_id, inventory_item_id)
    references public.inventory(household_id, id) on delete restrict,
  constraint inventory_transactions_type_check
    check (transaction_type in (
      'opening_balance', 'receipt_purchase', 'physical_count', 'waste',
      'manual_adjustment', 'recipe_usage'
    )),
  constraint inventory_transactions_nonnegative_after_check
    check (quantity_after >= 0),
  constraint inventory_transactions_metadata_object_check
    check (jsonb_typeof(metadata) = 'object')
);

create index if not exists inventory_transactions_item_occurred_idx
  on public.inventory_transactions (inventory_item_id, occurred_at desc);
create index if not exists inventory_transactions_household_type_idx
  on public.inventory_transactions (household_id, transaction_type, occurred_at desc);
create index if not exists inventory_transactions_receipt_idx
  on public.inventory_transactions (source_receipt_id)
  where source_receipt_id is not null;
create index if not exists inventory_transactions_purchase_idx
  on public.inventory_transactions (source_purchase_id)
  where source_purchase_id is not null;

alter table public.inventory_transactions enable row level security;
drop policy if exists inventory_transactions_household_select on public.inventory_transactions;
create policy inventory_transactions_household_select
  on public.inventory_transactions for select to authenticated
  using (household_id = public.current_household_id());

revoke all on table public.inventory_transactions from anon, authenticated;
grant select on table public.inventory_transactions to authenticated;

-- This helper is kept out of the exposed public schema and is callable only by
-- the owner of the controlled SECURITY DEFINER functions below.
create or replace function private.record_inventory_transaction(
  p_household_id uuid,
  p_inventory_item_id uuid,
  p_transaction_type text,
  p_quantity_delta numeric,
  p_quantity_before numeric,
  p_quantity_after numeric,
  p_unit text,
  p_source_receipt_id uuid default null,
  p_source_purchase_id uuid default null,
  p_reason text default null,
  p_metadata jsonb default '{}'::jsonb,
  p_occurred_at timestamptz default now()
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_transaction_id uuid;
begin
  if (select auth.uid()) is null then raise exception 'Authentication required'; end if;
  if p_household_id is distinct from public.current_household_id() then
    raise exception 'Household access denied';
  end if;
  if not exists (
    select 1 from public.inventory
    where household_id = p_household_id and id = p_inventory_item_id
  ) then raise exception 'Inventory item not found'; end if;

  insert into public.inventory_transactions (
    household_id, inventory_item_id, transaction_type,
    quantity_delta, quantity_before, quantity_after, unit,
    source_receipt_id, source_purchase_id, reason, metadata,
    occurred_at, recorded_by
  ) values (
    p_household_id, p_inventory_item_id, p_transaction_type,
    p_quantity_delta, p_quantity_before, p_quantity_after, p_unit,
    p_source_receipt_id, p_source_purchase_id, p_reason,
    coalesce(p_metadata, '{}'::jsonb), p_occurred_at, (select auth.uid())
  ) returning id into v_transaction_id;

  return v_transaction_id;
end;
$$;

revoke all on function private.record_inventory_transaction(
  uuid, uuid, text, numeric, numeric, numeric, text,
  uuid, uuid, text, jsonb, timestamptz
) from public, anon, authenticated;

create or replace function public.apply_inventory_adjustment(
  p_inventory_item_id uuid,
  p_transaction_type text,
  p_quantity numeric,
  p_mode text default 'delta',
  p_reason text default null,
  p_metadata jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_household_id uuid := public.current_household_id();
  v_item public.inventory%rowtype;
  v_delta numeric;
  v_after numeric;
  v_transaction_id uuid;
begin
  if v_household_id is null then raise exception 'No household access'; end if;
  if p_transaction_type not in ('physical_count', 'waste', 'manual_adjustment') then
    raise exception 'Unsupported inventory adjustment type';
  end if;
  if p_mode not in ('absolute', 'delta') then raise exception 'Unsupported quantity mode'; end if;
  if p_quantity is null then raise exception 'Quantity is required'; end if;
  if p_transaction_type = 'physical_count' and p_mode <> 'absolute' then
    raise exception 'Physical count requires an absolute quantity';
  end if;

  select * into v_item
  from public.inventory
  where id = p_inventory_item_id and household_id = v_household_id
  for update;
  if not found then raise exception 'Inventory item not found'; end if;

  if p_transaction_type = 'waste' then
    v_delta := -abs(p_quantity);
  elsif p_mode = 'absolute' then
    v_delta := p_quantity - v_item.current_qty;
  else
    v_delta := p_quantity;
  end if;
  v_after := v_item.current_qty + v_delta;
  if v_after < 0 then raise exception 'Inventory quantity cannot be negative'; end if;

  update public.inventory
  set current_qty = v_after,
      quantity_source = case when p_transaction_type = 'physical_count' then 'counted' else 'estimated' end,
      last_verified_at = case when p_transaction_type = 'physical_count' then now() else last_verified_at end
  where id = v_item.id and household_id = v_household_id;

  v_transaction_id := private.record_inventory_transaction(
    v_household_id, v_item.id, p_transaction_type, v_delta,
    v_item.current_qty, v_after, v_item.unit,
    null, null, p_reason, p_metadata, now()
  );

  return jsonb_build_object(
    'transaction_id', v_transaction_id,
    'inventory_item_id', v_item.id,
    'quantity_before', v_item.current_qty,
    'quantity_delta', v_delta,
    'quantity_after', v_after,
    'quantity_source', case when p_transaction_type = 'physical_count' then 'counted' else 'estimated' end
  );
end;
$$;

revoke all on function public.apply_inventory_adjustment(uuid, text, numeric, text, text, jsonb)
  from public, anon;
grant execute on function public.apply_inventory_adjustment(uuid, text, numeric, text, text, jsonb)
  to authenticated;

-- Existing production quantities become explicit opening balances. No legacy
-- purchase is reinterpreted as usage or a verified physical count.
insert into public.inventory_transactions (
  household_id, inventory_item_id, transaction_type,
  quantity_delta, quantity_before, quantity_after, unit,
  reason, metadata, occurred_at, recorded_by
)
select
  i.household_id, i.id, 'opening_balance', i.current_qty,
  0, i.current_qty, i.unit, 'Legacy opening balance',
  jsonb_build_object('migration', 'inventory_transaction_ledger'),
  coalesce(i.updated_at, i.created_at, now()), null
from public.inventory i
where not exists (
  select 1 from public.inventory_transactions t
  where t.inventory_item_id = i.id and t.transaction_type = 'opening_balance'
);

-- Receipt aliases belong to a household. The legacy global key would make a
-- store's raw receipt text collide across different owners.
alter table public.receipt_aliases
  drop constraint if exists receipt_aliases_store_raw_name_key;
alter table public.receipt_aliases
  drop constraint if exists receipt_aliases_household_store_raw_name_key;
alter table public.receipt_aliases
  add constraint receipt_aliases_household_store_raw_name_key
  unique (household_id, store, raw_name);

-- Receipt confirmation now updates the snapshot, purchase history, aliases,
-- and ledger in one short transaction.
create or replace function public.confirm_receipt_review(
  p_receipt_id uuid,
  p_review_items jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_household_id uuid := public.current_household_id();
  v_receipt public.session_receipts%rowtype;
  v_line jsonb;
  v_action text;
  v_item public.inventory%rowtype;
  v_item_id uuid;
  v_purchase_id uuid;
  v_purchase_ids uuid[] := array[]::uuid[];
  v_store text;
  v_raw_name text;
  v_name text;
  v_category text;
  v_unit text;
  v_pack_size numeric;
  v_packages numeric;
  v_price numeric;
  v_before numeric;
  v_after numeric;
  v_updated integer := 0;
  v_added integer := 0;
begin
  if v_household_id is null then raise exception 'No household access'; end if;
  if jsonb_typeof(p_review_items) <> 'array' then
    raise exception 'Receipt review items must be an array';
  end if;

  select * into v_receipt
  from public.session_receipts
  where id = p_receipt_id and household_id = v_household_id
  for update;
  if not found then raise exception 'Receipt not found'; end if;
  if v_receipt.status = 'confirmed' then raise exception 'Receipt is already confirmed'; end if;
  v_store := coalesce(nullif(v_receipt.store_guess, ''), 'Other');

  for v_line in select value from jsonb_array_elements(p_review_items) loop
    v_action := coalesce(v_line->>'action', 'decide');
    if v_action = 'skip' then continue; end if;
    if v_action not in ('match', 'add') then
      raise exception 'Every receipt line needs an explicit action';
    end if;

    v_packages := greatest(coalesce(nullif(v_line->>'qty', '')::numeric, 1), 0);
    v_price := coalesce(nullif(v_line->>'price', '')::numeric, 0);
    v_raw_name := coalesce(nullif(v_line->>'raw', ''), nullif(v_line->>'name', ''));

    if v_action = 'match' then
      v_item_id := nullif(v_line->>'inventoryId', '')::uuid;
      select * into v_item
      from public.inventory
      where id = v_item_id and household_id = v_household_id
      for update;
      if not found then raise exception 'Matched inventory item not found'; end if;
      v_before := v_item.current_qty;
      v_after := v_before + (v_packages * coalesce(v_item.pack_size, 1));

      update public.inventory
      set current_qty = v_after,
          quantity_source = 'receipt_updated',
          price = case when coalesce((v_line->>'applyPrice')::boolean, false) and v_price > 0 then v_price else price end
      where id = v_item.id and household_id = v_household_id;

      insert into public.purchase_log (
        household_id, session_id, item_id, item_name, category, store, unit, qty, price
      ) values (
        v_household_id, v_receipt.session_id, v_item.id, v_item.name, v_item.category,
        v_store, v_item.unit, v_packages, v_price
      ) returning id into v_purchase_id;

      perform private.record_inventory_transaction(
        v_household_id, v_item.id, 'receipt_purchase', v_after - v_before,
        v_before, v_after, v_item.unit, v_receipt.id, v_purchase_id,
        'Confirmed receipt purchase',
        jsonb_build_object('packages', v_packages, 'pack_size', coalesce(v_item.pack_size, 1), 'store', v_store),
        now()
      );

      if v_raw_name is not null then
        insert into public.receipt_aliases (
          household_id, store, raw_name, inventory_id, inventory_name
        ) values (v_household_id, v_store, v_raw_name, v_item.id, v_item.name)
        on conflict (household_id, store, raw_name) do update
        set inventory_id = excluded.inventory_id,
            inventory_name = excluded.inventory_name,
            updated_at = now();
      end if;
      v_updated := v_updated + 1;
    else
      v_name := nullif(trim(v_line->>'addName'), '');
      if v_name is null then raise exception 'New inventory item needs a name'; end if;
      v_category := coalesce(nullif(v_line->>'addCategory', ''), 'Other');
      v_unit := coalesce(nullif(v_line->>'addUnit', ''), 'ct');
      v_pack_size := greatest(coalesce(nullif(v_line->>'addPackSize', '')::numeric, 1), 0);
      v_after := v_packages * v_pack_size;

      insert into public.inventory (
        household_id, name, category, store, unit, current_qty, par_level,
        price, note, pack_size, quantity_source
      ) values (
        v_household_id, v_name, v_category,
        coalesce(nullif(v_line->>'addStore', ''), v_store), v_unit,
        v_after, v_after, v_price, 'Added from confirmed receipt',
        v_pack_size, 'receipt_updated'
      ) returning * into v_item;

      insert into public.purchase_log (
        household_id, session_id, item_id, item_name, category, store, unit, qty, price
      ) values (
        v_household_id, v_receipt.session_id, v_item.id, v_item.name, v_item.category,
        v_item.store, v_item.unit, v_packages, v_price
      ) returning id into v_purchase_id;

      perform private.record_inventory_transaction(
        v_household_id, v_item.id, 'receipt_purchase', v_after,
        0, v_after, v_item.unit, v_receipt.id, v_purchase_id,
        'Confirmed receipt purchase',
        jsonb_build_object('packages', v_packages, 'pack_size', v_pack_size, 'store', v_item.store),
        now()
      );

      if v_raw_name is not null then
        insert into public.receipt_aliases (
          household_id, store, raw_name, inventory_id, inventory_name, add_config
        ) values (
          v_household_id, v_store, v_raw_name, v_item.id, v_item.name,
          jsonb_build_object('name', v_item.name, 'category', v_item.category,
            'store', v_item.store, 'unit', v_item.unit, 'packSize', v_item.pack_size)
        )
        on conflict (household_id, store, raw_name) do update
        set inventory_id = excluded.inventory_id,
            inventory_name = excluded.inventory_name,
            add_config = excluded.add_config,
            updated_at = now();
      end if;
      v_added := v_added + 1;
    end if;
    v_purchase_ids := array_append(v_purchase_ids, v_purchase_id);
  end loop;

  update public.session_receipts
  set status = 'confirmed', review_items = p_review_items,
      linked_purchase_ids = to_jsonb(v_purchase_ids), processing_error = null,
      confirmed_at = now()
  where id = p_receipt_id and household_id = v_household_id;

  return jsonb_build_object(
    'updated', v_updated, 'added', v_added,
    'purchase_ids', to_jsonb(v_purchase_ids)
  );
end;
$$;

revoke all on function public.confirm_receipt_review(uuid, jsonb) from public, anon;
grant execute on function public.confirm_receipt_review(uuid, jsonb) to authenticated;
