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
