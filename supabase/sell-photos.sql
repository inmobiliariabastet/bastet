-- =====================================================================
-- Bastet · "Vender mi inmueble": paso «Fotos» (agregar al final de supabase/schema.sql, después de sell-requests.sql).
-- Idempotente. Las fotos viajan en la misma columna `documents` con type = 'foto' (misma carpeta privada `sell-documents`):
--   · hasta 8 fotos (solo imágenes) además de los 12 documentos de siempre → tope total 20 archivos;
--   · elegir «No tengo documentos» ya NO borra las fotos (solo los documentos).
-- Supone que existen: public.sell_requests y public.submit_sell_request() de supabase/sell-requests.sql.
-- =====================================================================

-- El tope de la tabla pasa de 12 a 20 archivos en total (12 documentos + 8 fotos)
do $$
declare c text;
begin
  for c in select conname from pg_constraint
           where conrelid = 'public.sell_requests'::regclass and contype = 'c'
             and pg_get_constraintdef(oid) like '%jsonb_array_length(documents)%' and conname <> 'sell_requests_documents_chk'
  loop
    execute format('alter table public.sell_requests drop constraint %I', c);
  end loop;
end $$;
alter table public.sell_requests drop constraint if exists sell_requests_documents_chk;
alter table public.sell_requests add constraint sell_requests_documents_chk
  check (jsonb_typeof(documents) = 'array' and jsonb_array_length(documents) <= 20);

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
revoke all on function public.submit_sell_request(jsonb) from public;
grant execute on function public.submit_sell_request(jsonb) to anon, authenticated;

notify pgrst, 'reload schema';
