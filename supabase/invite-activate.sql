-- Fix: un agente aprobado (invitación) nacía DESHABILITADO.
-- Causa: GoTrue crea el usuario y marca invited_at en un UPDATE posterior, así que
-- handle_new_user (que corre en el INSERT) lo veía en null y dejaba is_active = false.
-- Solución: al marcarse invited_at, se activa el perfil.
-- Correr completo en el SQL Editor de Supabase (idempotente).

-- 1) El perfil solo lo protege contra cambios hechos por usuarios logueados que no son
--    admin. Los cambios desde triggers / SQL Editor (auth.uid() null) pasan; el RLS ya
--    impide que alguien sin sesión toque profiles.
create or replace function public.protect_profile_privileged_columns()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is not null and not public.is_admin() then
    new.role := old.role;
    new.is_active := old.is_active;
    new.email := old.email;
  end if;
  if auth.uid() is not null then
    new.role := old.role;
  end if;
  return new;
end;
$$;

-- 2) Al invitar (invited_at pasa de null a un valor) se habilita el perfil.
create or replace function public.activate_invited_profile()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.profiles set is_active = true where id = new.id;
  return new;
end;
$$;

drop trigger if exists on_auth_user_invited on auth.users;
create trigger on_auth_user_invited
  after update of invited_at on auth.users
  for each row
  when (old.invited_at is null and new.invited_at is not null)
  execute function public.activate_invited_profile();
