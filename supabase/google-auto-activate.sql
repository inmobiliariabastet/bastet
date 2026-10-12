-- Registro automático con Google: quien entra con Google nace HABILITADO como agente.
-- (2026-10-12) Ya no hace falta solicitud + aprobación. El admin conserva Desactivar/Eliminar.
-- Cualquier otra vía de alta (signup directo con correo+contraseña a la API) sigue naciendo
-- DESACTIVADA; las invitaciones siguen activas por on_auth_user_invited.
-- Correr completo en el SQL Editor (idempotente).
-- Además, en Supabase: Authentication → Sign In / Providers → activar "Allow new users to sign up".

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, email, role, is_active, display_name)
  values (
    new.id,
    new.email,
    'agent',
    new.invited_at is not null or coalesce(new.raw_app_meta_data->>'provider', '') = 'google',
    nullif(trim(coalesce(new.raw_user_meta_data->>'full_name', new.raw_user_meta_data->>'name', '')), '')
  )
  on conflict (id) do nothing;
  return new;
end;
$$;
