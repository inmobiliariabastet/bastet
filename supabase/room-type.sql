-- =====================================================================
-- Bastet · Tipo «Habitación» y estadías temporales sin trámites de venta   — correr DESPUÉS de run-pending.sql
-- =====================================================================
-- 1) Nuevo tipo de inmueble «habitacion» (propiedades, solicitudes de venta y búsquedas de inmueble).
-- 2) Una estadía temporal no es venta, alquiler ni anticrético: no exige contrato marco para publicar
--    (es el de conexiones y comisiones) ni admite la verificación de la propiedad (documentos de propiedad).
-- Idempotente: se puede correr más de una vez.

do $$
declare r record; t text;
begin
  foreach t in array array['properties', 'sell_requests', 'property_requests'] loop
    if to_regclass('public.' || t) is null then continue; end if;
    for r in select c.conname from pg_constraint c
              where c.conrelid = ('public.' || t)::regclass and c.contype = 'c'
                and pg_get_constraintdef(c.oid) ilike '%property_type%' and pg_get_constraintdef(c.oid) not ilike '%habitacion%' loop
      execute format('alter table public.%I drop constraint %I', t, r.conname);
    end loop;
  end loop;
  if to_regclass('public.properties') is not null and not exists (select 1 from pg_constraint where conname = 'properties_property_type_room_check') then
    alter table public.properties add constraint properties_property_type_room_check
      check (property_type is null or property_type in ('casa', 'departamento', 'habitacion', 'terreno'));
  end if;
  if to_regclass('public.sell_requests') is not null and not exists (select 1 from pg_constraint where conname = 'sell_requests_property_type_room_check') then
    alter table public.sell_requests add constraint sell_requests_property_type_room_check
      check (property_type in ('casa', 'departamento', 'habitacion', 'terreno', 'otro'));
  end if;
  if to_regclass('public.property_requests') is not null and not exists (select 1 from pg_constraint where conname = 'property_requests_property_type_room_check') then
    alter table public.property_requests add constraint property_requests_property_type_room_check
      check (property_type in ('casa', 'departamento', 'habitacion', 'terreno', 'oficina', 'local', 'otro'));
  end if;
end $$;

-- Contrato marco: las estadías temporales no lo requieren (no hay conexión ni comisión de venta)
create or replace function public.require_framework_on_publish()
returns trigger language plpgsql security definer set search_path = public as $$
declare s public.connection_settings; uid uuid := auth.uid();
begin
  if uid is null or public.is_admin() or new.operation = 'temporal' then return new; end if;
  select * into s from public.connection_settings where id = 1;
  if s.enabled and char_length(btrim(s.framework_text)) > 0
     and not exists (select 1 from public.framework_acceptances a where a.user_id = uid and a.version = s.framework_version) then
    raise exception 'Antes de publicar debes aceptar el contrato marco de Bastet' using errcode = 'P0403', hint = 'framework';
  end if;
  return new;
end $$;

-- Verificación de propiedad: no se ofrece para estadías temporales
create or replace function public.request_verification(p_kind text, p_property uuid default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); rid uuid;
begin
  if uid is null or not public.is_active_user() then raise exception 'No autorizado' using errcode = '42501'; end if;
  if p_kind not in ('agente', 'propietario', 'propiedad') then raise exception 'Tipo de verificación inválido'; end if;
  if p_kind = 'propiedad' then
    if p_property is null or not exists (select 1 from public.properties where id = p_property and owner_id = uid) then raise exception 'Elige una de tus propiedades'; end if;
    if exists (select 1 from public.properties where id = p_property and operation = 'temporal') then raise exception 'Las estadías temporales no necesitan verificación de propiedad ni documentos de propiedad'; end if;
    if exists (select 1 from public.properties where id = p_property and verified) then raise exception 'Esta propiedad ya está verificada'; end if;
  else p_property := null; end if;
  if p_kind = 'agente' and exists (select 1 from public.profiles where id = uid and agent_verified) then raise exception 'Ya eres agente verificado'; end if;
  if p_kind = 'propietario' and exists (select 1 from public.profiles where id = uid and owner_verified) then raise exception 'Ya eres propietario verificado'; end if;
  select id into rid from public.verification_requests where user_id = uid and kind = p_kind and coalesce(property_id, '00000000-0000-0000-0000-000000000000'::uuid) = coalesce(p_property, '00000000-0000-0000-0000-000000000000'::uuid) and status in ('borrador', 'en_revision');
  if rid is not null then return rid; end if;
  insert into public.verification_requests (kind, user_id, property_id) values (p_kind, uid, p_property) returning id into rid;
  perform public._ver_log(rid, 'usuario', 'solicitud_creada', jsonb_build_object('kind', p_kind));
  return rid;
end $$;

notify pgrst, 'reload schema';
