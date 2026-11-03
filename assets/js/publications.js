/* Cuenta y publicaciones. Desde 2026-11-03 ya no hay planes ni suscripciones: publicar es libre, sin tope ni vencimiento, y solo
   administración destaca propiedades. Esta pieza carga el estado de la cuenta (RPC my_account, supabase/retire-subscriptions.sql) y lo
   publica en `UnoPublications.account` y con el evento `uno:account`. admin.js llama a refresh(), decorateCard(), confirmPublish() y
   featureProperty(). Usa el cliente global `supabaseClient`. */
(function () {
  'use strict';

  const state = { account: null };

  async function fetchAccount() {
    try {
      const { data, error } = await supabaseClient.rpc('my_account');
      if (error || !data) return null;
      return data;
    } catch (e) { return null; }
  }

  const isAdminAccount = (a) => !!a && a.exempt === true;

  function toast(msg, isError) {
    let el = document.getElementById('ct-toast');
    if (!el) { el = document.createElement('div'); el.id = 'ct-toast'; el.setAttribute('role', 'status'); document.body.appendChild(el); }
    el.textContent = msg;
    el.className = 'ct-toast show' + (isError ? ' is-error' : '');
    clearTimeout(toast.t);
    toast.t = setTimeout(() => { el.className = 'ct-toast'; }, 4200);
  }

  // Las publicaciones no vencen: no hay nada que marcar en la tarjeta ni que validar antes de publicar
  function decorateCard() {}
  async function confirmPublish() { return true; }

  /* Destacar (solo administración): confirma y llama a feature_property; la base de datos lo exige igual. */
  async function featureProperty(p) {
    if (!isAdminAccount(state.account)) await refresh();
    if (!isAdminAccount(state.account)) { toast('Solo administración puede destacar propiedades.', true); return; }
    if (!window.confirm('¿Destacar «' + p.title + '» durante 30 días? Aparecerá primero en el sitio con la etiqueta «Destacada».')) return;
    const { error } = await supabaseClient.rpc('feature_property', { p_property_id: String(p.id), p_service: null });
    if (error) { toast('No se pudo destacar: ' + (error.message || 'error'), true); return; }
    toast('Propiedad destacada por 30 días.');
    if (typeof loadProperties === 'function') loadProperties();
  }

  async function refresh() {
    state.account = await fetchAccount();
    document.dispatchEvent(new CustomEvent('uno:account', { detail: state.account }));
    return state.account;
  }

  // Apenas hay sesión se carga la cuenta
  supabaseClient.auth.onAuthStateChange((event, session) => {
    if (session && session.user) setTimeout(async () => { await refresh(); if (typeof loadProperties === 'function' && document.getElementById('property-list')) loadProperties(); }, 0);
  });

  window.UnoPublications = {
    refresh, decorateCard, confirmPublish, featureProperty,
    insufficientMessage: () => 'No se pudo publicar. Inténtalo de nuevo.',
    fillLine: () => {}, supportsAutoRenew: false,
    get account() { return state.account; },
  };
})();
