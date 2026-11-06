-- =====================================================================
-- Bastet · La cuenta «empresa» es un CLIENTE corporativo (no un agente)   — correr DESPUÉS de corporate.sql
-- =====================================================================
-- · Una empresa no publica inmuebles ni usa las herramientas de agente (contratos de exclusividad): compra, alquila o reserva estadías para ella o para su
--   gente. my_account() ya no le da agent_tools y la marca como cliente corporativo ('client' = true, 'company' = true).
-- · Los agentes inmobiliarios eligen «Agente»; «Empresa» es solo para empresas que necesitan alojamiento o espacios.
-- · Solicitudes corporativas con tres tipos: 'estadia' (alojamiento del equipo), 'espacio' (alquilar un espacio para operar: oficina, depósito, local, terreno…)
--   y 'compra' (comprar un inmueble). Las de estadía llevan fechas y trabajadores (se pueden elegir de la lista); las otras, operación, tipo y tamaño.
-- Idempotente: se puede correr más de una vez.

do $$
begin
  if to_regprocedure('public.my_company()') is null then raise exception 'Primero corre supabase/corporate.sql'; end if;
end $$;

-- ── Estado de la cuenta ──
create or replace function public.my_account()
returns jsonb language plpgsql security definer set search_path = public stable as $$
declare uid uuid := auth.uid(); p record; adm boolean; it text;
begin
  if uid is null or not public.is_active_user() then raise exception 'No autorizado' using errcode = '42501'; end if;
  adm := public.is_admin();
  select registered_at, interest into p from public.profiles where id = uid;
  it := case when adm then 'admin' else coalesce(p.interest, 'agente') end;
  return jsonb_build_object('exempt', adm, 'registered', adm or p.registered_at is not null, 'interest', p.interest,
    'account', jsonb_build_object('type', it, 'agent_tools', adm or it = 'agente', 'client', it in ('cliente', 'empresa'), 'company', it = 'empresa',
      'name', case it when 'propietario' then 'Propietario' when 'empresa' then 'Empresa' when 'admin' then 'Administrador' when 'cliente' then 'Cliente' else 'Agente' end),
    'active_properties', public._count_active_properties(uid));
end $$;

-- ── Cliente y empresa no publican inmuebles ──
create or replace function public.block_client_publishing()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is not null and not public.is_admin()
     and coalesce((select interest from public.profiles where id = auth.uid()), '') in ('cliente', 'empresa') then
    raise exception 'Las cuentas de cliente y de empresa no publican inmuebles. Si quieres publicar, escríbenos a inmobiliaria@bastet.uno.' using errcode = 'P0403', hint = 'client_account';
  end if;
  return new;
end $$;
drop trigger if exists block_client_publishing on public.properties;
create trigger block_client_publishing before insert on public.properties for each row execute function public.block_client_publishing();

-- ── El contrato de exclusividad es solo de agentes (y administración) ──
create or replace function public.require_agent_for_contracts()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is not null and not public.is_admin()
     and coalesce((select interest from public.profiles where id = auth.uid()), 'agente') <> 'agente' then
    raise exception 'El contrato de exclusividad es solo para cuentas de agente' using errcode = 'P0403', hint = 'account_tools';
  end if;
  return new;
end $$;
drop trigger if exists require_agent_for_contracts on public.exclusivity_contracts;
create trigger require_agent_for_contracts before insert on public.exclusivity_contracts for each row execute function public.require_agent_for_contracts();

-- ── Cambiar de tipo: un cliente o una empresa puede pasar a propietario o agente (no a empresa desde aquí) ──
create or replace function public.change_account_type(p_type text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); cur text;
begin
  if uid is null or not public.is_active_user() then raise exception 'No autorizado' using errcode = '42501'; end if;
  if public.is_admin() then raise exception 'Las cuentas de administración no cambian de tipo'; end if;
  if p_type is null or p_type not in ('propietario', 'agente') then raise exception 'Elige propietario o agente'; end if;
  select interest into cur from public.profiles where id = uid;
  if cur is null or cur not in ('cliente', 'empresa') then raise exception 'Para cambiar el tipo de tu cuenta escríbenos a inmobiliaria@bastet.uno' using errcode = 'P0403'; end if;
  perform set_config('uno.reg_rpc', '1', true);
  update public.profiles set interest = p_type where id = uid;
  return public.my_account();
end $$;

-- ── Solicitudes corporativas de tres tipos ──
alter table public.company_requests add column if not exists kind text not null default 'estadia';
alter table public.company_requests add column if not exists operation text;
alter table public.company_requests add column if not exists space_type text;
alter table public.company_requests add column if not exists size_text text;
alter table public.company_requests add column if not exists worker_ids uuid[] not null default '{}';

do $$
declare k record;
begin
  for k in select conname from pg_constraint where conrelid = 'public.company_requests'::regclass and contype = 'c' and pg_get_constraintdef(oid) like '%to_date > from_date%' loop
    execute format('alter table public.company_requests drop constraint %I', k.conname);
  end loop;
end $$;
alter table public.company_requests alter column from_date drop not null;
alter table public.company_requests alter column to_date drop not null;
alter table public.company_requests alter column workers_count drop not null;
alter table public.company_requests drop constraint if exists company_requests_kind_chk;
alter table public.company_requests add constraint company_requests_kind_chk check (kind in ('estadia', 'espacio', 'compra'));
alter table public.company_requests drop constraint if exists company_requests_shape_chk;
alter table public.company_requests add constraint company_requests_shape_chk check (
  (kind <> 'estadia' or (from_date is not null and to_date is not null and workers_count is not null and to_date > from_date))
  and (from_date is null or to_date is null or to_date >= from_date)
  and (operation is null or operation in ('alquiler', 'venta', 'anticretico'))
  and (space_type is null or char_length(space_type) <= 60)
  and (size_text is null or char_length(size_text) <= 120));

create or replace function public.company_submit_request(p jsonb)
returns text language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); c public.company_accounts; cd text; f date; t date; k text; op text; wids uuid[] := '{}'; wn integer;
begin
  if uid is null or not public.is_active_user() then raise exception 'No autorizado' using errcode = '42501'; end if;
  select * into c from public.company_accounts where owner_id = uid;
  if not found or c.status <> 'activa' then raise exception 'Tu empresa aún no está activa'; end if;
  if (select count(*) from public.company_requests where company_id = c.id and status in ('nueva', 'en_gestion', 'cotizada')) >= 20 then raise exception 'Tienes demasiadas solicitudes abiertas; espera a que Bastet responda alguna'; end if;
  k := coalesce(nullif(btrim(coalesce(p->>'kind', '')), ''), 'estadia');
  if k not in ('estadia', 'espacio', 'compra') then raise exception 'Tipo de solicitud no válido'; end if;
  op := nullif(btrim(coalesce(p->>'operation', '')), '');
  begin
    f := nullif(p->>'from_date', '')::date; t := nullif(p->>'to_date', '')::date;
    if f is not null and f < public.bo_today() then raise exception 'La fecha de inicio ya pasó'; end if;
    if k = 'estadia' then
      op := null;
      if jsonb_typeof(p->'worker_ids') = 'array' then
        select coalesce(array_agg(w.id), '{}') into wids from public.company_workers w
         where w.company_id = c.id and w.id::text in (select jsonb_array_elements_text(p->'worker_ids'));
      end if;
      wn := coalesce(nullif(p->>'workers_count', '')::integer, cardinality(wids));
    else
      t := null; wn := null;
      if k = 'compra' then op := 'venta'; elsif op is null then op := 'alquiler'; end if;
    end if;
    cd := 'CORP-' || upper(substr(md5(random()::text || clock_timestamp()::text), 1, 6));
    insert into public.company_requests (code, company_id, kind, city, from_date, to_date, workers_count, worker_ids, operation, space_type, size_text, budget_text, notes)
    values (cd, c.id, k, btrim(coalesce(p->>'city', '')), f, t, wn, wids, op, nullif(btrim(coalesce(p->>'space_type', '')), ''), nullif(btrim(coalesce(p->>'size_text', '')), ''),
            nullif(btrim(coalesce(p->>'budget_text', '')), ''), nullif(btrim(coalesce(p->>'notes', '')), ''));
  exception when check_violation or invalid_datetime_format or invalid_text_representation or datetime_field_overflow then
    raise exception 'Revisa la ciudad, las fechas (la salida va después de la llegada) y los datos de la solicitud.';
  end;
  return cd;
end $$;

revoke execute on function public.my_account(), public.change_account_type(text), public.company_submit_request(jsonb) from public, anon;
grant execute on function public.my_account(), public.change_account_type(text), public.company_submit_request(jsonb) to authenticated;

notify pgrst, 'reload schema';
