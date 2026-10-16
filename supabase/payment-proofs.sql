-- =====================================================================
-- UNO · Comprobantes de pago de suscripción   — agregar al final de supabase/schema.sql
-- (después de subscriptions.sql y registration.sql). Idempotente: se puede correr completo más de una vez.
--
-- Qué hace: quien solicita un plan puede adjuntar la foto o PDF de su comprobante de pago (transferencia, QR). Se guarda en una
-- carpeta PRIVADA (payment-proofs/<id de usuario>/…): cada persona solo ve la suya y los administradores ven todas, mediante
-- enlaces firmados de corta duración, para verificar el pago antes de confirmarlo.
-- =====================================================================

do $$
begin
  if to_regclass('public.subscription_requests') is null then
    raise exception 'Primero corre supabase/subscriptions.sql';
  end if;
end $$;

alter table public.subscription_requests add column if not exists proof_path text;
alter table public.subscription_requests drop constraint if exists subscription_requests_proof_path_check;
alter table public.subscription_requests add constraint subscription_requests_proof_path_check check (proof_path is null or char_length(proof_path) <= 300);

-- Carpeta privada: imágenes y PDF de hasta 5 MB
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('payment-proofs', 'payment-proofs', false, 5242880, array['application/pdf', 'image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do update set public = false, file_size_limit = 5242880, allowed_mime_types = array['application/pdf', 'image/jpeg', 'image/png', 'image/webp'];

drop policy if exists "users upload own payment proof" on storage.objects;
create policy "users upload own payment proof" on storage.objects for insert to authenticated
  with check (bucket_id = 'payment-proofs' and (storage.foldername(name))[1] = auth.uid()::text);
drop policy if exists "users read own payment proof" on storage.objects;
create policy "users read own payment proof" on storage.objects for select to authenticated
  using (bucket_id = 'payment-proofs' and (storage.foldername(name))[1] = auth.uid()::text);
drop policy if exists "admin reads payment proofs" on storage.objects;
create policy "admin reads payment proofs" on storage.objects for select to authenticated
  using (bucket_id = 'payment-proofs' and public.is_admin());
drop policy if exists "admin deletes payment proofs" on storage.objects;
create policy "admin deletes payment proofs" on storage.objects for delete to authenticated
  using (bucket_id = 'payment-proofs' and public.is_admin());

-- Asocia el archivo subido con la solicitud pendiente de la persona (solo dentro de su propia carpeta)
create or replace function public.attach_payment_proof(p_request_id bigint, p_path text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null or not public.is_active_user() then raise exception 'No autorizado' using errcode = '42501'; end if;
  if p_path is null or char_length(p_path) > 300 or p_path not like auth.uid()::text || '/%' or p_path like '%..%' then
    raise exception 'Comprobante inválido'; end if;
  update public.subscription_requests set proof_path = p_path
   where id = p_request_id and user_id = auth.uid() and status = 'pending';
  if not found then raise exception 'No hay una solicitud pendiente para adjuntar el comprobante'; end if;
end $$;

revoke all on function public.attach_payment_proof(bigint, text) from public, anon;
grant execute on function public.attach_payment_proof(bigint, text) to authenticated;

notify pgrst, 'reload schema';
