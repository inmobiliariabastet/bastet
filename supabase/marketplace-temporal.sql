-- Marketplace: nueva operación "Temporal" (alojamiento por día) en las propiedades.
-- Amplía el CHECK de properties.operation (antes solo venta / alquiler / anticrético).
-- Idempotente. Correr en el SQL Editor de Supabase ANTES de publicar propiedades temporales.

alter table public.properties drop constraint if exists properties_operation_check;
alter table public.properties
  add constraint properties_operation_check
  check (operation in ('venta', 'alquiler', 'anticretico', 'temporal'));
