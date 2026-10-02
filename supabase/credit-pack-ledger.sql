-- =====================================================================
-- UNO · Historial de créditos: la compra de un pack desglosa el regalo
-- (agregar al final de supabase/schema.sql). Idempotente: se puede correr completo más de una vez.
-- Antes: "Pack Exclusivo · transferencia  +440".  Ahora: "Pack Exclusivo · 400 + 40 de regalo · transferencia  +440".
-- Solo cambia el texto del movimiento: el monto acreditado es el mismo (créditos + regalo, congelados al pedir).
-- =====================================================================
create or replace function public.admin_resolve_credit_request(p_id bigint, p_approve boolean)
returns void language plpgsql security definer set search_path = public as $$
declare rq public.credit_requests; gift integer; label text;
begin
  if not public.is_admin() then raise exception 'Solo administradores' using errcode = '42501'; end if;
  select * into rq from public.credit_requests where id = p_id and status = 'pending' for update;
  if not found then raise exception 'Solicitud no encontrada o ya resuelta'; end if;

  update public.credit_requests
     set status = case when p_approve then 'approved' else 'rejected' end,
         resolved_at = now(), resolved_by = auth.uid()
   where id = p_id;

  if p_approve then
    select least(coalesce(bonus, 0), rq.credits) into gift from public.credit_packs where code = rq.pack_code;
    gift := coalesce(gift, 0);
    label := 'Pack ' || rq.pack_name || ' · ' ||
             case when gift > 0 then (rq.credits - gift) || ' + ' || gift || ' de regalo' else rq.credits || ' créditos' end ||
             ' · ' || rq.method;
    insert into public.credit_wallets (user_id, balance) values (rq.user_id, rq.credits)
    on conflict (user_id) do update set balance = public.credit_wallets.balance + excluded.balance, updated_at = now();
    insert into public.credit_ledger (user_id, kind, amount, description)
    values (rq.user_id, 'purchase', rq.credits, label);
  end if;
end $$;
