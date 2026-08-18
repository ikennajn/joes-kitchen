begin;

create index if not exists households_created_by_idx
  on public.households (created_by);

commit;
