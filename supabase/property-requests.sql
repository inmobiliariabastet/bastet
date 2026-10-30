-- =====================================================================
-- UNO · «Solicitar una propiedad» (comprador / inquilino): solicitudes de búsqueda   — agregar al final de supabase/schema.sql
-- Idempotente: se puede correr completo más de una vez.
--
-- Un visitante (con o sin cuenta) describe qué propiedad busca (operación, tipo, ciudad, características, presupuesto y contacto).
-- La solicitud queda registrada para que un asesor de Bastet la atienda; el visitante puede ver el estado de sus solicitudes
-- («Activa», «En proceso», «Finalizada») y finalizar la suya. El administrador las ve y cambia su estado.
-- Nadie lee la tabla directamente: todo pasa por funciones. Supone que existen: public.is_admin().
-- =====================================================================

create table if not exists public.property_requests (
  id            uuid primary key,                                   -- lo genera el navegador: el visitante lo guarda para ver su estado
  user_id       uuid references auth.users(id) on delete set null,   -- si estaba con sesión
  operation     text not null check (operation in ('venta','alquiler','anticretico','temporal')),
  property_type text not null check (property_type in ('casa','departamento','terreno','oficina','local','otro')),
  city          text not null check (char_length(city) between 2 and 60),
  zone          text check (zone is null or char_length(zone) <= 120),
  rooms_min     integer check (rooms_min is null or rooms_min between 0 and 99),
  baths_min     integer check (baths_min is null or baths_min between 0 and 99),
  area_min      numeric check (area_min is null or (area_min >= 0 and area_min < 100000000)),
  area_max      numeric check (area_max is null or (area_max >= 0 and area_max < 100000000)),
  features      text[] not null default '{}',                        -- comodidades y servicios cercanos que le importan
  budget_min    numeric check (budget_min is null or (budget_min >= 0 and budget_min < 1000000000)),
  budget_max    numeric check (budget_max is null or (budget_max >= 0 and budget_max < 1000000000)),
  currency      text not null default 'USD' check (currency in ('USD','BOB')),
  description   text check (description is null or char_length(description) <= 1000),
  contact_name  text not null check (char_length(contact_name) between 3 and 120),
  contact_phone text not null check (contact_phone ~ '^\+?[0-9]{7,15}$'),
  contact_email text check (contact_email is null or (char_length(contact_email) between 5 and 160 and contact_email like '%@%')),
  consent       boolean not null check (consent),
  status        text not null default 'active' check (status in ('active','in_progress','finished')),
  admin_note    text check (admin_note is null or char_length(admin_note) <= 1000),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  check (budget_min is null or budget_max is null or budget_max >= budget_min),
  check (area_min is null or area_max is null or area_max >= area_min),
  check (cardinality(features) <= 20)
);
create index if not exists property_requests_status_idx on public.property_requests (status, created_at desc);
create index if not exists property_requests_user_idx on public.property_requests (user_id);
create index if not exists property_requests_phone_idx on public.property_requests (contact_phone, created_at);

alter table public.property_requests enable row level security;
revoke all on public.property_requests from anon, authenticated;

-- Envío público (con o sin cuenta). Devuelve el id.
create or replace function public.submit_property_request(p jsonb)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  rid uuid;
  ph  text := regexp_replace(coalesce(p->>'contact_phone', ''), '[\s().-]', '', 'g');
  feats text[];
  num numeric;
begin
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

-- Estado de mis solicitudes: las que pido por id (las guardó este navegador) y, si hay sesión, todas las de mi cuenta
create or replace function public.my_property_requests(p_ids uuid[] default '{}')
returns table (id uuid, operation text, property_type text, city text, zone text, budget_min numeric, budget_max numeric, currency text, status text, created_at timestamptz)
language sql security definer set search_path = public stable as $$
  select r.id, r.operation, r.property_type, r.city, r.zone, r.budget_min, r.budget_max, r.currency, r.status, r.created_at
  from public.property_requests r
  where r.id = any(coalesce(p_ids, '{}')) or (auth.uid() is not null and r.user_id = auth.uid())
  order by r.created_at desc limit 50
$$;

-- El solicitante finaliza la suya (ya encontró lo que buscaba)
create or replace function public.finish_property_request(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  update public.property_requests set status = 'finished', updated_at = now() where id = p_id;
  if not found then raise exception 'Solicitud no encontrada'; end if;
end $$;

-- Administración
create or replace function public.admin_property_requests()
returns setof public.property_requests language plpgsql security definer set search_path = public stable as $$
begin
  if not public.is_admin() then raise exception 'No autorizado' using errcode = '42501'; end if;
  return query select * from public.property_requests order by created_at desc limit 500;
end $$;

create or replace function public.admin_set_property_request_status(p_id uuid, p_status text, p_note text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'No autorizado' using errcode = '42501'; end if;
  if p_status not in ('active','in_progress','finished') then raise exception 'Estado no válido'; end if;
  update public.property_requests set status = p_status, admin_note = coalesce(nullif(btrim(coalesce(p_note, '')), ''), admin_note), updated_at = now() where id = p_id;
  if not found then raise exception 'Solicitud no encontrada'; end if;
end $$;

revoke all on function public.submit_property_request(jsonb), public.my_property_requests(uuid[]), public.finish_property_request(uuid),
  public.admin_property_requests(), public.admin_set_property_request_status(uuid, text, text) from public, anon;
grant execute on function public.submit_property_request(jsonb), public.my_property_requests(uuid[]), public.finish_property_request(uuid) to anon, authenticated;
grant execute on function public.admin_property_requests(), public.admin_set_property_request_status(uuid, text, text) to authenticated;

notify pgrst, 'reload schema';
