begin;

-- Run only after the authenticated frontend is deployed and an owner account
-- has been verified. This migration performs the security cutover.
do $$
declare
  table_name text;
  household uuid;
  legacy_policy record;
begin
  if not exists (
    select 1
    from public.household_members
    where role = 'owner'
  ) then
    raise exception 'Security cutover requires a verified household owner';
  end if;

  select id into household
  from public.households
  order by created_at, id
  limit 1;

  foreach table_name in array array[
    'inventory', 'shopping_sessions', 'session_notes', 'purchase_log',
    'rider_payments', 'receipt_aliases', 'meals', 'meal_ingredients',
    'shop_quantities', 'session_receipts'
  ] loop
    execute format(
      'update public.%I set household_id = $1 where household_id is null',
      table_name
    ) using household;
    execute format(
      'alter table public.%I alter column household_id set not null',
      table_name
    );

    for legacy_policy in
      select polname
      from pg_policy
      where polrelid = format('public.%I', table_name)::regclass
        and polname <> table_name || '_household_access'
    loop
      execute format(
        'drop policy if exists %I on public.%I',
        legacy_policy.polname,
        table_name
      );
    end loop;

    execute format('revoke all on table public.%I from anon', table_name);
  end loop;
end;
$$;

revoke all on table public.households, public.profiles, public.household_members from anon;

update storage.buckets
set public = false
where id in ('receipts', 'item-photos');

drop policy if exists "public read item-photos" on storage.objects;
drop policy if exists "public write item-photos" on storage.objects;
drop policy if exists "public update item-photos" on storage.objects;
drop policy if exists "public delete item-photos" on storage.objects;
drop policy if exists "public read receipts" on storage.objects;
drop policy if exists "public write receipts" on storage.objects;
drop policy if exists "public update receipts" on storage.objects;
drop policy if exists "public delete receipts" on storage.objects;

commit;
