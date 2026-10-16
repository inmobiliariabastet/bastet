-- =====================================================================
-- UNO · WhatsApp de contacto del agente (público)   — agregar al final de supabase/schema.sql
-- Idempotente: se puede correr completo más de una vez.
--
-- Qué hace: cada agente puede poner su WhatsApp de contacto en «Mi cuenta». Se muestra como ícono de WhatsApp en sus propiedades
-- (junto a Facebook, Instagram y TikTok). Es una columna APARTE de profiles.whatsapp (el WhatsApp privado del registro), para no
-- publicar por error el número de quien solo se registró: solo contact_whatsapp es de lectura pública.
-- =====================================================================

alter table public.profiles add column if not exists contact_whatsapp text;
alter table public.profiles drop constraint if exists profiles_contact_whatsapp_check;
alter table public.profiles add constraint profiles_contact_whatsapp_check
  check (contact_whatsapp is null or contact_whatsapp ~ '^\+?[0-9 ()-]{7,30}$');

-- Lectura pública de esa única columna nueva (la política de filas «public can read active agent public info» sigue limitando a agentes activos)
grant select (contact_whatsapp) on public.profiles to anon;

-- Quien se registró como agente o empresa parte con su WhatsApp del registro (puede cambiarlo o borrarlo en Mi cuenta)
do $$
begin
  if exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'profiles' and column_name = 'interest') then
    update public.profiles
       set contact_whatsapp = btrim(whatsapp)
     where contact_whatsapp is null and interest in ('agente', 'empresa') and whatsapp ~ '^\+?[0-9 ()-]{7,30}$';
  end if;
end $$;

notify pgrst, 'reload schema';
