-- =====================================================================
-- UNO · Generador de contratos de exclusividad   — agregar al final de supabase/schema.sql
-- Idempotente: se puede correr completo más de una vez.
-- Supone: public.profiles, public.is_admin(), public.is_active_user() y el bloque de créditos
-- (credit_wallets / credit_ledger) ya aplicados. Cada contrato generado cuesta créditos (hoy 5).
-- El cobro es 100% del servidor: el navegador nunca envía el costo.
-- =====================================================================

-- 1) Precio de las herramientas (editable por un admin; el cliente solo lo lee para mostrarlo)
create table if not exists public.credit_tool_prices (
  code   text primary key,
  name   text not null,
  cost   integer not null check (cost > 0),
  active boolean not null default true
);
insert into public.credit_tool_prices (code, name, cost) values
  ('contrato_exclusividad', 'Contrato de exclusividad', 5)
on conflict (code) do nothing;

-- Los movimientos de créditos pueden referenciar el contrato que los originó
alter table public.credit_ledger add column if not exists contract_id uuid;

-- 2) Datos legales del agente (C.I., teléfono, registro): privados, solo del propio agente
create table if not exists public.agent_legal_profiles (
  user_id      uuid primary key references public.profiles(id) on delete cascade,
  ci           text check (ci is null or char_length(ci) <= 30),
  phone        text check (phone is null or char_length(phone) <= 30),
  registration text check (registration is null or char_length(registration) <= 60),
  updated_at   timestamptz not null default now()
);

-- 3) Contratos generados y numeración correlativa por año
create table if not exists public.exclusivity_contract_counters (
  year        integer primary key,
  last_number integer not null default 0
);

create table if not exists public.exclusivity_contracts (
  id               uuid primary key default gen_random_uuid(),
  agent_id         uuid references auth.users(id) on delete set null,
  contract_number  text not null unique,
  verification_code text not null unique,
  template_version text not null,
  data             jsonb not null,           -- copia fiel de los campos del formulario: el PDF se vuelve a generar desde aquí (gratis)
  credits_charged  integer not null,
  idempotency_key  text not null,
  created_at       timestamptz not null default now(),
  unique (agent_id, idempotency_key)
);
create index if not exists exclusivity_contracts_agent_idx on public.exclusivity_contracts (agent_id, created_at desc);

-- 4) RLS: cada agente ve solo sus contratos (el admin todos); nadie escribe directo desde el navegador
alter table public.credit_tool_prices          enable row level security;
alter table public.agent_legal_profiles        enable row level security;
alter table public.exclusivity_contract_counters enable row level security;
alter table public.exclusivity_contracts       enable row level security;

drop policy if exists credit_tool_prices_read   on public.credit_tool_prices;
drop policy if exists credit_tool_prices_admin  on public.credit_tool_prices;
drop policy if exists agent_legal_own_select    on public.agent_legal_profiles;
drop policy if exists agent_legal_own_insert    on public.agent_legal_profiles;
drop policy if exists agent_legal_own_update    on public.agent_legal_profiles;
drop policy if exists exclusivity_contracts_read on public.exclusivity_contracts;

create policy credit_tool_prices_read  on public.credit_tool_prices for select to authenticated using (public.is_active_user());
create policy credit_tool_prices_admin on public.credit_tool_prices for all    to authenticated using (public.is_admin()) with check (public.is_admin());
create policy agent_legal_own_select on public.agent_legal_profiles for select to authenticated using (user_id = auth.uid() and public.is_active_user());
create policy agent_legal_own_insert on public.agent_legal_profiles for insert to authenticated with check (user_id = auth.uid() and public.is_active_user());
create policy agent_legal_own_update on public.agent_legal_profiles for update to authenticated using (user_id = auth.uid() and public.is_active_user()) with check (user_id = auth.uid() and public.is_active_user());
create policy exclusivity_contracts_read on public.exclusivity_contracts for select to authenticated
  using ((agent_id = auth.uid() and public.is_active_user()) or public.is_admin());
-- (el contador no tiene políticas: solo lo toca la función security definer)

revoke all on public.credit_tool_prices, public.agent_legal_profiles, public.exclusivity_contract_counters, public.exclusivity_contracts from anon;
revoke insert, update, delete on public.exclusivity_contracts, public.exclusivity_contract_counters from authenticated;
revoke all on public.exclusivity_contract_counters from authenticated;
grant select on public.exclusivity_contracts to authenticated;
grant select on public.credit_tool_prices to authenticated;
grant insert, update on public.credit_tool_prices to authenticated;          -- las políticas limitan la escritura al admin
grant select, insert, update on public.agent_legal_profiles to authenticated;

-- 5) Validación del lado servidor (mismas reglas que el formulario; el costo y los números nunca vienen del cliente)
create or replace function public.validate_exclusivity_data(d jsonb)
returns void language plpgsql immutable as $$
declare
  k text;
  n numeric;
  txt text;
begin
  if d is null or jsonb_typeof(d) <> 'object' then raise exception 'Datos del contrato inválidos' using errcode = '22023'; end if;
  if pg_column_size(d) > 20000 then raise exception 'Los datos del contrato son demasiado extensos' using errcode = '22023'; end if;

  foreach k in array array[
    'propietario_nombre','propietario_ci','propietario_estado_civil','propietario_domicilio','propietario_telefono','propietario_email',
    'inmueble_tipo','inmueble_direccion','inmueble_zona','inmueble_ciudad','inmueble_departamento','inmueble_matricula',
    'agente_nombre','agente_ci','agente_telefono','agente_email','agencia_nombre','agencia_domicilio',
    'forma_pago','ciudad_firma','ciudad_jurisdiccion','fecha_inicio'
  ] loop
    txt := btrim(coalesce(d ->> k, ''));
    if txt = '' then raise exception 'Falta el dato obligatorio: %', k using errcode = '22023'; end if;
    if char_length(txt) > 300 then raise exception 'El dato % es demasiado largo', k using errcode = '22023'; end if;
  end loop;

  if (d ->> 'operacion') not in ('venta','alquiler','anticretico') then raise exception 'Operación inválida' using errcode = '22023'; end if;
  if (d ->> 'moneda') not in ('Bs','USD') then raise exception 'Moneda inválida' using errcode = '22023'; end if;
  if (d ->> 'propietario_email') !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'Correo del propietario inválido' using errcode = '22023'; end if;
  if (d ->> 'agente_email') !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'Correo del agente inválido' using errcode = '22023'; end if;
  if (d ->> 'propietario_ci') !~ '^[0-9]{4,10}([ -]?[0-9A-Za-z]{1,3})?$' then raise exception 'C.I. del propietario inválida' using errcode = '22023'; end if;
  if (d ->> 'agente_ci') !~ '^[0-9]{4,10}([ -]?[0-9A-Za-z]{1,3})?$' then raise exception 'C.I. del agente inválida' using errcode = '22023'; end if;
  if (d ->> 'fecha_inicio') !~ '^\d{4}-\d{2}-\d{2}$' then raise exception 'Fecha de inicio inválida' using errcode = '22023'; end if;
  perform (d ->> 'fecha_inicio')::date;

  foreach k in array array['precio','inmueble_sup_terreno'] loop
    begin n := (d ->> k)::numeric; exception when others then n := null; end;
    if n is null or n <= 0 or n > 100000000000 then raise exception 'El campo % debe ser un número mayor que 0', k using errcode = '22023'; end if;
  end loop;
  if nullif(d ->> 'precio_minimo', '') is not null then
    begin n := (d ->> 'precio_minimo')::numeric; exception when others then n := null; end;
    if n is null or n <= 0 then raise exception 'El precio mínimo debe ser mayor que 0' using errcode = '22023'; end if;
  end if;

  begin n := (d ->> 'plazo_dias')::numeric; exception when others then n := null; end;
  if n is null or n <> trunc(n) or n < 15 or n > 730 then raise exception 'El plazo debe ser de 15 a 730 días' using errcode = '22023'; end if;

  if (d ->> 'operacion') = 'alquiler' then
    begin n := (d ->> 'comision_meses')::numeric; exception when others then n := null; end;
    if n is null or n <= 0 or n > 24 then raise exception 'Los meses de honorarios deben ser mayores que 0' using errcode = '22023'; end if;
  else
    begin n := (d ->> 'comision_porcentaje')::numeric; exception when others then n := null; end;
    if n is null or n <= 0 or n > 100 then raise exception 'El porcentaje de honorarios debe estar entre 0 y 100' using errcode = '22023'; end if;
  end if;

  if coalesce((d ->> 'tiene_copropietario')::boolean, false) and (btrim(coalesce(d ->> 'copropietario_nombre','')) = '' or btrim(coalesce(d ->> 'copropietario_ci','')) = '') then
    raise exception 'Faltan los datos del copropietario' using errcode = '22023';
  end if;
  if coalesce((d ->> 'tiene_apoderado')::boolean, false) and (btrim(coalesce(d ->> 'apoderado_nombre','')) = '' or btrim(coalesce(d ->> 'apoderado_ci','')) = ''
      or btrim(coalesce(d ->> 'poder_numero','')) = '' or btrim(coalesce(d ->> 'poder_fecha','')) = '' or btrim(coalesce(d ->> 'poder_notaria','')) = '') then
    raise exception 'Faltan los datos del apoderado' using errcode = '22023';
  end if;
  if coalesce((d ->> 'con_gravamenes')::boolean, false) and btrim(coalesce(d ->> 'gravamenes_detalle','')) = '' then
    raise exception 'Describe el gravamen del inmueble' using errcode = '22023';
  end if;
end $$;

-- 6) Generar el contrato: cobra, numera y guarda en UNA transacción. Si algo falla, no se cobra nada.
create or replace function public.create_exclusivity_contract(p_data jsonb, p_idempotency_key text, p_template_version text default 'exclusividad-v1')
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  uid     uuid := auth.uid();
  key     text := btrim(coalesce(p_idempotency_key, ''));
  cost    integer;
  bal     integer;
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
    select balance into bal from public.credit_wallets where user_id = uid;
    return jsonb_build_object('id', c.id, 'contract_number', c.contract_number, 'verification_code', c.verification_code,
                              'created_at', c.created_at, 'balance', coalesce(bal, 0), 'charged', false);
  end if;

  perform public.validate_exclusivity_data(p_data);

  select t.cost into cost from public.credit_tool_prices t where t.code = 'contrato_exclusividad' and t.active;
  if cost is null then raise exception 'Herramienta no disponible' using errcode = '22023'; end if;

  -- Descuento atómico: solo si alcanza el saldo (la fila queda bloqueada hasta el final de la transacción)
  update public.credit_wallets w set balance = w.balance - cost, updated_at = now()
   where w.user_id = uid and w.balance >= cost
   returning w.balance into bal;
  if not found then
    select balance into bal from public.credit_wallets where user_id = uid;
    raise exception 'Saldo insuficiente' using errcode = 'P0402', detail = 'balance=' || coalesce(bal, 0), hint = 'cost=' || cost;
  end if;

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
  values (cid, uid, num, code, p_template_version, p_data, cost, key)
  returning * into c;

  insert into public.credit_ledger (user_id, kind, amount, description, contract_id)
  values (uid, 'spend', -cost, 'Contrato de exclusividad ' || num, cid);

  return jsonb_build_object('id', c.id, 'contract_number', c.contract_number, 'verification_code', c.verification_code,
                            'created_at', c.created_at, 'balance', bal, 'charged', true);
end $$;

-- 7) Verificación pública: confirma que el contrato existe SIN mostrar datos del propietario
drop function if exists public.verify_exclusivity_contract(text);
create function public.verify_exclusivity_contract(p_code text)
returns table (contract_number text, created_at timestamptz, agent_name text, template_version text)
language sql security definer set search_path = public stable as $$
  select c.contract_number, c.created_at, coalesce(nullif(btrim(p.display_name), ''), 'Agente de Bastet'), c.template_version
    from public.exclusivity_contracts c
    left join public.profiles p on p.id = c.agent_id
   where c.verification_code = upper(btrim(coalesce(p_code, '')))
   limit 1;
$$;

revoke all on function public.validate_exclusivity_data(jsonb) from public, anon;
revoke all on function public.create_exclusivity_contract(jsonb, text, text) from public, anon;
revoke all on function public.verify_exclusivity_contract(text) from public;
grant execute on function public.create_exclusivity_contract(jsonb, text, text) to authenticated;
grant execute on function public.verify_exclusivity_contract(text) to anon, authenticated;
