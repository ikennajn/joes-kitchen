-- Transactional verification for shopping cancellation, receipt purchase
-- dates, canonical products, and independent piece counts.
begin;

set local role authenticated;
select set_config(
  'request.jwt.claims',
  '{"sub":"10000000-0000-0000-0000-000000000001","role":"authenticated"}',
  true
);

-- Direct piece counts do not manufacture a conversion to the primary unit.
select public.apply_inventory_adjustment(
  '20000000-0000-0000-0000-000000000001',
  'physical_count', null, 'absolute', 'Piece count test',
  '{"individual_count":20,"individual_unit":"pieces","source":"verification"}'::jsonb
);

select public.apply_inventory_adjustment(
  '20000000-0000-0000-0000-000000000001',
  'waste', null, 'delta', 'Piece waste test',
  '{"individual_waste":3,"individual_unit":"pieces","source":"verification"}'::jsonb
);

do $$
begin
  if not exists (
    select 1 from public.inventory
    where id = '20000000-0000-0000-0000-000000000001'
      and individual_count = 17 and individual_unit = 'pieces'
      and current_qty = 2
  ) then raise exception 'Independent piece count snapshot is incorrect'; end if;
  if not exists (
    select 1 from public.inventory_transactions
    where inventory_item_id = '20000000-0000-0000-0000-000000000001'
      and transaction_type = 'waste'
      and metadata->>'individual_count_after' = '17'
  ) then raise exception 'Piece waste was not recorded in the ledger'; end if;
end;
$$;

-- Receipt store and printed purchase date remain purchase observations. The
-- created inventory item stays canonical and store-neutral.
insert into public.shopping_sessions (id, status)
values ('41000000-0000-0000-0000-000000000001', 'active');

insert into public.session_receipts (
  id, session_id, status, store_guess, purchase_date,
  review_items, raw_items, item_count, total
) values (
  '51000000-0000-0000-0000-000000000001',
  '41000000-0000-0000-0000-000000000001',
  'needs_review', 'HMart', date '2026-07-04',
  '[]'::jsonb, '[]'::jsonb, 1, 8.99
);

select public.confirm_receipt_review(
  '51000000-0000-0000-0000-000000000001',
  jsonb_build_array(jsonb_build_object(
    'action', 'add', 'name', 'KEWPIE MAYO HMART', 'raw', 'KEWPIE MAYO',
    'qty', 1, 'price', 8.99, 'addName', 'Kewpie Mayo',
    'addCategory', 'Pantry', 'addUnit', 'ct', 'addPackSize', 1
  ))
);

do $$
begin
  if (select count(*) from public.inventory where name = 'Kewpie Mayo') <> 1 then
    raise exception 'Canonical inventory item was not created exactly once';
  end if;
  if (select store from public.inventory where name = 'Kewpie Mayo') <> 'Other' then
    raise exception 'Receipt store leaked into the canonical inventory item';
  end if;
  if not exists (
    select 1 from public.purchase_log
    where item_name = 'Kewpie Mayo' and store = 'HMart'
      and (purchased_at at time zone 'UTC')::date = date '2026-07-04'
  ) then raise exception 'Purchase did not retain receipt store and purchase date'; end if;
  if not exists (
    select 1 from public.inventory_transactions
    where source_receipt_id = '51000000-0000-0000-0000-000000000001'
      and (occurred_at at time zone 'UTC')::date = date '2026-07-04'
  ) then raise exception 'Ledger transaction did not use the receipt purchase date'; end if;
end;
$$;

-- Cancelling voids unfinished receipt work and cart intent, while a confirmed
-- receipt remains authoritative history.
insert into public.shopping_sessions (id, status)
values ('41000000-0000-0000-0000-000000000002', 'active');

update public.inventory
set session_id = '41000000-0000-0000-0000-000000000002', checked_at = now()
where id = '20000000-0000-0000-0000-000000000001';

insert into public.session_receipts (
  id, session_id, status, store_guess, purchase_date,
  review_items, raw_items, item_count, total
) values
  ('51000000-0000-0000-0000-000000000002', '41000000-0000-0000-0000-000000000002', 'needs_review', 'Costco', current_date, '[]'::jsonb, '[]'::jsonb, 1, 5),
  ('51000000-0000-0000-0000-000000000003', '41000000-0000-0000-0000-000000000002', 'confirmed', 'HMart', current_date, '[]'::jsonb, '[]'::jsonb, 1, 4);

insert into public.purchase_log (
  session_id, item_id, item_name, category, store, unit, qty, price
) values (
  '41000000-0000-0000-0000-000000000002',
  '20000000-0000-0000-0000-000000000001', 'Rice', 'Pantry', 'HMart', 'lb', 2, 2
);

select public.cancel_shopping_run('41000000-0000-0000-0000-000000000002');

do $$
begin
  if (select status from public.shopping_sessions where id = '41000000-0000-0000-0000-000000000002') <> 'cancelled' then
    raise exception 'Shopping run did not become cancelled';
  end if;
  if (select status from public.session_receipts where id = '51000000-0000-0000-0000-000000000002') <> 'voided' then
    raise exception 'Unfinished receipt was not voided';
  end if;
  if (select status from public.session_receipts where id = '51000000-0000-0000-0000-000000000003') <> 'confirmed' then
    raise exception 'Confirmed receipt was not preserved';
  end if;
  if exists (
    select 1 from public.inventory
    where id = '20000000-0000-0000-0000-000000000001'
      and (session_id is not null or checked_at is not null)
  ) then raise exception 'Cancelled cart intent was not cleared'; end if;
  if not exists (
    select 1 from public.purchase_log
    where session_id = '41000000-0000-0000-0000-000000000002'
  ) then raise exception 'Confirmed purchase was not preserved'; end if;
end;
$$;

rollback;
