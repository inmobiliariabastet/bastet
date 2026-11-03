/* Cuenta y publicaciones. Desde 2026-11-03 ya no hay planes ni suscripciones: publicar es libre, sin tope ni vencimiento, y solo
   administración destaca propiedades. Esta pieza carga el estado de la cuenta (RPC my_account, supabase/retire-subscriptions.sql) y lo
   publica en `UnoPublications.account` y con el evento `uno:account`. admin.js llama a refresh(), decorateCard(), confirmPublish() y
   featureProperty(). Usa el cliente global `supabaseClient`. */
(function () {
  'use strict';

  const state = { account: null };
  const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

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

  // Las publicaciones no vencen: no hay nada que marcar en la tarjeta
  function decorateCard() {}

  /* Contrato marco (supabase/connections.sql): si las conexiones están activas, antes de publicar (y tras cada versión nueva) el titular lo lee y
     lo acepta. Devuelve una promesa: true = ya está aceptado, false = lo cerró sin aceptar. La base de datos lo exige igual. */
  async function ensureFramework() {
    let f = null;
    try { const { data, error } = await supabaseClient.rpc('my_framework'); if (!error) f = data; } catch (e) { /* sin el SQL no hay contrato */ }
    if (!f || !f.required || f.accepted) return true;
    return new Promise((resolve) => {
      const prev = document.getElementById('fw-overlay'); if (prev) prev.remove();
      const o = document.createElement('div');
      o.className = 'modal-overlay'; o.id = 'fw-overlay';
      o.innerHTML = '<div class="modal-panel fw-panel" role="dialog" aria-modal="true" aria-labelledby="fw-title"><h2 id="fw-title">Contrato marco de Bastet</h2>' +
        '<p class="fw-hint">Para publicar propiedades debes leer y aceptar este contrato. Lo aceptas una sola vez.</p>' +
        '<div class="fw-text" tabindex="0">' + esc(f.text) + '</div>' +
        '<label class="fw-check"><input type="checkbox" id="fw-ok"> He leído y acepto el contrato marco de Bastet.</label>' +
        '<p id="fw-err" class="form-error hidden"></p>' +
        '<div class="modal-form-actions"><button type="button" class="btn btn-ghost" id="fw-cancel">Ahora no</button><button type="button" class="btn btn-accent" id="fw-accept" disabled>Aceptar y continuar</button></div></div>';
      document.body.appendChild(o);
      const done = (v) => { o.remove(); resolve(v); };
      const ok = o.querySelector('#fw-ok'), go = o.querySelector('#fw-accept');
      ok.addEventListener('change', () => { go.disabled = !ok.checked; });
      o.querySelector('#fw-cancel').addEventListener('click', () => done(false));
      go.addEventListener('click', async () => {
        go.disabled = true; go.textContent = 'Guardando…';
        const { error } = await supabaseClient.rpc('accept_framework_contract', { p_version: f.version });
        if (error) { const er = o.querySelector('#fw-err'); er.textContent = error.message || 'No se pudo registrar tu aceptación.'; er.classList.remove('hidden'); go.disabled = false; go.textContent = 'Aceptar y continuar'; return; }
        done(true);
      });
    });
  }
  /* Acuerdo de anfitrión (supabase/host-agreement.sql): quien publica una estadía temporal lo acepta una vez por versión. */
  async function ensureHostAgreement() {
    let f = null;
    try { const { data, error } = await supabaseClient.rpc('my_host_agreement'); if (!error) f = data; } catch (e) { /* sin el SQL no hay acuerdo */ }
    if (!f || !f.required || f.accepted) return true;
    return new Promise((resolve) => {
      const prev = document.getElementById('fw-overlay'); if (prev) prev.remove();
      const o = document.createElement('div');
      o.className = 'modal-overlay'; o.id = 'fw-overlay';
      o.innerHTML = '<div class="modal-panel fw-panel" role="dialog" aria-modal="true" aria-labelledby="fw-title"><h2 id="fw-title">Acuerdo de anfitrión de Bastet</h2>' +
        '<p class="fw-hint">Para publicar estadías temporales debes leer y aceptar este acuerdo. Lo aceptas una sola vez.</p>' +
        '<div class="fw-text" tabindex="0">' + esc(f.text) + '</div>' +
        '<label class="fw-check"><input type="checkbox" id="fw-ok"> He leído y acepto el acuerdo de anfitrión de Bastet.</label>' +
        '<p id="fw-err" class="form-error hidden"></p>' +
        '<div class="modal-form-actions"><button type="button" class="btn btn-ghost" id="fw-cancel">Ahora no</button><button type="button" class="btn btn-accent" id="fw-accept" disabled>Aceptar y continuar</button></div></div>';
      document.body.appendChild(o);
      const done = (v) => { o.remove(); resolve(v); };
      const ok = o.querySelector('#fw-ok'), go = o.querySelector('#fw-accept');
      ok.addEventListener('change', () => { go.disabled = !ok.checked; });
      o.querySelector('#fw-cancel').addEventListener('click', () => done(false));
      go.addEventListener('click', async () => {
        go.disabled = true; go.textContent = 'Guardando…';
        const { error } = await supabaseClient.rpc('accept_host_agreement', { p_version: f.version });
        if (error) { const er = o.querySelector('#fw-err'); er.textContent = error.message || 'No se pudo registrar tu aceptación.'; er.classList.remove('hidden'); go.disabled = false; go.textContent = 'Aceptar y continuar'; return; }
        done(true);
      });
    });
  }
  // Una estadía temporal acepta el acuerdo de anfitrión; las demás operaciones, el contrato marco de conexiones
  async function confirmPublish(title, operation) { return operation === 'temporal' ? ensureHostAgreement() : ensureFramework(); }

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
    refresh, decorateCard, confirmPublish, featureProperty, ensureFramework, ensureHostAgreement,
    insufficientMessage: () => 'No se pudo publicar. Inténtalo de nuevo.',
    fillLine: () => {}, supportsAutoRenew: false,
    get account() { return state.account; },
  };
})();
