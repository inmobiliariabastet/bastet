-- =====================================================================
-- UNO · "Vender mi inmueble": solicitudes de propietarios desde el landing
-- (agregar al final de supabase/schema.sql). Idempotente: se puede correr completo más de una vez.
-- Un visitante (sin cuenta) llena el formulario del botón "Vender mi inmueble": sus datos, los del inmueble,
-- la ubicación en el mapa y, si los tiene, los documentos que respaldan la propiedad. Si no los tiene, marca que
-- necesita apoyo legal para sanear los papeles. Un administrador las ve en la pestaña "Propietarios".
-- Supone que existen: public.is_admin().
-- =====================================================================

create table if not exists public.sell_requests (
  id                  uuid primary key,                                   -- lo genera el navegador: sirve de carpeta de los documentos
  owner_name          text not null check (char_length(owner_name) between 3 and 120),
  owner_ci            text check (owner_ci is null or char_length(owner_ci) between 4 and 30),
  owner_phone         text not null check (owner_phone ~ '^\+?[0-9]{7,15}$'),
  owner_email         text check (owner_email is null or (char_length(owner_email) between 5 and 160 and owner_email like '%@%')),
  owner_role          text not null default 'propietario' check (owner_role in ('propietario','copropietario','apoderado','heredero')),
  property_type       text not null check (property_type in ('casa','departamento','terreno','otro')),
  operation           text not null default 'venta' check (operation in ('venta','anticretico','alquiler')),
  city                text not null check (char_length(city) between 2 and 60),
  zone                text check (zone is null or char_length(zone) <= 120),
  address             text not null check (char_length(address) between 5 and 250),
  latitude            double precision check (latitude between -90 and 90),
  longitude           double precision check (longitude between -180 and 180),
  price               numeric check (price is null or (price > 0 and price < 1000000000)),
  currency            text not null default 'USD' check (currency in ('USD','BOB')),
  land_area           numeric check (land_area is null or (land_area > 0 and land_area < 100000000)),
  built_area          numeric check (built_area is null or (built_area >= 0 and built_area < 100000000)),
  rooms               integer check (rooms is null or rooms between 0 and 99),
  baths               integer check (baths is null or baths between 0 and 99),
  description         text check (description is null or char_length(description) <= 1500),
  doc_status          text not null check (doc_status in ('en_regla','por_regularizar','sin_documentos')),
  needs_legal_support boolean not null default false,
  documents           jsonb not null default '[]'::jsonb,                 -- [{type,name,path,size}]
  consent             boolean not null check (consent),
  status              text not null default 'new' check (status in ('new','contacted','review','closed','discarded')),
  admin_notes         text check (admin_notes is null or char_length(admin_notes) <= 2000),
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  check ((latitude is null) = (longitude is null)),
  check (jsonb_typeof(documents) = 'array' and jsonb_array_length(documents) <= 12),
  check (doc_status <> 'sin_documentos' or needs_legal_support)           -- sin documentos => apoyo legal siempre
);
create index if not exists sell_requests_status_idx on public.sell_requests (status, created_at desc);

alter table public.sell_requests enable row level security;
-- Sin políticas para anon/agentes: la única puerta de entrada es submit_sell_request(). Los administradores leen y gestionan.
drop policy if exists "admin reads sell requests" on public.sell_requests;
create policy "admin reads sell requests" on public.sell_requests for select to authenticated using (public.is_admin());
drop policy if exists "admin updates sell requests" on public.sell_requests;
create policy "admin updates sell requests" on public.sell_requests for update to authenticated using (public.is_admin()) with check (public.is_admin());
drop policy if exists "admin deletes sell requests" on public.sell_requests;
create policy "admin deletes sell requests" on public.sell_requests for delete to authenticated using (public.is_admin());
revoke all on public.sell_requests from anon;
revoke insert on public.sell_requests from authenticated;

-- Un administrador solo cambia el seguimiento (estado y notas); los datos que dejó el propietario quedan congelados.
create or replace function public.protect_sell_request_columns()
returns trigger language plpgsql as $$
begin
  if auth.uid() is not null then
    new.id := old.id; new.owner_name := old.owner_name; new.owner_ci := old.owner_ci; new.owner_phone := old.owner_phone;
    new.owner_email := old.owner_email; new.owner_role := old.owner_role; new.property_type := old.property_type;
    new.operation := old.operation; new.city := old.city; new.zone := old.zone; new.address := old.address;
    new.latitude := old.latitude; new.longitude := old.longitude; new.price := old.price; new.currency := old.currency;
    new.land_area := old.land_area; new.built_area := old.built_area; new.rooms := old.rooms; new.baths := old.baths;
    new.description := old.description; new.doc_status := old.doc_status; new.needs_legal_support := old.needs_legal_support;
    new.documents := old.documents; new.consent := old.consent; new.created_at := old.created_at;
  end if;
  new.updated_at := now();
  return new;
end $$;
drop trigger if exists protect_sell_request_columns on public.sell_requests;
create trigger protect_sell_request_columns before update on public.sell_requests
  for each row execute function public.protect_sell_request_columns();

-- Alta desde el landing (anon y authenticated). Valida todo y limita el abuso.
create or replace function public.submit_sell_request(p jsonb)
returns boolean language plpgsql security definer set search_path = public as $$
declare
  rid   uuid;
  ph    text := regexp_replace(coalesce(p->>'owner_phone', ''), '[\s().-]', '', 'g');
  docs  jsonb := coalesce(p->'documents', '[]'::jsonb);
  d     jsonb;
  st    text := coalesce(p->>'doc_status', '');
  needs boolean := coalesce((p->>'needs_legal_support')::boolean, false);
begin
  begin rid := (p->>'id')::uuid; exception when others then raise exception 'Solicitud no válida.'; end;
  if rid is null then raise exception 'Solicitud no válida.'; end if;
  if coalesce((p->>'consent')::boolean, false) is not true then raise exception 'Debes aceptar que usemos tus datos para contactarte.'; end if;
  if ph !~ '^\+?[0-9]{7,15}$' then raise exception 'Escribe un número de WhatsApp válido (solo dígitos, con + si incluye código de país).'; end if;
  if jsonb_typeof(docs) <> 'array' or jsonb_array_length(docs) > 12 then raise exception 'Máximo 12 documentos.'; end if;
  for d in select * from jsonb_array_elements(docs) loop
    -- cada archivo debe estar dentro de la carpeta de ESTA solicitud
    if coalesce(d->>'path', '') !~ ('^' || rid::text || '/[A-Za-z0-9._-]{1,120}$') then raise exception 'Documento no válido.'; end if;
  end loop;
  if st = 'sin_documentos' then needs := true; docs := '[]'::jsonb; end if;

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
revoke all on function public.submit_sell_request(jsonb) from public;
grant execute on function public.submit_sell_request(jsonb) to anon, authenticated;

-- ── Storage: carpeta privada de documentos. Cualquiera puede SUBIR (con tope de tamaño y tipo), solo un administrador puede VER.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('sell-documents', 'sell-documents', false, 10485760,
        array['application/pdf','image/jpeg','image/png','image/webp'])
on conflict (id) do update set public = false, file_size_limit = 10485760,
  allowed_mime_types = array['application/pdf','image/jpeg','image/png','image/webp'];

drop policy if exists "anyone can upload sell documents" on storage.objects;
create policy "anyone can upload sell documents" on storage.objects for insert to anon, authenticated
  with check (bucket_id = 'sell-documents' and name ~ '^[0-9a-f-]{36}/[A-Za-z0-9._-]{1,120}$');
drop policy if exists "admin reads sell documents" on storage.objects;
create policy "admin reads sell documents" on storage.objects for select to authenticated
  using (bucket_id = 'sell-documents' and public.is_admin());
drop policy if exists "admin deletes sell documents" on storage.objects;
create policy "admin deletes sell documents" on storage.objects for delete to authenticated
  using (bucket_id = 'sell-documents' and public.is_admin());
