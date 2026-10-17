-- =====================================================================
-- UNO · «Vender mi inmueble» acepta también la operación TEMPORAL   — agregar al final de supabase/schema.sql
-- Idempotente: se puede correr completo más de una vez.
--
-- Qué hace: el formulario público «Vender mi inmueble» ahora permite elegir «Temporal (por noche)» para quienes quieren ofrecer su
-- inmueble como alojamiento temporal. Solo amplía la lista de operaciones permitidas de sell_requests; nada más cambia.
-- =====================================================================

do $$
declare c record;
begin
  if to_regclass('public.sell_requests') is null then
    raise exception 'Primero corre supabase/sell-requests.sql';
  end if;
  -- se elimina la restricción actual de «operation» (su nombre automático) y se vuelve a crear con «temporal»
  for c in select conname from pg_constraint
            where conrelid = 'public.sell_requests'::regclass and contype = 'c' and pg_get_constraintdef(oid) ilike '%operation%' loop
    execute format('alter table public.sell_requests drop constraint %I', c.conname);
  end loop;
  alter table public.sell_requests add constraint sell_requests_operation_check
    check (operation in ('venta', 'anticretico', 'alquiler', 'temporal'));
end $$;

notify pgrst, 'reload schema';
