-- =====================================================================
-- UNO · Administración de contratos: anular un contrato   — agregar al final de supabase/schema.sql
-- Idempotente: se puede correr completo más de una vez.
-- Supone el bloque de contratos (contracts.sql) ya aplicado.
-- Anular NO borra nada ni devuelve créditos: el contrato queda marcado, la página pública de verificación
-- muestra "Anulado" y los PDF que se vuelvan a descargar llevan la marca de agua ANULADO.
-- =====================================================================

alter table public.exclusivity_contracts add column if not exists voided_at   timestamptz;
alter table public.exclusivity_contracts add column if not exists voided_by   uuid references auth.users(id) on delete set null;
alter table public.exclusivity_contracts add column if not exists void_reason text check (void_reason is null or char_length(void_reason) <= 300);

-- Solo un administrador activo puede anular. Es irreversible desde la app (deja quién y cuándo).
create or replace function public.admin_void_exclusivity_contract(p_id uuid, p_reason text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  reason text := btrim(coalesce(p_reason, ''));
  c public.exclusivity_contracts;
begin
  if not public.is_admin() then raise exception 'Solo administradores' using errcode = '42501'; end if;
  if char_length(reason) < 5 then raise exception 'Escribe el motivo de la anulación (mínimo 5 caracteres)' using errcode = '22023'; end if;
  if char_length(reason) > 300 then raise exception 'El motivo es demasiado largo (máximo 300 caracteres)' using errcode = '22023'; end if;

  select * into c from public.exclusivity_contracts where id = p_id for update;
  if not found then raise exception 'Contrato no encontrado' using errcode = '22023'; end if;
  if c.voided_at is not null then raise exception 'Este contrato ya está anulado' using errcode = '22023'; end if;

  update public.exclusivity_contracts
     set voided_at = now(), voided_by = auth.uid(), void_reason = reason
   where id = p_id
   returning * into c;

  return jsonb_build_object('id', c.id, 'contract_number', c.contract_number, 'voided_at', c.voided_at);
end $$;

revoke all on function public.admin_void_exclusivity_contract(uuid, text) from public, anon;
grant execute on function public.admin_void_exclusivity_contract(uuid, text) to authenticated;

-- La verificación pública ahora también informa si el contrato fue anulado (sin el motivo ni quién lo anuló)
drop function if exists public.verify_exclusivity_contract(text);
create function public.verify_exclusivity_contract(p_code text)
returns table (contract_number text, created_at timestamptz, agent_name text, template_version text, voided boolean, voided_at timestamptz)
language sql security definer set search_path = public stable as $$
  select c.contract_number, c.created_at, coalesce(nullif(btrim(p.display_name), ''), 'Agente de Bastet'), c.template_version,
         (c.voided_at is not null), c.voided_at
    from public.exclusivity_contracts c
    left join public.profiles p on p.id = c.agent_id
   where c.verification_code = upper(btrim(coalesce(p_code, '')))
   limit 1;
$$;
revoke all on function public.verify_exclusivity_contract(text) from public;
grant execute on function public.verify_exclusivity_contract(text) to anon, authenticated;
