-- =====================================================================
-- Bastet · Retirar residuos del flujo viejo de acceso   — OPCIONAL y DESTRUCTIVO (no se puede deshacer)
-- Desde 2026-10-12 todos entran con Google y se crean solos como agentes: ya no existen solicitudes de cuenta ni invitaciones por correo.
-- Qué borra:
--   · la tabla public.agent_requests (solicitudes de cuenta de agentes: datos y políticas). Si quieres conservar ese historial,
--     antes expórtala: Supabase → Table Editor → agent_requests → Export → CSV.
--   · el trigger on_auth_user_invited (sobre auth.users) y su función public.activate_invited_profile().
-- Qué NO toca: handle_new_user (quien entra con Google sigue naciendo activo), perfiles, propiedades ni nada más.
-- Después, en Supabase → Edge Functions, borra a mano la función `invite-admin` si aparece (ya no se usa).
-- Idempotente: se puede correr más de una vez.
-- =====================================================================

do $$
declare n bigint := 0;
begin
  if to_regclass('public.agent_requests') is not null then
    execute 'select count(*) from public.agent_requests' into n;
    raise notice 'agent_requests: se borran % solicitudes antiguas.', n;
  end if;
end $$;

drop table if exists public.agent_requests;
drop trigger if exists on_auth_user_invited on auth.users;
drop function if exists public.activate_invited_profile();

notify pgrst, 'reload schema';
