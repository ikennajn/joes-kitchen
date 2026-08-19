-- Transactional verification for reusable count lists, resumable entry
-- capture, quick counts, weekly full counts, cancellation, and ledger writes.
begin;

set local role authenticated;
select set_config(
  'request.jwt.claims',
  '{"sub":"10000000-0000-0000-0000-000000000001","role":"authenticated"}',
  true
);

insert into public.inventory (
  id, name, category, store, unit, current_qty, par_level, price, storage_location
) values (
  '20000000-0000-0000-0000-000000000002', 'Test Oil', 'Pantry', 'Other',
  'ct', 3, 4, 5, 'Dry storage'
);

do $$
declare
  list_id uuid;
  quick_session_id uuid;
  weekly_session_id uuid;
  cancelled_session_id uuid;
  rice_before numeric;
  oil_before numeric;
begin
  list_id := public.save_inventory_count_list(
    null, 'Post-cook essentials', 'quick',
    '["20000000-0000-0000-0000-000000000001","20000000-0000-0000-0000-000000000002"]'::jsonb,
    array['Unassigned', 'Dry storage']
  );
  if (
    select count(*) from public.inventory_count_list_items
    where count_list_id = list_id
  ) <> 2 then raise exception 'Reusable count list did not save both items'; end if;

  quick_session_id := public.start_inventory_count(
    'quick', list_id, '[]'::jsonb, array['Unassigned', 'Dry storage']
  );
  if (
    select count(*) from public.inventory_count_entries
    where count_session_id = quick_session_id
  ) <> 2 then raise exception 'Quick count did not snapshot both list items'; end if;

  perform public.record_inventory_count_entry(
    quick_session_id, '20000000-0000-0000-0000-000000000001', 5
  );
  perform public.complete_inventory_count(quick_session_id, 'Post-cook check');
  if (select status from public.inventory_count_sessions where id = quick_session_id) <> 'completed' then
    raise exception 'Quick count did not complete';
  end if;
  if (select current_qty from public.inventory where id = '20000000-0000-0000-0000-000000000001') <> 5 then
    raise exception 'Quick count did not update the counted item';
  end if;
  if (select current_qty from public.inventory where id = '20000000-0000-0000-0000-000000000002') <> 3 then
    raise exception 'Quick count changed an uncounted item';
  end if;
  if not exists (
    select 1 from public.inventory_transactions
    where inventory_item_id = '20000000-0000-0000-0000-000000000001'
      and transaction_type = 'physical_count'
      and metadata->>'count_session_id' = quick_session_id::text
      and quantity_before = 2 and quantity_after = 5
  ) then raise exception 'Quick count ledger row is missing'; end if;

  begin
    perform public.record_inventory_count_entry(
      quick_session_id, '20000000-0000-0000-0000-000000000002', 4
    );
    raise exception 'Completed count accepted another entry';
  exception when others then
    if sqlerrm = 'Completed count accepted another entry' then raise; end if;
  end;

  weekly_session_id := public.start_inventory_count(
    'weekly_full', null,
    '["20000000-0000-0000-0000-000000000001","20000000-0000-0000-0000-000000000002"]'::jsonb,
    array['Unassigned', 'Dry storage']
  );
  perform public.record_inventory_count_entry(
    weekly_session_id, '20000000-0000-0000-0000-000000000001', 6
  );
  select current_qty into rice_before from public.inventory
  where id = '20000000-0000-0000-0000-000000000001';
  select current_qty into oil_before from public.inventory
  where id = '20000000-0000-0000-0000-000000000002';
  begin
    perform public.complete_inventory_count(weekly_session_id, null);
    raise exception 'Incomplete weekly count was accepted';
  exception when others then
    if sqlerrm = 'Incomplete weekly count was accepted' then raise; end if;
  end;
  if (select current_qty from public.inventory where id = '20000000-0000-0000-0000-000000000001') <> rice_before
     or (select current_qty from public.inventory where id = '20000000-0000-0000-0000-000000000002') <> oil_before then
    raise exception 'Rejected weekly count changed inventory';
  end if;

  perform public.record_inventory_count_entry(
    weekly_session_id, '20000000-0000-0000-0000-000000000002', 4
  );
  perform public.complete_inventory_count(weekly_session_id, 'Weekly count');
  if (select current_qty from public.inventory where id = '20000000-0000-0000-0000-000000000001') <> 6
     or (select current_qty from public.inventory where id = '20000000-0000-0000-0000-000000000002') <> 4 then
    raise exception 'Completed weekly count did not update all items';
  end if;
  if (
    select count(*) from public.inventory_transactions
    where metadata->>'count_session_id' = weekly_session_id::text
      and transaction_type = 'physical_count'
  ) <> 2 then raise exception 'Weekly count did not write two ledger rows'; end if;

  cancelled_session_id := public.start_inventory_count(
    'quick', list_id, '[]'::jsonb, array['Unassigned', 'Dry storage']
  );
  perform public.cancel_inventory_count(cancelled_session_id);
  if (select status from public.inventory_count_sessions where id = cancelled_session_id) <> 'cancelled' then
    raise exception 'Count cancellation failed';
  end if;

  begin
    insert into public.inventory_count_sessions (count_type) values ('quick');
    raise exception 'Direct count-session insert was accepted';
  exception when insufficient_privilege then null;
  end;
end;
$$;

rollback;
