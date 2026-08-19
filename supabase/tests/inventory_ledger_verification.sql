-- Transactional verification for physical counts, waste, manual adjustments,
-- append-only permissions, and inventory snapshot synchronization.
begin;

set local role authenticated;
select set_config(
  'request.jwt.claims',
  '{"sub":"10000000-0000-0000-0000-000000000001","role":"authenticated"}',
  true
);

do $$
begin
  if not exists (
    select 1 from public.inventory_transactions
    where inventory_item_id = '20000000-0000-0000-0000-000000000001'
      and transaction_type = 'opening_balance'
  ) then raise exception 'Legacy opening balance was not created'; end if;
end;
$$;

select public.apply_inventory_adjustment(
  '20000000-0000-0000-0000-000000000001',
  'physical_count', 7, 'absolute', 'Weekly full count',
  '{"count_type":"weekly"}'::jsonb
);

do $$
begin
  if not exists (
    select 1 from public.inventory
    where id = '20000000-0000-0000-0000-000000000001'
      and current_qty = 7 and quantity_source = 'counted' and last_verified_at is not null
  ) then raise exception 'Physical count did not update the inventory snapshot'; end if;
  if not exists (
    select 1 from public.inventory_transactions
    where inventory_item_id = '20000000-0000-0000-0000-000000000001'
      and transaction_type = 'physical_count'
      and quantity_before = 2 and quantity_delta = 5 and quantity_after = 7
  ) then raise exception 'Physical count ledger row is incorrect'; end if;
end;
$$;

select public.apply_inventory_adjustment(
  '20000000-0000-0000-0000-000000000001',
  'waste', 2, 'delta', 'Spoilage', '{"cause":"expired"}'::jsonb
);

do $$
begin
  if not exists (
    select 1 from public.inventory
    where id = '20000000-0000-0000-0000-000000000001'
      and current_qty = 5 and quantity_source = 'estimated'
  ) then raise exception 'Waste did not update the inventory snapshot'; end if;
  if not exists (
    select 1 from public.inventory_transactions
    where inventory_item_id = '20000000-0000-0000-0000-000000000001'
      and transaction_type = 'waste'
      and quantity_before = 7 and quantity_delta = -2 and quantity_after = 5
  ) then raise exception 'Waste ledger row is incorrect'; end if;
end;
$$;

-- Authenticated clients can read the ledger but cannot forge direct rows.
do $$
begin
  begin
    insert into public.inventory_transactions (
      inventory_item_id, transaction_type, quantity_delta,
      quantity_before, quantity_after, unit
    ) values (
      '20000000-0000-0000-0000-000000000001',
      'manual_adjustment', 100, 5, 105, 'lb'
    );
    raise exception 'Direct ledger insert was incorrectly allowed';
  exception
    when insufficient_privilege then null;
  end;
end;
$$;

-- A change that would make stock negative must fail without a ledger row.
do $$
declare before_count bigint;
begin
  select count(*) into before_count from public.inventory_transactions
  where inventory_item_id = '20000000-0000-0000-0000-000000000001';
  begin
    perform public.apply_inventory_adjustment(
      '20000000-0000-0000-0000-000000000001',
      'manual_adjustment', -100, 'delta', 'Invalid test', '{}'::jsonb
    );
    raise exception 'Negative inventory was incorrectly allowed';
  exception when others then
    if sqlerrm = 'Negative inventory was incorrectly allowed' then raise; end if;
  end;
  if (select current_qty from public.inventory where id = '20000000-0000-0000-0000-000000000001') <> 5 then
    raise exception 'Rejected adjustment changed inventory';
  end if;
  if (select count(*) from public.inventory_transactions where inventory_item_id = '20000000-0000-0000-0000-000000000001') <> before_count then
    raise exception 'Rejected adjustment wrote a ledger row';
  end if;
end;
$$;

rollback;
