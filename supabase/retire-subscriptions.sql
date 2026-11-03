-- =====================================================================
-- Bastet · Retiro del modelo de suscripción (planes Propietario/Agente/Empresa, prueba gratuita, límites y vencimientos)   — fase 2, paso A
-- Idempotente: se puede correr completo más de una vez. Correr DESPUÉS de todo lo demás (subscriptions, registration, owner-services, stay-bookings).
--
-- Decisiones de la dueña (2026-11-03): publicar es libre y sin tope ni vencimiento; solo administración destaca propiedades; el contrato de
-- exclusividad lo genera cualquier cuenta de agente o empresa; los servicios de propietario se mantienen por tipo de cuenta (profiles.interest).
-- El ingreso pasa a ser por conexiones y comisiones (docs/ESPECIFICACION_MAESTRA.md, sección 1).
--
-- NO borra datos: las tablas subscriptions, subscription_plans, subscription_requests, subscription_events, featured_activations y trial_claims
-- se conservan como historial (se pueden eliminar más adelante). Sí borra las funciones de planes y deja las propiedades sin vencimiento.
-- =====================================================================

do $$
begin
  if to_regclass('public.subscriptions') is null or to_regprocedure('public.create_owner_offer(uuid, uuid, jsonb)') is null then
    raise exception 'Primero corre schema.sql completo (subscriptions, registration y owner-services)';
  end if;
end $$;

-- 1) Publicar: libre, sin tope y sin vencimiento
create or replace function public.charge_property_publication()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  new.expires_at := null;
  return new;
end $$;

drop trigger if exists plan_limit_on_reactivate on public.properties;
drop function if exists public.enforce_plan_on_reactivate();
drop function if exists public.renew_property(uuid);

do $$
begin
  perform set_config('uno.renew_rpc', '1', true);
  update public.properties set expires_at = null where expires_at is not null;
end $$;

-- 2) Destacar: solo administración (sin cupos ni ciclos)
create or replace function public.feature_property(p_property_id text, p_service text)   -- p_service ya no se usa (firma conservada)
returns jsonb language plpgsql security definer set search_path = public as $$
declare prop record; new_until timestamptz; dur integer := public._setting('featured_duration_days', 30);
begin
  if auth.uid() is null or not public.is_admin() then raise exception 'Solo administración puede destacar propiedades' using errcode = '42501'; end if;
  select p.id, p.status, p.featured_until into prop from public.properties p where p.id::text = p_property_id for update;
  if not found then raise exception 'Propiedad no encontrada'; end if;
  if prop.status <> 'available' then raise exception 'Solo se pueden destacar propiedades disponibles'; end if;
  if prop.featured_until is not null and prop.featured_until > now() then
    raise exception 'Esta propiedad ya está destacada hasta el %', to_char(prop.featured_until - interval '4 hours', 'DD/MM/YYYY') using errcode = 'P0409', hint = 'already_featured';
  end if;
  new_until := now() + make_interval(days => dur);
  perform set_config('uno.credit_rpc', '1', true);
  update public.properties set featured_until = new_until where id = prop.id;
  return jsonb_build_object('featured_until', new_until);
end $$;

-- 3) Estado de la cuenta para el panel (reemplaza a my_subscription): tipo de cuenta, registro y propiedades activas
create or replace function public.my_account()
returns jsonb language plpgsql security definer set search_path = public stable as $$
declare uid uuid := auth.uid(); p record; adm boolean; it text;
begin
  if uid is null or not public.is_active_user() then raise exception 'No autorizado' using errcode = '42501'; end if;
  adm := public.is_admin();
  select registered_at, interest into p from public.profiles where id = uid;
  it := case when adm then 'admin' else coalesce(p.interest, 'agente') end;
  return jsonb_build_object('exempt', adm, 'registered', adm or p.registered_at is not null, 'interest', p.interest,
    'account', jsonb_build_object('type', it, 'agent_tools', adm or it <> 'propietario',
      'name', case it when 'propietario' then 'Propietario' when 'empresa' then 'Empresa' when 'admin' then 'Administrador' else 'Agente' end),
    'active_properties', public._count_active_properties(uid));
end $$;

-- 4) Registro sin prueba gratuita (misma firma; p_start_trial se ignora)
create or replace function public.complete_registration(p_full_name text, p_whatsapp text, p_city text, p_company text, p_interest text, p_consent boolean, p_start_trial boolean default false, p_adult boolean default false)
returns jsonb language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); nm text := btrim(coalesce(p_full_name, '')); wa text := btrim(coalesce(p_whatsapp, ''));
begin
  if uid is null or not public.is_active_user() then raise exception 'No autorizado' using errcode = '42501'; end if;
  if public.is_admin() then raise exception 'Los administradores no necesitan registro'; end if;
  if char_length(nm) not between 3 and 120 then raise exception 'Escribe tu nombre completo'; end if;
  if wa !~ '^\+?[0-9 ()-]{7,30}$' then raise exception 'Escribe un WhatsApp válido (solo números, con código de país si es de otro país)'; end if;
  if char_length(btrim(coalesce(p_city, ''))) > 80 or char_length(btrim(coalesce(p_company, ''))) > 120 then raise exception 'Ciudad o empresa demasiado largas'; end if;
  if p_interest is null or p_interest not in ('propietario', 'agente', 'empresa') then raise exception 'Elige cómo usarás Bastet: propietario, agente o empresa'; end if;
  if p_adult is not true then raise exception 'Debes confirmar que tienes 18 años o más para crear una cuenta'; end if;
  if p_consent is not true then raise exception 'Debes aceptar el uso de tus datos para continuar'; end if;

  perform set_config('uno.reg_rpc', '1', true);
  update public.profiles
     set full_name = nm, whatsapp = wa, city = nullif(btrim(coalesce(p_city, '')), ''), company = nullif(btrim(coalesce(p_company, '')), ''),
         interest = p_interest, registered_at = coalesce(registered_at, now()), age_confirmed_at = coalesce(age_confirmed_at, now()),
         display_name = coalesce(nullif(btrim(coalesce(display_name, '')), ''), nm)
   where id = uid;
  return public.my_account();
end $$;

-- 5) Contrato de exclusividad por tipo de cuenta
create or replace function public.create_exclusivity_contract(p_data jsonb, p_idempotency_key text, p_template_version text default 'exclusividad-v1')
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  uid     uuid := auth.uid();
  key     text := btrim(coalesce(p_idempotency_key, ''));
  yr      integer;
  seq     integer;
  num     text;
  code    text;
  cid     uuid := gen_random_uuid();
  c       public.exclusivity_contracts;
  alphabet constant text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
begin
  if uid is null or not public.is_active_user() then
    raise exception 'No autorizado' using errcode = '42501';
  end if;
  if char_length(key) < 8 or char_length(key) > 80 then raise exception 'Llave de idempotencia inválida' using errcode = '22023'; end if;
  if p_template_version is null or p_template_version not in ('exclusividad-v1', 'exclusividad-v2') then raise exception 'Plantilla no disponible' using errcode = '22023'; end if;

  -- Dos peticiones simultáneas con la misma llave se ejecutan una detrás de otra
  perform pg_advisory_xact_lock(hashtext(uid::text || ':' || key));

  select * into c from public.exclusivity_contracts where agent_id = uid and idempotency_key = key;
  if found then
    return jsonb_build_object('id', c.id, 'contract_number', c.contract_number, 'verification_code', c.verification_code,
                              'created_at', c.created_at, 'charged', false);
  end if;

  -- El contrato de exclusividad es una herramienta de cuentas de agente o de empresa; el administrador está exento
  if not public.is_admin() and coalesce((select interest from public.profiles where id = uid), 'agente') = 'propietario' then
    raise exception 'El contrato de exclusividad es para cuentas de agente o de empresa' using errcode = 'P0403', hint = 'account_tools';
  end if;

  perform public.validate_exclusivity_data(p_data);

  yr := extract(year from ((now() at time zone 'UTC') - interval '4 hours'))::integer; -- hora de Bolivia (UTC-4, sin horario de verano)
  insert into public.exclusivity_contract_counters (year, last_number) values (yr, 1)
  on conflict (year) do update set last_number = public.exclusivity_contract_counters.last_number + 1
  returning last_number into seq;
  num := 'BST-CE-' || yr || '-' || lpad(seq::text, 4, '0');

  loop
    select string_agg(substr(alphabet, 1 + floor(random() * 32)::integer, 1), '') into code from generate_series(1, 8);
    exit when not exists (select 1 from public.exclusivity_contracts where verification_code = code);
  end loop;

  insert into public.exclusivity_contracts (id, agent_id, contract_number, verification_code, template_version, data, credits_charged, idempotency_key)
  values (cid, uid, num, code, p_template_version, p_data, 0, key)
  returning * into c;

  return jsonb_build_object('id', c.id, 'contract_number', c.contract_number, 'verification_code', c.verification_code,
                            'created_at', c.created_at, 'charged', false);
end $$;

-- 6) Servicios del propietario y ofertas, por tipo de cuenta
create or replace function public.list_agent_directory()
returns table (id uuid, display_name text, avatar_url text, facebook_url text, instagram_url text, tiktok_url text, plan_name text, active_properties integer)
language plpgsql security definer set search_path = public stable as $$
begin
  if auth.uid() is null or not public.is_active_user() then raise exception 'No autorizado' using errcode = '42501'; end if;
  return query
    select p.id, coalesce(nullif(btrim(p.display_name), ''), 'Agente de Bastet'), p.avatar_url, p.facebook_url, p.instagram_url, p.tiktok_url,
           case p.interest when 'empresa' then 'Empresa' else 'Agente' end, public._count_active_properties(p.id)
      from public.profiles p
     where p.is_active and p.role = 'agent' and p.registered_at is not null and coalesce(p.interest, 'agente') in ('agente', 'empresa') and p.id <> auth.uid()
     order by coalesce(nullif(btrim(p.display_name), ''), 'zzz'), p.id;
end $$;

create or replace function public.create_legal_request(p_service text, p_property uuid, p_description text)
returns bigint language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); svc public.legal_service_types; prop record; rid bigint; ptitle text;
begin
  if uid is null or not public.is_active_user() then raise exception 'No autorizado' using errcode = '42501'; end if;
  if coalesce((select interest from public.profiles where id = uid), 'agente') <> 'propietario' then
    raise exception 'Este servicio es para cuentas de propietario.' using errcode = 'P0403', hint = 'plan_owner';
  end if;
  select * into svc from public.legal_service_types where code = p_service and active;
  if not found then raise exception 'Servicio no disponible'; end if;
  if char_length(btrim(coalesce(p_description, ''))) < 10 or char_length(p_description) > 2000 then
    raise exception 'Describe lo que necesitas (entre 10 y 2000 caracteres)'; end if;
  if p_property is not null then
    select id, title into prop from public.properties where id = p_property and owner_id = uid;
    if not found then raise exception 'Propiedad no encontrada'; end if;
    ptitle := prop.title;
  end if;
  if (select count(*) from public.legal_requests where user_id = uid and status in ('pending', 'in_review', 'in_progress')) >= 10 then
    raise exception 'Tienes demasiadas solicitudes abiertas. Espera a que se atiendan algunas.'; end if;
  insert into public.legal_requests (user_id, service_code, property_id, property_title, description)
  values (uid, svc.code, p_property, ptitle, btrim(p_description)) returning id into rid;
  return rid;
end $$;

create or replace function public.create_owner_offer(p_property uuid, p_agent uuid, p_terms jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid();
  prop record;
  ag record;
  t jsonb := coalesce(p_terms, '{}'::jsonb);
  n numeric;
  yr integer; seq integer; num text; oid uuid := gen_random_uuid();
  me record;
begin
  if uid is null or not public.is_active_user() then raise exception 'No autorizado' using errcode = '42501'; end if;
  perform pg_advisory_xact_lock(hashtext('offer:' || uid::text));
  if coalesce((select interest from public.profiles where id = uid), 'agente') <> 'propietario' then
    raise exception 'Ofrecer tu propiedad a un agente es una función de las cuentas de propietario' using errcode = 'P0403', hint = 'plan_owner';
  end if;

  select id, title, location, address, price, currency, area, rooms, baths, property_type, operation, code_number, description, status, expires_at, owner_whatsapp
    into prop from public.properties where id = p_property and owner_id = uid;
  if not found then raise exception 'Propiedad no encontrada'; end if;
  if prop.status <> 'available' or (prop.expires_at is not null and prop.expires_at <= now()) then raise exception 'Solo puedes ofrecer propiedades activas'; end if;

  select p.id, p.display_name into ag from public.profiles p where p.id = p_agent and p.is_active and p.role = 'agent';
  if not found or p_agent = uid then raise exception 'Agente no disponible'; end if;
  if coalesce((select interest from public.profiles where id = p_agent), 'agente') = 'propietario' then raise exception 'Agente no disponible'; end if;

  begin n := (t ->> 'comision_porcentaje')::numeric; exception when others then n := null; end;
  if n is null or n < 0.5 or n > 15 then raise exception 'La comisión debe estar entre 0,5 %% y 15 %%'; end if;
  begin n := (t ->> 'plazo_dias')::numeric; exception when others then n := null; end;
  if n is null or n <> trunc(n) or n < 15 or n > 365 then raise exception 'El plazo debe ser de 15 a 365 días'; end if;
  if jsonb_typeof(t -> 'exclusividad') is distinct from 'boolean' then raise exception 'Indica si la oferta es con exclusividad'; end if;
  if char_length(btrim(coalesce(t ->> 'owner_nombre', ''))) not between 3 and 120 then raise exception 'Escribe tu nombre completo'; end if;
  if coalesce(t ->> 'owner_ci', '') !~ '^[0-9]{4,10}([ -]?[0-9A-Za-z]{1,3})?$' then raise exception 'C.I. inválida'; end if;
  if char_length(btrim(coalesce(t ->> 'owner_telefono', ''))) not between 7 and 30 then raise exception 'Escribe un teléfono de contacto'; end if;
  if char_length(coalesce(t ->> 'mensaje', '')) > 500 then raise exception 'El mensaje es demasiado largo (máximo 500 caracteres)'; end if;
  if exists (select 1 from public.owner_offers where property_id = p_property and agent_id = p_agent and status = 'pending') then
    raise exception 'Ya tienes una oferta pendiente de esta propiedad para ese agente'; end if;
  if (select count(*) from public.owner_offers where owner_id = uid and status = 'pending') >= 10 then
    raise exception 'Tienes demasiadas ofertas pendientes. Espera respuestas o cancela alguna.'; end if;

  select email, display_name into me from public.profiles where id = uid;
  yr := extract(year from ((now() at time zone 'UTC') - interval '4 hours'))::integer;     -- año de Bolivia (UTC-4)
  insert into public.owner_offer_counters (year, last_number) values (yr, 1)
  on conflict (year) do update set last_number = public.owner_offer_counters.last_number + 1 returning last_number into seq;
  num := 'BST-CO-' || yr || '-' || lpad(seq::text, 4, '0');

  insert into public.owner_offers (id, doc_number, owner_id, agent_id, property_id, property_data, owner_data, agent_data, terms)
  values (oid, num, uid, p_agent, p_property,
    jsonb_build_object('title', prop.title, 'location', prop.location, 'address', prop.address, 'price', prop.price, 'currency', coalesce(prop.currency, 'USD'),
      'area', prop.area, 'rooms', prop.rooms, 'baths', prop.baths, 'property_type', prop.property_type, 'operation', prop.operation,
      'code_number', prop.code_number, 'description', left(coalesce(prop.description, ''), 1000)),
    jsonb_build_object('nombre', btrim(t ->> 'owner_nombre'), 'ci', btrim(t ->> 'owner_ci'), 'telefono', btrim(t ->> 'owner_telefono'), 'email', me.email),
    jsonb_build_object('nombre', coalesce(nullif(btrim(ag.display_name), ''), 'Agente de Bastet')),
    jsonb_build_object('comision_porcentaje', (t ->> 'comision_porcentaje')::numeric, 'plazo_dias', (t ->> 'plazo_dias')::integer,
      'exclusividad', (t -> 'exclusividad')::boolean, 'mensaje', nullif(btrim(coalesce(t ->> 'mensaje', '')), '')));
  insert into public.owner_offer_events (offer_id, kind, actor) values (oid, 'created', uid);
  return jsonb_build_object('id', oid, 'doc_number', num);
end $$;

create or replace function public.respond_owner_offer(p_id uuid, p_accept boolean, p_note text default null)
returns void language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); o public.owner_offers;
begin
  if uid is null or not public.is_active_user() then raise exception 'No autorizado' using errcode = '42501'; end if;
  select * into o from public.owner_offers where id = p_id and agent_id = uid for update;
  if not found then raise exception 'Oferta no encontrada'; end if;
  if o.status <> 'pending' then raise exception 'La oferta ya fue respondida o cancelada'; end if;
  if p_accept and not public.is_admin() and coalesce((select interest from public.profiles where id = uid), 'agente') = 'propietario' then
    raise exception 'Solo las cuentas de agente o de empresa aceptan ofertas' using errcode = 'P0403', hint = 'plan_tools';
  end if;
  if char_length(coalesce(p_note, '')) > 500 then raise exception 'La nota es demasiado larga (máximo 500 caracteres)'; end if;
  update public.owner_offers set status = case when p_accept then 'accepted' else 'rejected' end, response_note = nullif(btrim(coalesce(p_note, '')), ''), responded_at = now(),
         agent_data = case when p_accept then agent_data || (select coalesce(jsonb_strip_nulls(jsonb_build_object('ci', nullif(btrim(l.ci), ''), 'registro', nullif(btrim(l.registration), ''), 'telefono', nullif(btrim(l.phone), ''))), '{}'::jsonb) from (select 1) x left join public.agent_legal_profiles l on l.user_id = uid) else agent_data end
   where id = p_id;
  insert into public.owner_offer_events (offer_id, kind, actor, note) values (p_id, case when p_accept then 'accepted' else 'rejected' end, uid, nullif(btrim(coalesce(p_note, '')), ''));
end $$;

-- 7) Se retiran las funciones del modelo de planes y de la prueba gratuita (las tablas quedan como historial)
drop function if exists public.start_free_trial();
drop function if exists public.my_subscription();
drop function if exists public.request_subscription(text, text, text);
drop function if exists public.admin_resolve_subscription_request(bigint, boolean, text);
drop function if exists public.admin_grant_subscription(uuid, text, integer);
drop function if exists public.cancel_subscription();
drop function if exists public.resume_subscription();
drop function if exists public.attach_payment_proof(bigint, text);
drop function if exists public._start_trial(uuid);
drop function if exists public._trial_eligible(uuid);
drop function if exists public._activate_subscription(uuid, text, text, integer, uuid);
drop function if exists public._sync_property_expiry(uuid, timestamptz, integer);
drop function if exists public._featured_cycle_start(timestamptz);

-- 8) Permisos
revoke all on function public.my_account() from public, anon;
grant execute on function public.my_account() to authenticated;
revoke all on function public.feature_property(text, text) from public, anon;
grant execute on function public.feature_property(text, text) to authenticated;
revoke all on function public.complete_registration(text, text, text, text, text, boolean, boolean, boolean) from public, anon;
grant execute on function public.complete_registration(text, text, text, text, text, boolean, boolean, boolean) to authenticated;
revoke all on function public.create_exclusivity_contract(jsonb, text, text) from public, anon;
grant execute on function public.create_exclusivity_contract(jsonb, text, text) to authenticated;
revoke all on function public.list_agent_directory() from public, anon;
grant execute on function public.list_agent_directory() to authenticated;
revoke all on function public.create_legal_request(text, uuid, text), public.create_owner_offer(uuid, uuid, jsonb), public.respond_owner_offer(uuid, boolean, text) from public, anon;
grant execute on function public.create_legal_request(text, uuid, text), public.create_owner_offer(uuid, uuid, jsonb), public.respond_owner_offer(uuid, boolean, text) to authenticated;

notify pgrst, 'reload schema';
