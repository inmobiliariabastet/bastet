/* Conexiones (público): ¿están activas las solicitudes de contacto con tarifa? (supabase/connections.sql, interruptor connection_settings.enabled).
 * Apagado, el sitio funciona como siempre (WhatsApp directo y formulario de clientes interesados). Encendido, main.js reemplaza el WhatsApp directo
 * de las propiedades de venta, alquiler y anticrético por la solicitud de contacto. Autónomo: usa el cliente global `supabaseClient`.
 * Expone window.Connections { init(), isOn() }. */
(function () {
  'use strict';
  let on = false, verifyRequired = false;
  window.Connections = {
    init: async function () {
      try { const { data, error } = await supabaseClient.rpc('connections_enabled'); on = !error && data === true; } catch (e) { on = false; }
      try { const { data, error } = await supabaseClient.rpc('verification_required'); verifyRequired = !error && data === true; } catch (e) { verifyRequired = false; }
      return on;
    },
    isOn: function () { return on; },
    verificationRequired: function () { return verifyRequired; },
  };
})();
