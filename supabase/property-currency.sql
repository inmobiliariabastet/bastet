-- =====================================================================
-- UNO · Moneda del precio de la propiedad (dólares o bolivianos)
-- (agregar al final de supabase/schema.sql). Idempotente: se puede correr completo más de una vez.
-- Cada propiedad guarda en qué moneda está su precio: 'USD' (por defecto, como todas las que ya existen) o 'BOB' (Bs.-).
-- El "tipo de cambio aceptado" solo aplica a precios en dólares.
-- =====================================================================
alter table public.properties add column if not exists currency text not null default 'USD';

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'properties_currency_check' and conrelid = 'public.properties'::regclass) then
    alter table public.properties add constraint properties_currency_check check (currency in ('USD', 'BOB'));
  end if;
end $$;
