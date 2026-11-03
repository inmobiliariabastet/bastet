-- =====================================================================
-- Bastet · El huésped ve el WhatsApp del dueño de la publicación al confirmarse su reserva   — correr DESPUÉS de sell-temporal.sql
-- =====================================================================
-- Antes, al confirmarse el pago, la reserva mostraba el botón «Escribir al anfitrión» solo si el perfil del anfitrión tenía WhatsApp de contacto
-- o la propiedad tenía WhatsApp de agente (campo que ya no se pide). Ahora se usa primero el «WhatsApp del dueño de la publicación»
-- (properties.owner_whatsapp), luego el del perfil y al final el de la propiedad. Solo se entrega cuando la reserva está confirmada y verificada
-- (igual que antes). Reescribe get_stay_booking, verify_stay_booking y my_stay_bookings a partir de su definición actual.
-- Idempotente.

do $$
declare fn text; def text; newdef text;
begin
  foreach fn in array array['get_stay_booking(text)', 'verify_stay_booking(text)', 'my_stay_bookings()'] loop
    def := pg_get_functiondef(('public.' || fn)::regprocedure);
    newdef := replace(def, 'coalesce(contact, prop.whatsapp)', 'coalesce(nullif(btrim((select owner_whatsapp from public.properties where id = b.property_id)), ''''), contact, prop.whatsapp)');
    newdef := replace(newdef, 'coalesce((select contact_whatsapp from public.profiles where id = b.host_id), p.whatsapp)', 'coalesce(nullif(btrim(p.owner_whatsapp), ''''), (select contact_whatsapp from public.profiles where id = b.host_id), p.whatsapp)');
    if newdef <> def then execute newdef; end if;
  end loop;
end $$;

notify pgrst, 'reload schema';
