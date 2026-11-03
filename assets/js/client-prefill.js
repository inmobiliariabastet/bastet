/* Precarga los formularios de contacto y de reserva con los datos de la cuenta (nombre, WhatsApp y correo), para que pedir un contacto
 * o una reserva sea cuestión de segundos. Solo rellena campos vacíos y solo con sesión iniciada; sin sesión no hace nada.
 * Datos: RPC my_prefill (supabase/client-accounts.sql). Uso: ClientPrefill.fill(raíz, { '#campo': 'name' | 'phone' | 'email' }). */
(function () {
  'use strict';
  let cache = null;
  async function get() {
    if (cache) return cache;
    cache = (async () => {
      try {
        if (typeof supabaseClient === 'undefined') return null;
        const { data: s } = await supabaseClient.auth.getSession();
        if (!s || !s.session) return null;
        const { data, error } = await supabaseClient.rpc('my_prefill');
        return error || !data || !data.signed_in ? null : data;
      } catch (e) { return null; }
    })();
    return cache;
  }
  async function fill(root, map) {
    if (!root) return;
    const d = await get(); if (!d) return;
    Object.keys(map).forEach((sel) => {
      const el = root.querySelector(sel), v = d[map[sel]];
      if (el && v && !String(el.value || '').trim()) el.value = v;
    });
  }
  window.ClientPrefill = { fill };
})();
