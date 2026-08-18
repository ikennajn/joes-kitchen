-- Read-only checks to run after applying 20260818000100_recipe_foundation.sql
-- in a disposable database. Each query should return zero rows unless noted.

-- Every Recipe Builder table exists with RLS enabled.
select expected.table_name
from unnest(array[
  'recipes', 'recipe_versions', 'recipe_processes', 'recipe_steps',
  'recipe_ingredients', 'recipe_step_ingredients', 'cooking_sessions',
  'cooking_events', 'cooking_timers', 'session_ingredient_usage'
]) as expected(table_name)
left join pg_class c on c.relname = expected.table_name
left join pg_namespace n on n.oid = c.relnamespace and n.nspname = 'public'
where c.oid is null or not c.relrowsecurity;

-- Anonymous users have no table privileges.
select table_name, privilege_type
from information_schema.role_table_grants
where table_schema = 'public'
  and grantee = 'anon'
  and table_name in (
    'recipes', 'recipe_versions', 'recipe_processes', 'recipe_steps',
    'recipe_ingredients', 'recipe_step_ingredients', 'cooking_sessions',
    'cooking_events', 'cooking_timers', 'session_ingredient_usage'
  );

-- Exactly one household policy exists on every Recipe Builder table.
select expected.table_name, count(p.policyname) as policy_count
from unnest(array[
  'recipes', 'recipe_versions', 'recipe_processes', 'recipe_steps',
  'recipe_ingredients', 'recipe_step_ingredients', 'cooking_sessions',
  'cooking_events', 'cooking_timers', 'session_ingredient_usage'
]) as expected(table_name)
left join pg_policies p
  on p.schemaname = 'public' and p.tablename = expected.table_name
group by expected.table_name
having count(p.policyname) <> 1;

-- Legacy meal backfill reconciliation.
select
  (select count(*) from public.meals) as legacy_meals,
  (select count(*) from public.recipes where legacy_meal_id is not null) as migrated_recipes,
  (select count(*) from public.meal_ingredients) as legacy_ingredients,
  (
    select count(*)
    from public.recipe_ingredients ri
    join public.recipe_versions rv on rv.id = ri.recipe_version_id
    join public.recipes r on r.id = rv.recipe_id
    where r.legacy_meal_id is not null and rv.version_number = 1
  ) as migrated_ingredients;

-- No recipe points at a version belonging to another recipe.
select r.id, r.current_version_id
from public.recipes r
join public.recipe_versions rv on rv.id = r.current_version_id
where rv.household_id <> r.household_id or rv.recipe_id <> r.id;

-- No step or ingredient allocation crosses its declared version.
select s.id
from public.recipe_steps s
join public.recipe_processes p on p.id = s.process_id
where p.household_id <> s.household_id
   or p.recipe_version_id <> s.recipe_version_id;

select si.id
from public.recipe_step_ingredients si
join public.recipe_steps s on s.id = si.recipe_step_id
join public.recipe_ingredients i on i.id = si.recipe_ingredient_id
where s.household_id <> si.household_id
   or i.household_id <> si.household_id
   or s.recipe_version_id <> si.recipe_version_id
   or i.recipe_version_id <> si.recipe_version_id;

-- Foreign-key columns without a left-prefix supporting index.
select conrelid::regclass as table_name, conname
from pg_constraint c
where c.contype = 'f'
  and c.connamespace = 'public'::regnamespace
  and c.conrelid in (
    'public.recipes'::regclass,
    'public.recipe_versions'::regclass,
    'public.recipe_processes'::regclass,
    'public.recipe_steps'::regclass,
    'public.recipe_ingredients'::regclass,
    'public.recipe_step_ingredients'::regclass,
    'public.cooking_sessions'::regclass,
    'public.cooking_events'::regclass,
    'public.cooking_timers'::regclass,
    'public.session_ingredient_usage'::regclass
  )
  and not exists (
    select 1
    from pg_index i
    where i.indrelid = c.conrelid
      and i.indisvalid
      and (i.indkey::smallint[])[0:cardinality(c.conkey)-1] = c.conkey
  );
