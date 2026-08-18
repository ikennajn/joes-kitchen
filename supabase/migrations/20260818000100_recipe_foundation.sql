begin;

-- Additive Recipe Builder foundation. Legacy meals remain intact for compatibility.

alter table public.inventory
  add constraint inventory_household_id_id_key unique (household_id, id);

alter table public.meals
  add constraint meals_household_id_id_key unique (household_id, id);

create table public.recipes (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null default public.current_household_id(),
  name text not null check (btrim(name) <> ''),
  description text,
  status text not null default 'draft'
    check (status in ('draft', 'published', 'archived')),
  current_version_id uuid,
  legacy_meal_id uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint recipes_household_id_fkey
    foreign key (household_id) references public.households(id) on delete restrict,
  constraint recipes_household_id_id_key unique (household_id, id),
  constraint recipes_household_legacy_meal_key unique (household_id, legacy_meal_id),
  constraint recipes_legacy_meal_fkey
    foreign key (household_id, legacy_meal_id)
    references public.meals(household_id, id)
    on delete set null (legacy_meal_id)
);

create table public.recipe_versions (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null default public.current_household_id(),
  recipe_id uuid not null,
  version_number integer not null check (version_number > 0),
  status text not null default 'draft'
    check (status in ('draft', 'published', 'superseded')),
  yield_quantity numeric check (yield_quantity > 0),
  yield_unit text check (yield_unit is null or btrim(yield_unit) <> ''),
  serving_size_quantity numeric check (serving_size_quantity > 0),
  serving_size_unit text check (serving_size_unit is null or btrim(serving_size_unit) <> ''),
  description text,
  notes text,
  published_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint recipe_versions_publish_state_check check (
    (status = 'published' and published_at is not null)
    or (status <> 'published')
  ),
  constraint recipe_versions_household_id_fkey
    foreign key (household_id) references public.households(id) on delete restrict,
  constraint recipe_versions_recipe_fkey
    foreign key (household_id, recipe_id)
    references public.recipes(household_id, id) on delete cascade,
  constraint recipe_versions_household_id_id_key unique (household_id, id),
  constraint recipe_versions_recipe_id_id_key unique (household_id, recipe_id, id),
  constraint recipe_versions_number_key unique (household_id, recipe_id, version_number)
);

alter table public.recipes
  add constraint recipes_current_version_fkey
  foreign key (household_id, id, current_version_id)
  references public.recipe_versions(household_id, recipe_id, id)
  on delete set null (current_version_id);

create table public.recipe_processes (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null default public.current_household_id(),
  recipe_version_id uuid not null,
  name text not null check (btrim(name) <> ''),
  position integer not null default 0 check (position >= 0),
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint recipe_processes_household_id_fkey
    foreign key (household_id) references public.households(id) on delete restrict,
  constraint recipe_processes_version_fkey
    foreign key (household_id, recipe_version_id)
    references public.recipe_versions(household_id, id) on delete cascade,
  constraint recipe_processes_household_id_id_key unique (household_id, id),
  constraint recipe_processes_version_id_id_key
    unique (household_id, recipe_version_id, id),
  constraint recipe_processes_position_key unique (household_id, recipe_version_id, position)
);

create table public.recipe_steps (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null default public.current_household_id(),
  recipe_version_id uuid not null,
  process_id uuid not null,
  position integer not null default 0 check (position >= 0),
  instruction text not null check (btrim(instruction) <> ''),
  expected_duration_seconds integer check (expected_duration_seconds >= 0),
  temperature_value numeric,
  temperature_unit text check (temperature_unit is null or temperature_unit in ('f', 'c')),
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint recipe_steps_household_id_fkey
    foreign key (household_id) references public.households(id) on delete restrict,
  constraint recipe_steps_version_fkey
    foreign key (household_id, recipe_version_id)
    references public.recipe_versions(household_id, id) on delete cascade,
  constraint recipe_steps_process_fkey
    foreign key (household_id, recipe_version_id, process_id)
    references public.recipe_processes(household_id, recipe_version_id, id) on delete cascade,
  constraint recipe_steps_household_id_id_key unique (household_id, id),
  constraint recipe_steps_version_id_id_key
    unique (household_id, recipe_version_id, id),
  constraint recipe_steps_position_key unique (household_id, process_id, position)
);

create table public.recipe_ingredients (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null default public.current_household_id(),
  recipe_version_id uuid not null,
  inventory_item_id uuid,
  ingredient_name text not null check (btrim(ingredient_name) <> ''),
  quantity numeric not null check (quantity > 0),
  unit text not null check (btrim(unit) <> ''),
  measurement_dimension text not null default 'other'
    check (measurement_dimension in ('weight', 'volume', 'count', 'other')),
  preparation_note text,
  position integer not null default 0 check (position >= 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint recipe_ingredients_household_id_fkey
    foreign key (household_id) references public.households(id) on delete restrict,
  constraint recipe_ingredients_version_fkey
    foreign key (household_id, recipe_version_id)
    references public.recipe_versions(household_id, id) on delete cascade,
  constraint recipe_ingredients_inventory_fkey
    foreign key (household_id, inventory_item_id)
    references public.inventory(household_id, id)
    on delete set null (inventory_item_id),
  constraint recipe_ingredients_household_id_id_key unique (household_id, id),
  constraint recipe_ingredients_version_id_id_key
    unique (household_id, recipe_version_id, id),
  constraint recipe_ingredients_position_key unique (household_id, recipe_version_id, position)
);

create table public.recipe_step_ingredients (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null default public.current_household_id(),
  recipe_version_id uuid not null,
  recipe_step_id uuid not null,
  recipe_ingredient_id uuid not null,
  quantity numeric not null check (quantity > 0),
  unit text not null check (btrim(unit) <> ''),
  position integer not null default 0 check (position >= 0),
  note text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint recipe_step_ingredients_household_id_fkey
    foreign key (household_id) references public.households(id) on delete restrict,
  constraint recipe_step_ingredients_step_fkey
    foreign key (household_id, recipe_version_id, recipe_step_id)
    references public.recipe_steps(household_id, recipe_version_id, id) on delete cascade,
  constraint recipe_step_ingredients_ingredient_fkey
    foreign key (household_id, recipe_version_id, recipe_ingredient_id)
    references public.recipe_ingredients(household_id, recipe_version_id, id) on delete cascade,
  constraint recipe_step_ingredients_position_key
    unique (household_id, recipe_step_id, position)
);

create index recipes_household_lower_name_idx
  on public.recipes (household_id, lower(name));
create index recipes_current_version_fk_idx
  on public.recipes (household_id, id, current_version_id);
create index recipe_steps_process_fk_idx
  on public.recipe_steps (household_id, recipe_version_id, process_id);
create index recipe_ingredients_inventory_fk_idx
  on public.recipe_ingredients (household_id, inventory_item_id);
create index recipe_step_ingredients_step_fk_idx
  on public.recipe_step_ingredients (household_id, recipe_version_id, recipe_step_id);
create index recipe_step_ingredients_ingredient_fk_idx
  on public.recipe_step_ingredients (household_id, recipe_version_id, recipe_ingredient_id);

-- Reuse the application's existing updated_at trigger function.
create trigger recipes_set_updated_at
  before update on public.recipes
  for each row execute function public.update_updated_at();
create trigger recipe_versions_set_updated_at
  before update on public.recipe_versions
  for each row execute function public.update_updated_at();
create trigger recipe_processes_set_updated_at
  before update on public.recipe_processes
  for each row execute function public.update_updated_at();
create trigger recipe_steps_set_updated_at
  before update on public.recipe_steps
  for each row execute function public.update_updated_at();
create trigger recipe_ingredients_set_updated_at
  before update on public.recipe_ingredients
  for each row execute function public.update_updated_at();
create trigger recipe_step_ingredients_set_updated_at
  before update on public.recipe_step_ingredients
  for each row execute function public.update_updated_at();

-- Backfill legacy Meals as published version 1 recipes. Provenance makes this idempotent.
insert into public.recipes (
  household_id, name, description, status, legacy_meal_id
)
select m.household_id, m.name, m.note, 'published', m.id
from public.meals m
on conflict (household_id, legacy_meal_id) do nothing;

insert into public.recipe_versions (
  household_id, recipe_id, version_number, status,
  yield_quantity, yield_unit, notes, published_at
)
select r.household_id, r.id, 1, 'published',
       greatest(coalesce(m.portions, 1), 1), 'servings', m.note, now()
from public.recipes r
join public.meals m
  on m.household_id = r.household_id and m.id = r.legacy_meal_id
on conflict (household_id, recipe_id, version_number) do nothing;

insert into public.recipe_ingredients (
  household_id, recipe_version_id, inventory_item_id, ingredient_name,
  quantity, unit, measurement_dimension, position
)
select mi.household_id, rv.id, mi.item_id, i.name,
       mi.qty_per_batch, coalesce(nullif(btrim(mi.unit), ''), i.unit),
       case
         when lower(coalesce(nullif(btrim(mi.unit), ''), i.unit)) in
           ('oz', 'lb', 'g', 'kg') then 'weight'
         when lower(coalesce(nullif(btrim(mi.unit), ''), i.unit)) in
           ('tsp', 'tbsp', 'fl oz', 'cup', 'pt', 'qt', 'gal', 'ml', 'l') then 'volume'
         when lower(coalesce(nullif(btrim(mi.unit), ''), i.unit)) in
           ('ct', 'each', 'item', 'items') then 'count'
         else 'other'
       end,
       row_number() over (partition by mi.household_id, mi.meal_id order by i.name, mi.item_id) - 1
from public.meal_ingredients mi
join public.recipes r
  on r.household_id = mi.household_id and r.legacy_meal_id = mi.meal_id
join public.recipe_versions rv
  on rv.household_id = r.household_id and rv.recipe_id = r.id and rv.version_number = 1
join public.inventory i
  on i.household_id = mi.household_id and i.id = mi.item_id
on conflict (household_id, recipe_version_id, position) do nothing;

update public.recipes r
set current_version_id = rv.id,
    updated_at = now()
from public.recipe_versions rv
where rv.household_id = r.household_id
  and rv.recipe_id = r.id
  and rv.version_number = 1
  and r.legacy_meal_id is not null
  and r.current_version_id is null;

do $$
declare
  table_name text;
  policy_name text;
begin
  foreach table_name in array array[
    'recipes', 'recipe_versions', 'recipe_processes', 'recipe_steps',
    'recipe_ingredients', 'recipe_step_ingredients'
  ] loop
    execute format('alter table public.%I enable row level security', table_name);
    policy_name := table_name || '_household_access';
    execute format(
      'create policy %I on public.%I for all to authenticated using (household_id = (select public.current_household_id())) with check (household_id = (select public.current_household_id()))',
      policy_name, table_name
    );
    execute format('revoke all on table public.%I from public, anon, authenticated', table_name);
    execute format('grant select, insert, update, delete on table public.%I to authenticated', table_name);
  end loop;
end;
$$;

commit;
