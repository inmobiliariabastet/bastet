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
