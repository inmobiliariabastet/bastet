/* Publicaciones gratis del mes: contador del panel y avisos al crear una propiedad.
   Regla (la aplica la base de datos al crear la propiedad, aquí solo se muestra): 3 publicaciones gratis por mes, se renuevan
   el día 1 y vuelven a 3 (no se acumulan); después, cada propiedad nueva cuesta 8 créditos. Los administradores no pagan.
   Usa el cliente global `supabaseClient`; admin.js llama a UnoPublications.refresh() después de guardar. */
(function () {
  'use strict';

  const MONTHS = ['enero', 'febrero', 'marzo', 'abril', 'mayo', 'junio', 'julio', 'agosto', 'septiembre', 'octubre', 'noviembre', 'diciembre'];
  const state = { quota: null };

  const longDate = (iso) => { const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(iso || ''); return m ? (+m[3]) + ' de ' + MONTHS[+m[2] - 1] : ''; };
  const plural = (n, one, many) => (n === 1 ? one : many);

  async function fetchQuota() {
    try {
      const { data, error } = await supabaseClient.rpc('my_publication_quota');
      if (error || !data) return null;          // si el SQL aún no se corrió, el contador simplemente no se muestra
      return data;
    } catch (e) { return null; }
  }

  function dots(q) {
    let h = '';
    for (let i = 0; i < q.free_total; i++) h += '<i class="pub-dot' + (i < q.free_left ? ' is-free' : '') + '"></i>';
    return '<span class="pub-dots" aria-hidden="true">' + h + '</span>';
  }

  function chipHtml(q) {
    if (q.exempt) return '<div class="pub-quota-main"><b>Administrador</b><span>Publicas sin límite y sin costo en créditos.</span></div>';
    const left = q.free_left;
    const main = '<div class="pub-quota-main">' + dots(q) +
      '<div><b>Publicaciones gratis este mes: ' + left + ' de ' + q.free_total + '</b>' +
      '<span>Se renuevan el ' + esc(longDate(q.resets_on)) + ' y vuelven a ' + q.free_total + '. ' +
      (left > 0 ? 'Después, cada propiedad nueva cuesta ' + q.cost + ' créditos.' : 'Cada propiedad nueva ahora cuesta <b>' + q.cost + ' créditos</b> (tu saldo: ' + q.balance + ').') + '</span></div></div>';
    const buy = left === 0 && q.balance < q.cost
      ? '<button type="button" class="btn btn-accent btn-sm" data-pub-buy>Comprar créditos</button>' : '';
    return main + buy;
  }

  const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

  function renderChip() {
    const el = document.getElementById('pub-quota');
    if (!el) return;
    const q = state.quota;
    el.classList.toggle('hidden', !q);
    if (q) el.innerHTML = chipHtml(q);
  }

  // Aviso dentro del formulario "Nueva propiedad" (no aparece al editar)
  function renderBanner() {
    const el = document.getElementById('property-form-pub');
    if (!el) return;
    const modal = document.getElementById('property-form-modal');
    const title = document.getElementById('property-form-title-heading');
    const isNew = modal && !modal.classList.contains('hidden') && title && title.textContent.trim() === 'Nueva propiedad';
    const q = state.quota;
    if (!isNew || !q || q.exempt) { el.classList.add('hidden'); el.innerHTML = ''; return; }
    el.classList.remove('hidden', 'is-low');
    if (q.free_left > 0) {
      el.innerHTML = '<b>Esta publicación es gratis.</b> Te ' + plural(q.free_left, 'queda', 'quedan') + ' ' + q.free_left + ' de ' + q.free_total + ' este mes.';
    } else if (q.balance >= q.cost) {
      el.innerHTML = '<b>Ya usaste tus ' + q.free_total + ' publicaciones gratis de este mes.</b> Esta propiedad costará ' + q.cost + ' créditos (tu saldo: ' + q.balance + '; después de publicar: ' + (q.balance - q.cost) + ').';
    } else {
      el.classList.add('is-low');
      el.innerHTML = '<b>No puedes publicar todavía.</b> Ya usaste tus ' + q.free_total + ' publicaciones gratis y tu saldo (' + q.balance + ') no alcanza para los ' + q.cost + ' créditos. <button type="button" class="ct-link" data-pub-buy>Comprar créditos</button>';
    }
  }

  function fillLine(el) {
    if (!el) return;
    const q = state.quota;
    if (!q) { el.textContent = ''; return; }
    el.textContent = q.exempt
      ? 'Como administrador publicas propiedades sin límite.'
      : 'Publicaciones gratis este mes: ' + q.free_left + ' de ' + q.free_total + ' (se renuevan el ' + longDate(q.resets_on) + '). Cada propiedad extra cuesta ' + q.cost + ' créditos.';
  }

  async function refresh() {
    state.quota = await fetchQuota();
    renderChip();
    renderBanner();
    fillLine(document.getElementById('credits-pub-line'));
    return state.quota;
  }

  function insufficientMessage() {
    const q = state.quota;
    return q
      ? 'No se publicó: ya usaste tus ' + q.free_total + ' publicaciones gratis de este mes y tu saldo (' + q.balance + ') no alcanza para los ' + q.cost + ' créditos. Compra créditos en la pestaña Créditos e inténtalo de nuevo.'
      : 'No se publicó: no tienes publicaciones gratis disponibles ni saldo suficiente de créditos. Compra créditos e inténtalo de nuevo.';
  }

  function goBuy() {
    const modal = document.getElementById('property-form-modal');
    if (modal) modal.classList.add('hidden');
    const tab = document.querySelector('.admin-tab[data-tab="credits"]');
    if (tab) tab.click();
  }

  document.addEventListener('click', (e) => {
    if (e.target.closest('[data-pub-buy]')) { goBuy(); return; }
    if (e.target.closest('.admin-tab[data-tab="properties"]') || e.target.closest('#new-property-btn')) refresh();
  });

  // El aviso del formulario se actualiza cuando el formulario se abre o se cierra
  const modal = document.getElementById('property-form-modal');
  if (modal) new MutationObserver(() => { if (!modal.classList.contains('hidden')) refresh(); else renderBanner(); }).observe(modal, { attributes: true, attributeFilter: ['class'] });

  // Apenas hay sesión, se carga el contador
  supabaseClient.auth.onAuthStateChange((event, session) => { if (session && session.user) setTimeout(refresh, 0); });

  window.UnoPublications = { refresh, fillLine, insufficientMessage, get quota() { return state.quota; } };
})();
