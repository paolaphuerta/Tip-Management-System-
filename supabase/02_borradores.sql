-- Ejecuta UNA VEZ en Supabase > SQL Editor, después del schema.sql original.
create table if not exists public.reparto_borrador (
  workspace_id uuid primary key references public.workspaces(id) on delete cascade,
  data jsonb not null,
  updated_by uuid not null references auth.users(id),
  updated_at timestamptz not null default now()
);
create or replace function public.touch_reparto_borrador() returns trigger
language plpgsql set search_path = '' as $$ begin new.updated_at = clock_timestamp(); return new; end $$;
drop trigger if exists reparto_borrador_updated_at on public.reparto_borrador;
create trigger reparto_borrador_updated_at before update on public.reparto_borrador
for each row execute function public.touch_reparto_borrador();
alter table public.reparto_borrador enable row level security;
create policy "borrador select" on public.reparto_borrador for select to authenticated using (public.is_member(workspace_id));
create policy "borrador insert" on public.reparto_borrador for insert to authenticated with check (public.is_member(workspace_id) and updated_by=(select auth.uid()));
create policy "borrador update" on public.reparto_borrador for update to authenticated using (public.is_member(workspace_id)) with check (public.is_member(workspace_id) and updated_by=(select auth.uid()));
create policy "borrador delete" on public.reparto_borrador for delete to authenticated using (public.is_member(workspace_id));
