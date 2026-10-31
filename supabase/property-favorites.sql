-- =====================================================================
-- Bastet · Favoritos guardados en la cuenta (agregar al final de supabase/schema.sql). Idempotente.
-- Quien inicia sesión conserva sus propiedades guardadas (corazón) en cualquier dispositivo. Cada persona solo ve y cambia las suyas.
-- Sin sesión los favoritos siguen en el navegador (localStorage); al iniciar sesión se unen con los de la cuenta.
-- Supone que existe: public.properties.
-- =====================================================================

create table if not exists public.property_favorites (
  user_id     uuid not null default auth.uid() references auth.users(id) on delete cascade,
  property_id uuid not null references public.properties(id) on delete cascade,
  created_at  timestamptz not null default now(),
  primary key (user_id, property_id)
);

alter table public.property_favorites enable row level security;
drop policy if exists "own favorites select" on public.property_favorites;
create policy "own favorites select" on public.property_favorites for select to authenticated using (user_id = auth.uid());
drop policy if exists "own favorites insert" on public.property_favorites;
create policy "own favorites insert" on public.property_favorites for insert to authenticated with check (user_id = auth.uid());
drop policy if exists "own favorites delete" on public.property_favorites;
create policy "own favorites delete" on public.property_favorites for delete to authenticated using (user_id = auth.uid());
revoke all on public.property_favorites from anon;
revoke update on public.property_favorites from authenticated;

-- Tope por persona (evita llenar la tabla)
create or replace function public.limit_property_favorites()
returns trigger language plpgsql as $$
begin
  if (select count(*) from public.property_favorites where user_id = new.user_id) >= 30 then
    raise exception 'Llegaste al máximo de 30 favoritos. Quita alguno para guardar otro.';
  end if;
  return new;
end $$;
drop trigger if exists limit_property_favorites on public.property_favorites;
create trigger limit_property_favorites before insert on public.property_favorites
  for each row execute function public.limit_property_favorites();

notify pgrst, 'reload schema';
