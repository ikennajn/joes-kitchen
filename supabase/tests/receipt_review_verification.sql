-- Transactional verification for the persistent receipt-review inbox.
-- All writes are rolled back after the assertions complete.
begin;

set local role authenticated;
select set_config(
  'request.jwt.claims',
  '{"sub":"10000000-0000-0000-0000-000000000001","role":"authenticated"}',
  true
);

insert into public.shopping_sessions (id, status)
values ('40000000-0000-0000-0000-000000000001', 'active');

insert into public.session_receipts (
  id, session_id, status, store_guess, review_items, raw_items, item_count, total
) values (
  '50000000-0000-0000-0000-000000000001',
  '40000000-0000-0000-0000-000000000001',
  'needs_review', 'Test Store', '[]'::jsonb, '[]'::jsonb, 3, 9.00
);

select public.confirm_receipt_review(
  '50000000-0000-0000-0000-000000000001',
  jsonb_build_array(
    jsonb_build_object(
      'action', 'match', 'inventoryId', '20000000-0000-0000-0000-000000000001',
      'name', 'Rice', 'raw', 'RICE 2LB', 'qty', 2, 'price', 2.00, 'applyPrice', true
    ),
    jsonb_build_object(
      'action', 'add', 'name', 'Beans', 'raw', 'BEANS CAN', 'qty', 1, 'price', 3.00,
      'addName', 'Test Beans', 'addCategory', 'Pantry', 'addStore', 'Test Store',
      'addUnit', 'ct', 'addPackSize', 1
    ),
    jsonb_build_object('action', 'skip', 'name', 'Bag fee', 'raw', 'BAG', 'qty', 1, 'price', 0.10)
  )
);

do $$
begin
  if (select current_qty from public.inventory where id = '20000000-0000-0000-0000-000000000001') <> 4 then
    raise exception 'Matched inventory quantity was not updated';
  end if;
  if (select price from public.inventory where id = '20000000-0000-0000-0000-000000000001') <> 2.00 then
    raise exception 'Matched inventory price was not updated';
  end if;
  if not exists (select 1 from public.inventory where name = 'Test Beans' and current_qty = 1) then
    raise exception 'Explicit create-item action did not create inventory';
  end if;
  if (select count(*) from public.purchase_log where session_id = '40000000-0000-0000-0000-000000000001') <> 2 then
    raise exception 'Confirmed receipt did not create exactly two purchases';
  end if;
  if not exists (
    select 1 from public.session_receipts
    where id = '50000000-0000-0000-0000-000000000001'
      and status = 'confirmed' and confirmed_at is not null
      and jsonb_array_length(linked_purchase_ids) = 2
  ) then
    raise exception 'Receipt did not transition to confirmed';
  end if;
  if (select count(*) from public.receipt_aliases where store = 'Test Store' and raw_name in ('RICE 2LB', 'BEANS CAN')) <> 2 then
    raise exception 'Confirmed aliases were not saved';
  end if;
  if (select count(*) from public.inventory_transactions where source_receipt_id = '50000000-0000-0000-0000-000000000001' and transaction_type = 'receipt_purchase') <> 2 then
    raise exception 'Confirmed receipt did not write the inventory ledger';
  end if;
end;
$$;

-- Repeated OCR lines must create one canonical item, purchase row, and ledger
-- row per product while preserving the combined package quantity and spend.
insert into public.session_receipts (
  id, session_id, status, store_guess, review_items, raw_items, item_count, total
) values (
  '50000000-0000-0000-0000-000000000003',
  '40000000-0000-0000-0000-000000000001',
  'needs_review', 'Test Store', '[]'::jsonb, '[]'::jsonb, 6, 48.00
);

select public.confirm_receipt_review(
  '50000000-0000-0000-0000-000000000003',
  jsonb_build_array(
    jsonb_build_object('action', 'add', 'name', 'Grouped Sauce', 'raw', 'GROUPED SAUCE', 'qty', 1, 'price', 9.00, 'addName', 'Grouped Sauce', 'addCategory', 'Pantry', 'addStore', 'Test Store', 'addUnit', 'ct', 'addPackSize', 1),
    jsonb_build_object('action', 'add', 'name', 'Grouped Sauce', 'raw', 'GROUPED SAUCE', 'qty', 1, 'price', 9.00, 'addName', 'Grouped Sauce', 'addCategory', 'Pantry', 'addStore', 'Test Store', 'addUnit', 'ct', 'addPackSize', 1),
    jsonb_build_object('action', 'add', 'name', 'Grouped Sauce', 'raw', 'GROUPED SAUCE', 'qty', 1, 'price', 9.00, 'addName', 'Grouped Sauce', 'addCategory', 'Pantry', 'addStore', 'Test Store', 'addUnit', 'ct', 'addPackSize', 1),
    jsonb_build_object('action', 'add', 'name', 'Grouped Seasoning', 'raw', 'GROUPED SEASONING', 'qty', 1, 'price', 7.00, 'addName', 'Grouped Seasoning', 'addCategory', 'Pantry', 'addStore', 'Test Store', 'addUnit', 'ct', 'addPackSize', 1),
    jsonb_build_object('action', 'add', 'name', 'Grouped Seasoning', 'raw', 'GROUPED SEASONING', 'qty', 1, 'price', 7.00, 'addName', 'Grouped Seasoning', 'addCategory', 'Pantry', 'addStore', 'Test Store', 'addUnit', 'ct', 'addPackSize', 1),
    jsonb_build_object('action', 'add', 'name', 'Grouped Seasoning', 'raw', 'GROUPED SEASONING', 'qty', 1, 'price', 7.00, 'addName', 'Grouped Seasoning', 'addCategory', 'Pantry', 'addStore', 'Test Store', 'addUnit', 'ct', 'addPackSize', 1)
  )
);

do $$
begin
  if (select count(*) from public.inventory where name = 'Grouped Sauce') <> 1 then
    raise exception 'Repeated sauce lines created duplicate inventory items';
  end if;
  if (select current_qty from public.inventory where name = 'Grouped Sauce') <> 3 then
    raise exception 'Repeated sauce quantity was not consolidated';
  end if;
  if (select count(*) from public.inventory where name = 'Grouped Seasoning') <> 1 then
    raise exception 'Repeated seasoning lines created duplicate inventory items';
  end if;
  if (select current_qty from public.inventory where name = 'Grouped Seasoning') <> 3 then
    raise exception 'Repeated seasoning quantity was not consolidated';
  end if;
  if (select count(*) from public.purchase_log where session_id = '40000000-0000-0000-0000-000000000001' and item_name in ('Grouped Sauce', 'Grouped Seasoning')) <> 2 then
    raise exception 'Repeated lines did not consolidate to two purchase rows';
  end if;
  if exists (
    select 1 from public.purchase_log
    where session_id = '40000000-0000-0000-0000-000000000001'
      and item_name in ('Grouped Sauce', 'Grouped Seasoning')
      and qty <> 3
  ) then raise exception 'Consolidated purchase quantity is incorrect'; end if;
  if (select count(*) from public.inventory_transactions where source_receipt_id = '50000000-0000-0000-0000-000000000003' and transaction_type = 'receipt_purchase') <> 2 then
    raise exception 'Repeated lines did not consolidate to two ledger rows';
  end if;
  if not exists (
    select 1 from public.session_receipts
    where id = '50000000-0000-0000-0000-000000000003'
      and status = 'confirmed' and jsonb_array_length(linked_purchase_ids) = 2
  ) then raise exception 'Grouped receipt did not link two purchases'; end if;
end;
$$;

-- A later create request with the same normalized name must reuse the
-- canonical item instead of creating another one.
insert into public.session_receipts (
  id, session_id, status, store_guess, review_items, raw_items, item_count, total
) values (
  '50000000-0000-0000-0000-000000000004',
  '40000000-0000-0000-0000-000000000001',
  'needs_review', 'Test Store', '[]'::jsonb, '[]'::jsonb, 2, 20.00
);

do $$
declare result jsonb;
begin
  select public.confirm_receipt_review(
    '50000000-0000-0000-0000-000000000004',
    jsonb_build_array(
      jsonb_build_object('action', 'add', 'name', 'Grouped Sauce', 'raw', 'GROUPED SAUCE LARGE', 'qty', 1, 'price', 10.00, 'addName', '  Grouped   Sauce  ', 'addCategory', 'Pantry', 'addStore', 'Test Store', 'addUnit', 'ct', 'addPackSize', 1),
      jsonb_build_object('action', 'add', 'name', 'Grouped Sauce', 'raw', 'GROUPED SAUCE LARGE', 'qty', 1, 'price', 10.00, 'addName', 'Grouped Sauce', 'addCategory', 'Pantry', 'addStore', 'Test Store', 'addUnit', 'ct', 'addPackSize', 1)
    )
  ) into result;

  if (result->>'reused')::integer <> 1 then
    raise exception 'Existing canonical item was not reported as reused';
  end if;
  if (select count(*) from public.inventory where name = 'Grouped Sauce') <> 1 then
    raise exception 'Later create request duplicated the canonical item';
  end if;
  if (select current_qty from public.inventory where name = 'Grouped Sauce') <> 5 then
    raise exception 'Reused canonical item did not receive combined quantity';
  end if;
  if (select count(*) from public.inventory_transactions where source_receipt_id = '50000000-0000-0000-0000-000000000004') <> 1 then
    raise exception 'Reused item did not consolidate to one ledger row';
  end if;
end;
$$;

-- An unresolved line must fail and roll back the whole attempted confirmation.
insert into public.session_receipts (
  id, session_id, status, store_guess, review_items, raw_items, item_count, total
) values (
  '50000000-0000-0000-0000-000000000002',
  '40000000-0000-0000-0000-000000000001',
  'needs_review', 'Test Store', '[]'::jsonb, '[]'::jsonb, 2, 4.00
);

do $$
declare
  before_qty numeric;
begin
  select current_qty into before_qty from public.inventory where id = '20000000-0000-0000-0000-000000000001';
  begin
    perform public.confirm_receipt_review(
      '50000000-0000-0000-0000-000000000002',
      jsonb_build_array(
        jsonb_build_object(
          'action', 'match', 'inventoryId', '20000000-0000-0000-0000-000000000001',
          'name', 'Rice', 'raw', 'RICE', 'qty', 1, 'price', 2.00
        ),
        jsonb_build_object('action', 'decide', 'name', 'Unknown line', 'raw', 'UNKNOWN', 'qty', 1, 'price', 2.00)
      )
    );
    raise exception 'Unresolved receipt line was incorrectly accepted';
  exception
    when others then
      if sqlerrm = 'Unresolved receipt line was incorrectly accepted' then raise; end if;
  end;
  if (select current_qty from public.inventory where id = '20000000-0000-0000-0000-000000000001') <> before_qty then
    raise exception 'Failed confirmation did not roll back inventory';
  end if;
  if (select status from public.session_receipts where id = '50000000-0000-0000-0000-000000000002') <> 'needs_review' then
    raise exception 'Failed confirmation changed receipt status';
  end if;
end;
$$;

rollback;
