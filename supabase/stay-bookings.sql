-- =====================================================================
-- Bastet · Estadías temporales: reservas con aprobación del anfitrión y pago del 10 %   — correr DESPUÉS de stays.sql y stay-availability.sql
-- Idempotente: se puede correr completo más de una vez. Implementa docs/ESPECIFICACION_MAESTRA.md, secciones 3, 4 y 9.2.
--
-- Flujo: el huésped (sin cuenta) solicita fechas → el anfitrión tiene 2 horas para aceptar o rechazar → si acepta, el huésped paga a Bastet
-- el 10 % del total (QR/transferencia) y sube el comprobante → un administrador lo verifica → recién entonces se revela el contacto
-- (conexión). El 90 % restante se coordina directo entre huésped y anfitrión: Bastet NO lo cobra, retiene ni garantiza.
--
-- INTERRUPTOR: stay_settings.enabled (apagado por defecto). Mientras esté apagado, Estadías sigue consultando por WhatsApp.
--   Para encender:  update public.stay_settings set enabled = true where id = 1;
-- Tarifa y reglas son editables en stay_settings (o desde el panel, pestaña Reservas). El tipo de cambio es el INTERNO de Bastet.
-- Plazo del huésped para pagar tras la aceptación: 12 horas (decisión de la dueña, 2026-11-03), editable en pay_window_hours.
-- Aviso al anfitrión: contador y actualización automática en su panel + botón «Avisar por WhatsApp» para administración (my_stay_bookings devuelve host_whatsapp solo al admin).
-- =====================================================================

do $$
begin
  if to_regclass('public.stay_blocks') is null then raise exception 'Primero corre supabase/stay-availability.sql'; end if;
end $$;

-- 1) Reglas editables (una sola fila)
create table if not exists public.stay_settings (
  id                  smallint primary key default 1 check (id = 1),
  enabled             boolean  not null default false,
  fee_percent         numeric(5,2) not null default 10 check (fee_percent between 0 and 50),   -- comisión de Bastet; en cancelación tardía el anfitrión retiene otro tanto
  response_hours      integer  not null default 2  check (response_hours between 1 and 72),
  free_cancel_hours   integer  not null default 72 check (free_cancel_hours between 0 and 720),
  pay_window_hours    integer  default 12 check (pay_window_hours is null or pay_window_hours between 1 and 720),   -- horas que tiene el huésped para pagar tras la aceptación (null = sin plazo)
  bob_per_usd         numeric(8,4) not null default 6.96 check (bob_per_usd > 0),               -- tipo de cambio INTERNO de Bastet
  pay_instructions    text not null default '' check (char_length(pay_instructions) <= 1500),
  pay_qr_url          text check (pay_qr_url is null or char_length(pay_qr_url) <= 400),
  updated_at          timestamptz not null default now()
);
alter table public.stay_settings alter column pay_window_hours set default 12;
insert into public.stay_settings (id) values (1) on conflict (id) do nothing;
alter table public.stay_settings enable row level security;
revoke all on public.stay_settings from anon, authenticated;

-- 2) Reservas
create table if not exists public.stay_bookings (
  id                 uuid primary key default gen_random_uuid(),
  code               text not null unique,
  property_id        uuid not null references public.properties(id) on delete cascade,
  host_id            uuid references auth.users(id) on delete set null,
  guest_name         text not null check (char_length(btrim(guest_name)) between 2 and 60),
  guest_phone        text not null check (char_length(guest_phone) between 7 and 20),
  guest_email        text check (guest_email is null or char_length(guest_email) <= 120),
  guests             smallint not null check (guests between 1 and 16),
  check_in           date not null,
  check_out          date not null,
  nights             integer not null check (nights between 1 and 90),
  currency           text not null check (currency in ('USD', 'BOB')),
  nightly_price      numeric(14,2) not null,
  total              numeric(14,2) not null,            -- valor total de la reserva, en la moneda de la propiedad
  fee_amount         numeric(14,2) not null,            -- 10 % del total, en la moneda de la propiedad
  bob_per_usd_used   numeric(8,4) not null,             -- tipo de cambio interno congelado al solicitar
  fee_bs             numeric(14,2) not null,            -- lo que se paga a Bastet, en bolivianos
  status             text not null default 'pendiente_respuesta_anfitrion' check (status in
                       ('pendiente_respuesta_anfitrion','rechazada','expirada','aceptada_pendiente_pago','comprobante_enviado',
                        'pago_en_revision','pago_verificado','conexion_generada','cancelada','en_disputa')),
  respond_by         timestamptz not null,
  accepted_at        timestamptz,
  proof_path         text check (proof_path is null or char_length(proof_path) <= 300),
  proof_at           timestamptz,
  verified_at        timestamptz,
  verified_by        uuid references auth.users(id) on delete set null,
  review_note        text check (review_note is null or char_length(review_note) <= 500),
  cancelled_by       text check (cancelled_by in ('guest', 'host', 'admin')),
  cancelled_at       timestamptz,
  cancel_reason      text check (cancel_reason is null or char_length(cancel_reason) <= 500),
  late_cancel        boolean,
  bastet_refund_bs   numeric(14,2),                     -- cuánto devuelve Bastet del pago que recibió
  host_retention     numeric(14,2),                     -- cancelación tardía del huésped: 10 % que conserva el anfitrión (moneda de la propiedad)
  host_refund_due    numeric(14,2),                     -- lo que el anfitrión debe devolver DIRECTO al huésped si recibió el 90 %
  direct_status      text check (direct_status in ('no_recibido', 'recibido_con_comprobante', 'declarado_sin_comprobante')),
  direct_amount      numeric(14,2),
  direct_date        date,
  direct_method      text check (direct_method is null or char_length(direct_method) <= 60),
  direct_proof_path  text check (direct_proof_path is null or char_length(direct_proof_path) <= 300),
  direct_declared_at timestamptz,
  direct_review      text check (direct_review in ('pendiente', 'revisado', 'controvertido')),
  direct_review_note text check (direct_review_note is null or char_length(direct_review_note) <= 500),
  created_at         timestamptz not null default now(),
  constraint stay_bookings_range_check check (check_out > check_in)
);
create index if not exists stay_bookings_property_idx on public.stay_bookings (property_id, status, check_in);
create index if not exists stay_bookings_host_idx on public.stay_bookings (host_id, created_at desc);
alter table public.stay_bookings enable row level security;
revoke all on public.stay_bookings from anon, authenticated;

-- 3) Auditoría: quién, cuándo, de qué estado a cuál y con qué datos (sección 9.6)
create table if not exists public.stay_booking_events (
  id          bigint generated always as identity primary key,
  booking_id  uuid not null references public.stay_bookings(id) on delete cascade,
  actor       text not null,                            -- guest | host | admin | system
  actor_id    uuid,
  event       text not null,
  from_status text,
  to_status   text,
  data        jsonb,
  created_at  timestamptz not null default now()
);
create index if not exists stay_booking_events_idx on public.stay_booking_events (booking_id, created_at);
alter table public.stay_booking_events enable row level security;
revoke all on public.stay_booking_events from anon, authenticated;

create or replace function public.stay_log(p_booking uuid, p_actor text, p_event text, p_from text, p_to text, p_data jsonb default null)
returns void language sql security definer set search_path = public as $$
  insert into public.stay_booking_events (booking_id, actor, actor_id, event, from_status, to_status, data)
  values (p_booking, p_actor, auth.uid(), p_event, p_from, p_to, p_data);
$$;
revoke all on function public.stay_log(uuid, text, text, text, text, jsonb) from public, anon, authenticated;

-- Solicitudes sin respuesta del anfitrión dentro del plazo → expiradas (se aplica al consultar, sin tareas programadas)
create or replace function public.stay_expire_pending()
returns void language plpgsql security definer set search_path = public as $$
declare r record;
begin
  for r in select id from public.stay_bookings where status = 'pendiente_respuesta_anfitrion' and respond_by < now() loop
    update public.stay_bookings set status = 'expirada' where id = r.id;
    perform public.stay_log(r.id, 'system', 'expirada_sin_respuesta', 'pendiente_respuesta_anfitrion', 'expirada');
  end loop;
  -- Plazo de pago (solo si el negocio lo define)
  for r in select b.id from public.stay_bookings b, public.stay_settings s
            where s.pay_window_hours is not null and b.status = 'aceptada_pendiente_pago' and b.accepted_at + make_interval(hours => s.pay_window_hours) < now() loop
    update public.stay_bookings set status = 'expirada' where id = r.id;
    perform public.stay_log(r.id, 'system', 'expirada_sin_pago', 'aceptada_pendiente_pago', 'expirada');
  end loop;
end $$;
revoke all on function public.stay_expire_pending() from public, anon, authenticated;

-- 4) Comprobantes: carpeta privada (huésped sube a <código>/…; anfitrión sube su constancia del 90 % a host/<id de reserva>/…)
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('stay-proofs', 'stay-proofs', false, 5242880, array['application/pdf', 'image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do update set public = false, file_size_limit = 5242880, allowed_mime_types = array['application/pdf', 'image/jpeg', 'image/png', 'image/webp'];

create or replace function public.stay_code_accepts_proof(p_code text)
returns boolean language sql security definer set search_path = public stable as $$
  select exists (select 1 from public.stay_bookings where code = p_code and status in ('aceptada_pendiente_pago', 'comprobante_enviado', 'pago_en_revision'));
$$;
create or replace function public.stay_host_owns_booking(p_id text)
returns boolean language sql security definer set search_path = public stable as $$
  select auth.uid() is not null and exists (select 1 from public.stay_bookings where id::text = p_id and host_id = auth.uid());
$$;
revoke all on function public.stay_code_accepts_proof(text), public.stay_host_owns_booking(text) from public;
grant execute on function public.stay_code_accepts_proof(text), public.stay_host_owns_booking(text) to anon, authenticated;

drop policy if exists "guest uploads stay proof" on storage.objects;
create policy "guest uploads stay proof" on storage.objects for insert to anon, authenticated
  with check (bucket_id = 'stay-proofs' and (storage.foldername(name))[1] <> 'host' and public.stay_code_accepts_proof((storage.foldername(name))[1]));
drop policy if exists "host uploads direct proof" on storage.objects;
create policy "host uploads direct proof" on storage.objects for insert to authenticated
  with check (bucket_id = 'stay-proofs' and (storage.foldername(name))[1] = 'host' and public.stay_host_owns_booking((storage.foldername(name))[2]));
drop policy if exists "admin reads stay proofs" on storage.objects;
create policy "admin reads stay proofs" on storage.objects for select to authenticated using (bucket_id = 'stay-proofs' and public.is_admin());
drop policy if exists "admin deletes stay proofs" on storage.objects;
create policy "admin deletes stay proofs" on storage.objects for delete to authenticated using (bucket_id = 'stay-proofs' and public.is_admin());

-- 5) Público: ¿están activas las reservas con pago?
create or replace function public.stay_booking_enabled()
returns boolean language sql security definer set search_path = public stable as $$ select coalesce((select enabled from public.stay_settings where id = 1), false) $$;
revoke all on function public.stay_booking_enabled() from public;
grant execute on function public.stay_booking_enabled() to anon, authenticated;

-- 6) El huésped solicita una reserva (sin cuenta). Devuelve su código de seguimiento.
create or replace function public.create_stay_booking(p_property uuid, p_from date, p_to date, p_guests integer, p_name text, p_phone text, p_email text default null)
returns text language plpgsql security definer set search_path = public as $$
declare s public.stay_settings; prop record; v_n integer; v_price numeric; v_total numeric; v_fee numeric; v_rate numeric; v_feebs numeric; tries int := 0; cd text;
        nm text := btrim(coalesce(p_name, '')); ph text := regexp_replace(coalesce(p_phone, ''), '[^0-9+]', '', 'g'); em text := nullif(btrim(coalesce(p_email, '')), '');
begin
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

-- 7) El huésped consulta su reserva con el código. El contacto del anfitrión solo se entrega cuando el pago está verificado.
create or replace function public.get_stay_booking(p_code text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare b public.stay_bookings; s public.stay_settings; prop record; contact text; pay boolean; reveal boolean; arrival timestamp; host_name text;
begin
  perform public.stay_expire_pending();
  select * into b from public.stay_bookings where code = upper(btrim(coalesce(p_code, '')));
  if not found then return jsonb_build_object('found', false); end if;
  select * into s from public.stay_settings where id = 1;
  select title, location, photos[1] as photo, whatsapp into prop from public.properties where id = b.property_id;
  select display_name, contact_whatsapp into host_name, contact from public.profiles where id = b.host_id;
  reveal := b.status = 'conexion_generada';
  pay := b.status in ('aceptada_pendiente_pago', 'comprobante_enviado', 'pago_en_revision');
  arrival := b.check_in::timestamp;
  return jsonb_build_object('found', true, 'code', b.code, 'status', b.status, 'title', prop.title, 'location', prop.location, 'photo', prop.photo,
    'guest_name', b.guest_name, 'guests', b.guests, 'check_in', b.check_in, 'check_out', b.check_out, 'nights', b.nights, 'currency', b.currency,
    'total', b.total, 'fee_amount', b.fee_amount, 'fee_bs', b.fee_bs, 'balance', b.total - b.fee_amount, 'fee_percent', s.fee_percent,
    'respond_by', b.respond_by, 'pay_by', case when b.status = 'aceptada_pendiente_pago' and s.pay_window_hours is not null then b.accepted_at + make_interval(hours => s.pay_window_hours) end, 'proof_sent', b.proof_path is not null, 'review_note', b.review_note,
    'pay_instructions', case when pay then s.pay_instructions end, 'pay_qr_url', case when pay then s.pay_qr_url end,
    'host_name', case when reveal then host_name end, 'host_whatsapp', case when reveal then coalesce(contact, prop.whatsapp) end,
    'free_cancel_until', arrival - make_interval(hours => s.free_cancel_hours),
    'is_late_cancel', ((now() at time zone 'UTC') - interval '4 hours') > arrival - make_interval(hours => s.free_cancel_hours),
    'can_cancel', b.status in ('pendiente_respuesta_anfitrion', 'aceptada_pendiente_pago', 'comprobante_enviado', 'pago_en_revision', 'conexion_generada'),
    'cancelled_by', b.cancelled_by, 'late_cancel', b.late_cancel, 'bastet_refund_bs', b.bastet_refund_bs, 'host_retention', b.host_retention, 'host_refund_due', b.host_refund_due);
end $$;

-- 8) El huésped avisa que subió el comprobante (el archivo ya está en stay-proofs/<código>/…)
create or replace function public.attach_stay_proof(p_code text, p_path text)
returns void language plpgsql security definer set search_path = public as $$
declare b public.stay_bookings; cd text := upper(btrim(coalesce(p_code, '')));
begin
  if p_path is null or char_length(p_path) > 300 or p_path not like cd || '/%' or p_path like '%..%' then raise exception 'Comprobante inválido'; end if;
  select * into b from public.stay_bookings where code = cd for update;
  if not found or b.status not in ('aceptada_pendiente_pago', 'comprobante_enviado', 'pago_en_revision') then raise exception 'Esta reserva no espera un comprobante'; end if;
  update public.stay_bookings set proof_path = p_path, proof_at = now(), status = 'comprobante_enviado', review_note = null where id = b.id;
  perform public.stay_log(b.id, 'guest', 'comprobante_enviado', b.status, 'comprobante_enviado', jsonb_build_object('path', p_path));
end $$;

-- 9) El anfitrión (o un admin) acepta o rechaza dentro del plazo
create or replace function public.host_respond_stay_booking(p_booking uuid, p_accept boolean)
returns void language plpgsql security definer set search_path = public as $$
declare b public.stay_bookings; uid uuid := auth.uid();
begin
  if uid is null or not public.is_active_user() then raise exception 'No autorizado' using errcode = '42501'; end if;
  perform public.stay_expire_pending();
  select * into b from public.stay_bookings where id = p_booking for update;
  if not found or (b.host_id is distinct from uid and not public.is_admin()) then raise exception 'Reserva no encontrada'; end if;
  if b.status = 'expirada' then raise exception 'El plazo para responder terminó y la solicitud expiró'; end if;
  if b.status <> 'pendiente_respuesta_anfitrion' then raise exception 'Esta solicitud ya fue respondida'; end if;
  if p_accept then
    if exists (select 1 from public.stay_blocks x where x.property_id = b.property_id and x.from_date < b.check_out and (x.to_date is null or x.to_date >= b.check_in))
       or exists (select 1 from public.stay_bookings k where k.id <> b.id and k.property_id = b.property_id and k.check_in < b.check_out and k.check_out > b.check_in
                    and k.status in ('aceptada_pendiente_pago', 'comprobante_enviado', 'pago_en_revision', 'pago_verificado', 'conexion_generada', 'en_disputa')) then
      raise exception 'Esas fechas ya no están libres'; end if;
    update public.stay_bookings set status = 'aceptada_pendiente_pago', accepted_at = now() where id = b.id;
    perform public.stay_log(b.id, case when b.host_id = uid then 'host' else 'admin' end, 'aceptada', b.status, 'aceptada_pendiente_pago');
  else
    update public.stay_bookings set status = 'rechazada' where id = b.id;
    perform public.stay_log(b.id, case when b.host_id = uid then 'host' else 'admin' end, 'rechazada', b.status, 'rechazada');
  end if;
end $$;

-- 10) Un administrador verifica o rechaza el comprobante. Al verificar se genera la conexión y se revela el contacto.
create or replace function public.admin_review_stay_proof(p_booking uuid, p_approve boolean, p_note text default null)
returns void language plpgsql security definer set search_path = public as $$
declare b public.stay_bookings; nt text := nullif(btrim(coalesce(p_note, '')), '');
begin
  if not public.is_admin() then raise exception 'Solo administradores' using errcode = '42501'; end if;
  select * into b from public.stay_bookings where id = p_booking for update;
  if not found or b.status not in ('comprobante_enviado', 'pago_en_revision') then raise exception 'No hay un comprobante por revisar en esta reserva'; end if;
  if p_approve then
    update public.stay_bookings set status = 'conexion_generada', verified_at = now(), verified_by = auth.uid(), review_note = nt where id = b.id;
    perform public.stay_log(b.id, 'admin', 'pago_verificado_y_conexion', b.status, 'conexion_generada', jsonb_build_object('fee_bs', b.fee_bs, 'note', nt));
  else
    if nt is null then raise exception 'Escribe el motivo del rechazo para que el huésped pueda corregirlo'; end if;
    update public.stay_bookings set status = 'aceptada_pendiente_pago', proof_path = null, proof_at = null, review_note = nt where id = b.id;
    perform public.stay_log(b.id, 'admin', 'comprobante_rechazado', b.status, 'aceptada_pendiente_pago', jsonb_build_object('note', nt, 'path', b.proof_path));
  end if;
end $$;

-- 11) Cancelación por el huésped (con su código). Gratis hasta 72 h antes del día de llegada; después se retiene el 20 % (10 % Bastet + 10 % anfitrión).
create or replace function public.cancel_stay_booking(p_code text, p_reason text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare b public.stay_bookings; s public.stay_settings; arrival timestamp; late boolean := false; paid boolean; refund numeric := 0; hostret numeric := null; due numeric := null;
        rs text := nullif(btrim(coalesce(p_reason, '')), '');
begin
  perform public.stay_expire_pending();
  select * into b from public.stay_bookings where code = upper(btrim(coalesce(p_code, ''))) for update;
  if not found or b.status not in ('pendiente_respuesta_anfitrion', 'aceptada_pendiente_pago', 'comprobante_enviado', 'pago_en_revision', 'conexion_generada') then
    raise exception 'Esta reserva no se puede cancelar'; end if;
  select * into s from public.stay_settings where id = 1;
  paid := b.status = 'conexion_generada';
  if paid then
    arrival := b.check_in::timestamp;
    late := ((now() at time zone 'UTC') - interval '4 hours') > arrival - make_interval(hours => s.free_cancel_hours);
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

-- 12) Cancelación por el anfitrión: Bastet devuelve el 100 % de lo que recibió; el anfitrión devuelve DIRECTO el 90 % si lo recibió
create or replace function public.host_cancel_stay_booking(p_booking uuid, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
declare b public.stay_bookings; uid uuid := auth.uid(); rs text := nullif(btrim(coalesce(p_reason, '')), '');
begin
  if uid is null or not public.is_active_user() then raise exception 'No autorizado' using errcode = '42501'; end if;
  if rs is null then raise exception 'Escribe el motivo de la cancelación'; end if;
  select * into b from public.stay_bookings where id = p_booking for update;
  if not found or (b.host_id is distinct from uid and not public.is_admin()) then raise exception 'Reserva no encontrada'; end if;
  if b.status not in ('aceptada_pendiente_pago', 'comprobante_enviado', 'pago_en_revision', 'conexion_generada') then raise exception 'Esta reserva no se puede cancelar'; end if;
  update public.stay_bookings set status = 'cancelada', cancelled_by = case when b.host_id = uid then 'host' else 'admin' end, cancelled_at = now(), cancel_reason = rs, late_cancel = false,
         bastet_refund_bs = case when b.status = 'aceptada_pendiente_pago' then 0 else b.fee_bs end, host_retention = null,
         host_refund_due = case when b.status = 'conexion_generada' then b.total - b.fee_amount else null end where id = b.id;
  perform public.stay_log(b.id, case when b.host_id = uid then 'host' else 'admin' end, 'cancelada_por_anfitrion', b.status, 'cancelada', jsonb_build_object('reason', rs));
end $$;

-- 13) El anfitrión declara si recibió el 90 % directo (obligatorio en cancelaciones tardías); adjunta comprobante cuando exista
create or replace function public.host_declare_direct_payment(p_booking uuid, p_status text, p_amount numeric default null, p_date date default null,
                                                              p_method text default null, p_proof_path text default null)
returns void language plpgsql security definer set search_path = public as $$
declare b public.stay_bookings; uid uuid := auth.uid(); pp text := nullif(btrim(coalesce(p_proof_path, '')), '');
begin
  if uid is null or not public.is_active_user() then raise exception 'No autorizado' using errcode = '42501'; end if;
  if p_status not in ('no_recibido', 'recibido_con_comprobante', 'declarado_sin_comprobante') then raise exception 'Estado inválido'; end if;
  select * into b from public.stay_bookings where id = p_booking for update;
  if not found or b.host_id is distinct from uid then raise exception 'Reserva no encontrada'; end if;
  if b.status not in ('conexion_generada', 'cancelada', 'en_disputa') or (b.status = 'cancelada' and b.verified_at is null) then
    raise exception 'Todavía no hay un pago directo que declarar en esta reserva'; end if;
  if p_status <> 'no_recibido' and (p_amount is null or p_amount <= 0 or p_date is null) then raise exception 'Indica el importe y la fecha en que lo recibiste'; end if;
  if p_status = 'recibido_con_comprobante' and pp is null then raise exception 'Adjunta el comprobante o elige «Lo recibí, sin comprobante»'; end if;
  if pp is not null and (char_length(pp) > 300 or pp not like 'host/' || b.id::text || '/%' or pp like '%..%') then raise exception 'Comprobante inválido'; end if;
  update public.stay_bookings set direct_status = p_status, direct_amount = case when p_status = 'no_recibido' then null else p_amount end,
         direct_date = case when p_status = 'no_recibido' then null else p_date end, direct_method = nullif(btrim(coalesce(p_method, '')), ''),
         direct_proof_path = pp, direct_declared_at = now(), direct_review = 'pendiente' where id = b.id;
  perform public.stay_log(b.id, 'host', 'declaro_pago_directo', b.status, b.status, jsonb_build_object('status', p_status, 'amount', p_amount, 'date', p_date, 'proof', pp));
end $$;

-- 14) Administración: revisar lo declarado del 90 % y abrir/cerrar disputas
create or replace function public.admin_review_direct_payment(p_booking uuid, p_review text, p_note text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Solo administradores' using errcode = '42501'; end if;
  if p_review not in ('pendiente', 'revisado', 'controvertido') then raise exception 'Estado inválido'; end if;
  update public.stay_bookings set direct_review = p_review, direct_review_note = nullif(btrim(coalesce(p_note, '')), '') where id = p_booking;
  if not found then raise exception 'Reserva no encontrada'; end if;
  perform public.stay_log(p_booking, 'admin', 'revision_pago_directo', null, null, jsonb_build_object('review', p_review, 'note', p_note));
end $$;

create or replace function public.admin_set_stay_dispute(p_booking uuid, p_open boolean, p_note text default null)
returns void language plpgsql security definer set search_path = public as $$
declare b public.stay_bookings;
begin
  if not public.is_admin() then raise exception 'Solo administradores' using errcode = '42501'; end if;
  select * into b from public.stay_bookings where id = p_booking for update;
  if not found then raise exception 'Reserva no encontrada'; end if;
  if p_open then
    if b.status not in ('conexion_generada', 'cancelada') then raise exception 'Solo se abre una disputa en reservas con conexión o canceladas'; end if;
    update public.stay_bookings set status = 'en_disputa' where id = b.id;
    perform public.stay_log(b.id, 'admin', 'disputa_abierta', b.status, 'en_disputa', jsonb_build_object('note', p_note));
  else
    if b.status <> 'en_disputa' then raise exception 'La reserva no está en disputa'; end if;
    update public.stay_bookings set status = case when b.cancelled_at is not null then 'cancelada' else 'conexion_generada' end where id = b.id;
    perform public.stay_log(b.id, 'admin', 'disputa_cerrada', 'en_disputa', null, jsonb_build_object('note', p_note));
  end if;
end $$;

-- 15) Listas del panel. El anfitrión ve los datos de contacto del huésped solo cuando hay conexión; el administrador ve todo.
create or replace function public.my_stay_bookings()
returns jsonb language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); adm boolean;
begin
  if uid is null or not public.is_active_user() then raise exception 'No autorizado' using errcode = '42501'; end if;
  perform public.stay_expire_pending();
  adm := public.is_admin();
  return coalesce((select jsonb_agg(jsonb_build_object(
      'id', b.id, 'code', b.code, 'status', b.status, 'property_id', b.property_id, 'title', p.title, 'guest_name', b.guest_name, 'guests', b.guests,
      'check_in', b.check_in, 'check_out', b.check_out, 'nights', b.nights, 'currency', b.currency, 'total', b.total, 'fee_amount', b.fee_amount,
      'fee_bs', b.fee_bs, 'balance', b.total - b.fee_amount, 'respond_by', b.respond_by, 'created_at', b.created_at,
      'guest_phone', case when adm or b.status in ('conexion_generada', 'en_disputa') or b.verified_at is not null then b.guest_phone end,
      'guest_email', case when adm or b.status in ('conexion_generada', 'en_disputa') or b.verified_at is not null then b.guest_email end,
      'host_id', b.host_id, 'host_name', case when adm then (select display_name from public.profiles where id = b.host_id) end,
      'host_whatsapp', case when adm then coalesce((select contact_whatsapp from public.profiles where id = b.host_id), p.whatsapp) end,
      'accepted_at', b.accepted_at, 'pay_by', case when b.status = 'aceptada_pendiente_pago' and s.pay_window_hours is not null then b.accepted_at + make_interval(hours => s.pay_window_hours) end,
      'proof_path', case when adm then b.proof_path end, 'proof_at', b.proof_at, 'verified_at', b.verified_at, 'review_note', b.review_note,
      'cancelled_by', b.cancelled_by, 'cancel_reason', b.cancel_reason, 'late_cancel', b.late_cancel, 'bastet_refund_bs', b.bastet_refund_bs,
      'host_retention', b.host_retention, 'host_refund_due', b.host_refund_due, 'direct_status', b.direct_status, 'direct_amount', b.direct_amount,
      'direct_date', b.direct_date, 'direct_method', b.direct_method, 'direct_proof_path', b.direct_proof_path, 'direct_review', b.direct_review,
      'direct_review_note', b.direct_review_note, 'needs_direct_declaration', b.verified_at is not null and b.direct_status is null and b.status in ('cancelada', 'conexion_generada', 'en_disputa'))
      order by b.created_at desc)
    from public.stay_bookings b join public.properties p on p.id = b.property_id cross join public.stay_settings s
    where (adm or b.host_id = uid) and b.created_at > now() - interval '18 months'), '[]'::jsonb);
end $$;

create or replace function public.stay_booking_events(p_booking uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Solo administradores' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('actor', e.actor, 'event', e.event, 'from', e.from_status, 'to', e.to_status, 'data', e.data, 'at', e.created_at) order by e.created_at, e.id)
                    from public.stay_booking_events e where e.booking_id = p_booking), '[]'::jsonb);
end $$;

-- 16) Reglas editables por administración
create or replace function public.get_stay_settings()
returns jsonb language plpgsql security definer set search_path = public stable as $$
begin
  if not public.is_admin() then raise exception 'Solo administradores' using errcode = '42501'; end if;
  return (select to_jsonb(s) from public.stay_settings s where id = 1);
end $$;

drop function if exists public.admin_update_stay_settings(boolean, numeric, text, text, integer);
create or replace function public.admin_update_stay_settings(p_enabled boolean, p_bob_per_usd numeric, p_pay_instructions text, p_pay_qr_url text, p_pay_window_hours integer default 12)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Solo administradores' using errcode = '42501'; end if;
  if p_bob_per_usd is null or p_bob_per_usd <= 0 then raise exception 'El tipo de cambio debe ser mayor que cero'; end if;
  if p_pay_window_hours is not null and p_pay_window_hours not between 1 and 720 then raise exception 'El plazo de pago debe ser de 1 a 720 horas (déjalo vacío para no poner plazo)'; end if;
  if p_enabled and char_length(btrim(coalesce(p_pay_instructions, ''))) < 10 then raise exception 'Antes de activar, escribe las instrucciones de pago (cuenta o QR)'; end if;
  update public.stay_settings set enabled = coalesce(p_enabled, false), bob_per_usd = p_bob_per_usd, pay_instructions = btrim(coalesce(p_pay_instructions, '')),
         pay_qr_url = nullif(btrim(coalesce(p_pay_qr_url, '')), ''), pay_window_hours = p_pay_window_hours, updated_at = now() where id = 1;
end $$;

revoke all on function public.create_stay_booking(uuid, date, date, integer, text, text, text), public.get_stay_booking(text), public.attach_stay_proof(text, text),
  public.cancel_stay_booking(text, text), public.host_respond_stay_booking(uuid, boolean), public.admin_review_stay_proof(uuid, boolean, text),
  public.host_cancel_stay_booking(uuid, text), public.host_declare_direct_payment(uuid, text, numeric, date, text, text), public.admin_review_direct_payment(uuid, text, text),
  public.admin_set_stay_dispute(uuid, boolean, text), public.my_stay_bookings(), public.stay_booking_events(uuid), public.get_stay_settings(),
  public.admin_update_stay_settings(boolean, numeric, text, text, integer) from public, anon;
grant execute on function public.create_stay_booking(uuid, date, date, integer, text, text, text), public.get_stay_booking(text), public.attach_stay_proof(text, text),
  public.cancel_stay_booking(text, text) to anon, authenticated;
grant execute on function public.host_respond_stay_booking(uuid, boolean), public.admin_review_stay_proof(uuid, boolean, text), public.host_cancel_stay_booking(uuid, text),
  public.host_declare_direct_payment(uuid, text, numeric, date, text, text), public.admin_review_direct_payment(uuid, text, text), public.admin_set_stay_dispute(uuid, boolean, text),
  public.my_stay_bookings(), public.stay_booking_events(uuid), public.get_stay_settings(), public.admin_update_stay_settings(boolean, numeric, text, text, integer) to authenticated;

notify pgrst, 'reload schema';
