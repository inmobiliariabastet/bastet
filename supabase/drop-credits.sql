-- =====================================================================
-- UNO · Borrar el sistema antiguo de créditos   — OPCIONAL y DESTRUCTIVO (no se puede deshacer)
-- Ejecutar solo si ya no necesitas el historial de créditos. Si quieres conservarlo, antes exporta cada tabla a CSV
-- (Supabase → Table Editor → la tabla → Export → CSV): credit_wallets, credit_ledger, credit_requests, credit_packs, credit_services, credit_tool_prices.
--
-- Qué borra: las 6 tablas credit_* (con sus políticas y datos) y las 5 funciones que solo servían a los créditos:
--   request_credit_pack, admin_resolve_credit_request, admin_grant_credits, my_publication_quota, _consume_publication.
-- Qué NO toca: suscripciones, pagos, propiedades ni contratos. Las columnas históricas `credits_charged` de
--   property_publications y exclusivity_contracts se dejan (son solo un número por fila; no estorban).
-- =====================================================================

do $$
declare n_wallets bigint := 0; n_ledger bigint := 0; n_req bigint := 0; bad text;
begin
  -- Seguridad: si alguna otra función (fuera de las 5 antiguas) todavía usa las tablas de créditos, no se borra nada
  select string_agg(p.oid::regprocedure::text, ', ') into bad
    from pg_proc p
   where p.pronamespace = 'public'::regnamespace
     and p.prosrc ~* 'credit_(wallets|ledger|requests|packs|services|tool_prices)'
     and p.proname not in ('request_credit_pack', 'admin_resolve_credit_request', 'admin_grant_credits', 'my_publication_quota', '_consume_publication');
  if bad is not null then
    raise exception 'No se borra nada: estas funciones todavía usan las tablas de créditos: %', bad;
  end if;

  if to_regclass('public.credit_wallets') is not null then execute 'select count(*) from public.credit_wallets' into n_wallets; end if;
  if to_regclass('public.credit_ledger')  is not null then execute 'select count(*) from public.credit_ledger'  into n_ledger;  end if;
  if to_regclass('public.credit_requests') is not null then execute 'select count(*) from public.credit_requests' into n_req;    end if;
  raise notice 'Se borrarán % billeteras, % movimientos y % solicitudes de créditos.', n_wallets, n_ledger, n_req;
end $$;

drop function if exists public.request_credit_pack(text, text);
drop function if exists public.admin_resolve_credit_request(bigint, boolean);
drop function if exists public.admin_grant_credits(uuid, integer, text);
drop function if exists public.my_publication_quota();
drop function if exists public._consume_publication(uuid, uuid, text, text, boolean);

drop table if exists public.credit_ledger;
drop table if exists public.credit_requests;
drop table if exists public.credit_wallets;
drop table if exists public.credit_services;
drop table if exists public.credit_packs;
drop table if exists public.credit_tool_prices;

notify pgrst, 'reload schema';
