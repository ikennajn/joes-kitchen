-- Consolidate every confirmed receipt to one purchase and one inventory
-- transaction per canonical inventory item. Repeated OCR lines still retain
-- their combined package quantity and total cost.
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
  v_group jsonb;
  v_resolved_lines jsonb := '[]'::jsonb;
  v_action text;
  v_item public.inventory%rowtype;
  v_item_id uuid;
  v_purchase_id uuid;
  v_purchase_ids uuid[] := array[]::uuid[];
  v_store text;
  v_raw_name text;
  v_raw_alias text;
  v_name text;
  v_name_key text;
  v_category text;
  v_unit text;
  v_pack_size numeric;
  v_packages numeric;
  v_price numeric;
  v_before numeric;
  v_after numeric;
  v_quantity_delta numeric;
  v_total_cost numeric;
  v_purchase_price numeric;
  v_apply_price boolean;
  v_was_created boolean;
  v_requested_add boolean;
  v_source_line_count integer;
  v_updated integer := 0;
  v_added integer := 0;
  v_reused integer := 0;
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

  -- Resolve each review line first. This makes old, ungrouped drafts safe even
  -- when several lines request creation of the same canonical item.
  for v_line in select value from jsonb_array_elements(p_review_items) loop
    v_action := coalesce(v_line->>'action', 'decide');
    if v_action = 'skip' then continue; end if;
    if v_action not in ('match', 'add') then
      raise exception 'Every receipt line needs an explicit action';
    end if;

    v_packages := greatest(coalesce(nullif(v_line->>'qty', '')::numeric, 1), 0);
    v_price := greatest(coalesce(nullif(v_line->>'price', '')::numeric, 0), 0);
    v_raw_name := coalesce(nullif(v_line->>'raw', ''), nullif(v_line->>'name', ''));
    v_was_created := false;

    if v_action = 'match' then
      v_item_id := nullif(v_line->>'inventoryId', '')::uuid;
      select * into v_item
      from public.inventory
      where id = v_item_id and household_id = v_household_id
      for update;
      if not found then raise exception 'Matched inventory item not found'; end if;
    else
      v_name := nullif(regexp_replace(trim(v_line->>'addName'), '\s+', ' ', 'g'), '');
      if v_name is null then raise exception 'New inventory item needs a name'; end if;
      v_name_key := lower(v_name);
      v_category := coalesce(nullif(v_line->>'addCategory', ''), 'Other');
      v_unit := coalesce(nullif(v_line->>'addUnit', ''), 'ct');
      v_pack_size := greatest(coalesce(nullif(v_line->>'addPackSize', '')::numeric, 1), 0);
      if v_pack_size <= 0 then raise exception 'Pack size must be greater than zero'; end if;

      -- Serialize same-name creation attempts within a household, then reuse
      -- an existing canonical item instead of silently creating a duplicate.
      perform pg_advisory_xact_lock(hashtextextended(v_household_id::text || '|' || v_name_key, 0));
      select * into v_item
      from public.inventory
      where household_id = v_household_id
        and lower(regexp_replace(trim(name), '\s+', ' ', 'g')) = v_name_key
      order by created_at nulls last, id
      limit 1
      for update;

      if not found then
        insert into public.inventory (
          household_id, name, category, store, unit, current_qty, par_level,
          price, note, pack_size, quantity_source
        ) values (
          v_household_id, v_name, v_category,
          coalesce(nullif(v_line->>'addStore', ''), v_store), v_unit,
          0, 0, v_price, 'Added from confirmed receipt',
          v_pack_size, 'receipt_updated'
        ) returning * into v_item;
        v_was_created := true;
      end if;
    end if;

    -- Save every raw spelling represented by a grouped line. This preserves
    -- store-specific aliases even when the UI combines identical products.
    for v_raw_alias in
      select value #>> '{}'
      from jsonb_array_elements(
        case
          when jsonb_typeof(v_line->'rawLines') = 'array' then v_line->'rawLines'
          when v_raw_name is not null then jsonb_build_array(v_raw_name)
          else '[]'::jsonb
        end
      )
    loop
      if nullif(trim(v_raw_alias), '') is null then continue; end if;
      insert into public.receipt_aliases (
        household_id, store, raw_name, inventory_id, inventory_name, add_config
      ) values (
        v_household_id, v_store, v_raw_alias, v_item.id, v_item.name,
        case when v_action = 'add' then
          jsonb_build_object(
            'name', v_item.name, 'category', v_item.category,
            'store', v_item.store, 'unit', v_item.unit,
            'packSize', coalesce(v_item.pack_size, 1)
          )
        else null end
      )
      on conflict (household_id, store, raw_name) do update
      set inventory_id = excluded.inventory_id,
          inventory_name = excluded.inventory_name,
          add_config = coalesce(excluded.add_config, receipt_aliases.add_config),
          updated_at = now();
    end loop;

    v_resolved_lines := v_resolved_lines || jsonb_build_array(
      v_line || jsonb_build_object(
        '_item_id', v_item.id,
        '_packages', v_packages,
        '_line_cost', v_packages * v_price,
        '_quantity_delta', v_packages * coalesce(v_item.pack_size, 1),
        '_was_created', v_was_created,
        '_requested_add', v_action = 'add',
        '_source_line_count', greatest(coalesce(nullif(v_line->>'sourceLineCount', '')::integer, 1), 1),
        '_raw_name', v_raw_name
      )
    );
  end loop;

  -- Aggregate resolved lines by canonical inventory item. Purchase history,
  -- inventory quantity, and the ledger therefore receive exactly one row per
  -- item while retaining the full package quantity and spend.
  for v_group in
    select jsonb_build_object(
      'item_id', grouped.item_id,
      'packages', grouped.packages,
      'total_cost', grouped.total_cost,
      'quantity_delta', grouped.quantity_delta,
      'apply_price', grouped.apply_price,
      'was_created', grouped.was_created,
      'requested_add', grouped.requested_add,
      'source_line_count', grouped.source_line_count,
      'raw_names', grouped.raw_names
    )
    from (
      select
        resolved.item_id,
        sum(resolved.packages) as packages,
        sum(resolved.line_cost) as total_cost,
        sum(resolved.quantity_delta) as quantity_delta,
        bool_or(resolved.apply_price) as apply_price,
        bool_or(resolved.was_created) as was_created,
        bool_or(resolved.requested_add) as requested_add,
        sum(resolved.source_line_count) as source_line_count,
        jsonb_agg(distinct resolved.raw_name) filter (where resolved.raw_name is not null) as raw_names
      from (
        select
          (value->>'_item_id')::uuid as item_id,
          (value->>'_packages')::numeric as packages,
          (value->>'_line_cost')::numeric as line_cost,
          (value->>'_quantity_delta')::numeric as quantity_delta,
          coalesce((value->>'applyPrice')::boolean, false) as apply_price,
          (value->>'_was_created')::boolean as was_created,
          (value->>'_requested_add')::boolean as requested_add,
          (value->>'_source_line_count')::integer as source_line_count,
          nullif(value->>'_raw_name', '') as raw_name
        from jsonb_array_elements(v_resolved_lines)
      ) resolved
      group by resolved.item_id
    ) grouped
  loop
    v_item_id := (v_group->>'item_id')::uuid;
    v_packages := (v_group->>'packages')::numeric;
    v_total_cost := (v_group->>'total_cost')::numeric;
    v_quantity_delta := (v_group->>'quantity_delta')::numeric;
    v_apply_price := (v_group->>'apply_price')::boolean;
    v_was_created := (v_group->>'was_created')::boolean;
    v_requested_add := (v_group->>'requested_add')::boolean;
    v_source_line_count := (v_group->>'source_line_count')::integer;
    v_purchase_price := case when v_packages > 0 then v_total_cost / v_packages else 0 end;

    select * into v_item
    from public.inventory
    where id = v_item_id and household_id = v_household_id
    for update;
    if not found then raise exception 'Resolved inventory item not found'; end if;

    v_before := v_item.current_qty;
    v_after := v_before + v_quantity_delta;
    update public.inventory
    set current_qty = v_after,
        par_level = case when v_was_created and par_level = 0 then v_after else par_level end,
        quantity_source = 'receipt_updated',
        price = case
          when (v_was_created or v_apply_price) and v_purchase_price > 0 then v_purchase_price
          else price
        end
    where id = v_item.id and household_id = v_household_id;

    insert into public.purchase_log (
      household_id, session_id, item_id, item_name, category, store, unit, qty, price
    ) values (
      v_household_id, v_receipt.session_id, v_item.id, v_item.name,
      v_item.category, v_store, v_item.unit, v_packages, v_purchase_price
    ) returning id into v_purchase_id;

    perform private.record_inventory_transaction(
      v_household_id, v_item.id, 'receipt_purchase', v_quantity_delta,
      v_before, v_after, v_item.unit, v_receipt.id, v_purchase_id,
      'Confirmed receipt purchase',
      jsonb_build_object(
        'packages', v_packages,
        'pack_size', coalesce(v_item.pack_size, 1),
        'store', v_store,
        'source_line_count', v_source_line_count,
        'raw_names', coalesce(v_group->'raw_names', '[]'::jsonb)
      ),
      now()
    );

    if v_was_created then
      v_added := v_added + 1;
    elsif v_requested_add then
      v_reused := v_reused + 1;
    else
      v_updated := v_updated + 1;
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
    'reused', v_reused,
    'purchase_groups', coalesce(array_length(v_purchase_ids, 1), 0),
    'purchase_ids', to_jsonb(v_purchase_ids)
  );
end;
$$;

revoke all on function public.confirm_receipt_review(uuid, jsonb) from public, anon;
grant execute on function public.confirm_receipt_review(uuid, jsonb) to authenticated;
