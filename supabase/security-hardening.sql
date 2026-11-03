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
