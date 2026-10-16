-- Contrato de exclusividad: nueva plantilla "exclusividad-v2" (contrato base de Bastet, solo VENTA).
-- La función create_exclusivity_contract aceptaba solo 'exclusividad-v1'; ahora acepta v1 y v2.
-- Los contratos ya guardados no cambian (cada uno conserva su template_version).
-- Correr completo en el SQL Editor de Supabase (idempotente). Hacerlo ANTES de usar la plantilla nueva en la app.

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

revoke all on function public.create_exclusivity_contract(jsonb, text, text) from public, anon;
grant execute on function public.create_exclusivity_contract(jsonb, text, text) to authenticated;
