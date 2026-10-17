-- =====================================================================
-- UNO · Estadías temporales: ubicación en el mapa, calificaciones y reseñas de huéspedes   — agregar al final de supabase/schema.sql
-- Idempotente: se puede correr completo más de una vez.
--
-- Qué hace:
--  1) properties.latitude / longitude: el punto exacto que el anfitrión marca en el mapa (para mostrar la ubicación en la ficha).
--  2) PRIVACIDAD: hasta ahora cualquier visitante podía leer TODAS las columnas de las propiedades disponibles con la clave pública de
--     la API, incluido owner_whatsapp (el teléfono privado del propietario). Desde aquí el visitante anónimo solo puede leer las columnas
--     públicas. Si agregas una columna pública nueva a properties, hay que darle permiso con «grant select (columna) on public.properties to anon».
--  3) Reseñas: el anfitrión (propietario, agente o empresa) genera un ENLACE DE RESEÑA de un solo uso para cada huésped que se alojó;
--     el huésped califica de 1 a 5 estrellas y escribe su reseña sin necesitar cuenta. Así solo reseñan quienes recibieron el enlace.
--     El anfitrión puede responder y un administrador puede ocultar reseñas inapropiadas.
-- =====================================================================

do $$
begin
  if to_regclass('public.properties') is null then raise exception 'Primero corre supabase/schema.sql'; end if;
end $$;

-- 1) Ubicación
alter table public.properties add column if not exists latitude  double precision;
alter table public.properties add column if not exists longitude double precision;
alter table public.properties drop constraint if exists properties_latlng_check;
alter table public.properties add constraint properties_latlng_check
  check ((latitude is null) = (longitude is null) and (latitude is null or (latitude between -90 and 90 and longitude between -180 and 180)));

-- 2) El visitante anónimo solo lee columnas públicas (nunca owner_whatsapp ni datos internos de renovación)
revoke select on public.properties from anon;
grant select (id, title, location, address, price, currency, exchange_rate, area, rooms, baths, description, photos, whatsapp, owner_id,
              featured, featured_until, sort_order, status, created_at, code_number, property_type, operation, floors, has_garage, garage_spots,
              has_storage, pets_allowed, kids_allowed, expires_at, latitude, longitude)
  on public.properties to anon;

-- 3) Reseñas de huéspedes
create table if not exists public.stay_review_invites (
  id          uuid primary key default gen_random_uuid(),
  property_id uuid not null references public.properties(id) on delete cascade,
  host_id     uuid not null references auth.users(id) on delete cascade,
  token       text not null unique,
  guest_name  text check (guest_name is null or char_length(guest_name) <= 80),
  created_at  timestamptz not null default now(),
  used_at     timestamptz
);
create index if not exists stay_review_invites_property_idx on public.stay_review_invites (property_id, used_at);

create table if not exists public.stay_reviews (
  id          uuid primary key default gen_random_uuid(),
  property_id uuid not null references public.properties(id) on delete cascade,
  invite_id   uuid unique references public.stay_review_invites(id) on delete set null,
  guest_name  text not null check (char_length(btrim(guest_name)) between 2 and 60),
  rating      smallint not null check (rating between 1 and 5),
  comment     text check (comment is null or char_length(comment) <= 1200),
  host_reply  text check (host_reply is null or char_length(host_reply) <= 800),
  replied_at  timestamptz,
  status      text not null default 'published' check (status in ('published', 'hidden')),
  created_at  timestamptz not null default now()
);
create index if not exists stay_reviews_property_idx on public.stay_reviews (property_id, status, created_at desc);

-- Nadie lee ni escribe estas tablas directamente: todo pasa por las funciones de abajo
alter table public.stay_review_invites enable row level security;
alter table public.stay_reviews enable row level security;
revoke all on public.stay_review_invites, public.stay_reviews from anon, authenticated;

-- El anfitrión crea un enlace de reseña (un solo uso) para un huésped
create or replace function public.create_review_invite(p_property uuid, p_guest text default null)
returns text language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); prop record; tok text; tries int := 0;
begin
  if uid is null or not public.is_active_user() then raise exception 'No autorizado' using errcode = '42501'; end if;
  select id, owner_id, operation, status into prop from public.properties where id = p_property;
  if not found or (prop.owner_id is distinct from uid and not public.is_admin()) then raise exception 'Propiedad no encontrada'; end if;
  if prop.operation is distinct from 'temporal' then raise exception 'Las reseñas son solo para alojamientos temporales'; end if;
  if (select count(*) from public.stay_review_invites where property_id = p_property and used_at is null) >= 20 then
    raise exception 'Ya tienes 20 enlaces de reseña sin usar en esta propiedad. Espera a que los huéspedes los usen o elimina alguno.';
  end if;
  if (select count(*) from public.stay_review_invites where property_id = p_property and created_at > now() - interval '30 days') >= 60 then
    raise exception 'Alcanzaste el máximo de enlaces de reseña de este mes para esta propiedad.';
  end if;
  loop
    tok := upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 12));
    begin
      insert into public.stay_review_invites (property_id, host_id, token, guest_name)
      values (p_property, uid, tok, nullif(btrim(coalesce(p_guest, '')), ''));
      return tok;
    exception when unique_violation then
      tries := tries + 1; if tries > 5 then raise; end if;
    end;
  end loop;
end $$;

-- El anfitrión elimina un enlace que aún no se usó
create or replace function public.revoke_review_invite(p_token text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null or not public.is_active_user() then raise exception 'No autorizado' using errcode = '42501'; end if;
  delete from public.stay_review_invites where token = upper(btrim(coalesce(p_token, ''))) and used_at is null and (host_id = auth.uid() or public.is_admin());
  if not found then raise exception 'Enlace no encontrado o ya usado'; end if;
end $$;

-- Datos mínimos del enlace para mostrar el formulario (no revela nada del anfitrión)
create or replace function public.get_review_invite(p_token text)
returns jsonb language plpgsql security definer set search_path = public stable as $$
declare i record;
begin
  select v.guest_name, v.used_at, p.title, p.location into i
    from public.stay_review_invites v join public.properties p on p.id = v.property_id
   where v.token = upper(btrim(coalesce(p_token, '')));
  if not found then return jsonb_build_object('valid', false); end if;
  return jsonb_build_object('valid', i.used_at is null, 'used', i.used_at is not null, 'guest_name', i.guest_name, 'title', i.title, 'location', i.location);
end $$;

-- El huésped envía su reseña con el enlace (sin cuenta). Un enlace sirve una sola vez.
create or replace function public.submit_stay_review(p_token text, p_name text, p_rating integer, p_comment text)
returns boolean language plpgsql security definer set search_path = public as $$
declare i public.stay_review_invites; nm text := btrim(coalesce(p_name, '')); cm text := nullif(btrim(coalesce(p_comment, '')), '');
begin
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

-- Calificación promedio y cantidad de reseñas por propiedad (solo publicadas)
create or replace function public.list_stay_ratings(p_ids uuid[])
returns table (property_id uuid, avg_rating numeric, review_count integer)
language sql security definer set search_path = public stable as $$
  select r.property_id, round(avg(r.rating)::numeric, 2), count(*)::integer
    from public.stay_reviews r
   where r.status = 'published' and r.property_id = any (coalesce(p_ids, '{}'::uuid[])) and coalesce(array_length(p_ids, 1), 0) <= 300
   group by r.property_id;
$$;

-- Reseñas publicadas de una propiedad (el nombre se muestra como «Nombre A.»)
create or replace function public.list_stay_reviews(p_property uuid, p_limit integer default 30)
returns table (id uuid, guest_name text, rating smallint, comment text, host_reply text, created_at timestamptz)
language sql security definer set search_path = public stable as $$
  select r.id,
         split_part(btrim(r.guest_name), ' ', 1) || coalesce(' ' || upper(left(nullif(split_part(btrim(r.guest_name), ' ', 2), ''), 1)) || '.', ''),
         r.rating, r.comment, r.host_reply, r.created_at
    from public.stay_reviews r
   where r.property_id = p_property and r.status = 'published'
   order by r.created_at desc
   limit least(greatest(coalesce(p_limit, 30), 1), 100);
$$;

-- Panel del anfitrión: todas las reseñas (también las ocultas) y los enlaces pendientes
create or replace function public.host_stay_reviews(p_property uuid)
returns jsonb language plpgsql security definer set search_path = public stable as $$
declare uid uuid := auth.uid(); owner uuid;
begin
  if uid is null or not public.is_active_user() then raise exception 'No autorizado' using errcode = '42501'; end if;
  select owner_id into owner from public.properties where id = p_property;
  if not found or (owner is distinct from uid and not public.is_admin()) then raise exception 'Propiedad no encontrada'; end if;
  return jsonb_build_object(
    'reviews', coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'guest_name', r.guest_name, 'rating', r.rating, 'comment', r.comment,
                          'host_reply', r.host_reply, 'status', r.status, 'created_at', r.created_at) order by r.created_at desc)
                         from public.stay_reviews r where r.property_id = p_property), '[]'::jsonb),
    'invites', coalesce((select jsonb_agg(jsonb_build_object('token', v.token, 'guest_name', v.guest_name, 'created_at', v.created_at) order by v.created_at desc)
                         from public.stay_review_invites v where v.property_id = p_property and v.used_at is null), '[]'::jsonb));
end $$;

-- El anfitrión responde a una reseña de su propiedad
create or replace function public.reply_stay_review(p_review uuid, p_reply text)
returns void language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); rp text := nullif(btrim(coalesce(p_reply, '')), '');
begin
  if uid is null or not public.is_active_user() then raise exception 'No autorizado' using errcode = '42501'; end if;
  if rp is not null and char_length(rp) > 800 then raise exception 'La respuesta es demasiado larga (máximo 800 caracteres)'; end if;
  update public.stay_reviews r set host_reply = rp, replied_at = case when rp is null then null else now() end
   where r.id = p_review and exists (select 1 from public.properties p where p.id = r.property_id and (p.owner_id = uid or public.is_admin()));
  if not found then raise exception 'Reseña no encontrada'; end if;
end $$;

-- Un administrador oculta o vuelve a publicar una reseña
create or replace function public.admin_set_review_status(p_review uuid, p_status text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Solo administradores' using errcode = '42501'; end if;
  if p_status not in ('published', 'hidden') then raise exception 'Estado inválido'; end if;
  update public.stay_reviews set status = p_status where id = p_review;
  if not found then raise exception 'Reseña no encontrada'; end if;
end $$;

revoke all on function public.create_review_invite(uuid, text), public.revoke_review_invite(text), public.get_review_invite(text),
  public.submit_stay_review(text, text, integer, text), public.list_stay_ratings(uuid[]), public.list_stay_reviews(uuid, integer),
  public.host_stay_reviews(uuid), public.reply_stay_review(uuid, text), public.admin_set_review_status(uuid, text) from public, anon;
grant execute on function public.get_review_invite(text), public.submit_stay_review(text, text, integer, text),
  public.list_stay_ratings(uuid[]), public.list_stay_reviews(uuid, integer) to anon, authenticated;
grant execute on function public.create_review_invite(uuid, text), public.revoke_review_invite(text), public.host_stay_reviews(uuid),
  public.reply_stay_review(uuid, text), public.admin_set_review_status(uuid, text) to authenticated;

notify pgrst, 'reload schema';
