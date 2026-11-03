-- =====================================================================
-- Bastet · Eliminar mi cuenta (desde «Mi cuenta»)   — correr DESPUÉS de host-agreement.sql
-- =====================================================================
-- Quien tiene cuenta puede eliminarla SOLO si no tiene pagos pendientes ni disputas abiertas:
--   · conexiones con pago por hacer o por verificar; inmuebles con conexiones de Bastet sin cerrar la operación;
--   · operaciones por confirmar o comisiones por pagar;
--   · investigaciones abiertas o penalizaciones propuestas / impuestas;
--   · reservas de estadías en curso, con pago por verificar o en disputa;
--   · cobranzas y pedidos de servicios legales sin resolver.
-- Las cuentas de administración no se eliminan por aquí (se retiran desde «Usuarios»).
-- Al eliminar: se retiran sus inmuebles disponibles, se borran sus datos personales (perfil, favoritos, búsquedas, datos legales,
-- solicitudes de verificación) y se cierra su acceso (la cuenta de acceso queda anonimizada y bloqueada; el correo y el ingreso con Google
-- quedan libres). Se CONSERVAN, por obligación contractual y de prueba, los registros de conexiones, operaciones, actas, reservas,
-- aceptaciones de contratos e investigaciones (con los datos de las partes que ya contenían).
-- Idempotente: se puede correr más de una vez.

-- El perfil protege is_active y email frente a quien no es admin; la eliminación de cuenta (única vía) pasa por un permiso interno
create or replace function public.protect_profile_privileged_columns()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is not null and not public.is_admin() and coalesce(current_setting('uno.account_rpc', true), '') <> '1' then
    new.role := old.role;
    new.is_active := old.is_active;
    new.email := old.email;
    if coalesce(current_setting('uno.reg_rpc', true), '') <> '1' then
      new.registered_at := old.registered_at;
      new.trial_used_at := old.trial_used_at;
      new.age_confirmed_at := old.age_confirmed_at;
    end if;
  end if;
  -- Desde 2026-09-29 no se crean administradores nuevos desde la app: el rol solo se cambia desde el SQL Editor
  if auth.uid() is not null then
    new.role := old.role;
  end if;
  return new;
end $$;

-- Motivos que impiden eliminar la cuenta de un usuario (vacío = puede eliminarla)
create or replace function public._account_blockers(p_user uuid)
returns text[] language plpgsql security definer set search_path = public as $$
declare r text[] := '{}'; n integer;
begin
  if exists (select 1 from public.profiles where id = p_user and role = 'admin') then
    r := array_append(r, 'Las cuentas de administración no se eliminan desde aquí: se retiran desde «Usuarios».');
  end if;
  if to_regclass('public.connections') is not null then
    select count(*) into n from public.connections where titular_id = p_user and status in ('aceptada_pendiente_pago', 'comprobante_enviado');
    if n > 0 then r := array_append(r, n || ' conexión(es) con el pago de la tarifa pendiente o en revisión.'); end if;
    select count(*) into n from public.properties p where p.owner_id = p_user and p.status = 'available'
       and exists (select 1 from public.connections c where c.property_id = p.id and c.status in ('aceptada_pendiente_pago', 'comprobante_enviado', 'conexion_generada'));
    if n > 0 then r := array_append(r, n || ' inmueble(s) con conexiones de Bastet: primero cierra la operación (vendida, alquilada) o firma el desistimiento en «Cerrar operación».'); end if;
  end if;
  if to_regclass('public.operations') is not null then
    select count(*) into n from public.operations where titular_id = p_user and (status in ('pendiente_interesado', 'en_revision') or commission_status in ('exigible', 'comprobante_enviado'));
    if n > 0 then r := array_append(r, n || ' operación(es) por confirmar o con la comisión pendiente de pago.'); end if;
  end if;
  if to_regclass('public.investigations') is not null then
    select count(*) into n from public.investigations where subject_id = p_user and (status in ('abierta', 'descargos', 'revision_juridica') or penalty_status in ('propuesta', 'impuesta'));
    if n > 0 then r := array_append(r, n || ' investigación(es) abierta(s) o penalización(es) sin resolver.'); end if;
  end if;
  if to_regclass('public.stay_bookings') is not null then
    select count(*) into n from public.stay_bookings where host_id = p_user
       and (status in ('pendiente_respuesta_anfitrion', 'aceptada_pendiente_pago', 'comprobante_enviado', 'pago_en_revision', 'pago_verificado', 'en_disputa')
            or (status = 'conexion_generada' and check_out >= current_date));
    if n > 0 then r := array_append(r, n || ' reserva(s) de estadías en curso, con pago por verificar o en disputa.'); end if;
  end if;
  if to_regclass('public.collections') is not null then
    select count(*) into n from public.collections where agent_id = p_user and status in ('pending', 'in_process');
    if n > 0 then r := array_append(r, n || ' cobranza(s) sin pagar.'); end if;
  end if;
  if to_regclass('public.legal_requests') is not null then
    select count(*) into n from public.legal_requests where user_id = p_user and status in ('pending', 'in_review', 'in_progress');
    if n > 0 then r := array_append(r, n || ' pedido(s) de servicios legales sin terminar.'); end if;
  end if;
  return r;
end $$;

-- La propia persona consulta si puede eliminar su cuenta y qué se lo impide
create or replace function public.my_account_deletion_check()
returns jsonb language plpgsql security definer set search_path = public stable as $$
declare uid uuid := auth.uid(); b text[];
begin
  if uid is null or not public.is_active_user() then raise exception 'No autorizado' using errcode = '42501'; end if;
  b := public._account_blockers(uid);
  return jsonb_build_object('can_delete', coalesce(array_length(b, 1), 0) = 0, 'blockers', to_jsonb(b));
end $$;

-- Elimina (anonimiza y cierra) la cuenta de quien la pide. Hay que escribir ELIMINAR para confirmar.
create or replace function public.delete_my_account(p_confirm text)
returns void language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); b text[]; anon_email text;
begin
  if uid is null or not public.is_active_user() then raise exception 'No autorizado' using errcode = '42501'; end if;
  if upper(btrim(coalesce(p_confirm, ''))) <> 'ELIMINAR' then raise exception 'Escribe ELIMINAR para confirmar'; end if;
  b := public._account_blockers(uid);
  if coalesce(array_length(b, 1), 0) > 0 then raise exception 'No puedes eliminar tu cuenta todavía: %', b[1] using errcode = 'P0403', hint = 'blockers'; end if;

  -- 1) Sus inmuebles disponibles dejan de publicarse
  update public.properties set status = 'withdrawn' where owner_id = uid and status = 'available';
  -- 2) Contactos de terceros que recibió: pasan a administración (sin agente)
  if to_regclass('public.property_leads') is not null then update public.property_leads set agent_id = null where agent_id = uid; end if;
  -- 3) Datos personales
  if to_regclass('public.property_favorites') is not null then delete from public.property_favorites where user_id = uid; end if;
  if to_regclass('public.property_requests') is not null then delete from public.property_requests where user_id = uid; end if;
  if to_regclass('public.agent_legal_profiles') is not null then delete from public.agent_legal_profiles where user_id = uid; end if;
  if to_regclass('public.verification_requests') is not null then delete from public.verification_requests where user_id = uid; end if;
  anon_email := 'cuenta-eliminada-' || uid::text || '@bastet.invalid';
  perform set_config('uno.account_rpc', '1', true); perform set_config('uno.verif_rpc', '1', true);
  update public.profiles set is_active = false, email = anon_email, display_name = 'Cuenta eliminada', avatar_url = null,
         facebook_url = null, instagram_url = null, tiktok_url = null, contact_whatsapp = null, full_name = null, whatsapp = null, city = null,
         company = null, agent_verified = false, owner_verified = false where id = uid;
  -- 4) Acceso: la cuenta de acceso queda anonimizada y bloqueada; el correo y el ingreso con Google quedan libres
  if to_regclass('auth.identities') is not null then delete from auth.identities where user_id = uid; end if;
  update auth.users set email = anon_email, raw_user_meta_data = '{}'::jsonb where id = uid;
  if exists (select 1 from information_schema.columns where table_schema = 'auth' and table_name = 'users' and column_name = 'banned_until') then
    update auth.users set banned_until = 'infinity' where id = uid;
  end if;
  if exists (select 1 from information_schema.columns where table_schema = 'auth' and table_name = 'users' and column_name = 'phone') then
    update auth.users set phone = null where id = uid;
  end if;
  if to_regclass('auth.sessions') is not null then delete from auth.sessions where user_id = uid; end if;
  if to_regclass('auth.refresh_tokens') is not null then delete from auth.refresh_tokens where user_id::text = uid::text; end if;
end $$;

revoke execute on function public._account_blockers(uuid) from public, anon, authenticated;
revoke execute on function public.my_account_deletion_check(), public.delete_my_account(text) from public, anon;
grant execute on function public.my_account_deletion_check(), public.delete_my_account(text) to authenticated;

notify pgrst, 'reload schema';
