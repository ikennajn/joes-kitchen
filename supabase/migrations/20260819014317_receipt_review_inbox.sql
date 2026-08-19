-- Persist receipt review independently from the scanner modal so a user can
-- leave an interrupted review and resume it from the active shopping run.
alter table public.session_receipts
  add column if not exists status text not null default 'confirmed',
  add column if not exists review_items jsonb not null default '[]'::jsonb,
  add column if not exists processing_error text,
  add column if not exists confirmed_at timestamptz,
  add column if not exists updated_at timestamptz not null default now();

update public.session_receipts
set confirmed_at = coalesce(confirmed_at, uploaded_at, now())
where status = 'confirmed';

alter table public.session_receipts
  drop constraint if exists session_receipts_status_check;

alter table public.session_receipts
  add constraint session_receipts_status_check
  check (status in ('draft', 'needs_review', 'confirmed', 'failed', 'voided'));

create index if not exists session_receipts_review_inbox_idx
  on public.session_receipts (household_id, status, uploaded_at desc);

drop trigger if exists session_receipts_set_updated_at on public.session_receipts;
create trigger session_receipts_set_updated_at
  before update on public.session_receipts
  for each row execute function public.update_updated_at();

-- Confirmation is one database transaction. A failed line rolls the entire
-- receipt back, preventing inventory and purchase history from diverging.
create or replace function public.confirm_receipt_review(
  p_receipt_id uuid,
  p_review_items jsonb
)
returns jsonb
language plpgsql
security invoker
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
  v_updated integer := 0;
  v_added integer := 0;
begin
  if v_household_id is null then
    raise exception 'No household access';
  end if;
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

      update public.inventory
      set current_qty = current_qty + (v_packages * coalesce(pack_size, 1)),
          price = case when coalesce((v_line->>'applyPrice')::boolean, false) and v_price > 0 then v_price else price end
      where id = v_item.id and household_id = v_household_id;

      insert into public.purchase_log (
        household_id, session_id, item_id, item_name, category, store, unit, qty, price
      ) values (
        v_household_id, v_receipt.session_id, v_item.id, v_item.name, v_item.category,
        v_store, v_item.unit, v_packages, v_price
      ) returning id into v_purchase_id;

      if v_raw_name is not null then
        insert into public.receipt_aliases (
          household_id, store, raw_name, inventory_id, inventory_name
        ) values (
          v_household_id, v_store, v_raw_name, v_item.id, v_item.name
        )
        on conflict (store, raw_name) do update
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

      insert into public.inventory (
        household_id, name, category, store, unit, current_qty, par_level, price, note, pack_size
      ) values (
        v_household_id, v_name, v_category,
        coalesce(nullif(v_line->>'addStore', ''), v_store), v_unit,
        v_packages * v_pack_size, v_packages * v_pack_size, v_price,
        'Added from confirmed receipt', v_pack_size
      ) returning * into v_item;

      insert into public.purchase_log (
        household_id, session_id, item_id, item_name, category, store, unit, qty, price
      ) values (
        v_household_id, v_receipt.session_id, v_item.id, v_item.name, v_item.category,
        v_item.store, v_item.unit, v_packages, v_price
      ) returning id into v_purchase_id;

      if v_raw_name is not null then
        insert into public.receipt_aliases (
          household_id, store, raw_name, inventory_id, inventory_name, add_config
        ) values (
          v_household_id, v_store, v_raw_name, v_item.id, v_item.name,
          jsonb_build_object('name', v_item.name, 'category', v_item.category,
            'store', v_item.store, 'unit', v_item.unit, 'packSize', v_item.pack_size)
        )
        on conflict (store, raw_name) do update
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
  set status = 'confirmed',
      review_items = p_review_items,
      linked_purchase_ids = to_jsonb(v_purchase_ids),
      processing_error = null,
      confirmed_at = now()
  where id = p_receipt_id and household_id = v_household_id;

  return jsonb_build_object(
    'updated', v_updated,
    'added', v_added,
    'purchase_ids', to_jsonb(v_purchase_ids)
  );
end;
$$;

revoke all on function public.confirm_receipt_review(uuid, jsonb) from public, anon;
grant execute on function public.confirm_receipt_review(uuid, jsonb) to authenticated;
