-- Keep canonical inventory quantities separate from optional, directly
-- observed piece counts. A piece count is intentionally not converted to the
-- primary unit unless valid package conversion data exists.
alter table public.inventory
  add column if not exists individual_count integer,
  add column if not exists individual_unit text not null default 'pieces',
  add column if not exists individual_counted_at timestamptz;

alter table public.inventory
  drop constraint if exists inventory_individual_count_nonnegative_check;
alter table public.inventory
  add constraint inventory_individual_count_nonnegative_check
  check (individual_count is null or individual_count >= 0);

alter table public.inventory
  drop constraint if exists inventory_individual_unit_nonempty_check;
alter table public.inventory
  add constraint inventory_individual_unit_nonempty_check
  check (length(trim(individual_unit)) > 0);

-- Purchase date is the date printed on the receipt. uploaded_at and
-- confirmed_at continue to describe when the app processed the receipt.
alter table public.session_receipts
  add column if not exists purchase_date date;

update public.session_receipts
set purchase_date = (coalesce(uploaded_at, now()) at time zone 'UTC')::date
where purchase_date is null;

alter table public.session_receipts
  alter column purchase_date set default current_date,
  alter column purchase_date set not null;

create index if not exists session_receipts_household_purchase_date_idx
  on public.session_receipts (household_id, purchase_date desc);
create index if not exists purchase_log_household_purchased_at_idx
  on public.purchase_log (household_id, purchased_at desc);

-- The existing confirmation implementation remains the single source of its
-- grouping logic. Wrap it so date normalization and canonical-store cleanup
-- happen in the same database transaction.
alter function public.confirm_receipt_review(uuid, jsonb)
  rename to confirm_receipt_review_core;

revoke all on function public.confirm_receipt_review_core(uuid, jsonb)
  from public, anon, authenticated;

create function public.confirm_receipt_review(
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
  v_result jsonb;
  v_purchase_at timestamptz;
  v_existing_item_ids uuid[];
begin
  if v_household_id is null then raise exception 'No household access'; end if;

  select * into v_receipt
  from public.session_receipts
  where id = p_receipt_id and household_id = v_household_id
  for update;
  if not found then raise exception 'Receipt not found'; end if;

  -- Noon UTC preserves the selected calendar date across US time zones while
  -- keeping purchased_at compatible with existing time-based analytics.
  v_purchase_at := (v_receipt.purchase_date::timestamp + time '12:00') at time zone 'UTC';
  select coalesce(array_agg(id), array[]::uuid[]) into v_existing_item_ids
  from public.inventory where household_id = v_household_id;

  v_result := public.confirm_receipt_review_core(p_receipt_id, p_review_items);

  update public.purchase_log
  set purchased_at = v_purchase_at
  where household_id = v_household_id
    and id in (
      select value::uuid
      from jsonb_array_elements_text(coalesce(v_result->'purchase_ids', '[]'::jsonb))
    );

  update public.inventory_transactions
  set occurred_at = v_purchase_at
  where household_id = v_household_id and source_receipt_id = p_receipt_id;

  -- A canonical item is not a store listing. Store remains on the receipt,
  -- purchase observation, and store-specific alias.
  update public.inventory i
  set store = 'Other'
  where i.household_id = v_household_id
    and not (i.id = any(v_existing_item_ids))
    and i.id in (
      select p.item_id
      from public.purchase_log p
      where p.household_id = v_household_id
        and p.id in (
          select value::uuid
          from jsonb_array_elements_text(coalesce(v_result->'purchase_ids', '[]'::jsonb))
        )
    );

  update public.receipt_aliases
  set add_config = add_config - 'store'
  where household_id = v_household_id
    and store = coalesce(nullif(v_receipt.store_guess, ''), 'Other')
    and add_config is not null;

  return v_result || jsonb_build_object(
    'purchase_date', v_receipt.purchase_date,
    'store', coalesce(nullif(v_receipt.store_guess, ''), 'Other')
  );
end;
$$;

revoke all on function public.confirm_receipt_review(uuid, jsonb)
  from public, anon;
grant execute on function public.confirm_receipt_review(uuid, jsonb)
  to authenticated;

-- Cancelling a run atomically voids only unfinished receipts, clears cart
-- intent, and preserves every already-confirmed purchase and inventory entry.
create or replace function public.cancel_shopping_run(p_session_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_household_id uuid := public.current_household_id();
  v_session public.shopping_sessions%rowtype;
  v_voided integer := 0;
  v_cleared integer := 0;
  v_confirmed integer := 0;
  v_total numeric := 0;
begin
  if v_household_id is null then raise exception 'No household access'; end if;

  select * into v_session
  from public.shopping_sessions
  where id = p_session_id and household_id = v_household_id
  for update;
  if not found then raise exception 'Shopping run not found'; end if;
  if v_session.status <> 'active' then raise exception 'Shopping run is not active'; end if;

  update public.session_receipts
  set status = 'voided', processing_error = null
  where session_id = p_session_id
    and household_id = v_household_id
    and status in ('draft', 'needs_review', 'failed');
  get diagnostics v_voided = row_count;

  update public.inventory
  set checked_at = null, session_id = null, shopper_note = ''
  where household_id = v_household_id and session_id = p_session_id;
  get diagnostics v_cleared = row_count;

  select count(*), coalesce(sum(qty * price), 0)
  into v_confirmed, v_total
  from public.purchase_log
  where household_id = v_household_id and session_id = p_session_id;

  update public.shopping_sessions
  set status = 'cancelled', ended_at = now(), item_count = v_confirmed,
      total_spent = v_total, receipt_count = (
        select count(*) from public.session_receipts
        where household_id = v_household_id
          and session_id = p_session_id and status = 'confirmed'
      ), notes_summary = case
        when v_confirmed > 0 then 'Run cancelled; confirmed purchases preserved'
        else 'Run cancelled'
      end
  where id = p_session_id and household_id = v_household_id;

  return jsonb_build_object(
    'session_id', p_session_id,
    'status', 'cancelled',
    'voided_receipts', v_voided,
    'cleared_cart_items', v_cleared,
    'confirmed_purchases_preserved', v_confirmed
  );
end;
$$;

revoke all on function public.cancel_shopping_run(uuid) from public, anon;
grant execute on function public.cancel_shopping_run(uuid) to authenticated;

-- Extend the existing ledger RPC without changing its signature. Optional
-- individual piece observations are carried in metadata and copied to the
-- inventory snapshot for fast display.
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
  v_delta numeric := 0;
  v_after numeric;
  v_transaction_id uuid;
  v_individual_after integer;
  v_individual_waste integer;
  v_individual_unit text;
  v_has_individual_count boolean := coalesce(p_metadata, '{}'::jsonb) ? 'individual_count';
  v_has_individual_waste boolean := coalesce(p_metadata, '{}'::jsonb) ? 'individual_waste';
  v_record_metadata jsonb;
begin
  if v_household_id is null then raise exception 'No household access'; end if;
  if p_transaction_type not in ('physical_count', 'waste', 'manual_adjustment') then
    raise exception 'Unsupported inventory adjustment type';
  end if;
  if p_mode not in ('absolute', 'delta') then raise exception 'Unsupported quantity mode'; end if;
  if p_transaction_type = 'physical_count' and p_mode <> 'absolute' then
    raise exception 'Physical count requires an absolute quantity';
  end if;
  if p_quantity is null and not v_has_individual_count and not v_has_individual_waste then
    raise exception 'Quantity or individual count is required';
  end if;

  select * into v_item
  from public.inventory
  where id = p_inventory_item_id and household_id = v_household_id
  for update;
  if not found then raise exception 'Inventory item not found'; end if;

  if p_quantity is not null then
    if p_transaction_type = 'waste' then
      v_delta := -abs(p_quantity);
    elsif p_mode = 'absolute' then
      v_delta := p_quantity - v_item.current_qty;
    else
      v_delta := p_quantity;
    end if;
  end if;
  v_after := v_item.current_qty + v_delta;
  if v_after < 0 then raise exception 'Inventory quantity cannot be negative'; end if;

  v_individual_after := v_item.individual_count;
  v_individual_unit := coalesce(nullif(trim(p_metadata->>'individual_unit'), ''), v_item.individual_unit, 'pieces');
  if v_has_individual_count then
    v_individual_after := nullif(p_metadata->>'individual_count', '')::integer;
    if v_individual_after is null or v_individual_after < 0 then
      raise exception 'Individual count must be zero or greater';
    end if;
  elsif v_has_individual_waste then
    v_individual_waste := nullif(p_metadata->>'individual_waste', '')::integer;
    if v_individual_waste is null or v_individual_waste < 0 then
      raise exception 'Individual waste must be zero or greater';
    end if;
    if v_item.individual_count is null then
      raise exception 'Count individual pieces before recording piece waste';
    end if;
    v_individual_after := v_item.individual_count - v_individual_waste;
    if v_individual_after < 0 then raise exception 'Individual count cannot be negative'; end if;
  end if;

  update public.inventory
  set current_qty = v_after,
      quantity_source = case when p_transaction_type = 'physical_count' then 'counted' else 'estimated' end,
      last_verified_at = case when p_transaction_type = 'physical_count' then now() else last_verified_at end,
      individual_count = v_individual_after,
      individual_unit = v_individual_unit,
      individual_counted_at = case
        when v_has_individual_count then now()
        when v_has_individual_waste then coalesce(individual_counted_at, now())
        else individual_counted_at
      end
  where id = v_item.id and household_id = v_household_id;

  v_record_metadata := coalesce(p_metadata, '{}'::jsonb) || jsonb_build_object(
    'individual_count_before', v_item.individual_count,
    'individual_count_after', v_individual_after,
    'individual_unit', v_individual_unit
  );
  v_transaction_id := private.record_inventory_transaction(
    v_household_id, v_item.id, p_transaction_type, v_delta,
    v_item.current_qty, v_after, v_item.unit,
    null, null, p_reason, v_record_metadata, now()
  );

  return jsonb_build_object(
    'transaction_id', v_transaction_id,
    'inventory_item_id', v_item.id,
    'quantity_before', v_item.current_qty,
    'quantity_delta', v_delta,
    'quantity_after', v_after,
    'quantity_source', case when p_transaction_type = 'physical_count' then 'counted' else 'estimated' end,
    'individual_count', v_individual_after,
    'individual_unit', v_individual_unit
  );
end;
$$;

revoke all on function public.apply_inventory_adjustment(uuid, text, numeric, text, text, jsonb)
  from public, anon;
grant execute on function public.apply_inventory_adjustment(uuid, text, numeric, text, text, jsonb)
  to authenticated;
