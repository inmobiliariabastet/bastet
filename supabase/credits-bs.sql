-- =====================================================================
-- UNO · Precios de los packs de créditos en BOLIVIANOS   — agregar al final de supabase/schema.sql
-- Idempotente: se puede correr completo más de una vez.
-- Regla: cada crédito comprado cuesta 4 Bs (50 créditos = 200 Bs). Los créditos de regalo (bonus) no se cobran.
-- Supone el bloque de créditos ya aplicado (credit_packs / credit_requests / request_credit_pack).
-- =====================================================================

-- Nueva columna de precio en bolivianos (la de dólares queda como histórico y ya no es obligatoria)
alter table public.credit_packs    add column if not exists price_bs numeric(10,2) check (price_bs is null or price_bs >= 0);
alter table public.credit_requests add column if not exists price_bs numeric(10,2) check (price_bs is null or price_bs >= 0);
alter table public.credit_packs    alter column price_usd drop not null;
alter table public.credit_requests alter column price_usd drop not null;

-- Precio de los packs actuales: 4 Bs por crédito comprado (solo donde todavía no tienen precio en Bs;
-- si después editas un precio a mano, volver a correr este archivo no lo pisa).
update public.credit_packs set price_bs = credits * 4 where price_bs is null;

-- La solicitud de compra congela el precio en Bs del pack (el navegador nunca envía el precio)
create or replace function public.request_credit_pack(p_pack text, p_method text)
returns bigint language plpgsql security definer set search_path = public as $$
declare pk public.credit_packs; rid bigint;
begin
  if auth.uid() is null or not public.is_active_user() then
    raise exception 'No autorizado' using errcode = '42501';
  end if;
  select * into pk from public.credit_packs where code = p_pack and active;
  if not found then raise exception 'Pack no disponible'; end if;
  if pk.price_bs is null then raise exception 'Pack sin precio'; end if;
  if exists (select 1 from public.credit_requests where user_id = auth.uid() and status = 'pending') then
    raise exception 'Ya tienes una solicitud pendiente de confirmación';
  end if;
  insert into public.credit_requests (user_id, pack_code, pack_name, credits, price_bs, method)
  values (auth.uid(), pk.code, pk.name, pk.credits + pk.bonus, pk.price_bs, p_method)
  returning id into rid;
  return rid;
end $$;

revoke all on function public.request_credit_pack(text, text) from public, anon;
grant execute on function public.request_credit_pack(text, text) to authenticated;
