-- =====================================================================
-- Bastet · Verificar una solicitud de contacto (conexión) por su código   — correr DESPUÉS de account-deletion.sql
-- =====================================================================
-- Quien pide un contacto recibe un código de 10 caracteres. Con él (o con el número de constancia BST-CX-AAAA-NNNN) puede comprobar en
-- «Verificar» en qué estado está su solicitud. La respuesta es pública pero mínima: nunca incluye nombres, teléfonos, correos ni mensajes.
-- Idempotente: se puede correr más de una vez.

create or replace function public.verify_connection_code(p_code text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare cd text := upper(btrim(coalesce(p_code, ''))); c public.connections; p record;
begin
  perform public._throttle('verify_public', 30, 60);
  if cd = '' or char_length(cd) > 24 then return jsonb_build_object('found', false); end if;
  select * into c from public.connections where code = cd or number = cd limit 1;
  if not found then return jsonb_build_object('found', false); end if;
  select code_number, property_type, split_part(coalesce(location, ''), ',', 1) as city into p from public.properties where id = c.property_id;
  return jsonb_build_object('found', true, 'code', c.code, 'number', c.number, 'status', c.status, 'operation', c.operation,
    'property_code', case when p.code_number is not null then 'BST-' || p.code_number end, 'property_type', p.property_type, 'city', btrim(coalesce(p.city, '')),
    'requested_on', to_char(c.created_at, 'YYYY-MM-DD'), 'accepted_on', to_char(c.accepted_at, 'YYYY-MM-DD'), 'connected_on', to_char(c.verified_at, 'YYYY-MM-DD'),
    'framework_version', c.framework_version);
end $$;

revoke execute on function public.verify_connection_code(text) from public;
grant execute on function public.verify_connection_code(text) to anon, authenticated;

notify pgrst, 'reload schema';
