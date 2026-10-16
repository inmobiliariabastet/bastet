-- =====================================================================
-- UNO · Servicios del plan Propietario   — agregar al final de supabase/schema.sql (después de subscriptions.sql)
-- Idempotente: se puede correr completo más de una vez.
-- Supone: subscriptions.sql ya aplicado (planes, subscriptions, _count_active_properties).
--
-- 1) Directorio de agentes registrados (solo los que tienen un plan Agente/Empresa vigente) para que el propietario elija uno.
-- 2) Ofertas de colaboración: el propietario ofrece una de sus propiedades a un agente con condiciones (comisión, plazo,
--    exclusividad). El agente acepta o rechaza; se genera un documento (borrador sujeto a validación legal).
-- 3) Solicitudes a Maat Fima Legal: asesoramiento, trámites, saneamiento, impuestos, etc. Un administrador las gestiona.
-- Todo lo escribe la base de datos (funciones); el navegador no inserta ni cambia estados directamente.
-- Estas funciones son del plan Propietario: las demás cuentas (Agente/Empresa) no las usan.
-- =====================================================================

-- 1) Servicios legales configurables y solicitudes
create table if not exists public.legal_service_types (
  code       text primary key check (code ~ '^[a-z_]{3,30}$'),
  name       text not null,
  active     boolean not null default true,
  sort_order integer not null default 0
);
insert into public.legal_service_types (code, name, sort_order) values
  ('asesoramiento', 'Asesoramiento inmobiliario personalizado', 1),
  ('compra_venta',  'Apoyo en un proceso de compra y venta', 2),
  ('tramites',      'Trámites inmobiliarios', 3),
  ('saneamiento',   'Saneamiento de documentos', 4),
  ('impuestos',     'Apoyo con impuestos', 5),
  ('otro',          'Otro servicio', 6)
on conflict (code) do nothing;

create table if not exists public.legal_requests (
  id             bigint generated always as identity primary key,
  user_id        uuid not null references auth.users(id) on delete cascade,
  service_code   text not null references public.legal_service_types(code),
  property_id    uuid,                                 -- sin llave foránea: el pedido sobrevive si se borra la propiedad
  property_title text,
  description    text not null check (char_length(btrim(description)) between 10 and 2000),
  status         text not null default 'pending' check (status in ('pending', 'in_review', 'in_progress', 'completed', 'cancelled')),
  admin_note     text check (admin_note is null or char_length(admin_note) <= 1000),
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  resolved_by    uuid
);
create index if not exists legal_requests_user_idx on public.legal_requests (user_id, created_at desc);
create index if not exists legal_requests_status_idx on public.legal_requests (status, created_at desc);

-- 2) Ofertas de colaboración propietario → agente
create table if not exists public.owner_offer_counters (year integer primary key, last_number integer not null);
create table if not exists public.owner_offers (
  id            uuid primary key default gen_random_uuid(),
  doc_number    text not null unique,
  owner_id      uuid not null references auth.users(id) on delete cascade,
  agent_id      uuid not null references auth.users(id) on delete cascade,
  property_id   uuid not null,                         -- sin llave foránea: la oferta conserva su copia de los datos
  property_data jsonb not null,                        -- copia de la propiedad al ofrecerla (el documento sale siempre de aquí)
  owner_data    jsonb not null,
  agent_data    jsonb not null default '{}',                      -- nombre del agente al ofrecer; al aceptar se suman su C.I. y registro (si los tiene)
  terms         jsonb not null,
  status        text not null default 'pending' check (status in ('pending', 'accepted', 'rejected', 'canceled')),
  response_note text check (response_note is null or char_length(response_note) <= 500),
  responded_at  timestamptz,
  created_at    timestamptz not null default now(),
  check (owner_id <> agent_id)
);
create unique index if not exists owner_offers_one_pending_idx on public.owner_offers (property_id, agent_id) where status = 'pending';
alter table public.owner_offers add column if not exists agent_data jsonb not null default '{}';
create index if not exists owner_offers_owner_idx on public.owner_offers (owner_id, created_at desc);
create index if not exists owner_offers_agent_idx on public.owner_offers (agent_id, created_at desc);

create table if not exists public.owner_offer_events (
  id         bigint generated always as identity primary key,
  offer_id   uuid not null references public.owner_offers(id) on delete cascade,
  kind       text not null,
  actor      uuid,
  note       text,
  created_at timestamptz not null default now()
);
create index if not exists owner_offer_events_offer_idx on public.owner_offer_events (offer_id, created_at);

-- 3) RLS: cada parte ve lo suyo (el admin todo); sin escritura directa
alter table public.legal_service_types enable row level security;
alter table public.legal_requests      enable row level security;
alter table public.owner_offer_counters enable row level security;
alter table public.owner_offers        enable row level security;
alter table public.owner_offer_events  enable row level security;

drop policy if exists legal_service_types_read  on public.legal_service_types;
drop policy if exists legal_service_types_admin on public.legal_service_types;
drop policy if exists legal_requests_read       on public.legal_requests;
drop policy if exists owner_offers_read         on public.owner_offers;
drop policy if exists owner_offer_events_read   on public.owner_offer_events;
create policy legal_service_types_read  on public.legal_service_types for select to authenticated using (public.is_active_user());
create policy legal_service_types_admin on public.legal_service_types for all    to authenticated using (public.is_admin()) with check (public.is_admin());
create policy legal_requests_read on public.legal_requests for select to authenticated using (user_id = auth.uid() or public.is_admin());
create policy owner_offers_read   on public.owner_offers   for select to authenticated using (owner_id = auth.uid() or agent_id = auth.uid() or public.is_admin());
create policy owner_offer_events_read on public.owner_offer_events for select to authenticated
  using (exists (select 1 from public.owner_offers o where o.id = offer_id and (o.owner_id = auth.uid() or o.agent_id = auth.uid() or public.is_admin())));

revoke all on public.legal_service_types, public.legal_requests, public.owner_offer_counters, public.owner_offers, public.owner_offer_events from anon;
revoke insert, update, delete on public.legal_requests, public.owner_offer_counters, public.owner_offers, public.owner_offer_events from authenticated;
revoke all on public.owner_offer_counters from authenticated;
grant select on public.legal_requests, public.owner_offers, public.owner_offer_events to authenticated;
grant select, insert, update, delete on public.legal_service_types to authenticated;   -- las políticas limitan la edición al admin

-- 4) Directorio de agentes: solo con plan Agente/Empresa vigente y datos públicos (nunca correo, teléfono ni rol)
create or replace function public.list_agent_directory()
returns table (id uuid, display_name text, avatar_url text, facebook_url text, instagram_url text, tiktok_url text, plan_name text, active_properties integer)
language plpgsql security definer set search_path = public stable as $$
begin
  if auth.uid() is null or not public.is_active_user() then raise exception 'No autorizado' using errcode = '42501'; end if;
  return query
    select p.id, coalesce(nullif(btrim(p.display_name), ''), 'Agente de Bastet'), p.avatar_url, p.facebook_url, p.instagram_url, p.tiktok_url,
           pl.name, public._count_active_properties(p.id)
      from public.profiles p
      join public.subscriptions s on s.user_id = p.id and s.current_period_end > now()
      join public.subscription_plans pl on pl.code = s.plan_code and pl.agent_tools
     where p.is_active and p.role = 'agent' and p.id <> auth.uid()
     order by coalesce(nullif(btrim(p.display_name), ''), 'zzz'), p.id;
end $$;

-- 5) Solicitudes a Maat Fima Legal
create or replace function public.create_legal_request(p_service text, p_property uuid, p_description text)
returns bigint language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); sub public.subscriptions; svc public.legal_service_types; prop record; rid bigint; ptitle text;
begin
  if uid is null or not public.is_active_user() then raise exception 'No autorizado' using errcode = '42501'; end if;
  select * into sub from public.subscriptions where user_id = uid and current_period_end > now();
  if not found or sub.plan_code <> 'propietario' then
    raise exception 'Este servicio es del plan Propietario. Suscríbete para solicitarlo.' using errcode = 'P0403', hint = 'plan_owner';
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

create or replace function public.cancel_legal_request(p_id bigint)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null or not public.is_active_user() then raise exception 'No autorizado' using errcode = '42501'; end if;
  update public.legal_requests set status = 'cancelled', updated_at = now() where id = p_id and user_id = auth.uid() and status = 'pending';
  if not found then raise exception 'Solicitud no encontrada o ya en gestión'; end if;
end $$;

-- El admin gestiona el avance. Los estados finales (completada / cancelada) no se reabren.
create or replace function public.admin_update_legal_request(p_id bigint, p_status text, p_note text default null)
returns void language plpgsql security definer set search_path = public as $$
declare cur public.legal_requests;
begin
  if not public.is_admin() then raise exception 'Solo administradores' using errcode = '42501'; end if;
  if p_status not in ('pending', 'in_review', 'in_progress', 'completed', 'cancelled') then raise exception 'Estado inválido'; end if;
  select * into cur from public.legal_requests where id = p_id for update;
  if not found then raise exception 'Solicitud no encontrada'; end if;
  if cur.status in ('completed', 'cancelled') then raise exception 'La solicitud ya está cerrada'; end if;
  update public.legal_requests set status = p_status, admin_note = coalesce(nullif(btrim(coalesce(p_note, '')), ''), admin_note), updated_at = now(), resolved_by = auth.uid() where id = p_id;
end $$;

-- 6) Ofertas de colaboración
create or replace function public.create_owner_offer(p_property uuid, p_agent uuid, p_terms jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid();
  sub public.subscriptions;
  prop record;
  ag record;
  asub public.subscriptions;
  apl public.subscription_plans;
  t jsonb := coalesce(p_terms, '{}'::jsonb);
  n numeric;
  yr integer; seq integer; num text; oid uuid := gen_random_uuid();
  me record;
begin
  if uid is null or not public.is_active_user() then raise exception 'No autorizado' using errcode = '42501'; end if;
  perform pg_advisory_xact_lock(hashtext('offer:' || uid::text));
  select * into sub from public.subscriptions where user_id = uid and current_period_end > now();
  if not found or sub.plan_code <> 'propietario' then
    raise exception 'Ofrecer tu propiedad a un agente es una función del plan Propietario' using errcode = 'P0403', hint = 'plan_owner';
  end if;

  select id, title, location, address, price, currency, area, rooms, baths, property_type, operation, code_number, description, status, expires_at, owner_whatsapp
    into prop from public.properties where id = p_property and owner_id = uid;
  if not found then raise exception 'Propiedad no encontrada'; end if;
  if prop.status <> 'available' or (prop.expires_at is not null and prop.expires_at <= now()) then raise exception 'Solo puedes ofrecer propiedades activas'; end if;

  select p.id, p.display_name into ag from public.profiles p where p.id = p_agent and p.is_active and p.role = 'agent';
  if not found or p_agent = uid then raise exception 'Agente no disponible'; end if;
  select * into asub from public.subscriptions where user_id = p_agent and current_period_end > now();
  if not found then raise exception 'Ese agente no tiene un plan vigente'; end if;
  select * into apl from public.subscription_plans where code = asub.plan_code;
  if not apl.agent_tools then raise exception 'Ese agente no tiene un plan con herramientas de agente'; end if;

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
declare uid uuid := auth.uid(); o public.owner_offers; sub public.subscriptions; pl public.subscription_plans;
begin
  if uid is null or not public.is_active_user() then raise exception 'No autorizado' using errcode = '42501'; end if;
  select * into o from public.owner_offers where id = p_id and agent_id = uid for update;
  if not found then raise exception 'Oferta no encontrada'; end if;
  if o.status <> 'pending' then raise exception 'La oferta ya fue respondida o cancelada'; end if;
  if p_accept then
    select * into sub from public.subscriptions where user_id = uid and current_period_end > now();
    if not found then raise exception 'Necesitas un plan vigente para aceptar ofertas' using errcode = 'P0403', hint = 'no_subscription'; end if;
    select * into pl from public.subscription_plans where code = sub.plan_code;
    if not pl.agent_tools then raise exception 'Tu plan no incluye herramientas de agente' using errcode = 'P0403', hint = 'plan_tools'; end if;
  end if;
  if char_length(coalesce(p_note, '')) > 500 then raise exception 'La nota es demasiado larga (máximo 500 caracteres)'; end if;
  update public.owner_offers set status = case when p_accept then 'accepted' else 'rejected' end, response_note = nullif(btrim(coalesce(p_note, '')), ''), responded_at = now(),
         agent_data = case when p_accept then agent_data || (select coalesce(jsonb_strip_nulls(jsonb_build_object('ci', nullif(btrim(l.ci), ''), 'registro', nullif(btrim(l.registration), ''), 'telefono', nullif(btrim(l.phone), ''))), '{}'::jsonb) from (select 1) x left join public.agent_legal_profiles l on l.user_id = uid) else agent_data end
   where id = p_id;
  insert into public.owner_offer_events (offer_id, kind, actor, note) values (p_id, case when p_accept then 'accepted' else 'rejected' end, uid, nullif(btrim(coalesce(p_note, '')), ''));
end $$;

create or replace function public.cancel_owner_offer(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid();
begin
  if uid is null or not public.is_active_user() then raise exception 'No autorizado' using errcode = '42501'; end if;
  update public.owner_offers set status = 'canceled', responded_at = now() where id = p_id and owner_id = uid and status = 'pending';
  if not found then raise exception 'Oferta no encontrada o ya respondida'; end if;
  insert into public.owner_offer_events (offer_id, kind, actor) values (p_id, 'canceled', uid);
end $$;

-- 7) Permisos de las funciones
revoke all on function public.list_agent_directory() from public, anon;
revoke all on function public.create_legal_request(text, uuid, text) from public, anon;
revoke all on function public.cancel_legal_request(bigint) from public, anon;
revoke all on function public.admin_update_legal_request(bigint, text, text) from public, anon;
revoke all on function public.create_owner_offer(uuid, uuid, jsonb) from public, anon;
revoke all on function public.respond_owner_offer(uuid, boolean, text) from public, anon;
revoke all on function public.cancel_owner_offer(uuid) from public, anon;
grant execute on function public.list_agent_directory() to authenticated;
grant execute on function public.create_legal_request(text, uuid, text) to authenticated;
grant execute on function public.cancel_legal_request(bigint) to authenticated;
grant execute on function public.admin_update_legal_request(bigint, text, text) to authenticated;
grant execute on function public.create_owner_offer(uuid, uuid, jsonb) to authenticated;
grant execute on function public.respond_owner_offer(uuid, boolean, text) to authenticated;
grant execute on function public.cancel_owner_offer(uuid) to authenticated;
