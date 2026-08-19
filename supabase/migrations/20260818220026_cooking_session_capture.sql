begin;

create table public.cooking_sessions (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null default public.current_household_id(),
  recipe_id uuid,
  recipe_version_id uuid,
  mode text not null check (mode in ('build', 'cook')),
  status text not null default 'active' check (status in ('active', 'paused', 'review', 'completed', 'abandoned')),
  started_at timestamptz not null default now(),
  completed_at timestamptz,
  yield_quantity numeric check (yield_quantity is null or yield_quantity > 0),
  yield_unit text,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint cooking_sessions_household_id_fkey foreign key (household_id) references public.households(id) on delete restrict,
  constraint cooking_sessions_recipe_fkey foreign key (household_id, recipe_id) references public.recipes(household_id, id) on delete restrict,
  constraint cooking_sessions_version_fkey foreign key (household_id, recipe_version_id) references public.recipe_versions(household_id, id) on delete restrict,
  constraint cooking_sessions_household_id_id_key unique (household_id, id),
  constraint cooking_sessions_completion_check check ((status = 'completed' and completed_at is not null) or status <> 'completed')
);

create table public.cooking_events (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null default public.current_household_id(),
  cooking_session_id uuid not null,
  event_sequence bigint generated always as identity,
  occurred_at timestamptz not null default now(),
  event_type text not null check (event_type in ('session_started','ingredient_added','ingredient_adjusted','timer_started','timer_paused','timer_resumed','timer_stopped','step_started','step_completed','note','observation','correction')),
  process_id uuid,
  recipe_step_id uuid,
  inventory_item_id uuid,
  ingredient_name text,
  quantity numeric check (quantity is null or quantity > 0),
  unit text,
  duration_seconds integer check (duration_seconds is null or duration_seconds >= 0),
  temperature_value numeric,
  temperature_unit text check (temperature_unit is null or temperature_unit in ('f','c')),
  raw_transcript text,
  structured_data jsonb,
  supersedes_event_id uuid,
  confirmed_at timestamptz,
  created_at timestamptz not null default now(),
  constraint cooking_events_household_id_fkey foreign key (household_id) references public.households(id) on delete restrict,
  constraint cooking_events_session_fkey foreign key (household_id, cooking_session_id) references public.cooking_sessions(household_id, id) on delete cascade,
  constraint cooking_events_process_fkey foreign key (household_id, process_id) references public.recipe_processes(household_id, id) on delete set null (process_id),
  constraint cooking_events_step_fkey foreign key (household_id, recipe_step_id) references public.recipe_steps(household_id, id) on delete set null (recipe_step_id),
  constraint cooking_events_inventory_fkey foreign key (household_id, inventory_item_id) references public.inventory(household_id, id) on delete set null (inventory_item_id),
  constraint cooking_events_supersedes_fkey foreign key (household_id, supersedes_event_id) references public.cooking_events(household_id, id) on delete set null (supersedes_event_id),
  constraint cooking_events_household_id_id_key unique (household_id, id)
);

create table public.cooking_timers (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null default public.current_household_id(),
  cooking_session_id uuid not null,
  process_id uuid,
  recipe_step_id uuid,
  name text not null check (btrim(name) <> ''),
  status text not null default 'running' check (status in ('running','paused','stopped','cancelled')),
  started_at timestamptz not null default now(),
  paused_at timestamptz,
  stopped_at timestamptz,
  paused_duration_seconds integer not null default 0 check (paused_duration_seconds >= 0),
  target_duration_seconds integer check (target_duration_seconds is null or target_duration_seconds >= 0),
  final_duration_seconds integer check (final_duration_seconds is null or final_duration_seconds >= 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint cooking_timers_household_id_fkey foreign key (household_id) references public.households(id) on delete restrict,
  constraint cooking_timers_session_fkey foreign key (household_id, cooking_session_id) references public.cooking_sessions(household_id, id) on delete cascade,
  constraint cooking_timers_process_fkey foreign key (household_id, process_id) references public.recipe_processes(household_id, id) on delete set null (process_id),
  constraint cooking_timers_step_fkey foreign key (household_id, recipe_step_id) references public.recipe_steps(household_id, id) on delete set null (recipe_step_id),
  constraint cooking_timers_household_id_id_key unique (household_id, id)
);

create table public.session_ingredient_usage (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null default public.current_household_id(),
  cooking_session_id uuid not null,
  recipe_ingredient_id uuid,
  inventory_item_id uuid,
  ingredient_name text not null check (btrim(ingredient_name) <> ''),
  quantity numeric not null check (quantity > 0),
  unit text not null check (btrim(unit) <> ''),
  measurement_dimension text not null check (measurement_dimension in ('weight','volume','count','other')),
  confirmed_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint session_ingredient_usage_household_id_fkey foreign key (household_id) references public.households(id) on delete restrict,
  constraint session_ingredient_usage_session_fkey foreign key (household_id, cooking_session_id) references public.cooking_sessions(household_id, id) on delete cascade,
  constraint session_ingredient_usage_recipe_ingredient_fkey foreign key (household_id, recipe_ingredient_id) references public.recipe_ingredients(household_id, id) on delete set null (recipe_ingredient_id),
  constraint session_ingredient_usage_inventory_fkey foreign key (household_id, inventory_item_id) references public.inventory(household_id, id) on delete set null (inventory_item_id)
);

alter table public.recipe_versions add column source_session_id uuid;
alter table public.recipe_versions add constraint recipe_versions_source_session_fkey
  foreign key (household_id, source_session_id) references public.cooking_sessions(household_id, id) on delete set null (source_session_id);

create index cooking_sessions_household_status_idx on public.cooking_sessions (household_id, status, started_at desc);
create index cooking_sessions_recipe_fk_idx on public.cooking_sessions (household_id, recipe_id);
create index cooking_sessions_version_fk_idx on public.cooking_sessions (household_id, recipe_version_id);
create index cooking_events_session_timeline_idx on public.cooking_events (household_id, cooking_session_id, occurred_at, event_sequence);
create index cooking_events_process_fk_idx on public.cooking_events (household_id, process_id);
create index cooking_events_step_fk_idx on public.cooking_events (household_id, recipe_step_id);
create index cooking_events_inventory_fk_idx on public.cooking_events (household_id, inventory_item_id);
create index cooking_events_supersedes_fk_idx on public.cooking_events (household_id, supersedes_event_id);
create index cooking_timers_session_fk_idx on public.cooking_timers (household_id, cooking_session_id);
create index cooking_timers_process_fk_idx on public.cooking_timers (household_id, process_id);
create index cooking_timers_step_fk_idx on public.cooking_timers (household_id, recipe_step_id);
create index cooking_timers_active_idx on public.cooking_timers (household_id, cooking_session_id) where status in ('running','paused');
create index session_ingredient_usage_session_fk_idx on public.session_ingredient_usage (household_id, cooking_session_id);
create index session_ingredient_usage_recipe_ingredient_fk_idx on public.session_ingredient_usage (household_id, recipe_ingredient_id);
create index session_ingredient_usage_inventory_fk_idx on public.session_ingredient_usage (household_id, inventory_item_id);
create index recipe_versions_source_session_fk_idx on public.recipe_versions (household_id, source_session_id);

create trigger cooking_sessions_set_updated_at before update on public.cooking_sessions for each row execute function public.update_updated_at();
create trigger cooking_timers_set_updated_at before update on public.cooking_timers for each row execute function public.update_updated_at();
create trigger session_ingredient_usage_set_updated_at before update on public.session_ingredient_usage for each row execute function public.update_updated_at();

alter table public.cooking_sessions enable row level security;
alter table public.cooking_events enable row level security;
alter table public.cooking_timers enable row level security;
alter table public.session_ingredient_usage enable row level security;

create policy cooking_sessions_household_access on public.cooking_sessions for all to authenticated
  using (household_id = (select public.current_household_id())) with check (household_id = (select public.current_household_id()));
create policy cooking_events_household_access on public.cooking_events for all to authenticated
  using (household_id = (select public.current_household_id())) with check (household_id = (select public.current_household_id()));
create policy cooking_timers_household_access on public.cooking_timers for all to authenticated
  using (household_id = (select public.current_household_id())) with check (household_id = (select public.current_household_id()));
create policy session_ingredient_usage_household_access on public.session_ingredient_usage for all to authenticated
  using (household_id = (select public.current_household_id())) with check (household_id = (select public.current_household_id()));

revoke all on public.cooking_sessions, public.cooking_events, public.cooking_timers, public.session_ingredient_usage from public, anon;
grant select, insert, update, delete on public.cooking_sessions, public.cooking_events, public.cooking_timers, public.session_ingredient_usage to authenticated;
grant usage, select on sequence public.cooking_events_event_sequence_seq to authenticated;

commit;
