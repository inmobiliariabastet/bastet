-- =====================================================================
-- Bastet · Marcas: las filas de relleno «Anuncie aquí» se reemplazan por una sola, «Hospeda a tu gente con nosotros»   — correr cuando quieras
-- =====================================================================
-- Borra las filas de relleno (logo «UNO-anuncie-aqui») y deja una con el logo de «Hospeda a tu gente con nosotros», en el lugar de la primera.
-- Esa tarjeta, en el landing, abre el registro de anfitriones. No toca las marcas reales. Idempotente.

do $$
declare pos integer;
begin
  select min(sort_order) into pos from public.partners where logo_url ilike '%anuncie-aqui%';
  delete from public.partners where logo_url ilike '%anuncie-aqui%';
  if pos is not null and not exists (select 1 from public.partners where logo_url ilike '%hospeda-a-tu-gente%') then
    insert into public.partners (name, logo_url, sort_order)
    values ('Hospeda a tu gente con nosotros', 'https://bastet.uno/assets/img/hospeda-a-tu-gente.webp', pos);
  end if;
end $$;
