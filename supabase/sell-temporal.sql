-- =====================================================================
-- Bastet · Solicitudes de publicación de estadías temporales sin documentos de propiedad   — correr DESPUÉS de client-accounts.sql
-- =====================================================================
-- El formulario «Publicar mi inmueble» del Inicio pide documentos que respalden la propiedad en venta, alquiler y anticrético. Una estadía
-- temporal no es una de esas operaciones: no se piden documentos de propiedad. Para eso doc_status admite el valor 'no_aplica', que solo vale
-- cuando la operación es «temporal» (y las solicitudes de las demás operaciones siguen exigiendo uno de los tres estados de siempre).
-- Idempotente: se puede correr más de una vez.

do $$
declare r record;
begin
  if to_regclass('public.sell_requests') is null then raise exception 'Primero corre supabase/sell-requests.sql'; end if;
  for r in select c.conname from pg_constraint c
            where c.conrelid = 'public.sell_requests'::regclass and c.contype = 'c'
              and pg_get_constraintdef(c.oid) ilike '%doc_status%' and c.conname not in ('sell_requests_doc_status_v2', 'sell_requests_no_docs_need_legal_v2', 'sell_requests_no_aplica_only_temporal') loop
    execute format('alter table public.sell_requests drop constraint %I', r.conname);
  end loop;
  if not exists (select 1 from pg_constraint where conname = 'sell_requests_doc_status_v2') then
    alter table public.sell_requests add constraint sell_requests_doc_status_v2 check (doc_status in ('en_regla', 'por_regularizar', 'sin_documentos', 'no_aplica'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'sell_requests_no_docs_need_legal_v2') then
    alter table public.sell_requests add constraint sell_requests_no_docs_need_legal_v2 check (doc_status <> 'sin_documentos' or needs_legal_support);
  end if;
  if not exists (select 1 from pg_constraint where conname = 'sell_requests_no_aplica_only_temporal') then
    alter table public.sell_requests add constraint sell_requests_no_aplica_only_temporal check (doc_status <> 'no_aplica' or operation = 'temporal');
  end if;
end $$;

notify pgrst, 'reload schema';
