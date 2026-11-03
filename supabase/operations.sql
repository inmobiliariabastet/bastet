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
