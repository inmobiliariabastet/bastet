-- =====================================================================
-- Bastet · TODO LO PENDIENTE EN UN SOLO ARCHIVO (2026-11-03)
-- Pégalo completo en el SQL Editor de Supabase y pulsa Run. Se puede correr más de una vez sin problema.
--
-- Contiene, en este orden:
--   1) connections.sql          Conexiones y tarifas (solicitud de contacto, matriz de tarifas, contrato marco, pago con comprobante)
--   2) security-hardening.sql   Blindaje: contacto protegido, datos privados entre cuentas, fotos y avatares solo del dueño, límite por IP
--   3) operations.sql           Comisiones y cierre de operaciones
--   4) verification.sql         Distintivos de verificación, reseñas, certificado público y acta
--   5) investigations.sql       Investigaciones y sanciones
-- Requisito: ya corridos antes stay-bookings.sql y retire-subscriptions.sql (ya lo hiciste).
-- Todo queda APAGADO hasta que lo actives en el panel (Conexiones, Operaciones, Verificación, Investigaciones).
-- =====================================================================

-- =====================================================================
-- Bastet · Conexiones y tarifas (fase 2, paso B)   — correr DESPUÉS de stay-bookings.sql y retire-subscriptions.sql
-- Idempotente: se puede correr completo más de una vez. Implementa docs/ESPECIFICACION_MAESTRA.md, secciones 1 y 9.1–9.3.
--
-- Flujo (venta, alquiler y anticrético): la persona interesada (sin cuenta) solicita contacto → el titular de la cuenta que publicó (agente,
-- empresa o propietario) acepta o rechaza → si acepta, nace la obligación económica: la tarifa de conexión, calculada con la matriz editable y
-- CONGELADA en esa conexión → el titular paga a Bastet (QR/transferencia) y sube su comprobante → un administrador lo verifica → recién entonces
-- el titular ve los datos del interesado (conexión). Cada conexión genera una constancia numerada BST-CX-AAAA-NNNN con la versión del contrato marco.
-- Antes de publicar su primera propiedad el titular acepta un contrato marco (una vez por versión).
--
-- INTERRUPTOR: connection_settings.enabled (apagado por defecto). Apagado, el sitio sigue como antes (WhatsApp directo y formulario de clientes).
--   Para encenderlo hacen falta las instrucciones de pago y el TEXTO del contrato marco (que debe revisar un abogado en Bolivia).
-- Tarifas en Bs. Rangos fijos por la especificación: alquiler 10–50, venta 51–200; anticrético se calcula por matriz (10–200, sin rango aprobado).
-- Los valores iniciales de la matriz son PROVISIONALES (punto medio de cada rango) y están marcados así: la dueña los ajusta en el panel.
-- NO incluido todavía: ocultar de verdad el teléfono público de la propiedad en la API (hoy solo se oculta en la pantalla) — paso B2.
-- =====================================================================

do $$
begin
  if to_regclass('public.stay_settings') is null then raise exception 'Primero corre supabase/stay-bookings.sql'; end if;
  if to_regprocedure('public.my_account()') is null then raise exception 'Primero corre supabase/retire-subscriptions.sql'; end if;
end $$;

-- 1) Ajustes (una sola fila)
create table if not exists public.connection_settings (
  id                smallint primary key default 1 check (id = 1),
  enabled           boolean not null default false,
  pay_instructions  text not null default '' check (char_length(pay_instructions) <= 1500),
  pay_qr_url        text check (pay_qr_url is null or char_length(pay_qr_url) <= 400),
  framework_version integer not null default 1,
  framework_text    text not null default '' check (char_length(framework_text) <= 60000),
  updated_at        timestamptz not null default now()
);
insert into public.connection_settings (id) values (1) on conflict (id) do nothing;
alter table public.connection_settings enable row level security;
revoke all on public.connection_settings from anon, authenticated;

-- 2) Matriz de tarifas: límites por operación (especificación) y reglas editables
create table if not exists public.fee_bounds (
  operation text primary key check (operation in ('venta', 'alquiler', 'anticretico')),
  min_bs    numeric(10,2) not null,
  max_bs    numeric(10,2) not null,
  check (min_bs <= max_bs)
);
insert into public.fee_bounds (operation, min_bs, max_bs) values ('alquiler', 10, 50), ('venta', 51, 200), ('anticretico', 10, 200) on conflict (operation) do nothing;

create table if not exists public.fee_rules (
  id           bigint generated always as identity primary key,
  operation    text not null check (operation in ('venta', 'alquiler', 'anticretico')),
  property_type text,                                   -- null = cualquier tipo de inmueble
  value_min_bs numeric(14,2),                           -- valor del inmueble en Bs (null = sin mínimo)
  value_max_bs numeric(14,2),
  fee_bs       numeric(10,2) not null check (fee_bs >= 0),
  priority     integer not null default 0,
  label        text check (label is null or char_length(label) <= 100),
  provisional  boolean not null default false,
  active       boolean not null default true,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  check (value_min_bs is null or value_max_bs is null or value_min_bs <= value_max_bs)
);
insert into public.fee_rules (operation, fee_bs, label, provisional)
select v.operation, v.fee_bs, v.label, true
  from (values ('alquiler', 30, 'Alquiler · valor inicial provisional'), ('venta', 125, 'Venta · valor inicial provisional'),
               ('anticretico', 100, 'Anticrético · valor inicial provisional')) as v(operation, fee_bs, label)
 where not exists (select 1 from public.fee_rules);
alter table public.fee_rules enable row level security;
alter table public.fee_bounds enable row level security;
revoke all on public.fee_rules, public.fee_bounds from anon, authenticated;

create table if not exists public.fee_rule_events (        -- historial de cambios de la matriz (sección 1.2)
  id         bigint generated always as identity primary key,
  rule_id    bigint,
  actor      uuid,
  action     text not null,
  old_data   jsonb,
  new_data   jsonb,
  created_at timestamptz not null default now()
);
alter table public.fee_rule_events enable row level security;
revoke all on public.fee_rule_events from anon, authenticated;

-- 3) Contrato marco: quién aceptó qué versión
create table if not exists public.framework_acceptances (
  user_id     uuid not null references auth.users(id) on delete cascade,
  version     integer not null,
  accepted_at timestamptz not null default now(),
  primary key (user_id, version)
);
alter table public.framework_acceptances enable row level security;
revoke all on public.framework_acceptances from anon, authenticated;

-- 4) Conexiones
create table if not exists public.connection_counters (year integer primary key, last_number integer not null);
alter table public.connection_counters enable row level security;
revoke all on public.connection_counters from anon, authenticated;

create table if not exists public.connections (
  id                uuid primary key default gen_random_uuid(),
  code              text not null unique,
  number            text unique,                         -- constancia BST-CX-AAAA-NNNN (se asigna al aceptar)
  property_id       uuid not null references public.properties(id) on delete cascade,
  titular_id        uuid references auth.users(id) on delete set null,
  operation         text not null check (operation in ('venta', 'alquiler', 'anticretico')),
  interested_type   text not null check (interested_type in ('comprador', 'arrendatario', 'anticresista')),
  interested_name   text not null check (char_length(btrim(interested_name)) between 2 and 120),
  interested_phone  text not null check (char_length(interested_phone) between 7 and 20),
  interested_email  text check (interested_email is null or char_length(interested_email) <= 120),
  message           text check (message is null or char_length(message) <= 500),
  status            text not null default 'solicitada' check (status in
                      ('solicitada', 'rechazada', 'aceptada_pendiente_pago', 'comprobante_enviado', 'conexion_generada', 'cancelada')),
  fee_bs            numeric(10,2),                       -- tarifa CONGELADA al aceptar
  fee_calc          jsonb,                               -- regla, valor del inmueble en Bs y tipo de cambio usados
  property_snapshot jsonb,                               -- datos del inmueble al aceptar (constancia)
  framework_version integer,
  accepted_at       timestamptz,
  proof_path        text check (proof_path is null or char_length(proof_path) <= 300),
  proof_at          timestamptz,
  verified_at       timestamptz,
  verified_by       uuid references auth.users(id) on delete set null,
  review_note       text check (review_note is null or char_length(review_note) <= 500),
  cancelled_note    text check (cancelled_note is null or char_length(cancelled_note) <= 500),
  created_at        timestamptz not null default now()
);
create index if not exists connections_titular_idx on public.connections (titular_id, status, created_at desc);
create index if not exists connections_property_idx on public.connections (property_id, status);
alter table public.connections enable row level security;
revoke all on public.connections from anon, authenticated;

create table if not exists public.connection_events (
  id          bigint generated always as identity primary key,
  connection_id uuid not null references public.connections(id) on delete cascade,
  actor       text not null,
  actor_id    uuid,
  event       text not null,
  from_status text,
  to_status   text,
  data        jsonb,
  created_at  timestamptz not null default now()
);
create index if not exists connection_events_idx on public.connection_events (connection_id, created_at);
alter table public.connection_events enable row level security;
revoke all on public.connection_events from anon, authenticated;

create or replace function public._conn_log(p_conn uuid, p_actor text, p_event text, p_from text, p_to text, p_data jsonb default null)
returns void language sql security definer set search_path = public as $$
  insert into public.connection_events (connection_id, actor, actor_id, event, from_status, to_status, data) values (p_conn, p_actor, auth.uid(), p_event, p_from, p_to, p_data);
$$;
revoke all on function public._conn_log(uuid, text, text, text, text, jsonb) from public, anon, authenticated;

-- 5) Comprobantes de pago de la tarifa: carpeta privada, cada titular sube a la suya; el administrador lee todas
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('connection-proofs', 'connection-proofs', false, 5242880, array['application/pdf', 'image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do update set public = false, file_size_limit = 5242880, allowed_mime_types = array['application/pdf', 'image/jpeg', 'image/png', 'image/webp'];
drop policy if exists "titular uploads connection proof" on storage.objects;
create policy "titular uploads connection proof" on storage.objects for insert to authenticated
  with check (bucket_id = 'connection-proofs' and (storage.foldername(name))[1] = auth.uid()::text);
drop policy if exists "titular reads own connection proof" on storage.objects;
create policy "titular reads own connection proof" on storage.objects for select to authenticated
  using (bucket_id = 'connection-proofs' and (storage.foldername(name))[1] = auth.uid()::text);
drop policy if exists "admin reads connection proofs" on storage.objects;
create policy "admin reads connection proofs" on storage.objects for select to authenticated using (bucket_id = 'connection-proofs' and public.is_admin());
drop policy if exists "admin deletes connection proofs" on storage.objects;
create policy "admin deletes connection proofs" on storage.objects for delete to authenticated using (bucket_id = 'connection-proofs' and public.is_admin());

-- 6) Cálculo de la tarifa con la matriz (siempre en Bs; el valor en USD se convierte con el tipo de cambio INTERNO de Bastet)
create or replace function public._connection_fee(p_property uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare prop record; v numeric; rate numeric; vbs numeric; r record; b record; fee numeric; clamped boolean := false;
begin
  select id, coalesce(operation, 'venta') as operation, property_type, price, currency into prop from public.properties where id = p_property;   -- sin operación = venta (listados antiguos)
  if not found or prop.operation not in ('venta', 'alquiler', 'anticretico') then raise exception 'Esta propiedad no genera conexiones'; end if;
  v := nullif(regexp_replace(prop.price::text, '[^0-9]', '', 'g'), '')::numeric;
  select bob_per_usd into rate from public.stay_settings where id = 1;
  rate := coalesce(rate, 6.96);
  vbs := case when v is null then null when prop.currency = 'BOB' then v else v * rate end;
  select * into r from public.fee_rules f
   where f.active and f.operation = prop.operation and (f.property_type is null or f.property_type = prop.property_type)
     and (f.value_min_bs is null or (vbs is not null and vbs >= f.value_min_bs)) and (f.value_max_bs is null or (vbs is not null and vbs <= f.value_max_bs))
   order by ((f.property_type is not null)::int + (f.value_min_bs is not null)::int + (f.value_max_bs is not null)::int) desc, f.priority desc, f.id
   limit 1;
  if not found then raise exception 'No hay una regla de tarifa activa para esta propiedad. Avisa a administración.'; end if;
  select * into b from public.fee_bounds where operation = prop.operation;
  fee := r.fee_bs;
  if fee < b.min_bs then fee := b.min_bs; clamped := true; elsif fee > b.max_bs then fee := b.max_bs; clamped := true; end if;
  return jsonb_build_object('fee_bs', fee, 'rule_id', r.id, 'rule_label', r.label, 'provisional', r.provisional, 'clamped', clamped, 'operation', prop.operation,
    'property_type', prop.property_type, 'value_bs', vbs, 'bob_per_usd', rate, 'min_bs', b.min_bs, 'max_bs', b.max_bs);
end $$;
revoke all on function public._connection_fee(uuid) from public, anon, authenticated;

-- 7) Público: ¿están activas las conexiones?
create or replace function public.connections_enabled()
returns boolean language sql security definer set search_path = public stable as $$ select coalesce((select enabled from public.connection_settings where id = 1), false) $$;
revoke all on function public.connections_enabled() from public;
grant execute on function public.connections_enabled() to anon, authenticated;

-- 8) La persona interesada solicita contacto (sin cuenta)
create or replace function public.request_connection(p_property uuid, p_name text, p_phone text, p_email text default null, p_message text default null, p_consent boolean default false)
returns text language plpgsql security definer set search_path = public as $$
declare prop record; nm text := btrim(coalesce(p_name, '')); ph text := regexp_replace(coalesce(p_phone, ''), '[^0-9+]', '', 'g'); em text := nullif(btrim(coalesce(p_email, '')), '');
        msg text := nullif(btrim(coalesce(p_message, '')), ''); it text; cd text; tries int := 0;
begin
  if not public.connections_enabled() then raise exception 'Las solicitudes de contacto todavía no están activas'; end if;
  if p_consent is not true then raise exception 'Debes aceptar que se compartan tus datos con el agente'; end if;
  select id, owner_id, coalesce(operation, 'venta') as operation, status, expires_at into prop from public.properties where id = p_property;   -- sin operación = venta (listados antiguos)
  if not found or prop.status is distinct from 'available' or prop.operation not in ('venta', 'alquiler', 'anticretico')
     or (prop.expires_at is not null and prop.expires_at < now()) then raise exception 'Esta propiedad no está disponible'; end if;
  if char_length(nm) not between 2 and 120 then raise exception 'Escribe tu nombre'; end if;
  if char_length(regexp_replace(ph, '[^0-9]', '', 'g')) not between 7 and 15 then raise exception 'Escribe un número de WhatsApp válido'; end if;
  if em is not null and em !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'El correo no es válido'; end if;
  if msg is not null and char_length(msg) > 500 then raise exception 'El mensaje es demasiado largo (máximo 500 caracteres)'; end if;
  if exists (select 1 from public.connections c where c.property_id = p_property and c.interested_phone = ph and c.status in ('solicitada', 'aceptada_pendiente_pago', 'comprobante_enviado', 'conexion_generada')) then
    raise exception 'Ya enviaste una solicitud para esta propiedad'; end if;
  if (select count(*) from public.connections where interested_phone = ph and status = 'solicitada') >= 5 then
    raise exception 'Ya tienes 5 solicitudes esperando respuesta. Espera a que los agentes respondan.'; end if;
  it := case prop.operation when 'venta' then 'comprador' when 'alquiler' then 'arrendatario' else 'anticresista' end;
  loop
    cd := upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 10));
    begin
      insert into public.connections (code, property_id, titular_id, operation, interested_type, interested_name, interested_phone, interested_email, message)
      values (cd, p_property, prop.owner_id, prop.operation, it, nm, ph, em, msg);
      exit;
    exception when unique_violation then tries := tries + 1; if tries > 5 then raise; end if;
    end;
  end loop;
  perform public._conn_log((select id from public.connections where code = cd), 'interested', 'solicitada', null, 'solicitada', jsonb_build_object('type', it));
  return cd;
end $$;

-- 9) Contrato marco: estado y aceptación
create or replace function public.my_framework()
returns jsonb language plpgsql security definer set search_path = public stable as $$
declare s public.connection_settings; uid uuid := auth.uid(); req boolean;
begin
  if uid is null or not public.is_active_user() then raise exception 'No autorizado' using errcode = '42501'; end if;
  select * into s from public.connection_settings where id = 1;
  req := s.enabled and char_length(btrim(s.framework_text)) > 0 and not public.is_admin();
  return jsonb_build_object('required', req, 'version', s.framework_version, 'text', case when req then s.framework_text end,
    'accepted', not req or exists (select 1 from public.framework_acceptances a where a.user_id = uid and a.version = s.framework_version));
end $$;

create or replace function public.accept_framework_contract(p_version integer)
returns void language plpgsql security definer set search_path = public as $$
declare s public.connection_settings;
begin
  if auth.uid() is null or not public.is_active_user() then raise exception 'No autorizado' using errcode = '42501'; end if;
  select * into s from public.connection_settings where id = 1;
  if p_version is distinct from s.framework_version then raise exception 'El contrato marco cambió. Vuelve a leerlo y acéptalo.'; end if;
  insert into public.framework_acceptances (user_id, version) values (auth.uid(), s.framework_version) on conflict do nothing;
end $$;

-- Antes de la primera publicación (y tras cada nueva versión) hay que aceptar el contrato marco
create or replace function public.require_framework_on_publish()
returns trigger language plpgsql security definer set search_path = public as $$
declare s public.connection_settings; uid uuid := auth.uid();
begin
  if uid is null or public.is_admin() then return new; end if;
  select * into s from public.connection_settings where id = 1;
  if s.enabled and char_length(btrim(s.framework_text)) > 0
     and not exists (select 1 from public.framework_acceptances a where a.user_id = uid and a.version = s.framework_version) then
    raise exception 'Antes de publicar debes aceptar el contrato marco de Bastet' using errcode = 'P0403', hint = 'framework';
  end if;
  return new;
end $$;
drop trigger if exists require_framework_on_publish on public.properties;
create trigger require_framework_on_publish before insert on public.properties for each row execute function public.require_framework_on_publish();

-- 10) Titular (y administración): lista de conexiones. Los datos del interesado solo se ven con la conexión verificada (el admin ve todo).
create or replace function public.my_connections()
returns jsonb language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); adm boolean; s public.connection_settings;
begin
  if uid is null or not public.is_active_user() then raise exception 'No autorizado' using errcode = '42501'; end if;
  adm := public.is_admin();
  select * into s from public.connection_settings where id = 1;
  return jsonb_build_object('enabled', s.enabled, 'pay_instructions', s.pay_instructions, 'pay_qr_url', s.pay_qr_url,
    'items', coalesce((select jsonb_agg(jsonb_build_object(
        'id', c.id, 'code', c.code, 'number', c.number, 'status', c.status, 'property_id', c.property_id, 'title', p.title, 'property_code', p.code_number,
        'operation', c.operation, 'interested_type', c.interested_type, 'message', c.message, 'created_at', c.created_at,
        'interested_name', case when adm or c.status = 'conexion_generada' then c.interested_name
                                else split_part(btrim(c.interested_name), ' ', 1) || coalesce(' ' || upper(left(nullif(split_part(btrim(c.interested_name), ' ', 2), ''), 1)) || '.', '') end,
        'interested_phone', case when adm or c.status = 'conexion_generada' then c.interested_phone end,
        'interested_email', case when adm or c.status = 'conexion_generada' then c.interested_email end,
        'fee_bs', c.fee_bs, 'fee_calc', case when adm then c.fee_calc end, 'accepted_at', c.accepted_at, 'proof_at', c.proof_at, 'verified_at', c.verified_at,
        'review_note', c.review_note, 'proof_path', case when adm then c.proof_path end, 'framework_version', c.framework_version,
        'titular_name', case when adm then (select display_name from public.profiles where id = c.titular_id) end) order by c.created_at desc)
      from public.connections c join public.properties p on p.id = c.property_id
      where (adm or c.titular_id = uid) and c.created_at > now() - interval '24 months'), '[]'::jsonb));
end $$;

-- 11) El titular acepta o rechaza. Al aceptar nace la obligación: se congela la tarifa, se numera la constancia y se guarda la versión del contrato marco.
create or replace function public.respond_connection(p_id uuid, p_accept boolean)
returns jsonb language plpgsql security definer set search_path = public as $$
declare c public.connections; uid uuid := auth.uid(); s public.connection_settings; fee jsonb; yr integer; seq integer; num text; snap jsonb; who text;
begin
  if uid is null or not public.is_active_user() then raise exception 'No autorizado' using errcode = '42501'; end if;
  select * into c from public.connections where id = p_id for update;
  if not found or (c.titular_id is distinct from uid and not public.is_admin()) then raise exception 'Solicitud no encontrada'; end if;
  if c.status <> 'solicitada' then raise exception 'Esta solicitud ya fue respondida'; end if;
  who := case when c.titular_id = uid then 'titular' else 'admin' end;
  if not p_accept then
    update public.connections set status = 'rechazada' where id = c.id;
    perform public._conn_log(c.id, who, 'rechazada', c.status, 'rechazada');
    return jsonb_build_object('status', 'rechazada');
  end if;
  select * into s from public.connection_settings where id = 1;
  if s.enabled and char_length(btrim(s.framework_text)) > 0 and c.titular_id is not null
     and not exists (select 1 from public.framework_acceptances a where a.user_id = c.titular_id and a.version = s.framework_version) then
    raise exception 'Antes de aceptar debes aceptar el contrato marco de Bastet' using errcode = 'P0403', hint = 'framework';
  end if;
  fee := public._connection_fee(c.property_id);
  yr := extract(year from ((now() at time zone 'UTC') - interval '4 hours'))::integer;
  insert into public.connection_counters (year, last_number) values (yr, 1)
  on conflict (year) do update set last_number = public.connection_counters.last_number + 1 returning last_number into seq;
  num := 'BST-CX-' || yr || '-' || lpad(seq::text, 4, '0');
  select jsonb_build_object('title', p.title, 'code_number', p.code_number, 'location', p.location, 'address', p.address, 'price', p.price, 'currency', p.currency,
                            'operation', p.operation, 'property_type', p.property_type) into snap from public.properties p where p.id = c.property_id;
  update public.connections set status = 'aceptada_pendiente_pago', accepted_at = now(), number = num, fee_bs = (fee ->> 'fee_bs')::numeric, fee_calc = fee,
         property_snapshot = snap, framework_version = case when s.enabled and char_length(btrim(s.framework_text)) > 0 then s.framework_version end where id = c.id;
  perform public._conn_log(c.id, who, 'aceptada', c.status, 'aceptada_pendiente_pago', jsonb_build_object('number', num, 'fee', fee));
  return jsonb_build_object('status', 'aceptada_pendiente_pago', 'number', num, 'fee_bs', (fee ->> 'fee_bs')::numeric);
end $$;

-- 12) El titular avisa que subió el comprobante de la tarifa (el archivo ya está en connection-proofs/<id del titular>/…)
create or replace function public.attach_connection_proof(p_id uuid, p_path text)
returns void language plpgsql security definer set search_path = public as $$
declare c public.connections; uid uuid := auth.uid();
begin
  if uid is null or not public.is_active_user() then raise exception 'No autorizado' using errcode = '42501'; end if;
  if p_path is null or char_length(p_path) > 300 or p_path not like uid::text || '/%' or p_path like '%..%' then raise exception 'Comprobante inválido'; end if;
  select * into c from public.connections where id = p_id for update;
  if not found or c.titular_id is distinct from uid then raise exception 'Conexión no encontrada'; end if;
  if c.status not in ('aceptada_pendiente_pago', 'comprobante_enviado') then raise exception 'Esta conexión no espera un comprobante'; end if;
  update public.connections set proof_path = p_path, proof_at = now(), status = 'comprobante_enviado', review_note = null where id = c.id;
  perform public._conn_log(c.id, 'titular', 'comprobante_enviado', c.status, 'comprobante_enviado', jsonb_build_object('path', p_path));
end $$;

-- 13) Administración verifica o rechaza el comprobante; al verificar se genera la conexión y se revelan los datos del interesado
create or replace function public.admin_review_connection_proof(p_id uuid, p_approve boolean, p_note text default null)
returns void language plpgsql security definer set search_path = public as $$
declare c public.connections; nt text := nullif(btrim(coalesce(p_note, '')), '');
begin
  if not public.is_admin() then raise exception 'Solo administradores' using errcode = '42501'; end if;
  select * into c from public.connections where id = p_id for update;
  if not found or c.status <> 'comprobante_enviado' then raise exception 'No hay un comprobante por revisar en esta conexión'; end if;
  if p_approve then
    update public.connections set status = 'conexion_generada', verified_at = now(), verified_by = auth.uid(), review_note = nt where id = c.id;
    perform public._conn_log(c.id, 'admin', 'pago_verificado_y_conexion', c.status, 'conexion_generada', jsonb_build_object('fee_bs', c.fee_bs, 'note', nt));
  else
    if nt is null then raise exception 'Escribe el motivo del rechazo para que el titular pueda corregirlo'; end if;
    update public.connections set status = 'aceptada_pendiente_pago', proof_path = null, proof_at = null, review_note = nt where id = c.id;
    perform public._conn_log(c.id, 'admin', 'comprobante_rechazado', c.status, 'aceptada_pendiente_pago', jsonb_build_object('note', nt, 'path', c.proof_path));
  end if;
end $$;

create or replace function public.admin_cancel_connection(p_id uuid, p_note text)
returns void language plpgsql security definer set search_path = public as $$
declare c public.connections; nt text := nullif(btrim(coalesce(p_note, '')), '');
begin
  if not public.is_admin() then raise exception 'Solo administradores' using errcode = '42501'; end if;
  if nt is null then raise exception 'Escribe el motivo de la cancelación'; end if;
  select * into c from public.connections where id = p_id for update;
  if not found or c.status in ('cancelada', 'rechazada') then raise exception 'Conexión no encontrada o ya cerrada'; end if;
  update public.connections set status = 'cancelada', cancelled_note = nt where id = c.id;
  perform public._conn_log(c.id, 'admin', 'cancelada', c.status, 'cancelada', jsonb_build_object('note', nt));
end $$;

create or replace function public.connection_events(p_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Solo administradores' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('actor', e.actor, 'event', e.event, 'from', e.from_status, 'to', e.to_status, 'data', e.data, 'at', e.created_at) order by e.created_at, e.id)
                     from public.connection_events e where e.connection_id = p_id), '[]'::jsonb);
end $$;

-- 14) Vista previa de la tarifa de una propiedad (titular o administración)
create or replace function public.preview_connection_fee(p_property uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare owner uuid;
begin
  if auth.uid() is null or not public.is_active_user() then raise exception 'No autorizado' using errcode = '42501'; end if;
  select owner_id into owner from public.properties where id = p_property;
  if not found or (owner is distinct from auth.uid() and not public.is_admin()) then raise exception 'Propiedad no encontrada'; end if;
  return public._connection_fee(p_property);
end $$;

-- 15) Administración: ajustes, matriz, historial
create or replace function public.get_connection_settings()
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Solo administradores' using errcode = '42501'; end if;
  return jsonb_build_object('settings', (select to_jsonb(s) from public.connection_settings s where id = 1),
    'bounds', coalesce((select jsonb_agg(to_jsonb(b) order by b.operation) from public.fee_bounds b), '[]'::jsonb),
    'rules', coalesce((select jsonb_agg(to_jsonb(r) order by r.operation, r.priority desc, r.id) from public.fee_rules r), '[]'::jsonb),
    'history', coalesce((select jsonb_agg(jsonb_build_object('rule_id', h.rule_id, 'action', h.action, 'before', h.old_data, 'after', h.new_data, 'at', h.created_at) order by h.created_at desc)
                           from (select * from public.fee_rule_events order by created_at desc limit 50) h), '[]'::jsonb));
end $$;

create or replace function public.admin_update_connection_settings(p_enabled boolean, p_pay_instructions text, p_pay_qr_url text, p_framework_text text)
returns void language plpgsql security definer set search_path = public as $$
declare cur public.connection_settings; ft text := btrim(coalesce(p_framework_text, ''));
begin
  if not public.is_admin() then raise exception 'Solo administradores' using errcode = '42501'; end if;
  select * into cur from public.connection_settings where id = 1;
  if p_enabled and char_length(btrim(coalesce(p_pay_instructions, ''))) < 10 then raise exception 'Antes de activar, escribe las instrucciones de pago (cuenta o QR)'; end if;
  if p_enabled and char_length(ft) < 100 then raise exception 'Antes de activar, pega el texto del contrato marco (revisado por un abogado)'; end if;
  update public.connection_settings set enabled = coalesce(p_enabled, false), pay_instructions = btrim(coalesce(p_pay_instructions, '')),
         pay_qr_url = nullif(btrim(coalesce(p_pay_qr_url, '')), ''), framework_text = ft,
         framework_version = case when ft is distinct from cur.framework_text then cur.framework_version + 1 else cur.framework_version end, updated_at = now() where id = 1;
end $$;

create or replace function public.admin_save_fee_rule(p_id bigint, p_operation text, p_property_type text, p_min_bs numeric, p_max_bs numeric, p_fee_bs numeric,
                                                      p_priority integer, p_label text, p_active boolean)
returns bigint language plpgsql security definer set search_path = public as $$
declare b public.fee_bounds; old_row jsonb; rid bigint := p_id; pt text := nullif(btrim(coalesce(p_property_type, '')), '');
begin
  if not public.is_admin() then raise exception 'Solo administradores' using errcode = '42501'; end if;
  select * into b from public.fee_bounds where operation = p_operation;
  if not found then raise exception 'Operación inválida'; end if;
  if p_fee_bs is null or p_fee_bs < b.min_bs or p_fee_bs > b.max_bs then
    raise exception 'La tarifa de % debe estar entre Bs % y Bs %', p_operation, b.min_bs, b.max_bs; end if;
  if p_min_bs is not null and p_max_bs is not null and p_min_bs > p_max_bs then raise exception 'El valor mínimo no puede superar al máximo'; end if;
  if p_id is null then
    insert into public.fee_rules (operation, property_type, value_min_bs, value_max_bs, fee_bs, priority, label, active)
    values (p_operation, pt, p_min_bs, p_max_bs, p_fee_bs, coalesce(p_priority, 0), nullif(btrim(coalesce(p_label, '')), ''), coalesce(p_active, true)) returning id into rid;
    insert into public.fee_rule_events (rule_id, actor, action, new_data) select rid, auth.uid(), 'creada', to_jsonb(r) from public.fee_rules r where r.id = rid;
  else
    select to_jsonb(r) into old_row from public.fee_rules r where r.id = p_id;
    if old_row is null then raise exception 'Regla no encontrada'; end if;
    update public.fee_rules set operation = p_operation, property_type = pt, value_min_bs = p_min_bs, value_max_bs = p_max_bs, fee_bs = p_fee_bs,
           priority = coalesce(p_priority, 0), label = nullif(btrim(coalesce(p_label, '')), ''), active = coalesce(p_active, true), provisional = false, updated_at = now() where id = p_id;
    insert into public.fee_rule_events (rule_id, actor, action, old_data, new_data) select p_id, auth.uid(), 'editada', old_row, to_jsonb(r) from public.fee_rules r where r.id = p_id;
  end if;
  return rid;
end $$;

create or replace function public.admin_delete_fee_rule(p_id bigint)
returns void language plpgsql security definer set search_path = public as $$
declare old_row jsonb;
begin
  if not public.is_admin() then raise exception 'Solo administradores' using errcode = '42501'; end if;
  select to_jsonb(r) into old_row from public.fee_rules r where r.id = p_id;
  if old_row is null then raise exception 'Regla no encontrada'; end if;
  delete from public.fee_rules where id = p_id;
  insert into public.fee_rule_events (rule_id, actor, action, old_data) values (p_id, auth.uid(), 'eliminada', old_row);
end $$;

-- 16) Permisos
revoke all on function public.request_connection(uuid, text, text, text, text, boolean), public.my_framework(), public.accept_framework_contract(integer),
  public.require_framework_on_publish(), public.my_connections(), public.respond_connection(uuid, boolean), public.attach_connection_proof(uuid, text),
  public.admin_review_connection_proof(uuid, boolean, text), public.admin_cancel_connection(uuid, text), public.connection_events(uuid),
  public.preview_connection_fee(uuid), public.get_connection_settings(), public.admin_update_connection_settings(boolean, text, text, text),
  public.admin_save_fee_rule(bigint, text, text, numeric, numeric, numeric, integer, text, boolean), public.admin_delete_fee_rule(bigint) from public, anon;
grant execute on function public.request_connection(uuid, text, text, text, text, boolean) to anon, authenticated;
grant execute on function public.my_framework(), public.accept_framework_contract(integer), public.my_connections(), public.respond_connection(uuid, boolean),
  public.attach_connection_proof(uuid, text), public.admin_review_connection_proof(uuid, boolean, text), public.admin_cancel_connection(uuid, text),
  public.connection_events(uuid), public.preview_connection_fee(uuid), public.get_connection_settings(), public.admin_update_connection_settings(boolean, text, text, text),
  public.admin_save_fee_rule(bigint, text, text, numeric, numeric, numeric, integer, text, boolean), public.admin_delete_fee_rule(bigint) to authenticated;

notify pgrst, 'reload schema';

-- =====================================================================
-- Bastet · Blindaje de datos y antiabuso (fase 2, paso B2)
-- Idempotente: se puede correr completo más de una vez. Correr DESPUÉS de todo lo demás (connections.sql incluida).
--
-- Qué cierra (hallazgos de la auditoría del 2026-11-03):
--  1) CONTACTO: el visitante podía leer properties.whatsapp y profiles.contact_whatsapp con la clave pública de la API (y así saltarse la tarifa
--     de conexión). Ahora esas columnas no se leen; el contacto solo sale por public_property_contact / public_agent_contact, que respetan el
--     modelo vigente (con conexiones activas no entregan el teléfono).
--  2) CUENTAS: cualquier persona con sesión (basta una cuenta de Google) podía leer TODAS las columnas de TODAS las propiedades, incluido el
--     teléfono privado del propietario (owner_whatsapp), y las no disponibles. Ahora ve solo columnas públicas de propiedades disponibles (y las
--     suyas); sus propios teléfonos los obtiene con my_property_contacts().
--  3) FOTOS Y AVATARES: cualquier usuario activo podía borrar o reemplazar las fotos de propiedades y los avatares de otras personas. Ahora solo
--     el dueño de la propiedad (carpeta = id de la propiedad) o de la cuenta (carpeta = su id), o un administrador.
--  4) ANTIABUSO: límite de intentos por IP en los formularios públicos y en las consultas por código (spam y fuerza bruta).
--  5) PERMISOS MÍNIMOS: el visitante ya no tiene permisos de escritura sobre las tablas (antes solo los frenaba la seguridad por filas).
--  6) Perfiles públicos solo de agentes con propiedades disponibles (no se puede listar a todos los usuarios); sin planes públicos.
-- =====================================================================

do $$
begin
  if to_regprocedure('public.request_connection(uuid, text, text, text, text, boolean)') is null then raise exception 'Primero corre schema.sql completo (incluye connections.sql)'; end if;
end $$;

-- 1) Límite de intentos por IP (la IP la entrega el gateway en request.headers; sin cabeceras —SQL Editor, pruebas internas— no se limita)
create table if not exists public.rate_limits (
  key          text not null,
  action       text not null,
  window_start timestamptz not null,
  n            integer not null default 0,
  primary key (key, action, window_start)
);
alter table public.rate_limits enable row level security;
revoke all on public.rate_limits from anon, authenticated;

create or replace function public._throttle(p_action text, p_max integer, p_window_seconds integer)
returns void language plpgsql security definer set search_path = public as $$
declare hdr text; h json; ip text; ws timestamptz; cur integer;
begin
  hdr := current_setting('request.headers', true);
  if hdr is null or hdr = '' then return; end if;
  begin h := hdr::json; exception when others then return; end;
  -- La IP del cliente: cf-connecting-ip si existe; si no, el ÚLTIMO elemento de x-forwarded-for (el que añade el gateway, no el que escribe el cliente)
  ip := nullif(btrim(coalesce(h ->> 'cf-connecting-ip', (string_to_array(coalesce(h ->> 'x-forwarded-for', ''), ','))[array_length(string_to_array(coalesce(h ->> 'x-forwarded-for', ''), ','), 1)], h ->> 'x-real-ip', '')), '');
  if ip is null then return; end if;
  ws := to_timestamp(floor(extract(epoch from now()) / p_window_seconds) * p_window_seconds);
  select n into cur from public.rate_limits where key = ip and action = p_action and window_start = ws;
  if coalesce(cur, 0) >= p_max then   -- se verifica ANTES de sumar: si se lanzara el error después, la transacción desharía el conteo
    raise exception 'Demasiados intentos. Espera unos minutos e inténtalo de nuevo.' using errcode = 'P0429';
  end if;
  insert into public.rate_limits (key, action, window_start, n) values (ip, p_action, ws, 1)
  on conflict (key, action, window_start) do update set n = public.rate_limits.n + 1;
  if random() < 0.01 then delete from public.rate_limits where window_start < now() - interval '2 days'; end if;
end $$;
revoke all on function public._throttle(text, integer, integer) from public, anon, authenticated;

-- 2) Funciones públicas existentes, con límite por IP (copias de su última definición + una línea)
create or replace function public.request_connection(p_property uuid, p_name text, p_phone text, p_email text default null, p_message text default null, p_consent boolean default false)
returns text language plpgsql security definer set search_path = public as $$
declare prop record; nm text := btrim(coalesce(p_name, '')); ph text := regexp_replace(coalesce(p_phone, ''), '[^0-9+]', '', 'g'); em text := nullif(btrim(coalesce(p_email, '')), '');
        msg text := nullif(btrim(coalesce(p_message, '')), ''); it text; cd text; tries int := 0;
begin
  perform public._throttle('request_connection', 8, 600);
  if not public.connections_enabled() then raise exception 'Las solicitudes de contacto todavía no están activas'; end if;
  if p_consent is not true then raise exception 'Debes aceptar que se compartan tus datos con el agente'; end if;
  select id, owner_id, coalesce(operation, 'venta') as operation, status, expires_at into prop from public.properties where id = p_property;   -- sin operación = venta (listados antiguos)
  if not found or prop.status is distinct from 'available' or prop.operation not in ('venta', 'alquiler', 'anticretico')
     or (prop.expires_at is not null and prop.expires_at < now()) then raise exception 'Esta propiedad no está disponible'; end if;
  if char_length(nm) not between 2 and 120 then raise exception 'Escribe tu nombre'; end if;
  if char_length(regexp_replace(ph, '[^0-9]', '', 'g')) not between 7 and 15 then raise exception 'Escribe un número de WhatsApp válido'; end if;
  if em is not null and em !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'El correo no es válido'; end if;
  if msg is not null and char_length(msg) > 500 then raise exception 'El mensaje es demasiado largo (máximo 500 caracteres)'; end if;
  if exists (select 1 from public.connections c where c.property_id = p_property and c.interested_phone = ph and c.status in ('solicitada', 'aceptada_pendiente_pago', 'comprobante_enviado', 'conexion_generada')) then
    raise exception 'Ya enviaste una solicitud para esta propiedad'; end if;
  if (select count(*) from public.connections where interested_phone = ph and status = 'solicitada') >= 5 then
    raise exception 'Ya tienes 5 solicitudes esperando respuesta. Espera a que los agentes respondan.'; end if;
  it := case prop.operation when 'venta' then 'comprador' when 'alquiler' then 'arrendatario' else 'anticresista' end;
  loop
    cd := upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 10));
    begin
      insert into public.connections (code, property_id, titular_id, operation, interested_type, interested_name, interested_phone, interested_email, message)
      values (cd, p_property, prop.owner_id, prop.operation, it, nm, ph, em, msg);
      exit;
    exception when unique_violation then tries := tries + 1; if tries > 5 then raise; end if;
    end;
  end loop;
  perform public._conn_log((select id from public.connections where code = cd), 'interested', 'solicitada', null, 'solicitada', jsonb_build_object('type', it));
  return cd;
end $$;

create or replace function public.create_stay_booking(p_property uuid, p_from date, p_to date, p_guests integer, p_name text, p_phone text, p_email text default null)
returns text language plpgsql security definer set search_path = public as $$
declare s public.stay_settings; prop record; v_n integer; v_price numeric; v_total numeric; v_fee numeric; v_rate numeric; v_feebs numeric; tries int := 0; cd text;
        nm text := btrim(coalesce(p_name, '')); ph text := regexp_replace(coalesce(p_phone, ''), '[^0-9+]', '', 'g'); em text := nullif(btrim(coalesce(p_email, '')), '');
begin
  perform public._throttle('create_stay_booking', 8, 600);
  perform public.stay_expire_pending();
  select * into s from public.stay_settings where id = 1;
  if not found or not s.enabled then raise exception 'Las reservas en línea todavía no están activas'; end if;
  select id, owner_id, price, currency, operation, status, expires_at into prop from public.properties where id = p_property;
  if not found or prop.operation is distinct from 'temporal' or prop.status is distinct from 'available' or (prop.expires_at is not null and prop.expires_at < now()) then
    raise exception 'Este alojamiento no está disponible'; end if;
  if p_from is null or p_to is null or p_from < public.bo_today() then raise exception 'Elige una fecha de llegada que no haya pasado'; end if;
  v_n := p_to - p_from;
  if v_n < 1 or v_n > 90 then raise exception 'La estadía debe ser de 1 a 90 noches'; end if;
  if p_guests is null or p_guests not between 1 and 16 then raise exception 'Indica de 1 a 16 huéspedes'; end if;
  if char_length(nm) not between 2 and 60 then raise exception 'Escribe tu nombre (entre 2 y 60 letras)'; end if;
  if char_length(regexp_replace(ph, '[^0-9]', '', 'g')) not between 7 and 15 then raise exception 'Escribe un número de WhatsApp válido'; end if;
  if em is not null and em !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'El correo no es válido'; end if;
  if exists (select 1 from public.stay_blocks b where b.property_id = p_property and b.from_date < p_to and (b.to_date is null or b.to_date >= p_from)) then
    raise exception 'Esas fechas no están disponibles'; end if;
  if exists (select 1 from public.stay_bookings k where k.property_id = p_property and k.check_in < p_to and k.check_out > p_from
               and k.status in ('aceptada_pendiente_pago', 'comprobante_enviado', 'pago_en_revision', 'pago_verificado', 'conexion_generada', 'en_disputa')) then
    raise exception 'Esas fechas ya están reservadas'; end if;
  if (select count(*) from public.stay_bookings where guest_phone = ph and status = 'pendiente_respuesta_anfitrion') >= 3 then
    raise exception 'Ya tienes 3 solicitudes esperando respuesta. Espera a que respondan los anfitriones.'; end if;
  v_price := nullif(regexp_replace(prop.price::text, '[^0-9]', '', 'g'), '')::numeric;
  if v_price is null or v_price <= 0 then raise exception 'Este alojamiento no tiene precio por noche definido'; end if;
  v_total := v_price * v_n;
  v_fee := round(v_total * s.fee_percent / 100, 2);
  v_rate := s.bob_per_usd;
  v_feebs := round(case when prop.currency = 'BOB' then v_fee else v_fee * v_rate end, 2);
  loop
    cd := upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 10));
    begin
      insert into public.stay_bookings (code, property_id, host_id, guest_name, guest_phone, guest_email, guests, check_in, check_out, nights, currency, nightly_price, total,
                                        fee_amount, bob_per_usd_used, fee_bs, respond_by)
      values (cd, p_property, prop.owner_id, nm, ph, em, p_guests, p_from, p_to, v_n, prop.currency, v_price, v_total, v_fee, v_rate, v_feebs, now() + make_interval(hours => s.response_hours));
      exit;
    exception when unique_violation then
      tries := tries + 1; if tries > 5 then raise; end if;
    end;
  end loop;
  perform public.stay_log((select id from public.stay_bookings where code = cd), 'guest', 'solicitada', null, 'pendiente_respuesta_anfitrion',
                          jsonb_build_object('total', v_total, 'currency', prop.currency, 'fee_bs', v_feebs, 'bob_per_usd', v_rate));
  return cd;
end $$;

create or replace function public.cancel_stay_booking(p_code text, p_reason text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare b public.stay_bookings; s public.stay_settings; late boolean := false; paid boolean; refund numeric := 0; hostret numeric := null; due numeric := null;
        rs text := nullif(btrim(coalesce(p_reason, '')), '');
begin
  perform public._throttle('cancel_stay_booking', 20, 600);
  perform public.stay_expire_pending();
  select * into b from public.stay_bookings where code = upper(btrim(coalesce(p_code, ''))) for update;
  if not found or b.status not in ('pendiente_respuesta_anfitrion', 'aceptada_pendiente_pago', 'comprobante_enviado', 'pago_en_revision', 'conexion_generada') then
    raise exception 'Esta reserva no se puede cancelar'; end if;
  select * into s from public.stay_settings where id = 1;
  paid := b.status = 'conexion_generada';
  if paid then
    late := now() > coalesce(b.verified_at, now()) + make_interval(hours => s.free_cancel_hours);
    if late then hostret := b.fee_amount; refund := 0; due := b.total - b.fee_amount - hostret;       -- se queda 10 % Bastet + 10 % anfitrión
    else refund := b.fee_bs; due := b.total - b.fee_amount; end if;                                       -- el anfitrión devuelve el 90 % si lo recibió
  elsif b.status in ('comprobante_enviado', 'pago_en_revision') then
    refund := b.fee_bs;                                                                                   -- el administrador confirma si hubo pago que devolver
  end if;
  update public.stay_bookings set status = 'cancelada', cancelled_by = 'guest', cancelled_at = now(), cancel_reason = rs, late_cancel = late,
         bastet_refund_bs = refund, host_retention = hostret, host_refund_due = due where id = b.id;
  perform public.stay_log(b.id, 'guest', 'cancelada_por_huesped', b.status, 'cancelada', jsonb_build_object('late', late, 'bastet_refund_bs', refund, 'host_retention', hostret, 'host_refund_due', due, 'reason', rs));
  return jsonb_build_object('late_cancel', late, 'bastet_refund_bs', refund, 'host_retention', hostret, 'host_refund_due', due, 'paid', paid);
end $$;

create or replace function public.attach_stay_proof(p_code text, p_path text)
returns void language plpgsql security definer set search_path = public as $$
declare b public.stay_bookings; cd text := upper(btrim(coalesce(p_code, '')));
begin
  perform public._throttle('attach_stay_proof', 20, 600);
  if p_path is null or char_length(p_path) > 300 or p_path not like cd || '/%' or p_path like '%..%' then raise exception 'Comprobante inválido'; end if;
  select * into b from public.stay_bookings where code = cd for update;
  if not found or b.status not in ('aceptada_pendiente_pago', 'comprobante_enviado', 'pago_en_revision') then raise exception 'Esta reserva no espera un comprobante'; end if;
  update public.stay_bookings set proof_path = p_path, proof_at = now(), status = 'comprobante_enviado', review_note = null where id = b.id;
  perform public.stay_log(b.id, 'guest', 'comprobante_enviado', b.status, 'comprobante_enviado', jsonb_build_object('path', p_path));
end $$;

create or replace function public.get_stay_booking(p_code text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare b public.stay_bookings; s public.stay_settings; prop record; contact text; pay boolean; reveal boolean; free_until timestamptz; host_name text;
begin
  perform public._throttle('get_stay_booking', 90, 60);
  perform public.stay_expire_pending();
  select * into b from public.stay_bookings where code = upper(btrim(coalesce(p_code, '')));
  if not found then return jsonb_build_object('found', false); end if;
  select * into s from public.stay_settings where id = 1;
  select title, location, photos[1] as photo, whatsapp into prop from public.properties where id = b.property_id;
  select display_name, contact_whatsapp into host_name, contact from public.profiles where id = b.host_id;
  reveal := b.status = 'conexion_generada';
  pay := b.status in ('aceptada_pendiente_pago', 'comprobante_enviado', 'pago_en_revision');
  free_until := b.verified_at + make_interval(hours => s.free_cancel_hours);
  return jsonb_build_object('found', true, 'code', b.code, 'status', b.status, 'title', prop.title, 'location', prop.location, 'photo', prop.photo,
    'guest_name', b.guest_name, 'guests', b.guests, 'check_in', b.check_in, 'check_out', b.check_out, 'nights', b.nights, 'currency', b.currency,
    'total', b.total, 'fee_amount', b.fee_amount, 'fee_bs', b.fee_bs, 'balance', b.total - b.fee_amount, 'fee_percent', s.fee_percent,
    'respond_by', b.respond_by, 'pay_by', case when b.status = 'aceptada_pendiente_pago' and s.pay_window_hours is not null then b.accepted_at + make_interval(hours => s.pay_window_hours) end, 'proof_sent', b.proof_path is not null, 'review_note', b.review_note,
    'pay_instructions', case when pay then s.pay_instructions end, 'pay_qr_url', case when pay then s.pay_qr_url end,
    'host_name', case when reveal then host_name end, 'host_whatsapp', case when reveal then coalesce(contact, prop.whatsapp) end,
    'free_cancel_until', case when reveal then free_until end, 'free_cancel_hours', s.free_cancel_hours,
    'is_late_cancel', reveal and now() > free_until,
    'can_cancel', b.status in ('pendiente_respuesta_anfitrion', 'aceptada_pendiente_pago', 'comprobante_enviado', 'pago_en_revision', 'conexion_generada'),
    'cancelled_by', b.cancelled_by, 'late_cancel', b.late_cancel, 'bastet_refund_bs', b.bastet_refund_bs, 'host_retention', b.host_retention, 'host_refund_due', b.host_refund_due);
end $$;

create or replace function public.verify_stay_booking(p_code text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare b public.stay_bookings; prop record; host_name text; contact text; ok boolean;
begin
  perform public._throttle('verify_stay_booking', 30, 60);
  perform public.stay_expire_pending();
  select * into b from public.stay_bookings where code = upper(btrim(coalesce(p_code, '')));
  if not found then return jsonb_build_object('found', false); end if;
  select title, location, address, photos, latitude, longitude, whatsapp into prop from public.properties where id = b.property_id;
  select display_name, contact_whatsapp into host_name, contact from public.profiles where id = b.host_id;
  ok := b.verified_at is not null and b.status in ('conexion_generada', 'en_disputa');
  return jsonb_build_object('found', true, 'code', b.code, 'status', b.status, 'verified', ok, 'verified_at', b.verified_at,
    'title', prop.title, 'location', prop.location, 'address', prop.address, 'latitude', prop.latitude, 'longitude', prop.longitude,
    'photos', to_jsonb(coalesce(prop.photos, '{}'::text[])),
    'check_in', b.check_in, 'check_out', b.check_out, 'nights', b.nights, 'guests', b.guests,
    'guest_name', split_part(btrim(b.guest_name), ' ', 1) || coalesce(' ' || upper(left(nullif(split_part(btrim(b.guest_name), ' ', 2), ''), 1)) || '.', ''),
    'currency', b.currency, 'total', b.total, 'fee_bs', b.fee_bs, 'balance', b.total - b.fee_amount,
    'host_name', case when ok then host_name end, 'host_whatsapp', case when ok then coalesce(contact, prop.whatsapp) end,
    'cancelled_by', b.cancelled_by, 'created_at', b.created_at,
    'events', coalesce((select jsonb_agg(jsonb_build_object('event', e.event, 'at', e.created_at) order by e.created_at, e.id)
                          from public.stay_booking_events e
                         where e.booking_id = b.id and e.event in ('solicitada', 'aceptada', 'rechazada', 'expirada_sin_respuesta', 'expirada_sin_pago', 'comprobante_enviado',
                               'comprobante_rechazado', 'pago_verificado_y_conexion', 'cancelada_por_huesped', 'cancelada_por_anfitrion', 'disputa_abierta', 'disputa_cerrada')), '[]'::jsonb),
    'busy', coalesce((select jsonb_agg(jsonb_build_object('from', k.check_in, 'to', k.check_out - 1))
                        from public.stay_bookings k
                       where k.property_id = b.property_id and k.id <> b.id and k.check_out - 1 >= public.bo_today()
                         and k.status in ('aceptada_pendiente_pago', 'comprobante_enviado', 'pago_en_revision', 'pago_verificado', 'conexion_generada', 'en_disputa')), '[]'::jsonb));
end $$;

create or replace function public.submit_property_lead(
  p_property_id uuid, p_name text, p_whatsapp text, p_message text, p_consent boolean
) returns boolean
language plpgsql security definer set search_path = public as $$
declare
  prop   record;
  nm     text := btrim(coalesce(p_name, ''));
  ph     text := regexp_replace(coalesce(p_whatsapp, ''), '[\s().-]', '', 'g');
  msg    text := nullif(btrim(coalesce(p_message, '')), '');
begin
  perform public._throttle('submit_property_lead', 8, 600);
  if p_consent is not true then raise exception 'Debes aceptar que compartamos tus datos con el agente.'; end if;
  if char_length(nm) < 3 or char_length(nm) > 120 then raise exception 'Escribe tu nombre (entre 3 y 120 caracteres).'; end if;
  if ph !~ '^\+?[0-9]{7,15}$' then raise exception 'Escribe un número de WhatsApp válido (solo dígitos, con + si incluye código de país).'; end if;
  if msg is not null and char_length(msg) > 500 then raise exception 'El mensaje no puede pasar de 500 caracteres.'; end if;

  select id, owner_id into prop from public.properties where id = p_property_id and status = 'available';
  if not found then raise exception 'Esta propiedad ya no está disponible.'; end if;

  -- Límites contra abuso: 3 por mismo teléfono y propiedad en 24 h, 30 por propiedad al día y 500 en total al día.
  if (select count(*) from public.property_leads
       where property_id = prop.id and whatsapp = ph and created_at > now() - interval '24 hours') >= 3 then
    raise exception 'Ya recibimos tus solicitudes para esta propiedad. El agente te contactará pronto.';
  end if;
  if (select count(*) from public.property_leads
       where property_id = prop.id and created_at > now() - interval '24 hours') >= 30
     or (select count(*) from public.property_leads where created_at > now() - interval '24 hours') >= 500 then
    raise exception 'Hay muchas solicitudes en este momento. Inténtalo más tarde o escríbenos por WhatsApp.';
  end if;

  insert into public.property_leads (property_id, agent_id, full_name, whatsapp, message, consent)
  values (prop.id, prop.owner_id, nm, ph, msg, true);
  return true;
end $$;

create or replace function public.submit_sell_request(p jsonb)
returns boolean language plpgsql security definer set search_path = public as $$
declare
  rid   uuid;
  ph    text := regexp_replace(coalesce(p->>'owner_phone', ''), '[\s().-]', '', 'g');
  docs  jsonb := coalesce(p->'documents', '[]'::jsonb);
  d     jsonb;
  st    text := coalesce(p->>'doc_status', '');
  needs boolean := coalesce((p->>'needs_legal_support')::boolean, false);
  nfoto int := 0;
  ndoc  int := 0;
begin
  perform public._throttle('submit_sell_request', 5, 600);
  begin rid := (p->>'id')::uuid; exception when others then raise exception 'Solicitud no válida.'; end;
  if rid is null then raise exception 'Solicitud no válida.'; end if;
  if coalesce((p->>'consent')::boolean, false) is not true then raise exception 'Debes aceptar que usemos tus datos para contactarte.'; end if;
  if ph !~ '^\+?[0-9]{7,15}$' then raise exception 'Escribe un número de WhatsApp válido (solo dígitos, con + si incluye código de país).'; end if;
  if jsonb_typeof(docs) <> 'array' then raise exception 'Documento no válido.'; end if;
  for d in select * from jsonb_array_elements(docs) loop
    -- cada archivo debe estar dentro de la carpeta de ESTA solicitud
    if coalesce(d->>'path', '') !~ ('^' || rid::text || '/[A-Za-z0-9._-]{1,120}$') then raise exception 'Documento no válido.'; end if;
    if d->>'type' = 'foto' then
      if d->>'path' !~* '\.(jpe?g|png|webp)$' then raise exception 'Las fotos deben ser JPG, PNG o WEBP.'; end if;
      nfoto := nfoto + 1;
    else ndoc := ndoc + 1; end if;
  end loop;
  if nfoto > 8 then raise exception 'Máximo 8 fotos.'; end if;
  if ndoc > 12 then raise exception 'Máximo 12 documentos.'; end if;
  -- sin documentos: se descartan los documentos pero se conservan las fotos
  if st = 'sin_documentos' then
    needs := true;
    docs := coalesce((select jsonb_agg(x) from jsonb_array_elements(docs) x where x->>'type' = 'foto'), '[]'::jsonb);
  end if;

  -- Límites contra abuso: 3 por mismo teléfono en 24 h y 200 en total al día.
  if (select count(*) from public.sell_requests where owner_phone = ph and created_at > now() - interval '24 hours') >= 3 then
    raise exception 'Ya recibimos tus solicitudes. Un asesor te contactará pronto.';
  end if;
  if (select count(*) from public.sell_requests where created_at > now() - interval '24 hours') >= 200 then
    raise exception 'Hay muchas solicitudes en este momento. Inténtalo más tarde o escríbenos por WhatsApp.';
  end if;

  insert into public.sell_requests (
    id, owner_name, owner_ci, owner_phone, owner_email, owner_role, property_type, operation, city, zone, address,
    latitude, longitude, price, currency, land_area, built_area, rooms, baths, description,
    doc_status, needs_legal_support, documents, consent)
  values (
    rid, btrim(coalesce(p->>'owner_name', '')), nullif(btrim(coalesce(p->>'owner_ci', '')), ''), ph,
    nullif(btrim(coalesce(p->>'owner_email', '')), ''), coalesce(nullif(p->>'owner_role', ''), 'propietario'),
    p->>'property_type', coalesce(nullif(p->>'operation', ''), 'venta'), btrim(coalesce(p->>'city', '')),
    nullif(btrim(coalesce(p->>'zone', '')), ''), btrim(coalesce(p->>'address', '')),
    nullif(p->>'latitude', '')::double precision, nullif(p->>'longitude', '')::double precision,
    nullif(p->>'price', '')::numeric, coalesce(nullif(p->>'currency', ''), 'USD'),
    nullif(p->>'land_area', '')::numeric, nullif(p->>'built_area', '')::numeric,
    nullif(p->>'rooms', '')::integer, nullif(p->>'baths', '')::integer,
    nullif(btrim(coalesce(p->>'description', '')), ''), st, needs, docs, true);
  return true;
exception
  when unique_violation then raise exception 'Esta solicitud ya fue enviada.';
  when check_violation or invalid_text_representation or numeric_value_out_of_range then
    raise exception 'Revisa los datos del formulario: hay un campo incompleto o con un valor no válido.';
end $$;

create or replace function public.submit_property_request(p jsonb)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  rid uuid;
  ph  text := regexp_replace(coalesce(p->>'contact_phone', ''), '[\s().-]', '', 'g');
  feats text[];
  num numeric;
begin
  perform public._throttle('submit_property_request', 8, 600);
  begin rid := (p->>'id')::uuid; exception when others then raise exception 'Solicitud no válida.'; end;
  if rid is null then raise exception 'Solicitud no válida.'; end if;
  if coalesce((p->>'consent')::boolean, false) is not true then raise exception 'Debes aceptar que usemos tus datos para contactarte.'; end if;
  if ph !~ '^\+?[0-9]{7,15}$' then raise exception 'Escribe un número de WhatsApp válido (solo dígitos, con + si incluye código de país).'; end if;
  if exists (select 1 from public.property_requests where id = rid) then return rid; end if;     -- reintento del mismo envío

  if (select count(*) from public.property_requests where contact_phone = ph and created_at > now() - interval '24 hours') >= 3 then
    raise exception 'Ya recibimos tus solicitudes. Un asesor te contactará pronto.';
  end if;
  if (select count(*) from public.property_requests where created_at > now() - interval '24 hours') >= 200 then
    raise exception 'Hay muchas solicitudes en este momento. Inténtalo más tarde o escríbenos por WhatsApp.';
  end if;

  select coalesce(array_agg(left(btrim(x), 40)) filter (where btrim(x) <> ''), '{}') into feats
    from jsonb_array_elements_text(case when jsonb_typeof(p->'features') = 'array' then p->'features' else '[]'::jsonb end) x;

  insert into public.property_requests (id, user_id, operation, property_type, city, zone, rooms_min, baths_min, area_min, area_max, features,
    budget_min, budget_max, currency, description, contact_name, contact_phone, contact_email, consent)
  values (rid, auth.uid(), p->>'operation', p->>'property_type', btrim(coalesce(p->>'city', '')), nullif(btrim(coalesce(p->>'zone', '')), ''),
    nullif(p->>'rooms_min', '')::int, nullif(p->>'baths_min', '')::int, nullif(p->>'area_min', '')::numeric, nullif(p->>'area_max', '')::numeric, feats,
    nullif(p->>'budget_min', '')::numeric, nullif(p->>'budget_max', '')::numeric, coalesce(nullif(p->>'currency', ''), 'USD'),
    nullif(btrim(coalesce(p->>'description', '')), ''), btrim(coalesce(p->>'contact_name', '')), ph, nullif(btrim(coalesce(p->>'contact_email', '')), ''), true);
  return rid;
end $$;

create or replace function public.submit_stay_review(p_token text, p_name text, p_rating integer, p_comment text)
returns boolean language plpgsql security definer set search_path = public as $$
declare i public.stay_review_invites; nm text := btrim(coalesce(p_name, '')); cm text := nullif(btrim(coalesce(p_comment, '')), '');
begin
  perform public._throttle('submit_stay_review', 8, 600);
  select * into i from public.stay_review_invites where token = upper(btrim(coalesce(p_token, ''))) for update;
  if not found then raise exception 'Este enlace de reseña no es válido'; end if;
  if i.used_at is not null then raise exception 'Este enlace de reseña ya se usó. ¡Gracias por tu opinión!'; end if;
  if char_length(nm) not between 2 and 60 then raise exception 'Escribe tu nombre (entre 2 y 60 letras)'; end if;
  if p_rating is null or p_rating not between 1 and 5 then raise exception 'Elige de 1 a 5 estrellas'; end if;
  if cm is not null and char_length(cm) > 1200 then raise exception 'La reseña es demasiado larga (máximo 1200 caracteres)'; end if;
  insert into public.stay_reviews (property_id, invite_id, guest_name, rating, comment) values (i.property_id, i.id, nm, p_rating, cm);
  update public.stay_review_invites set used_at = now() where id = i.id;
  return true;
end $$;

create or replace function public.get_review_invite(p_token text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare i record;
begin
  perform public._throttle('get_review_invite', 30, 60);
  select v.guest_name, v.used_at, p.title, p.location into i
    from public.stay_review_invites v join public.properties p on p.id = v.property_id
   where v.token = upper(btrim(coalesce(p_token, '')));
  if not found then return jsonb_build_object('valid', false); end if;
  return jsonb_build_object('valid', i.used_at is null, 'used', i.used_at is not null, 'guest_name', i.guest_name, 'title', i.title, 'location', i.location);
end $$;

create or replace function public.finish_property_request(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public._throttle('finish_property_request', 20, 600);
  update public.property_requests set status = 'finished', updated_at = now() where id = p_id;
  if not found then raise exception 'Solicitud no encontrada'; end if;
end $$;

create or replace function public.stay_booked_ranges(p_ids uuid[])
returns table (property_id uuid, from_date date, to_date date, confirmed boolean)
language plpgsql security definer set search_path = public as $$
begin
  perform public._throttle('stay_booked_ranges', 120, 60);
  if coalesce(array_length(p_ids, 1), 0) > 300 then raise exception 'Demasiadas propiedades'; end if;
  perform public.stay_expire_pending();
  return query
    select b.property_id, b.check_in, b.check_out - 1, b.status in ('pago_verificado', 'conexion_generada', 'en_disputa')
      from public.stay_bookings b
     where b.property_id = any (coalesce(p_ids, '{}'::uuid[]))
       and b.status in ('aceptada_pendiente_pago', 'comprobante_enviado', 'pago_en_revision', 'pago_verificado', 'conexion_generada', 'en_disputa')
       and b.check_out - 1 >= public.bo_today()
     order by b.check_in;
end $$;

-- La verificación de contratos pasa a plpgsql para poder limitarla (misma firma y mismo resultado)
create or replace function public.verify_exclusivity_contract(p_code text)
returns table (contract_number text, created_at timestamptz, agent_name text, template_version text, voided boolean, voided_at timestamptz)
language plpgsql security definer set search_path = public as $$
begin
  perform public._throttle('verify_contract', 30, 60);
  return query
  select c.contract_number, c.created_at, coalesce(nullif(btrim(p.display_name), ''), 'Agente de Bastet'), c.template_version, (c.voided_at is not null), c.voided_at
    from public.exclusivity_contracts c left join public.profiles p on p.id = c.agent_id
   where c.verification_code = upper(btrim(coalesce(p_code, ''))) limit 1;
end $$;

-- 3) Contacto: el teléfono ya no se lee de las tablas
revoke select (whatsapp) on public.properties from anon;
revoke select on public.properties from authenticated;
grant select (id, title, location, address, price, currency, exchange_rate, area, rooms, baths, description, photos, owner_id, featured, featured_until, sort_order, status, created_at, code_number, property_type, operation, floors, has_garage, garage_spots, has_storage, pets_allowed, kids_allowed, expires_at, latitude, longitude) on public.properties to authenticated;
revoke select (contact_whatsapp) on public.profiles from anon;

drop policy if exists "authenticated can read all properties" on public.properties;
create policy "authenticated can read all properties" on public.properties for select to authenticated
  using (status = 'available' or owner_id = auth.uid() or public.is_admin());

drop policy if exists "public can read active agent public info" on public.profiles;
create policy "public can read active agent public info" on public.profiles for select to anon
  using (is_active = true and exists (select 1 from public.properties p where p.owner_id = profiles.id and p.status = 'available'));

-- Teléfonos de las propiedades de quien consulta (o de todas, si es administrador)
create or replace function public.my_property_contacts()
returns table (property_id uuid, whatsapp text, owner_whatsapp text)
language plpgsql security definer set search_path = public stable as $$
begin
  if auth.uid() is null or not public.is_active_user() then raise exception 'No autorizado' using errcode = '42501'; end if;
  return query select p.id, p.whatsapp, p.owner_whatsapp from public.properties p where p.owner_id = auth.uid() or public.is_admin();
end $$;

-- Contacto público: solo cuando el modelo vigente permite el contacto directo (con conexiones activas o reservas activas, el contacto va por la
-- solicitud o la reserva). Devuelve el teléfono del agente que publicó o, si no tiene, el de la propiedad.
create or replace function public.public_property_contact(p_property uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare prop record; op text; allowed boolean; ph text;
begin
  perform public._throttle('public_contact', 40, 60);
  select owner_id, whatsapp, status, expires_at, coalesce(operation, 'venta') as operation into prop from public.properties where id = p_property;
  if not found or prop.status is distinct from 'available' or (prop.expires_at is not null and prop.expires_at < now()) then return jsonb_build_object('allowed', false); end if;
  allowed := case when prop.operation = 'temporal' then not public.stay_booking_enabled() else not public.connections_enabled() end;
  if not allowed then return jsonb_build_object('allowed', false, 'via', case when prop.operation = 'temporal' then 'reserva' else 'solicitud' end); end if;
  select nullif(btrim(contact_whatsapp), '') into ph from public.profiles where id = prop.owner_id and is_active;
  return jsonb_build_object('allowed', true, 'phone', coalesce(ph, nullif(btrim(prop.whatsapp), '')));
end $$;

create or replace function public.public_agent_contact(p_agent uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare ph text;
begin
  perform public._throttle('public_contact', 40, 60);
  if public.connections_enabled() then return jsonb_build_object('allowed', false, 'via', 'solicitud'); end if;
  select nullif(btrim(contact_whatsapp), '') into ph from public.profiles p
   where p.id = p_agent and p.is_active and exists (select 1 from public.properties x where x.owner_id = p.id and x.status = 'available');
  return jsonb_build_object('allowed', ph is not null, 'phone', ph);
end $$;

revoke all on function public.my_property_contacts(), public.public_property_contact(uuid), public.public_agent_contact(uuid) from public, anon;
grant execute on function public.my_property_contacts() to authenticated;
grant execute on function public.public_property_contact(uuid), public.public_agent_contact(uuid) to anon, authenticated;

-- 4) Fotos de propiedades y avatares: solo su dueño (o un administrador)
create or replace function public.storage_property_folder_ok(p_folder text)
returns boolean language sql security definer set search_path = public stable as $$
  -- carpeta = id de la propiedad. Si la propiedad aún no existe (las fotos se suben antes de guardarla), se permite; si existe, solo su dueño o un admin
  select auth.uid() is not null and public.is_active_user() and (
    public.is_admin()
    or not exists (select 1 from public.properties where id::text = p_folder)
    or exists (select 1 from public.properties where id::text = p_folder and owner_id = auth.uid()));
$$;
revoke all on function public.storage_property_folder_ok(text) from public, anon;
grant execute on function public.storage_property_folder_ok(text) to authenticated;

drop policy if exists "authenticated can upload property photos" on storage.objects;
create policy "authenticated can upload property photos" on storage.objects for insert to authenticated
  with check (bucket_id = 'property-photos' and public.storage_property_folder_ok((storage.foldername(name))[1]));
drop policy if exists "authenticated can update property photos" on storage.objects;
create policy "authenticated can update property photos" on storage.objects for update to authenticated
  using (bucket_id = 'property-photos' and public.storage_property_folder_ok((storage.foldername(name))[1]));
drop policy if exists "authenticated can delete property photos" on storage.objects;
create policy "authenticated can delete property photos" on storage.objects for delete to authenticated
  using (bucket_id = 'property-photos' and public.storage_property_folder_ok((storage.foldername(name))[1]));

drop policy if exists "users can upload own avatar" on storage.objects;
create policy "users can upload own avatar" on storage.objects for insert to authenticated
  with check (bucket_id = 'agent-avatars' and public.is_active_user() and ((storage.foldername(name))[1] = auth.uid()::text or public.is_admin()));
drop policy if exists "users can update own avatar" on storage.objects;
create policy "users can update own avatar" on storage.objects for update to authenticated
  using (bucket_id = 'agent-avatars' and public.is_active_user() and ((storage.foldername(name))[1] = auth.uid()::text or public.is_admin()));
drop policy if exists "users can delete own avatar" on storage.objects;
create policy "users can delete own avatar" on storage.objects for delete to authenticated
  using (bucket_id = 'agent-avatars' and public.is_active_user() and ((storage.foldername(name))[1] = auth.uid()::text or public.is_admin()));

-- 5) Permisos mínimos
revoke insert, update, delete, truncate, references, trigger on all tables in schema public from anon;
grant insert on public.property_events to anon;                         -- analítica de vistas y clics
revoke truncate, references, trigger on all tables in schema public from authenticated;
alter default privileges in schema public revoke insert, update, delete, truncate, references, trigger on tables from anon;
revoke select on public.subscription_plans from anon;                    -- el modelo de planes está retirado
do $$
begin
  begin execute 'revoke execute on function public.handle_new_user() from public, anon, authenticated'; exception when undefined_function then null; end;
  begin execute 'revoke execute on function public.process_auto_renewals() from public, anon, authenticated'; exception when undefined_function then null; end;
end $$;

notify pgrst, 'reload schema';

-- =====================================================================
-- Bastet · Comisiones y cierre de operaciones (fase 3)   — correr DESPUÉS de connections.sql (y security-hardening.sql)
-- Idempotente: se puede correr completo más de una vez. Implementa docs/ESPECIFICACION_MAESTRA.md, secciones 1.3, 1.5 y 9.3.
--
-- Qué hace: cuando el titular quiere marcar como vendida, alquilada o anticretada (o retirar) una propiedad CON conexiones de Bastet
-- (aceptadas, en pago o verificadas), ya no puede hacerlo a mano: pasa por «Cerrar operación».
--   · Si lo vendió/alquiló a la persona de una conexión verificada, esa persona confirma por un enlace → se registra la operación, se calcula la
--     comisión (venta 0,75 % del precio; alquiler un mes de canon; anticrético 2 % del monto entregado), en Bs con el tipo de cambio INTERNO
--     de Bastet, congelada; la propiedad se cierra y el titular paga la comisión con comprobante (verifica un admin).
--   · Si lo vendió a otra persona (o el interesado no confirma), NO hay atribución automática: la operación queda «en revisión», la propiedad
--     sigue activa y administración analiza el caso y decide.
--   · Si desiste y quiere retirarla, acepta una declaración jurada digital de desistimiento (el TEXTO lo define la dueña con su abogado; sin texto no
--     se puede retirar una propiedad con conexiones).
-- Solo rige con connection_settings.enabled = true. Sin conexiones el titular marca vendida/retira como siempre.
-- =====================================================================

do $$
begin
  if to_regclass('public.connections') is null then raise exception 'Primero corre supabase/connections.sql'; end if;
  if to_regprocedure('public._throttle(text, integer, integer)') is null then raise exception 'Primero corre supabase/security-hardening.sql'; end if;
end $$;

-- 1) Ajustes (los porcentajes son los de la especificación; se editan solo por SQL)
alter table public.connection_settings add column if not exists sale_percent        numeric(6,3) not null default 0.75 check (sale_percent between 0 and 20);
alter table public.connection_settings add column if not exists anticretico_percent numeric(6,3) not null default 2    check (anticretico_percent between 0 and 20);
alter table public.connection_settings add column if not exists rent_months         numeric(4,2) not null default 1    check (rent_months between 0 and 12);
alter table public.connection_settings add column if not exists desist_version      integer not null default 1;
alter table public.connection_settings add column if not exists desist_text         text not null default '' check (char_length(desist_text) <= 20000);

-- Nuevo estado de propiedad: retirada (desistimiento)
alter table public.properties drop constraint if exists properties_status_check;
alter table public.properties add constraint properties_status_check check (status in ('available', 'sold', 'withdrawn'));

-- 2) Operaciones
create table if not exists public.operation_counters (year integer primary key, last_number integer not null);
alter table public.operation_counters enable row level security;
revoke all on public.operation_counters from anon, authenticated;

create table if not exists public.operations (
  id                    uuid primary key default gen_random_uuid(),
  code                  text not null unique,
  number                text unique,                       -- BST-OP-AAAA-NNNN (al confirmarse)
  cert_code             text unique,                       -- código del certificado público (OP-XXXXXXXX), se consulta en «Verificar»
  property_id           uuid references public.properties(id) on delete set null,
  titular_id            uuid references auth.users(id) on delete set null,
  connection_id         uuid references public.connections(id) on delete set null,
  kind                  text not null check (kind in ('venta', 'alquiler', 'anticretico', 'desistimiento')),
  status                text not null check (status in ('pendiente_interesado', 'en_revision', 'confirmada', 'rechazada', 'desistida', 'cancelada')),
  counterparty_name     text check (counterparty_name is null or char_length(counterparty_name) <= 120),
  to_interested         boolean,                           -- el titular dice que fue a la persona de la conexión
  amount                numeric(16,2),                     -- precio total / canon mensual / monto entregado
  currency              text check (currency in ('USD', 'BOB')),
  signed_date           date,
  interested_token      text unique,
  interested_confirmed  boolean,
  interested_at         timestamptz,
  commission_percent    numeric(6,3),
  commission_amount     numeric(16,2),                     -- en la moneda de la operación
  bob_per_usd_used      numeric(8,4),
  commission_bs         numeric(16,2),                     -- congelada, en bolivianos
  commission_status     text not null default 'no_aplica' check (commission_status in ('no_aplica', 'exigible', 'comprobante_enviado', 'pagada')),
  proof_path            text check (proof_path is null or char_length(proof_path) <= 300),
  proof_at              timestamptz,
  paid_at               timestamptz,
  review_note           text check (review_note is null or char_length(review_note) <= 500),
  declaration_version   integer,                           -- desistimiento
  declaration_text      text,
  declaration_at        timestamptz,
  reason                text check (reason is null or char_length(reason) <= 500),
  admin_note            text check (admin_note is null or char_length(admin_note) <= 800),
  resolved_by           uuid references auth.users(id) on delete set null,
  resolved_at           timestamptz,
  property_snapshot     jsonb,
  created_at            timestamptz not null default now()
);
alter table public.operations add column if not exists cert_code text unique;
create index if not exists operations_titular_idx on public.operations (titular_id, created_at desc);
create index if not exists operations_property_idx on public.operations (property_id, status);
alter table public.operations enable row level security;
revoke all on public.operations from anon, authenticated;

create table if not exists public.operation_events (
  id           bigint generated always as identity primary key,
  operation_id uuid not null references public.operations(id) on delete cascade,
  actor        text not null,
  actor_id     uuid,
  event        text not null,
  from_status  text,
  to_status    text,
  data         jsonb,
  created_at   timestamptz not null default now()
);
create index if not exists operation_events_idx on public.operation_events (operation_id, created_at);
alter table public.operation_events enable row level security;
revoke all on public.operation_events from anon, authenticated;

create or replace function public._op_log(p_op uuid, p_actor text, p_event text, p_from text, p_to text, p_data jsonb default null)
returns void language sql security definer set search_path = public as $$
  insert into public.operation_events (operation_id, actor, actor_id, event, from_status, to_status, data) values (p_op, p_actor, auth.uid(), p_event, p_from, p_to, p_data);
$$;
revoke all on function public._op_log(uuid, text, text, text, text, jsonb) from public, anon, authenticated;

-- 3) Una propiedad con conexiones de Bastet no se marca vendida ni se retira ni se borra a mano (solo por «Cerrar operación»)
create or replace function public.protect_closed_properties()
returns trigger language plpgsql security definer set search_path = public as $$
declare pid uuid; bad boolean := false;
begin
  if auth.uid() is null or public.is_admin() or coalesce(current_setting('uno.closure_rpc', true), '') = '1' or not public.connections_enabled() then
    if TG_OP = 'DELETE' then return old; else return new; end if;
  end if;
  if TG_OP = 'UPDATE' then
    bad := old.status = 'available' and new.status is distinct from 'available';
    pid := old.id;
  else
    bad := true; pid := old.id;
  end if;
  if bad and exists (select 1 from public.connections c where c.property_id = pid and c.status in ('aceptada_pendiente_pago', 'comprobante_enviado', 'conexion_generada')) then
    raise exception 'Esta propiedad tiene conexiones de Bastet. Para marcarla como vendida o alquilada, o para retirarla, usa «Cerrar operación».' using errcode = 'P0403', hint = 'closure';
  end if;
  if TG_OP = 'DELETE' then return old; else return new; end if;
end $$;
drop trigger if exists protect_closed_status on public.properties;
create trigger protect_closed_status before update of status on public.properties for each row execute function public.protect_closed_properties();
drop trigger if exists protect_closed_delete on public.properties;
create trigger protect_closed_delete before delete on public.properties for each row execute function public.protect_closed_properties();

-- 4) Comisión de una operación (siempre en Bs, con el tipo de cambio INTERNO)
create or replace function public._op_commission(p_kind text, p_amount numeric, p_currency text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare s public.connection_settings; rate numeric; pct numeric; cur numeric;
begin
  select * into s from public.connection_settings where id = 1;
  select bob_per_usd into rate from public.stay_settings where id = 1; rate := coalesce(rate, 6.96);
  if p_kind = 'venta' then pct := s.sale_percent; cur := round(p_amount * pct / 100, 2);
  elsif p_kind = 'anticretico' then pct := s.anticretico_percent; cur := round(p_amount * pct / 100, 2);
  elsif p_kind = 'alquiler' then pct := null; cur := round(p_amount * s.rent_months, 2);
  else raise exception 'Operación inválida'; end if;
  return jsonb_build_object('percent', pct, 'amount', cur, 'rate', rate, 'bs', round(case when p_currency = 'BOB' then cur else cur * rate end, 2));
end $$;
revoke all on function public._op_commission(text, numeric, text) from public, anon, authenticated;

-- Confirma una operación: comisión congelada, constancia numerada, propiedad cerrada
create or replace function public._confirm_operation(p_id uuid, p_with_commission boolean default true)
returns void language plpgsql security definer set search_path = public as $$
declare o public.operations; cm jsonb; yr integer; seq integer; snap jsonb; cert text; alpha constant text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
begin
  select * into o from public.operations where id = p_id for update;
  loop
    select 'OP-' || string_agg(substr(alpha, 1 + floor(random() * 32)::integer, 1), '') into cert from generate_series(1, 8);
    exit when not exists (select 1 from public.operations where cert_code = cert);
  end loop;
  yr := extract(year from ((now() at time zone 'UTC') - interval '4 hours'))::integer;
  insert into public.operation_counters (year, last_number) values (yr, 1)
  on conflict (year) do update set last_number = public.operation_counters.last_number + 1 returning last_number into seq;
  select jsonb_build_object('title', p.title, 'code_number', p.code_number, 'location', p.location, 'address', p.address, 'price', p.price, 'currency', p.currency, 'operation', p.operation)
    into snap from public.properties p where p.id = o.property_id;
  if p_with_commission then
    cm := public._op_commission(o.kind, o.amount, o.currency);
    update public.operations set commission_percent = (cm ->> 'percent')::numeric, commission_amount = (cm ->> 'amount')::numeric, bob_per_usd_used = (cm ->> 'rate')::numeric,
           commission_bs = (cm ->> 'bs')::numeric, commission_status = 'exigible' where id = o.id;
  end if;
  update public.operations set status = 'confirmada', number = 'BST-OP-' || yr || '-' || lpad(seq::text, 4, '0'), cert_code = cert, property_snapshot = snap, resolved_at = coalesce(resolved_at, now()) where id = o.id;
  perform set_config('uno.closure_rpc', '1', true);
  update public.properties set status = 'sold' where id = o.property_id;
  perform public._op_log(o.id, 'system', 'confirmada', o.status, 'confirmada', jsonb_build_object('commission', cm, 'with_commission', p_with_commission));
end $$;
revoke all on function public._confirm_operation(uuid, boolean) from public, anon, authenticated;

-- 5) Estado del cierre para el panel
create or replace function public.closure_state(p_property uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); prop record; s public.connection_settings;
begin
  if uid is null or not public.is_active_user() then raise exception 'No autorizado' using errcode = '42501'; end if;
  select id, owner_id, status, coalesce(operation, 'venta') as operation, title into prop from public.properties where id = p_property;
  if not found or (prop.owner_id is distinct from uid and not public.is_admin()) then raise exception 'Propiedad no encontrada'; end if;
  select * into s from public.connection_settings where id = 1;
  return jsonb_build_object('enabled', s.enabled, 'operation', prop.operation, 'status', prop.status, 'title', prop.title,
    'protected', s.enabled and exists (select 1 from public.connections c where c.property_id = p_property and c.status in ('aceptada_pendiente_pago', 'comprobante_enviado', 'conexion_generada')),
    'desist_ready', char_length(btrim(s.desist_text)) > 0, 'desist_version', s.desist_version, 'desist_text', case when char_length(btrim(s.desist_text)) > 0 then s.desist_text end,
    'connections', coalesce((select jsonb_agg(jsonb_build_object('id', c.id, 'code', c.code, 'number', c.number, 'status', c.status,
        'name', split_part(btrim(c.interested_name), ' ', 1) || coalesce(' ' || upper(left(nullif(split_part(btrim(c.interested_name), ' ', 2), ''), 1)) || '.', '')) order by c.created_at)
        from public.connections c where c.property_id = p_property and c.status = 'conexion_generada'), '[]'::jsonb),
    'open_operation', (select to_jsonb(x) from (select id, code, kind, status, created_at from public.operations where property_id = p_property and status in ('pendiente_interesado', 'en_revision') order by created_at desc limit 1) x));
end $$;

-- 6) El titular inicia el cierre (venta, alquiler o anticrético)
create or replace function public.start_property_closure(p_property uuid, p_kind text, p_connection uuid, p_buyer text, p_amount numeric, p_currency text, p_signed date)
returns jsonb language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); prop record; conn public.connections; st text; tok text; cd text; oid uuid; tries int := 0; bn text := btrim(coalesce(p_buyer, ''));
begin
  if uid is null or not public.is_active_user() then raise exception 'No autorizado' using errcode = '42501'; end if;
  if not public.connections_enabled() then raise exception 'El cierre de operaciones todavía no está activo'; end if;
  select id, owner_id, status, coalesce(operation, 'venta') as operation into prop from public.properties where id = p_property for update;
  if not found or prop.owner_id is distinct from uid then raise exception 'Propiedad no encontrada'; end if;
  if prop.status <> 'available' then raise exception 'La propiedad ya no está disponible'; end if;
  if p_kind not in ('venta', 'alquiler', 'anticretico') or p_kind <> prop.operation then raise exception 'El tipo de operación no coincide con la propiedad (%)', prop.operation; end if;
  if p_amount is null or p_amount <= 0 or p_amount > 100000000 then raise exception 'Indica el monto de la operación'; end if;
  if p_currency not in ('USD', 'BOB') then raise exception 'Elige la moneda'; end if;
  if p_signed is null or p_signed > public.bo_today() or p_signed < public.bo_today() - 90 then raise exception 'La fecha de firma debe ser de los últimos 90 días'; end if;
  if char_length(bn) not between 2 and 120 then raise exception 'Escribe el nombre de la persona a quien se vendió o alquiló'; end if;
  if exists (select 1 from public.operations where property_id = p_property and status in ('pendiente_interesado', 'en_revision')) then raise exception 'Ya hay una confirmación en curso para esta propiedad'; end if;
  if p_connection is not null then
    select * into conn from public.connections where id = p_connection and property_id = p_property and titular_id = uid and status = 'conexion_generada';
    if not found then raise exception 'La conexión elegida no corresponde a esta propiedad o aún no está verificada'; end if;
  end if;
  st := case when p_connection is not null then 'pendiente_interesado' else 'en_revision' end;
  tok := case when p_connection is not null then lower(replace(gen_random_uuid()::text, '-', '')) end;
  loop
    cd := upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 10));
    begin
      insert into public.operations (code, property_id, titular_id, connection_id, kind, status, counterparty_name, to_interested, amount, currency, signed_date, interested_token)
      values (cd, p_property, uid, p_connection, p_kind, st, bn, p_connection is not null, p_amount, p_currency, p_signed, tok) returning id into oid;
      exit;
    exception when unique_violation then tries := tries + 1; if tries > 5 then raise; end if;
    end;
  end loop;
  perform public._op_log(oid, 'titular', 'cierre_iniciado', null, st, jsonb_build_object('kind', p_kind, 'amount', p_amount, 'currency', p_currency, 'to_interested', p_connection is not null));
  return jsonb_build_object('id', oid, 'code', cd, 'status', st, 'token', tok);
end $$;

create or replace function public.cancel_property_closure(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare o public.operations;
begin
  if auth.uid() is null or not public.is_active_user() then raise exception 'No autorizado' using errcode = '42501'; end if;
  select * into o from public.operations where id = p_id and titular_id = auth.uid() and status in ('pendiente_interesado', 'en_revision') for update;
  if not found then raise exception 'Confirmación no encontrada o ya resuelta'; end if;
  update public.operations set status = 'cancelada' where id = o.id;
  perform public._op_log(o.id, 'titular', 'cierre_cancelado', o.status, 'cancelada');
end $$;

-- 7) La persona de la conexión confirma (o niega) por su enlace, sin cuenta
create or replace function public.get_operation_confirmation(p_token text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare o public.operations; p record;
begin
  perform public._throttle('operation_confirm', 30, 60);
  select * into o from public.operations where interested_token = lower(btrim(coalesce(p_token, '')));
  if not found then return jsonb_build_object('valid', false); end if;
  select title, location into p from public.properties where id = o.property_id;
  return jsonb_build_object('valid', o.status = 'pendiente_interesado', 'answered', o.status <> 'pendiente_interesado', 'kind', o.kind, 'title', coalesce(p.title, (o.property_snapshot ->> 'title')),
    'location', p.location, 'amount', o.amount, 'currency', o.currency, 'signed_date', o.signed_date);
end $$;

create or replace function public.respond_operation_confirmation(p_token text, p_confirm boolean)
returns jsonb language plpgsql security definer set search_path = public as $$
declare o public.operations;
begin
  perform public._throttle('operation_confirm', 30, 60);
  select * into o from public.operations where interested_token = lower(btrim(coalesce(p_token, ''))) for update;
  if not found then raise exception 'Este enlace no es válido'; end if;
  if o.status <> 'pendiente_interesado' then raise exception 'Esta operación ya fue respondida'; end if;
  update public.operations set interested_confirmed = coalesce(p_confirm, false), interested_at = now() where id = o.id;
  if p_confirm is true then
    perform public._confirm_operation(o.id);
    perform public._op_log(o.id, 'interested', 'interesado_confirma', o.status, 'confirmada');
    return jsonb_build_object('status', 'confirmada');
  end if;
  update public.operations set status = 'en_revision' where id = o.id;
  perform public._op_log(o.id, 'interested', 'interesado_niega', o.status, 'en_revision');
  return jsonb_build_object('status', 'en_revision');
end $$;

-- 8) Administración resuelve los casos en revisión (sin atribución automática)
create or replace function public.admin_resolve_operation(p_id uuid, p_decision text, p_note text)
returns void language plpgsql security definer set search_path = public as $$
declare o public.operations; nt text := nullif(btrim(coalesce(p_note, '')), '');
begin
  if not public.is_admin() then raise exception 'Solo administradores' using errcode = '42501'; end if;
  if nt is null then raise exception 'Escribe el motivo de la decisión (queda en el historial)'; end if;
  select * into o from public.operations where id = p_id and status in ('en_revision', 'pendiente_interesado') for update;
  if not found then raise exception 'Operación no encontrada o ya resuelta'; end if;
  update public.operations set admin_note = nt, resolved_by = auth.uid(), resolved_at = now() where id = o.id;
  if p_decision = 'confirmar' then perform public._confirm_operation(o.id, true);
  elsif p_decision = 'sin_comision' then perform public._confirm_operation(o.id, false);
  elsif p_decision = 'rechazar' then
    update public.operations set status = 'rechazada' where id = o.id;
    perform public._op_log(o.id, 'admin', 'rechazada', o.status, 'rechazada', jsonb_build_object('note', nt));
    return;
  else raise exception 'Decisión inválida'; end if;
  perform public._op_log(o.id, 'admin', 'resuelta_' || p_decision, o.status, 'confirmada', jsonb_build_object('note', nt));
end $$;

-- 9) Pago de la comisión (mismo circuito que la tarifa de conexión)
create or replace function public.attach_operation_proof(p_id uuid, p_path text)
returns void language plpgsql security definer set search_path = public as $$
declare o public.operations; uid uuid := auth.uid();
begin
  if uid is null or not public.is_active_user() then raise exception 'No autorizado' using errcode = '42501'; end if;
  if p_path is null or char_length(p_path) > 300 or p_path not like uid::text || '/%' or p_path like '%..%' then raise exception 'Comprobante inválido'; end if;
  select * into o from public.operations where id = p_id and titular_id = uid for update;
  if not found or o.commission_status not in ('exigible', 'comprobante_enviado') then raise exception 'Esta operación no espera un comprobante'; end if;
  update public.operations set proof_path = p_path, proof_at = now(), commission_status = 'comprobante_enviado', review_note = null where id = o.id;
  perform public._op_log(o.id, 'titular', 'comprobante_enviado', o.commission_status, 'comprobante_enviado', jsonb_build_object('path', p_path));
end $$;

create or replace function public.admin_review_operation_proof(p_id uuid, p_approve boolean, p_note text default null)
returns void language plpgsql security definer set search_path = public as $$
declare o public.operations; nt text := nullif(btrim(coalesce(p_note, '')), '');
begin
  if not public.is_admin() then raise exception 'Solo administradores' using errcode = '42501'; end if;
  select * into o from public.operations where id = p_id and commission_status = 'comprobante_enviado' for update;
  if not found then raise exception 'No hay un comprobante por revisar en esta operación'; end if;
  if p_approve then
    update public.operations set commission_status = 'pagada', paid_at = now(), review_note = nt where id = o.id;
    perform public._op_log(o.id, 'admin', 'comision_pagada', 'comprobante_enviado', 'pagada', jsonb_build_object('bs', o.commission_bs, 'note', nt));
  else
    if nt is null then raise exception 'Escribe el motivo del rechazo para que el titular pueda corregirlo'; end if;
    update public.operations set commission_status = 'exigible', proof_path = null, proof_at = null, review_note = nt where id = o.id;
    perform public._op_log(o.id, 'admin', 'comprobante_rechazado', 'comprobante_enviado', 'exigible', jsonb_build_object('note', nt, 'path', o.proof_path));
  end if;
end $$;

-- 10) Desistimiento: declaración jurada digital para retirar una propiedad con conexiones
create or replace function public.desist_property(p_property uuid, p_accept boolean, p_reason text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); prop record; s public.connection_settings; oid uuid; cd text; rs text := nullif(btrim(coalesce(p_reason, '')), ''); tries int := 0;
begin
  if uid is null or not public.is_active_user() then raise exception 'No autorizado' using errcode = '42501'; end if;
  select * into s from public.connection_settings where id = 1;
  if not s.enabled then raise exception 'El cierre de operaciones todavía no está activo'; end if;
  if char_length(btrim(s.desist_text)) = 0 then raise exception 'La declaración jurada de desistimiento todavía no está disponible. Escribe a Bastet para retirar esta propiedad.'; end if;
  select id, owner_id, status, coalesce(operation, 'venta') as operation into prop from public.properties where id = p_property for update;
  if not found or prop.owner_id is distinct from uid then raise exception 'Propiedad no encontrada'; end if;
  if prop.status <> 'available' then raise exception 'La propiedad ya no está disponible'; end if;
  if p_accept is not true then raise exception 'Debes aceptar la declaración jurada para retirar la propiedad'; end if;
  if rs is null then raise exception 'Cuéntanos brevemente el motivo del retiro'; end if;
  if exists (select 1 from public.operations where property_id = p_property and status in ('pendiente_interesado', 'en_revision')) then raise exception 'Hay una confirmación en curso para esta propiedad'; end if;
  loop
    cd := upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 10));
    begin
      insert into public.operations (code, property_id, titular_id, kind, status, reason, declaration_version, declaration_text, declaration_at, property_snapshot, resolved_at)
      select cd, p_property, uid, 'desistimiento', 'desistida', rs, s.desist_version, s.desist_text, now(),
             jsonb_build_object('title', p.title, 'code_number', p.code_number, 'location', p.location, 'operation', p.operation), now() from public.properties p where p.id = p_property returning id into oid;
      exit;
    exception when unique_violation then tries := tries + 1; if tries > 5 then raise; end if;
    end;
  end loop;
  perform set_config('uno.closure_rpc', '1', true);
  update public.properties set status = 'withdrawn' where id = p_property;
  perform public._op_log(oid, 'titular', 'desistimiento', null, 'desistida', jsonb_build_object('version', s.desist_version, 'reason', rs));
  return jsonb_build_object('id', oid, 'code', cd);
end $$;

-- 11) Listas
create or replace function public.my_operations()
returns jsonb language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); adm boolean; s public.connection_settings;
begin
  if uid is null or not public.is_active_user() then raise exception 'No autorizado' using errcode = '42501'; end if;
  adm := public.is_admin();
  select * into s from public.connection_settings where id = 1;
  return jsonb_build_object('enabled', s.enabled, 'pay_instructions', s.pay_instructions, 'pay_qr_url', s.pay_qr_url,
    'desist_text', case when adm then s.desist_text end, 'desist_version', s.desist_version,
    'items', coalesce((select jsonb_agg(jsonb_build_object(
        'id', o.id, 'code', o.code, 'number', o.number, 'cert_code', o.cert_code, 'kind', o.kind, 'status', o.status, 'property_id', o.property_id,
        'title', coalesce(p.title, o.property_snapshot ->> 'title'), 'counterparty_name', o.counterparty_name, 'to_interested', o.to_interested,
        'amount', o.amount, 'currency', o.currency, 'signed_date', o.signed_date, 'interested_token', case when o.status = 'pendiente_interesado' then o.interested_token end,
        'interested_confirmed', o.interested_confirmed, 'commission_percent', o.commission_percent, 'commission_amount', o.commission_amount,
        'commission_bs', o.commission_bs, 'commission_status', o.commission_status, 'proof_at', o.proof_at, 'paid_at', o.paid_at, 'review_note', o.review_note,
        'proof_path', case when adm then o.proof_path end, 'reason', o.reason, 'admin_note', o.admin_note, 'created_at', o.created_at, 'declaration_version', o.declaration_version,
        'titular_name', case when adm then (select display_name from public.profiles where id = o.titular_id) end,
        'connection_number', (select number from public.connections where id = o.connection_id),
        'interested_phone', (select c.interested_phone from public.connections c where c.id = o.connection_id and c.status = 'conexion_generada' and (adm or c.titular_id = uid))) order by o.created_at desc)
      from public.operations o left join public.properties p on p.id = o.property_id
      where (adm or o.titular_id = uid) and o.created_at > now() - interval '36 months'), '[]'::jsonb));
end $$;

create or replace function public.operation_events(p_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Solo administradores' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('actor', e.actor, 'event', e.event, 'from', e.from_status, 'to', e.to_status, 'data', e.data, 'at', e.created_at) order by e.created_at, e.id)
                     from public.operation_events e where e.operation_id = p_id), '[]'::jsonb);
end $$;

create or replace function public.admin_update_desist_text(p_text text)
returns void language plpgsql security definer set search_path = public as $$
declare cur public.connection_settings; tx text := btrim(coalesce(p_text, ''));
begin
  if not public.is_admin() then raise exception 'Solo administradores' using errcode = '42501'; end if;
  select * into cur from public.connection_settings where id = 1;
  update public.connection_settings set desist_text = tx, desist_version = case when tx is distinct from cur.desist_text then cur.desist_version + 1 else cur.desist_version end, updated_at = now() where id = 1;
end $$;

-- 12) Permisos
revoke all on function public.protect_closed_properties(), public.closure_state(uuid), public.start_property_closure(uuid, text, uuid, text, numeric, text, date),
  public.cancel_property_closure(uuid), public.get_operation_confirmation(text), public.respond_operation_confirmation(text, boolean),
  public.admin_resolve_operation(uuid, text, text), public.attach_operation_proof(uuid, text), public.admin_review_operation_proof(uuid, boolean, text),
  public.desist_property(uuid, boolean, text), public.my_operations(), public.operation_events(uuid), public.admin_update_desist_text(text) from public, anon;
grant execute on function public.get_operation_confirmation(text), public.respond_operation_confirmation(text, boolean) to anon, authenticated;
grant execute on function public.closure_state(uuid), public.start_property_closure(uuid, text, uuid, text, numeric, text, date), public.cancel_property_closure(uuid),
  public.admin_resolve_operation(uuid, text, text), public.attach_operation_proof(uuid, text), public.admin_review_operation_proof(uuid, boolean, text),
  public.desist_property(uuid, boolean, text), public.my_operations(), public.operation_events(uuid), public.admin_update_desist_text(text) to authenticated;

notify pgrst, 'reload schema';

-- =====================================================================
-- Bastet · Verificación, reputación, actas y certificado público (fase 4)   — correr DESPUÉS de operations.sql
-- Idempotente: se puede correr completo más de una vez. Implementa docs/ESPECIFICACION_MAESTRA.md, secciones 5, 7 y 9.5.
--
--  · TRES DISTINTIVOS INDEPENDIENTES (no equivalen a reputación):
--      Agente verificado por Bastet  = identidad, teléfono, documentación profesional y contrato directo con Bastet, revisados.
--      Propietario verificado        = identidad y documentación revisadas.
--      Propiedad verificada          = identidad del propietario, documentación legal y existencia física revisadas.
--    Solo un administrador los concede, tras una solicitud con documentos y una lista de comprobaciones COMPLETA; todo queda en un historial.
--    Si la dirección o el dueño de una propiedad verificada cambian, la verificación se pierde.
--  · «Propiedad pendiente de verificación»: con connection_settings.require_property_verification = true, una propiedad sin verificar se puede publicar
--    pero NO recibe solicitudes de contacto (conexiones) hasta verificarse.
--  · RESEÑAS de agentes y propietarios: solo la persona de una operación concretada mediante una conexión de Bastet (la que confirmó la operación)
--    puede reseñar, una vez, con estrellas y comentario; la reseña queda ligada a esa operación.
--  · CERTIFICADO PÚBLICO de cada operación confirmada (código OP-XXXXXXXX) y acta digital (para el titular y administración); consulta pública de
--    propiedades (BST-####) y agentes (AG-XXXXXX) en «Verificar». El certificado NO expone nombres, montos ni datos del contrato.
-- La FIRMA y la validez probatoria del acta, y los datos que puede divulgar el certificado, requieren revisión jurídica en Bolivia.
-- =====================================================================

do $$
begin
  if to_regclass('public.operations') is null then raise exception 'Primero corre supabase/operations.sql'; end if;
end $$;

-- 1) Marcas públicas y ajustes
alter table public.connection_settings add column if not exists require_property_verification boolean not null default false;
alter table public.properties add column if not exists verified boolean not null default false;
alter table public.profiles add column if not exists agent_verified boolean not null default false;
alter table public.profiles add column if not exists owner_verified boolean not null default false;
alter table public.profiles add column if not exists public_code text;
create unique index if not exists profiles_public_code_idx on public.profiles (public_code) where public_code is not null;

grant select (verified) on public.properties to anon, authenticated;
grant select (agent_verified, owner_verified, public_code) on public.profiles to anon;

create or replace function public.verification_required()
returns boolean language sql security definer set search_path = public stable as $$ select coalesce((select require_property_verification and enabled from public.connection_settings where id = 1), false) $$;
revoke all on function public.verification_required() from public;
grant execute on function public.verification_required() to anon, authenticated;

-- Nadie se concede un distintivo a sí mismo; y una propiedad verificada pierde la verificación si cambian su dirección, su ubicación o su dueño
create or replace function public.protect_property_verified()
returns trigger language plpgsql security definer set search_path = public as $$
declare ok boolean := coalesce(current_setting('uno.verif_rpc', true), '') = '1' or auth.uid() is null or public.is_admin();
begin
  if TG_OP = 'INSERT' then
    if not ok then new.verified := false; end if;
    return new;
  end if;
  if coalesce(current_setting('uno.verif_rpc', true), '') <> '1' then
    if not ok then new.verified := old.verified; end if;
    if old.verified and (new.address is distinct from old.address or new.owner_id is distinct from old.owner_id
                         or new.latitude is distinct from old.latitude or new.longitude is distinct from old.longitude) then
      new.verified := false;
    end if;
  end if;
  return new;
end $$;
drop trigger if exists protect_property_verified on public.properties;
create trigger protect_property_verified before insert or update on public.properties for each row execute function public.protect_property_verified();

create or replace function public.protect_profile_verified()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if not (coalesce(current_setting('uno.verif_rpc', true), '') = '1' or auth.uid() is null or public.is_admin()) then
    new.agent_verified := old.agent_verified; new.owner_verified := old.owner_verified; new.public_code := old.public_code;
  end if;
  return new;
end $$;
drop trigger if exists protect_profile_verified on public.profiles;
create trigger protect_profile_verified before update on public.profiles for each row execute function public.protect_profile_verified();

-- Una propiedad pendiente de verificación no genera conexiones (cuando el ajuste está activo)
create or replace function public.require_verified_for_connection()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if public.verification_required() and not coalesce((select verified from public.properties where id = new.property_id), false) then
    raise exception 'Esta propiedad está pendiente de verificación: todavía no recibe solicitudes de contacto.';
  end if;
  return new;
end $$;
drop trigger if exists require_verified_for_connection on public.connections;
create trigger require_verified_for_connection before insert on public.connections for each row execute function public.require_verified_for_connection();

-- 2) Solicitudes de verificación y su historial
create table if not exists public.verification_requests (
  id          uuid primary key default gen_random_uuid(),
  kind        text not null check (kind in ('agente', 'propietario', 'propiedad')),
  user_id     uuid not null references auth.users(id) on delete cascade,
  property_id uuid references public.properties(id) on delete set null,
  status      text not null default 'borrador' check (status in ('borrador', 'en_revision', 'aprobada', 'rechazada', 'revocada')),
  docs        jsonb not null default '[]'::jsonb,                 -- [{label, path}]
  checks      jsonb not null default '{}'::jsonb,
  note        text check (note is null or char_length(note) <= 500),
  admin_note  text check (admin_note is null or char_length(admin_note) <= 800),
  submitted_at timestamptz,
  decided_by  uuid references auth.users(id) on delete set null,
  decided_at  timestamptz,
  created_at  timestamptz not null default now()
);
create unique index if not exists verification_open_idx on public.verification_requests (user_id, kind, coalesce(property_id, '00000000-0000-0000-0000-000000000000'::uuid)) where status in ('borrador', 'en_revision');
alter table public.verification_requests enable row level security;
revoke all on public.verification_requests from anon, authenticated;

create table if not exists public.verification_events (
  id          bigint generated always as identity primary key,
  request_id  uuid not null references public.verification_requests(id) on delete cascade,
  actor       text not null, actor_id uuid, event text not null, data jsonb,
  created_at  timestamptz not null default now()
);
alter table public.verification_events enable row level security;
revoke all on public.verification_events from anon, authenticated;
create or replace function public._ver_log(p_req uuid, p_actor text, p_event text, p_data jsonb default null)
returns void language sql security definer set search_path = public as $$
  insert into public.verification_events (request_id, actor, actor_id, event, data) values (p_req, p_actor, auth.uid(), p_event, p_data);
$$;
revoke all on function public._ver_log(uuid, text, text, jsonb) from public, anon, authenticated;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('verification-docs', 'verification-docs', false, 8388608, array['application/pdf', 'image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do update set public = false, file_size_limit = 8388608, allowed_mime_types = array['application/pdf', 'image/jpeg', 'image/png', 'image/webp'];
drop policy if exists "owner uploads verification docs" on storage.objects;
create policy "owner uploads verification docs" on storage.objects for insert to authenticated
  with check (bucket_id = 'verification-docs' and (storage.foldername(name))[1] = auth.uid()::text and public.is_active_user());
drop policy if exists "owner reads own verification docs" on storage.objects;
create policy "owner reads own verification docs" on storage.objects for select to authenticated
  using (bucket_id = 'verification-docs' and (storage.foldername(name))[1] = auth.uid()::text);
drop policy if exists "admin reads verification docs" on storage.objects;
create policy "admin reads verification docs" on storage.objects for select to authenticated using (bucket_id = 'verification-docs' and public.is_admin());
drop policy if exists "admin deletes verification docs" on storage.objects;
create policy "admin deletes verification docs" on storage.objects for delete to authenticated using (bucket_id = 'verification-docs' and public.is_admin());

-- Qué se debe comprobar para cada distintivo (sección 5.3)
create or replace function public._ver_required_checks(p_kind text)
returns text[] language sql immutable as $$
  select case p_kind when 'agente' then array['identidad', 'telefono', 'documentacion_profesional', 'contrato_bastet']
                     when 'propietario' then array['identidad', 'documentacion']
                     else array['identidad_propietario', 'documentacion_legal', 'existencia_fisica'] end;
$$;

create or replace function public.request_verification(p_kind text, p_property uuid default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); rid uuid;
begin
  if uid is null or not public.is_active_user() then raise exception 'No autorizado' using errcode = '42501'; end if;
  if p_kind not in ('agente', 'propietario', 'propiedad') then raise exception 'Tipo de verificación inválido'; end if;
  if p_kind = 'propiedad' then
    if p_property is null or not exists (select 1 from public.properties where id = p_property and owner_id = uid) then raise exception 'Elige una de tus propiedades'; end if;
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

create or replace function public.attach_verification_doc(p_id uuid, p_path text, p_label text)
returns void language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); r public.verification_requests; lb text := btrim(coalesce(p_label, ''));
begin
  if uid is null or not public.is_active_user() then raise exception 'No autorizado' using errcode = '42501'; end if;
  if p_path is null or char_length(p_path) > 300 or p_path not like uid::text || '/%' or p_path like '%..%' then raise exception 'Documento inválido'; end if;
  if char_length(lb) not between 2 and 80 then raise exception 'Describe el documento (por ejemplo: «Cédula de identidad, anverso»)'; end if;
  select * into r from public.verification_requests where id = p_id and user_id = uid and status in ('borrador', 'en_revision') for update;
  if not found then raise exception 'Solicitud no encontrada o ya resuelta'; end if;
  if jsonb_array_length(r.docs) >= 12 then raise exception 'Máximo 12 documentos por solicitud'; end if;
  update public.verification_requests set docs = docs || jsonb_build_array(jsonb_build_object('label', lb, 'path', p_path, 'at', now())) where id = r.id;
  perform public._ver_log(r.id, 'usuario', 'documento_agregado', jsonb_build_object('label', lb));
end $$;

create or replace function public.submit_verification(p_id uuid, p_note text default null)
returns void language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); r public.verification_requests;
begin
  if uid is null or not public.is_active_user() then raise exception 'No autorizado' using errcode = '42501'; end if;
  select * into r from public.verification_requests where id = p_id and user_id = uid and status = 'borrador' for update;
  if not found then raise exception 'Solicitud no encontrada o ya enviada'; end if;
  if jsonb_array_length(r.docs) < 1 then raise exception 'Adjunta al menos un documento'; end if;
  update public.verification_requests set status = 'en_revision', submitted_at = now(), note = nullif(btrim(coalesce(p_note, '')), '') where id = r.id;
  perform public._ver_log(r.id, 'usuario', 'enviada_a_revision', null);
end $$;

create or replace function public.my_verifications()
returns jsonb language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); adm boolean;
begin
  if uid is null or not public.is_active_user() then raise exception 'No autorizado' using errcode = '42501'; end if;
  adm := public.is_admin();
  return jsonb_build_object('required', jsonb_build_object('agente', public._ver_required_checks('agente'), 'propietario', public._ver_required_checks('propietario'), 'propiedad', public._ver_required_checks('propiedad')),
    'me', (select jsonb_build_object('agent_verified', agent_verified, 'owner_verified', owner_verified, 'public_code', public_code) from public.profiles where id = uid),
    'items', coalesce((select jsonb_agg(jsonb_build_object('id', v.id, 'kind', v.kind, 'status', v.status, 'property_id', v.property_id,
        'property_title', (select title from public.properties where id = v.property_id), 'docs', v.docs, 'checks', v.checks, 'note', v.note, 'admin_note', v.admin_note,
        'submitted_at', v.submitted_at, 'decided_at', v.decided_at, 'created_at', v.created_at,
        'user_name', case when adm then (select coalesce(nullif(btrim(full_name), ''), display_name, email) from public.profiles where id = v.user_id) end) order by v.created_at desc)
      from public.verification_requests v where adm or v.user_id = uid), '[]'::jsonb));
end $$;

create or replace function public.admin_review_verification(p_id uuid, p_decision text, p_checks jsonb, p_note text)
returns void language plpgsql security definer set search_path = public as $$
declare r public.verification_requests; nt text := nullif(btrim(coalesce(p_note, '')), ''); req text[]; k text; code text; alpha constant text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
begin
  if not public.is_admin() then raise exception 'Solo administradores' using errcode = '42501'; end if;
  select * into r from public.verification_requests where id = p_id and status = 'en_revision' for update;
  if not found then raise exception 'No hay una solicitud en revisión con ese identificador'; end if;
  update public.verification_requests set checks = coalesce(p_checks, '{}'::jsonb) where id = r.id;
  if p_decision = 'aprobar' then
    req := public._ver_required_checks(r.kind);
    foreach k in array req loop
      if coalesce(p_checks ->> k, 'false') <> 'true' then raise exception 'Para aprobar hay que completar TODAS las comprobaciones (falta: %)', k; end if;
    end loop;
    perform set_config('uno.verif_rpc', '1', true);
    if r.kind = 'agente' then
      loop
        code := 'AG-' || (select string_agg(substr(alpha, 1 + floor(random() * 32)::integer, 1), '') from generate_series(1, 6));
        exit when not exists (select 1 from public.profiles where public_code = code);
      end loop;
      update public.profiles set agent_verified = true, public_code = coalesce(public_code, code) where id = r.user_id;
    elsif r.kind = 'propietario' then update public.profiles set owner_verified = true where id = r.user_id;
    else update public.properties set verified = true where id = r.property_id; end if;
    update public.verification_requests set status = 'aprobada', decided_by = auth.uid(), decided_at = now(), admin_note = nt where id = r.id;
    perform public._ver_log(r.id, 'admin', 'aprobada', jsonb_build_object('checks', p_checks, 'note', nt));
  elsif p_decision = 'rechazar' then
    if nt is null then raise exception 'Escribe el motivo del rechazo para que la persona pueda corregirlo'; end if;
    update public.verification_requests set status = 'rechazada', decided_by = auth.uid(), decided_at = now(), admin_note = nt where id = r.id;
    perform public._ver_log(r.id, 'admin', 'rechazada', jsonb_build_object('note', nt));
  else raise exception 'Decisión inválida'; end if;
end $$;

create or replace function public.admin_revoke_verification(p_id uuid, p_note text)
returns void language plpgsql security definer set search_path = public as $$
declare r public.verification_requests; nt text := nullif(btrim(coalesce(p_note, '')), '');
begin
  if not public.is_admin() then raise exception 'Solo administradores' using errcode = '42501'; end if;
  if nt is null then raise exception 'Escribe el motivo de la revocación'; end if;
  select * into r from public.verification_requests where id = p_id and status = 'aprobada' for update;
  if not found then raise exception 'La verificación no está vigente'; end if;
  perform set_config('uno.verif_rpc', '1', true);
  if r.kind = 'agente' then update public.profiles set agent_verified = false where id = r.user_id;
  elsif r.kind = 'propietario' then update public.profiles set owner_verified = false where id = r.user_id;
  else update public.properties set verified = false where id = r.property_id; end if;
  update public.verification_requests set status = 'revocada', admin_note = nt, decided_at = now() where id = r.id;
  perform public._ver_log(r.id, 'admin', 'revocada', jsonb_build_object('note', nt));
end $$;

create or replace function public.verification_events(p_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Solo administradores' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('actor', e.actor, 'event', e.event, 'data', e.data, 'at', e.created_at) order by e.created_at, e.id) from public.verification_events e where e.request_id = p_id), '[]'::jsonb);
end $$;

create or replace function public.admin_set_property_verification_required(p_required boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Solo administradores' using errcode = '42501'; end if;
  update public.connection_settings set require_property_verification = coalesce(p_required, false), updated_at = now() where id = 1;
end $$;

-- 3) Reseñas de agentes y propietarios (solo tras una operación concretada con una conexión de Bastet)
create table if not exists public.profile_reviews (
  id            uuid primary key default gen_random_uuid(),
  operation_id  uuid not null unique references public.operations(id) on delete cascade,
  reviewed_id   uuid not null references auth.users(id) on delete cascade,
  reviewer_name text not null check (char_length(reviewer_name) between 1 and 80),
  rating        smallint not null check (rating between 1 and 5),
  comment       text check (comment is null or char_length(comment) <= 1200),
  reply         text check (reply is null or char_length(reply) <= 800),
  replied_at    timestamptz,
  status        text not null default 'published' check (status in ('published', 'hidden')),
  created_at    timestamptz not null default now()
);
create index if not exists profile_reviews_idx on public.profile_reviews (reviewed_id, status, created_at desc);
alter table public.profile_reviews enable row level security;
revoke all on public.profile_reviews from anon, authenticated;

create or replace function public.get_operation_review(p_token text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare o public.operations;
begin
  perform public._throttle('operation_review', 30, 60);
  select * into o from public.operations where interested_token = lower(btrim(coalesce(p_token, ''))) and status = 'confirmada' and interested_confirmed is true;
  if not found then return jsonb_build_object('can_review', false); end if;
  return jsonb_build_object('can_review', not exists (select 1 from public.profile_reviews where operation_id = o.id), 'already', exists (select 1 from public.profile_reviews where operation_id = o.id),
    'title', o.property_snapshot ->> 'title', 'reviewed', (select split_part(coalesce(nullif(btrim(display_name), ''), 'el agente'), ' ', 1) from public.profiles where id = o.titular_id));
end $$;

create or replace function public.submit_operation_review(p_token text, p_rating integer, p_comment text)
returns void language plpgsql security definer set search_path = public as $$
declare o public.operations; cm text := nullif(btrim(coalesce(p_comment, '')), ''); nm text;
begin
  perform public._throttle('operation_review', 8, 600);
  select * into o from public.operations where interested_token = lower(btrim(coalesce(p_token, ''))) and status = 'confirmada' and interested_confirmed is true for update;
  if not found then raise exception 'Solo puede reseñar quien confirmó una operación concretada con Bastet'; end if;
  if exists (select 1 from public.profile_reviews where operation_id = o.id) then raise exception 'Ya enviaste tu reseña. ¡Gracias!'; end if;
  if p_rating is null or p_rating not between 1 and 5 then raise exception 'Elige de 1 a 5 estrellas'; end if;
  if cm is not null and char_length(cm) > 1200 then raise exception 'La reseña es demasiado larga (máximo 1200 caracteres)'; end if;
  select split_part(btrim(c.interested_name), ' ', 1) || coalesce(' ' || upper(left(nullif(split_part(btrim(c.interested_name), ' ', 2), ''), 1)) || '.', '') into nm from public.connections c where c.id = o.connection_id;
  insert into public.profile_reviews (operation_id, reviewed_id, reviewer_name, rating, comment) values (o.id, o.titular_id, coalesce(nm, 'Cliente verificado'), p_rating, cm);
end $$;

create or replace function public.list_profile_reviews(p_profile uuid, p_limit integer default 20)
returns table (id uuid, reviewer_name text, rating smallint, comment text, reply text, created_at timestamptz)
language plpgsql security definer set search_path = public as $$
begin
  perform public._throttle('profile_reviews', 60, 60);
  return query select r.id, r.reviewer_name, r.rating, r.comment, r.reply, r.created_at from public.profile_reviews r
    where r.reviewed_id = p_profile and r.status = 'published' order by r.created_at desc limit least(greatest(coalesce(p_limit, 20), 1), 50);
end $$;

create or replace function public.profile_reputation(p_ids uuid[])
returns table (profile_id uuid, avg_rating numeric, review_count integer, verified_operations integer, agent_verified boolean, owner_verified boolean)
language plpgsql security definer set search_path = public as $$
begin
  perform public._throttle('profile_reputation', 60, 60);
  if coalesce(array_length(p_ids, 1), 0) > 100 then raise exception 'Demasiados perfiles'; end if;
  return query select p.id,
    (select round(avg(r.rating)::numeric, 2) from public.profile_reviews r where r.reviewed_id = p.id and r.status = 'published'),
    (select count(*)::integer from public.profile_reviews r where r.reviewed_id = p.id and r.status = 'published'),
    (select count(*)::integer from public.operations o where o.titular_id = p.id and o.status = 'confirmada' and o.kind <> 'desistimiento'),
    p.agent_verified, p.owner_verified
   from public.profiles p where p.id = any (coalesce(p_ids, '{}'::uuid[])) and p.is_active;
end $$;

create or replace function public.reply_profile_review(p_id uuid, p_reply text)
returns void language plpgsql security definer set search_path = public as $$
declare rp text := nullif(btrim(coalesce(p_reply, '')), '');
begin
  if auth.uid() is null or not public.is_active_user() then raise exception 'No autorizado' using errcode = '42501'; end if;
  if rp is not null and char_length(rp) > 800 then raise exception 'La respuesta es demasiado larga (máximo 800 caracteres)'; end if;
  update public.profile_reviews set reply = rp, replied_at = case when rp is null then null else now() end where id = p_id and (reviewed_id = auth.uid() or public.is_admin());
  if not found then raise exception 'Reseña no encontrada'; end if;
end $$;

create or replace function public.admin_set_profile_review_status(p_id uuid, p_status text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Solo administradores' using errcode = '42501'; end if;
  if p_status not in ('published', 'hidden') then raise exception 'Estado inválido'; end if;
  update public.profile_reviews set status = p_status where id = p_id;
  if not found then raise exception 'Reseña no encontrada'; end if;
end $$;

create or replace function public.my_profile_reviews()
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null or not public.is_active_user() then raise exception 'No autorizado' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'reviewer_name', r.reviewer_name, 'rating', r.rating, 'comment', r.comment, 'reply', r.reply, 'status', r.status, 'created_at', r.created_at,
                    'reviewed', case when public.is_admin() then (select display_name from public.profiles where id = r.reviewed_id) end) order by r.created_at desc)
                     from public.profile_reviews r where r.reviewed_id = auth.uid() or public.is_admin()), '[]'::jsonb);
end $$;

-- 4) Consulta pública en «Verificar» (propiedad, agente, certificado de operación). Nunca nombres de particulares, montos ni datos del contrato.
create or replace function public.verify_property_code(p_code text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare n integer; p record;
begin
  perform public._throttle('verify_public', 30, 60);
  n := nullif(regexp_replace(coalesce(p_code, ''), '[^0-9]', '', 'g'), '')::integer;
  select p2.code_number, p2.verified, p2.status, p2.property_type, coalesce(p2.operation, 'venta') as operation, split_part(coalesce(p2.location, ''), ',', 1) as city,
         pr.agent_verified, pr.owner_verified into p
    from public.properties p2 left join public.profiles pr on pr.id = p2.owner_id where p2.code_number = n;
  if not found then return jsonb_build_object('found', false); end if;
  return jsonb_build_object('found', true, 'code', 'BST-' || p.code_number, 'verified', p.verified, 'status', p.status, 'property_type', p.property_type, 'operation', p.operation, 'city', btrim(p.city),
    'agent_verified', p.agent_verified, 'owner_verified', p.owner_verified);
end $$;

create or replace function public.verify_agent_code(p_code text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare p public.profiles; rep record;
begin
  perform public._throttle('verify_public', 30, 60);
  select * into p from public.profiles where public_code = upper(btrim(coalesce(p_code, ''))) and is_active;
  if not found then return jsonb_build_object('found', false); end if;
  select * into rep from public.profile_reputation(array[p.id]);
  return jsonb_build_object('found', true, 'code', p.public_code, 'name', coalesce(nullif(btrim(p.display_name), ''), 'Agente de Bastet'), 'agent_verified', p.agent_verified, 'owner_verified', p.owner_verified,
    'avg_rating', rep.avg_rating, 'review_count', rep.review_count, 'verified_operations', rep.verified_operations);
end $$;

create or replace function public.verify_operation_certificate(p_code text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare o public.operations; pr public.profiles;
begin
  perform public._throttle('verify_public', 30, 60);
  select * into o from public.operations where cert_code = upper(btrim(coalesce(p_code, ''))) and status = 'confirmada';
  if not found then return jsonb_build_object('found', false); end if;
  select * into pr from public.profiles where id = o.titular_id;
  return jsonb_build_object('found', true, 'code', o.cert_code, 'kind', o.kind, 'month', to_char(coalesce(o.signed_date, o.resolved_at::date), 'YYYY-MM'),
    'property_code', 'BST-' || (o.property_snapshot ->> 'code_number'), 'city', btrim(split_part(coalesce(o.property_snapshot ->> 'location', ''), ',', 1)),
    'origin', case when o.connection_id is not null then 'conexion_bastet' else 'revision_administrativa' end, 'agent_verified', pr.agent_verified, 'owner_verified', pr.owner_verified);
end $$;

-- 5) Acta digital de la operación (para el titular y administración): datos de las partes, aceptaciones registradas y numeración
create or replace function public.get_operation_acta(p_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare o public.operations; uid uuid := auth.uid(); c public.connections; pr public.profiles;
begin
  if uid is null or not public.is_active_user() then raise exception 'No autorizado' using errcode = '42501'; end if;
  select * into o from public.operations where id = p_id and status = 'confirmada';
  if not found or (o.titular_id is distinct from uid and not public.is_admin()) then raise exception 'Operación no encontrada'; end if;
  select * into pr from public.profiles where id = o.titular_id;
  select * into c from public.connections where id = o.connection_id;
  return jsonb_build_object('number', o.number, 'cert_code', o.cert_code, 'kind', o.kind, 'signed_date', o.signed_date, 'confirmed_at', o.resolved_at,
    'property', o.property_snapshot, 'amount', o.amount, 'currency', o.currency,
    'titular', jsonb_build_object('name', coalesce(nullif(btrim(pr.full_name), ''), pr.display_name), 'whatsapp', pr.whatsapp, 'agent_verified', pr.agent_verified, 'owner_verified', pr.owner_verified),
    'counterparty', jsonb_build_object('name', o.counterparty_name, 'to_interested', o.to_interested, 'confirmed', o.interested_confirmed, 'confirmed_at', o.interested_at),
    'connection', case when o.connection_id is null then null else jsonb_build_object('number', c.number, 'accepted_at', c.accepted_at, 'verified_at', c.verified_at, 'framework_version', c.framework_version) end,
    'commission', jsonb_build_object('percent', o.commission_percent, 'amount', o.commission_amount, 'bs', o.commission_bs, 'rate', o.bob_per_usd_used, 'status', o.commission_status),
    'admin_note', case when public.is_admin() then o.admin_note end);
end $$;

-- 6) Permisos
revoke all on function public.protect_property_verified(), public.protect_profile_verified(), public.require_verified_for_connection(), public._ver_required_checks(text),
  public.request_verification(text, uuid), public.attach_verification_doc(uuid, text, text), public.submit_verification(uuid, text), public.my_verifications(),
  public.admin_review_verification(uuid, text, jsonb, text), public.admin_revoke_verification(uuid, text), public.verification_events(uuid), public.admin_set_property_verification_required(boolean),
  public.get_operation_review(text), public.submit_operation_review(text, integer, text), public.list_profile_reviews(uuid, integer), public.profile_reputation(uuid[]),
  public.reply_profile_review(uuid, text), public.admin_set_profile_review_status(uuid, text), public.my_profile_reviews(),
  public.verify_property_code(text), public.verify_agent_code(text), public.verify_operation_certificate(text), public.get_operation_acta(uuid) from public, anon;
grant execute on function public.get_operation_review(text), public.submit_operation_review(text, integer, text), public.list_profile_reviews(uuid, integer), public.profile_reputation(uuid[]),
  public.verify_property_code(text), public.verify_agent_code(text), public.verify_operation_certificate(text) to anon, authenticated;
grant execute on function public.request_verification(text, uuid), public.attach_verification_doc(uuid, text, text), public.submit_verification(uuid, text), public.my_verifications(),
  public.admin_review_verification(uuid, text, jsonb, text), public.admin_revoke_verification(uuid, text), public.verification_events(uuid), public.admin_set_property_verification_required(boolean),
  public.reply_profile_review(uuid, text), public.admin_set_profile_review_status(uuid, text), public.my_profile_reviews(), public.get_operation_acta(uuid) to authenticated;

notify pgrst, 'reload schema';

-- =====================================================================
-- Bastet · Investigaciones y sanciones (fase 5)   — correr DESPUÉS de verification.sql
-- Idempotente: se puede correr completo más de una vez. Implementa docs/ESPECIFICACION_MAESTRA.md, secciones 1.6 y 9.4.
--
-- Ocultar una operación originada por una conexión de Bastet es una falta grave. Este módulo da a ADMINISTRACIÓN las herramientas para investigarla
-- con garantías y NO ejecuta nada irreversible por su cuenta:
--   · abrir la investigación (desde una operación, conexión o reserva) y registrar evidencia y notas con su cronología;
--   · SUSPENDER la cuenta mientras dura (reversible) — una cuenta suspendida no recibe nuevas conexiones;
--   · DESCARGOS: se abre un plazo y la persona investigada los presenta por un enlace propio (aunque su cuenta esté suspendida);
--   · REVISIÓN JURÍDICA: se registra quién revisó y su concepto;
--   · RESOLUCIÓN escrita. La penalización (2,25 % del precio de la operación = 3 veces la comisión de venta, en Bs con el tipo de cambio interno,
--     congelada) o la eliminación de la cuenta SOLO se pueden resolver con descargos cumplidos Y revisión jurídica registrada.
--   · La ELIMINACIÓN de la cuenta solo queda AUTORIZADA en el registro: no se ejecuta aquí (se hace a mano en Usuarios), nunca de forma automática.
-- La cláusula penal, el procedimiento y la sanción deben revisarse con un abogado en Bolivia ANTES de aplicarlos a una persona real.
-- =====================================================================

do $$
begin
  if to_regclass('public.operations') is null or to_regprocedure('public._throttle(text, integer, integer)') is null then raise exception 'Primero corre supabase/operations.sql y supabase/security-hardening.sql'; end if;
end $$;

alter table public.connection_settings add column if not exists penalty_percent numeric(6,3) not null default 2.25 check (penalty_percent between 0 and 20);
alter table public.connection_settings add column if not exists descargos_days  integer not null default 5 check (descargos_days between 1 and 30);

create table if not exists public.investigation_counters (year integer primary key, last_number integer not null);
alter table public.investigation_counters enable row level security;
revoke all on public.investigation_counters from anon, authenticated;

create table if not exists public.investigations (
  id               uuid primary key default gen_random_uuid(),
  code             text not null unique,
  kind             text not null check (kind in ('ocultamiento_operacion', 'falta_anfitrion', 'otra')),
  subject_id       uuid references auth.users(id) on delete set null,
  operation_id     uuid references public.operations(id) on delete set null,
  connection_id    uuid references public.connections(id) on delete set null,
  stay_booking_id  uuid references public.stay_bookings(id) on delete set null,
  property_id      uuid references public.properties(id) on delete set null,
  summary          text not null check (char_length(summary) between 10 and 2000),
  status           text not null default 'abierta' check (status in ('abierta', 'descargos', 'revision_juridica', 'resuelta', 'archivada')),
  suspended        boolean not null default false,
  suspended_at     timestamptz,
  suspension_reason text check (suspension_reason is null or char_length(suspension_reason) <= 500),
  descargos_token  text unique,
  descargos_opened_at timestamptz,
  descargos_until  timestamptz,
  basis_amount     numeric(16,2),                         -- precio de la operación sobre el que se calcula la penalización
  basis_currency   text check (basis_currency in ('USD', 'BOB')),
  penalty_percent  numeric(6,3),
  bob_per_usd_used numeric(8,4),
  penalty_bs       numeric(16,2),                         -- congelada, en bolivianos
  penalty_status   text not null default 'no_aplica' check (penalty_status in ('no_aplica', 'propuesta', 'impuesta', 'pagada', 'anulada')),
  legal_reviewer   text check (legal_reviewer is null or char_length(legal_reviewer) <= 120),
  legal_reviewed_at timestamptz,
  legal_concept    text check (legal_concept is null or char_length(legal_concept) <= 4000),
  decision         text check (decision in ('sin_falta', 'amonestacion', 'penalizacion', 'suspension', 'eliminacion_cuenta')),
  decision_note    text check (decision_note is null or char_length(decision_note) <= 4000),
  decided_by       uuid references auth.users(id) on delete set null,
  decided_at       timestamptz,
  deletion_authorized boolean not null default false,
  created_by       uuid references auth.users(id) on delete set null,
  created_at       timestamptz not null default now()
);
create index if not exists investigations_subject_idx on public.investigations (subject_id, status);
alter table public.investigations enable row level security;
revoke all on public.investigations from anon, authenticated;

create table if not exists public.investigation_items (
  id               bigint generated always as identity primary key,
  investigation_id uuid not null references public.investigations(id) on delete cascade,
  author           text not null check (author in ('admin', 'titular')),
  kind             text not null check (kind in ('evidencia', 'descargo', 'nota')),
  body             text not null check (char_length(body) between 1 and 4000),
  file_path        text check (file_path is null or char_length(file_path) <= 300),
  created_at       timestamptz not null default now()
);
create index if not exists investigation_items_idx on public.investigation_items (investigation_id, created_at);
alter table public.investigation_items enable row level security;
revoke all on public.investigation_items from anon, authenticated;

create table if not exists public.investigation_events (
  id               bigint generated always as identity primary key,
  investigation_id uuid not null references public.investigations(id) on delete cascade,
  actor            text not null, actor_id uuid, event text not null, data jsonb,
  created_at       timestamptz not null default now()
);
alter table public.investigation_events enable row level security;
revoke all on public.investigation_events from anon, authenticated;
create or replace function public._inv_log(p_inv uuid, p_actor text, p_event text, p_data jsonb default null)
returns void language sql security definer set search_path = public as $$
  insert into public.investigation_events (investigation_id, actor, actor_id, event, data) values (p_inv, p_actor, auth.uid(), p_event, p_data);
$$;
revoke all on function public._inv_log(uuid, text, text, jsonb) from public, anon, authenticated;

-- Carpeta privada de evidencia: solo administración
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('investigation-docs', 'investigation-docs', false, 10485760, array['application/pdf', 'image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do update set public = false, file_size_limit = 10485760, allowed_mime_types = array['application/pdf', 'image/jpeg', 'image/png', 'image/webp'];
drop policy if exists "admin manages investigation docs" on storage.objects;
create policy "admin manages investigation docs" on storage.objects for all to authenticated
  using (bucket_id = 'investigation-docs' and public.is_admin()) with check (bucket_id = 'investigation-docs' and public.is_admin());

-- Una cuenta suspendida (inactiva) no recibe nuevas conexiones
create or replace function public.block_suspended_owner_connection()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if exists (select 1 from public.profiles p where p.id = new.titular_id and not p.is_active) then
    raise exception 'Esta propiedad no está disponible por ahora.';
  end if;
  return new;
end $$;
drop trigger if exists block_suspended_owner_connection on public.connections;
create trigger block_suspended_owner_connection before insert on public.connections for each row execute function public.block_suspended_owner_connection();

-- 1) Abrir la investigación
create or replace function public.admin_open_investigation(p_kind text, p_subject uuid, p_operation uuid, p_connection uuid, p_booking uuid, p_property uuid, p_summary text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare s public.connection_settings; subj uuid := p_subject; op public.operations; yr integer; seq integer; cd text; iid uuid; rate numeric; pen numeric; sm text := btrim(coalesce(p_summary, ''));
begin
  if not public.is_admin() then raise exception 'Solo administradores' using errcode = '42501'; end if;
  if p_kind not in ('ocultamiento_operacion', 'falta_anfitrion', 'otra') then raise exception 'Tipo de investigación inválido'; end if;
  if char_length(sm) not between 10 and 2000 then raise exception 'Describe los hechos (entre 10 y 2000 caracteres)'; end if;
  select * into s from public.connection_settings where id = 1;
  select bob_per_usd into rate from public.stay_settings where id = 1; rate := coalesce(rate, 6.96);
  if p_operation is not null then
    select * into op from public.operations where id = p_operation;
    if not found then raise exception 'Operación no encontrada'; end if;
    subj := coalesce(subj, op.titular_id);
  end if;
  if subj is null and p_connection is not null then select titular_id into subj from public.connections where id = p_connection; end if;
  if subj is null and p_booking is not null then select host_id into subj from public.stay_bookings where id = p_booking; end if;
  if subj is null then raise exception 'Indica la persona investigada'; end if;
  if exists (select 1 from public.profiles where id = subj and role = 'admin') then raise exception 'No se investiga a una cuenta de administración desde aquí'; end if;
  yr := extract(year from ((now() at time zone 'UTC') - interval '4 hours'))::integer;
  insert into public.investigation_counters (year, last_number) values (yr, 1) on conflict (year) do update set last_number = public.investigation_counters.last_number + 1 returning last_number into seq;
  cd := 'INV-' || yr || '-' || lpad(seq::text, 4, '0');
  insert into public.investigations (code, kind, subject_id, operation_id, connection_id, stay_booking_id, property_id, summary, created_by)
  values (cd, p_kind, subj, p_operation, p_connection, p_booking, coalesce(p_property, op.property_id), sm, auth.uid()) returning id into iid;
  if p_kind = 'ocultamiento_operacion' and op.id is not null and op.amount is not null then
    pen := round(op.amount * s.penalty_percent / 100, 2);
    update public.investigations set basis_amount = op.amount, basis_currency = op.currency, penalty_percent = s.penalty_percent, bob_per_usd_used = rate,
           penalty_bs = round(case when op.currency = 'BOB' then pen else pen * rate end, 2), penalty_status = 'propuesta' where id = iid;
  end if;
  perform public._inv_log(iid, 'admin', 'abierta', jsonb_build_object('kind', p_kind, 'operation', p_operation, 'connection', p_connection, 'booking', p_booking));
  return jsonb_build_object('id', iid, 'code', cd);
end $$;

-- Si no hay operación de la que tomar el precio, se fija a mano
create or replace function public.admin_set_investigation_basis(p_inv uuid, p_amount numeric, p_currency text)
returns void language plpgsql security definer set search_path = public as $$
declare s public.connection_settings; rate numeric; pen numeric; i public.investigations;
begin
  if not public.is_admin() then raise exception 'Solo administradores' using errcode = '42501'; end if;
  select * into i from public.investigations where id = p_inv and status not in ('resuelta', 'archivada') for update;
  if not found then raise exception 'Investigación no encontrada o ya cerrada'; end if;
  if p_amount is null or p_amount <= 0 or p_currency not in ('USD', 'BOB') then raise exception 'Indica el precio de la operación y su moneda'; end if;
  select * into s from public.connection_settings where id = 1;
  select bob_per_usd into rate from public.stay_settings where id = 1; rate := coalesce(rate, 6.96);
  pen := round(p_amount * s.penalty_percent / 100, 2);
  update public.investigations set basis_amount = p_amount, basis_currency = p_currency, penalty_percent = s.penalty_percent, bob_per_usd_used = rate,
         penalty_bs = round(case when p_currency = 'BOB' then pen else pen * rate end, 2), penalty_status = 'propuesta' where id = i.id;
  perform public._inv_log(i.id, 'admin', 'base_de_penalizacion', jsonb_build_object('amount', p_amount, 'currency', p_currency));
end $$;

-- 2) Suspender / reponer la cuenta mientras dura (reversible)
create or replace function public.admin_set_suspension(p_inv uuid, p_suspend boolean, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
declare i public.investigations; rs text := nullif(btrim(coalesce(p_reason, '')), '');
begin
  if not public.is_admin() then raise exception 'Solo administradores' using errcode = '42501'; end if;
  if rs is null then raise exception 'Escribe el motivo (queda en el historial)'; end if;
  select * into i from public.investigations where id = p_inv for update;
  if not found or i.subject_id is null then raise exception 'Investigación no encontrada'; end if;
  if p_suspend then
    if i.suspended then raise exception 'La cuenta ya está suspendida por esta investigación'; end if;
    update public.profiles set is_active = false where id = i.subject_id and role <> 'admin';
    update public.investigations set suspended = true, suspended_at = now(), suspension_reason = rs where id = i.id;
    perform public._inv_log(i.id, 'admin', 'cuenta_suspendida', jsonb_build_object('reason', rs));
  else
    if not i.suspended then raise exception 'La cuenta no está suspendida por esta investigación'; end if;
    update public.profiles set is_active = true where id = i.subject_id;
    update public.investigations set suspended = false where id = i.id;
    perform public._inv_log(i.id, 'admin', 'cuenta_repuesta', jsonb_build_object('reason', rs));
  end if;
end $$;

-- 3) Descargos: plazo y enlace propio de la persona investigada
create or replace function public.admin_open_descargos(p_inv uuid, p_days integer default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare s public.connection_settings; i public.investigations; d integer; tok text;
begin
  if not public.is_admin() then raise exception 'Solo administradores' using errcode = '42501'; end if;
  select * into s from public.connection_settings where id = 1;
  d := coalesce(p_days, s.descargos_days);
  if d not between 1 and 30 then raise exception 'El plazo debe ser de 1 a 30 días'; end if;
  select * into i from public.investigations where id = p_inv and status in ('abierta', 'descargos', 'revision_juridica') for update;
  if not found then raise exception 'Investigación no encontrada o ya cerrada'; end if;
  tok := coalesce(i.descargos_token, lower(replace(gen_random_uuid()::text, '-', '')));
  update public.investigations set descargos_token = tok, descargos_opened_at = coalesce(descargos_opened_at, now()), descargos_until = now() + make_interval(days => d), status = case when status = 'abierta' then 'descargos' else status end where id = i.id;
  perform public._inv_log(i.id, 'admin', 'plazo_de_descargos', jsonb_build_object('days', d));
  return jsonb_build_object('token', tok, 'until', now() + make_interval(days => d));
end $$;

create or replace function public.get_descargos_public(p_token text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare i public.investigations;
begin
  perform public._throttle('descargos', 30, 60);
  select * into i from public.investigations where descargos_token = lower(btrim(coalesce(p_token, '')));
  if not found then return jsonb_build_object('valid', false); end if;
  return jsonb_build_object('valid', true, 'code', i.code, 'summary', i.summary, 'status', i.status, 'until', i.descargos_until,
    'open', i.descargos_until is not null and i.descargos_until >= now() and i.status in ('abierta', 'descargos', 'revision_juridica'),
    'sent', coalesce((select jsonb_agg(jsonb_build_object('body', x.body, 'at', x.created_at) order by x.created_at) from public.investigation_items x where x.investigation_id = i.id and x.kind = 'descargo'), '[]'::jsonb));
end $$;

create or replace function public.submit_descargo_public(p_token text, p_text text)
returns void language plpgsql security definer set search_path = public as $$
declare i public.investigations; tx text := btrim(coalesce(p_text, ''));
begin
  perform public._throttle('descargos', 8, 600);
  select * into i from public.investigations where descargos_token = lower(btrim(coalesce(p_token, ''))) for update;
  if not found then raise exception 'Este enlace no es válido'; end if;
  if i.descargos_until is null or i.descargos_until < now() or i.status not in ('abierta', 'descargos', 'revision_juridica') then raise exception 'El plazo para presentar descargos terminó'; end if;
  if char_length(tx) not between 10 and 4000 then raise exception 'Escribe tus descargos (entre 10 y 4000 caracteres)'; end if;
  if (select count(*) from public.investigation_items where investigation_id = i.id and kind = 'descargo') >= 5 then raise exception 'Ya enviaste el máximo de 5 descargos'; end if;
  insert into public.investigation_items (investigation_id, author, kind, body) values (i.id, 'titular', 'descargo', tx);
  perform public._inv_log(i.id, 'titular', 'descargo_presentado', jsonb_build_object('chars', char_length(tx)));
end $$;

-- 4) Evidencia, notas y revisión jurídica
create or replace function public.admin_add_investigation_item(p_inv uuid, p_kind text, p_body text, p_path text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Solo administradores' using errcode = '42501'; end if;
  if p_kind not in ('evidencia', 'nota') then raise exception 'Tipo inválido'; end if;
  if p_path is not null and (char_length(p_path) > 300 or p_path like '%..%') then raise exception 'Archivo inválido'; end if;
  if not exists (select 1 from public.investigations where id = p_inv) then raise exception 'Investigación no encontrada'; end if;
  insert into public.investigation_items (investigation_id, author, kind, body, file_path) values (p_inv, 'admin', p_kind, btrim(coalesce(p_body, '')), nullif(btrim(coalesce(p_path, '')), ''));
  perform public._inv_log(p_inv, 'admin', 'evidencia_o_nota', jsonb_build_object('kind', p_kind));
end $$;

create or replace function public.admin_record_legal_review(p_inv uuid, p_reviewer text, p_concept text)
returns void language plpgsql security definer set search_path = public as $$
declare i public.investigations; rv text := btrim(coalesce(p_reviewer, '')); cp text := btrim(coalesce(p_concept, ''));
begin
  if not public.is_admin() then raise exception 'Solo administradores' using errcode = '42501'; end if;
  if char_length(rv) < 3 then raise exception 'Indica quién hizo la revisión jurídica'; end if;
  if char_length(cp) < 20 then raise exception 'Resume el concepto jurídico (mínimo 20 caracteres)'; end if;
  select * into i from public.investigations where id = p_inv and status not in ('resuelta', 'archivada') for update;
  if not found then raise exception 'Investigación no encontrada o ya cerrada'; end if;
  update public.investigations set legal_reviewer = rv, legal_concept = cp, legal_reviewed_at = now(), status = 'revision_juridica' where id = i.id;
  perform public._inv_log(i.id, 'admin', 'revision_juridica', jsonb_build_object('reviewer', rv));
end $$;

-- 5) Resolución: las sanciones exigen descargos cumplidos Y revisión jurídica registrada. Nada irreversible se ejecuta aquí.
create or replace function public.admin_resolve_investigation(p_inv uuid, p_decision text, p_note text)
returns void language plpgsql security definer set search_path = public as $$
declare i public.investigations; nt text := btrim(coalesce(p_note, '')); desc_ok boolean; grave boolean;
begin
  if not public.is_admin() then raise exception 'Solo administradores' using errcode = '42501'; end if;
  if p_decision not in ('sin_falta', 'amonestacion', 'penalizacion', 'suspension', 'eliminacion_cuenta') then raise exception 'Decisión inválida'; end if;
  if char_length(nt) < 20 then raise exception 'Documenta la decisión (mínimo 20 caracteres): queda en el historial'; end if;
  select * into i from public.investigations where id = p_inv and status not in ('resuelta', 'archivada') for update;
  if not found then raise exception 'Investigación no encontrada o ya cerrada'; end if;
  desc_ok := exists (select 1 from public.investigation_items where investigation_id = i.id and kind = 'descargo') or (i.descargos_until is not null and i.descargos_until < now());
  grave := p_decision in ('penalizacion', 'suspension', 'eliminacion_cuenta');
  if p_decision <> 'sin_falta' and not desc_ok then raise exception 'Antes de decidir hay que dar a la persona la oportunidad de presentar descargos (abrir el plazo y esperar sus descargos o su vencimiento)'; end if;
  if grave and i.legal_reviewed_at is null then raise exception 'Esta decisión exige una revisión jurídica registrada (quién revisó y su concepto)'; end if;
  if p_decision = 'penalizacion' and i.penalty_bs is null then raise exception 'Falta la base de la penalización: indica el precio de la operación'; end if;
  if p_decision = 'sin_falta' then
    update public.investigations set penalty_status = case when penalty_status = 'no_aplica' then 'no_aplica' else 'anulada' end where id = i.id;
    if i.suspended then update public.profiles set is_active = true where id = i.subject_id; update public.investigations set suspended = false where id = i.id; end if;
  elsif p_decision = 'penalizacion' then update public.investigations set penalty_status = 'impuesta' where id = i.id;
  elsif p_decision = 'suspension' then
    update public.profiles set is_active = false where id = i.subject_id and role <> 'admin';
    update public.investigations set suspended = true, suspended_at = coalesce(suspended_at, now()), suspension_reason = coalesce(suspension_reason, nt) where id = i.id;
  elsif p_decision = 'eliminacion_cuenta' then update public.investigations set deletion_authorized = true where id = i.id;
  end if;
  update public.investigations set status = 'resuelta', decision = p_decision, decision_note = nt, decided_by = auth.uid(), decided_at = now() where id = i.id;
  perform public._inv_log(i.id, 'admin', 'resuelta', jsonb_build_object('decision', p_decision, 'note', nt, 'penalty_bs', case when p_decision = 'penalizacion' then i.penalty_bs end));
end $$;

create or replace function public.admin_mark_penalty_paid(p_inv uuid, p_note text)
returns void language plpgsql security definer set search_path = public as $$
declare i public.investigations;
begin
  if not public.is_admin() then raise exception 'Solo administradores' using errcode = '42501'; end if;
  select * into i from public.investigations where id = p_inv and penalty_status = 'impuesta' for update;
  if not found then raise exception 'No hay una penalización impuesta pendiente de pago'; end if;
  update public.investigations set penalty_status = 'pagada' where id = i.id;
  perform public._inv_log(i.id, 'admin', 'penalizacion_pagada', jsonb_build_object('bs', i.penalty_bs, 'note', p_note));
end $$;

create or replace function public.admin_archive_investigation(p_inv uuid, p_note text)
returns void language plpgsql security definer set search_path = public as $$
declare i public.investigations; nt text := btrim(coalesce(p_note, ''));
begin
  if not public.is_admin() then raise exception 'Solo administradores' using errcode = '42501'; end if;
  if char_length(nt) < 10 then raise exception 'Explica por qué se archiva'; end if;
  select * into i from public.investigations where id = p_inv and status not in ('resuelta', 'archivada') for update;
  if not found then raise exception 'Investigación no encontrada o ya cerrada'; end if;
  if i.suspended then update public.profiles set is_active = true where id = i.subject_id; end if;
  update public.investigations set status = 'archivada', suspended = false, decision_note = nt, decided_by = auth.uid(), decided_at = now() where id = i.id;
  perform public._inv_log(i.id, 'admin', 'archivada', jsonb_build_object('note', nt));
end $$;

-- 6) Listas (solo administración)
create or replace function public.admin_investigations()
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Solo administradores' using errcode = '42501'; end if;
  return jsonb_build_object('penalty_percent', (select penalty_percent from public.connection_settings where id = 1), 'descargos_days', (select descargos_days from public.connection_settings where id = 1),
    'items', coalesce((select jsonb_agg(jsonb_build_object('id', i.id, 'code', i.code, 'kind', i.kind, 'status', i.status, 'summary', i.summary, 'subject_id', i.subject_id,
        'subject_name', (select coalesce(nullif(btrim(full_name), ''), display_name, email) from public.profiles where id = i.subject_id), 'subject_active', (select is_active from public.profiles where id = i.subject_id),
        'operation_id', i.operation_id, 'operation_number', (select number from public.operations where id = i.operation_id), 'connection_id', i.connection_id, 'stay_booking_id', i.stay_booking_id, 'property_id', i.property_id,
        'suspended', i.suspended, 'suspended_at', i.suspended_at, 'suspension_reason', i.suspension_reason, 'descargos_token', i.descargos_token, 'descargos_until', i.descargos_until,
        'basis_amount', i.basis_amount, 'basis_currency', i.basis_currency, 'penalty_percent', i.penalty_percent, 'penalty_bs', i.penalty_bs, 'penalty_status', i.penalty_status,
        'legal_reviewer', i.legal_reviewer, 'legal_reviewed_at', i.legal_reviewed_at, 'legal_concept', i.legal_concept, 'decision', i.decision, 'decision_note', i.decision_note, 'decided_at', i.decided_at,
        'deletion_authorized', i.deletion_authorized, 'created_at', i.created_at,
        'items', coalesce((select jsonb_agg(jsonb_build_object('author', x.author, 'kind', x.kind, 'body', x.body, 'file_path', x.file_path, 'at', x.created_at) order by x.created_at) from public.investigation_items x where x.investigation_id = i.id), '[]'::jsonb))
        order by i.created_at desc) from public.investigations i), '[]'::jsonb));
end $$;

create or replace function public.investigation_events(p_inv uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Solo administradores' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('actor', e.actor, 'event', e.event, 'data', e.data, 'at', e.created_at) order by e.created_at, e.id) from public.investigation_events e where e.investigation_id = p_inv), '[]'::jsonb);
end $$;

-- 7) Permisos
revoke all on function public.block_suspended_owner_connection(), public.admin_open_investigation(text, uuid, uuid, uuid, uuid, uuid, text), public.admin_set_investigation_basis(uuid, numeric, text),
  public.admin_set_suspension(uuid, boolean, text), public.admin_open_descargos(uuid, integer), public.get_descargos_public(text), public.submit_descargo_public(text, text),
  public.admin_add_investigation_item(uuid, text, text, text), public.admin_record_legal_review(uuid, text, text), public.admin_resolve_investigation(uuid, text, text),
  public.admin_mark_penalty_paid(uuid, text), public.admin_archive_investigation(uuid, text), public.admin_investigations(), public.investigation_events(uuid) from public, anon;
grant execute on function public.get_descargos_public(text), public.submit_descargo_public(text, text) to anon, authenticated;
grant execute on function public.admin_open_investigation(text, uuid, uuid, uuid, uuid, uuid, text), public.admin_set_investigation_basis(uuid, numeric, text), public.admin_set_suspension(uuid, boolean, text),
  public.admin_open_descargos(uuid, integer), public.admin_add_investigation_item(uuid, text, text, text), public.admin_record_legal_review(uuid, text, text), public.admin_resolve_investigation(uuid, text, text),
  public.admin_mark_penalty_paid(uuid, text), public.admin_archive_investigation(uuid, text), public.admin_investigations(), public.investigation_events(uuid) to authenticated;

notify pgrst, 'reload schema';
