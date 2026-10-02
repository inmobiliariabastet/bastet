/* Publicaciones: contador de gratis del mes, vigencia de 30 días con cuenta regresiva, renovar y renovación automática.
   Reglas (las aplica la base de datos; aquí solo se muestran): 3 publicaciones gratis por mes (se renuevan el día 1 y no se
   acumulan); después cada propiedad nueva cuesta 8 créditos. Cada publicación dura 30 días y debe renovarse: renovar usa
   primero las gratis del mes y, si ya no hay, 8 créditos. La renovación automática (opcional, por propiedad) hace eso sola.
   Usa el cliente global `supabaseClient`; admin.js llama a UnoPublications.refresh() y decorateCard(). */
(function () {
  'use strict';

  const DAY = 86400000;
  const MONTHS = ['enero', 'febrero', 'marzo', 'abril', 'mayo', 'junio', 'julio', 'agosto', 'septiembre', 'octubre', 'noviembre', 'diciembre'];
  const state = { quota: null, supported: false };

  const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const longDate = (iso) => { const d = new Date(iso); return isNaN(d) ? '' : d.getDate() + ' de ' + MONTHS[d.getMonth()]; };
  const dayOfMonth = (iso) => { const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(iso || ''); return m ? (+m[3]) + ' de ' + MONTHS[+m[2] - 1] : ''; };
  const plural = (n, one, many) => (n === 1 ? one : many);

  async function fetchQuota() {
    try {
      const { data, error } = await supabaseClient.rpc('my_publication_quota');
      if (error || !data) return null;          // si el SQL aún no se corrió, nada de esto se muestra
      return data;
    } catch (e) { return null; }
  }

  /* ───────── Contador de gratis ───────── */
  function dots(q) {
    let h = '';
    for (let i = 0; i < q.free_total; i++) h += '<i class="pub-dot' + (i < q.free_left ? ' is-free' : '') + '"></i>';
    return '<span class="pub-dots" aria-hidden="true">' + h + '</span>';
  }

  function chipHtml(q) {
    if (q.exempt) return '<div class="pub-quota-main"><div><b>Administrador</b><span>Publicas y renuevas sin límite y sin costo en créditos.</span></div></div>';
    const left = q.free_left;
    const main = '<div class="pub-quota-main">' + dots(q) +
      '<div><b>Publicaciones gratis este mes: ' + left + ' de ' + q.free_total + '</b>' +
      '<span>Se renuevan el ' + esc(dayOfMonth(q.resets_on)) + ' y vuelven a ' + q.free_total + '. Cada publicación dura ' + (q.validity_days || 30) + ' días y se renueva con una gratis' +
      (left > 0 ? '' : ' (ya no te quedan)') + ' o con ' + q.cost + ' créditos' + (left > 0 ? '' : ' — tu saldo: ' + q.balance) + '.</span></div></div>';
    const buy = left === 0 && q.balance < q.cost ? '<button type="button" class="btn btn-accent btn-sm" data-pub-buy>Comprar créditos</button>' : '';
    return main + buy;
  }

  function renderChip() {
    const el = document.getElementById('pub-quota');
    if (!el) return;
    el.classList.toggle('hidden', !state.quota);
    if (state.quota) el.innerHTML = chipHtml(state.quota);
  }

  // Aviso dentro del formulario "Nueva propiedad" (no aparece al editar)
  function renderBanner() {
    const el = document.getElementById('property-form-pub');
    if (!el) return;
    const modal = document.getElementById('property-form-modal');
    const title = document.getElementById('property-form-title-heading');
    const isNew = modal && !modal.classList.contains('hidden') && title && title.textContent.trim() === 'Nueva propiedad';
    const q = state.quota;
    const wrap = document.getElementById('field-auto-renew-wrap');
    if (wrap) wrap.classList.toggle('hidden', !state.supported);
    if (!isNew || !q || q.exempt) { el.classList.add('hidden'); el.innerHTML = ''; return; }
    el.classList.remove('hidden', 'is-low');
    const days = q.validity_days || 30;
    if (q.free_left > 0) {
      el.innerHTML = '<b>Esta publicación es gratis</b> y dura ' + days + ' días. Te ' + plural(q.free_left, 'queda', 'quedan') + ' ' + q.free_left + ' de ' + q.free_total + ' este mes.';
    } else if (q.balance >= q.cost) {
      el.innerHTML = '<b>Ya usaste tus ' + q.free_total + ' publicaciones gratis de este mes.</b> Esta propiedad costará ' + q.cost + ' créditos (tu saldo: ' + q.balance + '; después de publicar: ' + (q.balance - q.cost) + ') y dura ' + days + ' días.';
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
      ? 'Como administrador publicas y renuevas propiedades sin límite.'
      : 'Publicaciones gratis este mes: ' + q.free_left + ' de ' + q.free_total + ' (se renuevan el ' + dayOfMonth(q.resets_on) + '). Publicar o renovar más cuesta ' + q.cost + ' créditos.';
  }

  /* ───────── Cuenta regresiva de cada publicación ───────── */
  function timeLeft(expiresAt) {
    const ms = new Date(expiresAt).getTime() - Date.now();
    if (ms <= 0) {
      const d = Math.floor(-ms / DAY);
      return { ms, expired: true, text: d >= 1 ? 'Venció hace ' + d + ' ' + plural(d, 'día', 'días') : 'Venció hoy', level: 'bad', pct: 0 };
    }
    const d = Math.floor(ms / DAY);
    const h = Math.floor((ms % DAY) / 3600000);
    const m = Math.floor((ms % 3600000) / 60000);
    const text = d >= 1 ? d + ' ' + plural(d, 'día', 'días') + ' ' + h + ' h' : h + ' h ' + m + ' min';
    return { ms, expired: false, text, level: d < 7 ? 'warn' : 'ok', pct: Math.max(2, Math.min(100, (ms / (30 * DAY)) * 100)), soon: d < 7 };
  }

  function paintLife(life) {
    const card = life.closest('.prop-card');
    const t = timeLeft(life.dataset.expires);
    life.dataset.level = t.level;
    const time = life.querySelector('.prop-life-time');
    if (time) time.textContent = t.expired ? t.text : 'Quedan ' + t.text;
    const bar = life.querySelector('.prop-life-bar i');
    if (bar) bar.style.width = t.pct + '%';
    if (card) {
      card.classList.toggle('is-expired', t.expired);
      const renew = card.querySelector('[data-pub-renew]');
      if (renew) renew.classList.toggle('hidden', !(t.expired || t.soon));
      let badge = card.querySelector('.pub-expired-badge');
      if (t.expired && !badge) {
        badge = document.createElement('span'); badge.className = 'badge b-bad pub-expired-badge'; badge.textContent = 'Vencida · oculta del sitio';
        const ph = card.querySelector('.prop-ph'); if (ph) ph.insertBefore(badge, ph.firstChild.nextSibling);
      } else if (!t.expired && badge) badge.remove();
    }
  }

  function tick() { document.querySelectorAll('.prop-life[data-expires]').forEach(paintLife); }
  setInterval(tick, 30000);

  function decorateCard(card, p) {
    if (!p || !p.expires_at || p.status === 'sold') return;       // sin el SQL (o vendida) la tarjeta queda como antes
    const life = document.createElement('div');
    life.className = 'prop-life';
    life.dataset.expires = p.expires_at;
    const hasAuto = typeof p.auto_renew === 'boolean';
    const failed = hasAuto && p.auto_renew && p.auto_renew_failed_at && new Date(p.expires_at).getTime() < Date.now() + 3600000;
    life.innerHTML =
      '<div class="prop-life-top"><span class="prop-life-label">Vigencia</span><b class="prop-life-time"></b></div>' +
      '<div class="prop-life-bar"><i></i></div>' +
      '<div class="prop-life-date">Hasta el ' + esc(longDate(p.expires_at)) + (p.last_renewed_at ? ' · última renovación ' + esc(longDate(p.last_renewed_at)) : '') + '</div>' +
      (hasAuto
        ? '<label class="ct-toggle pub-auto" title="Se renueva sola 1 hora antes de vencer, con una publicación gratis del mes o con créditos"><input type="checkbox" data-pub-auto' + (p.auto_renew ? ' checked' : '') + '><span class="ct-switch" aria-hidden="true"></span>' +
          '<span class="ct-toggle-text"><b>Renovación automática</b><small>' + (p.auto_renew ? 'Activada: se renueva sola antes de vencer.' : 'Desactivada: tendrás que renovarla tú.') + '</small></span></label>'
        : '') +
      (failed ? '<p class="pub-auto-fail">La renovación automática no pudo cobrar (sin cupo gratis y sin créditos suficientes). Compra créditos y se renovará sola.</p>' : '');
    const actions = card.querySelector('.prop-row-actions');
    if (actions) actions.parentNode.insertBefore(life, actions);
    if (actions) {
      const btn = document.createElement('button');
      btn.type = 'button'; btn.className = 'btn btn-accent btn-sm hidden'; btn.dataset.pubRenew = '1'; btn.textContent = 'Renovar';
      btn.addEventListener('click', (e) => { e.stopPropagation(); renewDialog(p); });
      actions.insertBefore(btn, actions.firstChild);
    }
    const toggle = life.querySelector('[data-pub-auto]');
    if (toggle) {
      toggle.closest('label').addEventListener('click', (e) => e.stopPropagation());
      toggle.addEventListener('change', async () => {
        toggle.disabled = true;
        const { error } = await supabaseClient.from('properties').update({ auto_renew: toggle.checked }).eq('id', p.id);
        toggle.disabled = false;
        if (error) { toggle.checked = !toggle.checked; toast('No se pudo cambiar la renovación automática: ' + error.message, true); return; }
        p.auto_renew = toggle.checked;
        const small = life.querySelector('.ct-toggle-text small');
        if (small) small.textContent = p.auto_renew ? 'Activada: se renueva sola antes de vencer.' : 'Desactivada: tendrás que renovarla tú.';
        toast(p.auto_renew ? 'Renovación automática activada.' : 'Renovación automática desactivada.');
      });
    }
    paintLife(life);
  }

  /* ───────── Renovar ───────── */
  function toast(msg, isError) {
    let el = document.getElementById('ct-toast');
    if (!el) { el = document.createElement('div'); el.id = 'ct-toast'; el.setAttribute('role', 'status'); document.body.appendChild(el); }
    el.textContent = msg;
    el.className = 'ct-toast show' + (isError ? ' is-error' : '');
    clearTimeout(toast.t);
    toast.t = setTimeout(() => { el.className = 'ct-toast'; }, 4200);
  }

  const closeOverlay = () => { const o = document.getElementById('pub-overlay'); if (o) o.remove(); };

  async function renewDialog(p) {
    await refresh();
    const q = state.quota;
    const days = (q && q.validity_days) || 30;
    const exp = new Date(p.expires_at).getTime();
    const base = exp > Date.now() ? exp : Date.now();
    const newExp = new Date(base + days * DAY);
    let how; let canPay = true;
    if (!q) { how = ''; }
    else if (q.exempt) how = '<p>Como administrador, renovar es <b>gratis</b>.</p>';
    else if (q.free_left > 0) how = '<p>Usará <b>1 de tus publicaciones gratis</b> de este mes (te ' + plural(q.free_left - 1, 'quedará', 'quedarán') + ' ' + (q.free_left - 1) + ' de ' + q.free_total + ').</p>';
    else if (q.balance >= q.cost) how = '<p>Ya no te quedan publicaciones gratis este mes: renovar cuesta <b>' + q.cost + ' créditos</b> (tu saldo: ' + q.balance + ' → ' + (q.balance - q.cost) + ').</p>';
    else { canPay = false; how = '<p class="pub-modal-low">No te quedan publicaciones gratis este mes y tu saldo (' + q.balance + ') no alcanza para los ' + q.cost + ' créditos.</p>'; }
    closeOverlay();
    const o = document.createElement('div');
    o.className = 'modal-overlay'; o.id = 'pub-overlay';
    o.innerHTML = '<div class="modal-panel pub-modal" role="dialog" aria-modal="true"><h2>Renovar publicación</h2>' +
      '<p><b>' + esc(p.title) + '</b></p>' + how +
      '<p class="pub-modal-new">Nuevo vencimiento: <b>' + esc(longDate(newExp.toISOString())) + '</b> (' + days + ' días' + (exp > Date.now() ? ' sumados a lo que te queda' : ' desde hoy') + ').</p>' +
      '<p id="pub-modal-error" class="form-error hidden"></p>' +
      '<div class="modal-form-actions"><button type="button" class="btn btn-ghost" data-pub-close>Cancelar</button>' +
      (canPay ? '<button type="button" class="btn btn-accent" id="pub-confirm">Renovar</button>' : '<button type="button" class="btn btn-accent" data-pub-buy>Comprar créditos</button>') + '</div></div>';
    document.body.appendChild(o);
    o.addEventListener('click', (e) => { if (e.target === o || e.target.closest('[data-pub-close]')) closeOverlay(); });
    const confirm = o.querySelector('#pub-confirm');
    if (confirm) confirm.addEventListener('click', async () => {
      confirm.disabled = true; confirm.textContent = 'Renovando…';
      const { error } = await supabaseClient.rpc('renew_property', { p_property_id: p.id });
      if (error) {
        const err = o.querySelector('#pub-modal-error');
        err.textContent = /Saldo insuficiente/i.test(error.message || '') ? insufficientMessage('renovar') : 'No se pudo renovar: ' + (error.message || 'error');
        err.classList.remove('hidden'); confirm.disabled = false; confirm.textContent = 'Reintentar';
        return;
      }
      closeOverlay();
      toast('Publicación renovada por ' + days + ' días.');
      if (typeof loadProperties === 'function') loadProperties();
      refresh();
    });
  }

  function insufficientMessage(action) {
    const q = state.quota;
    const verb = action === 'renovar' ? 'No se renovó' : 'No se publicó';
    return q
      ? verb + ': ya usaste tus ' + q.free_total + ' publicaciones gratis de este mes y tu saldo (' + q.balance + ') no alcanza para los ' + q.cost + ' créditos. Compra créditos en la pestaña Créditos e inténtalo de nuevo.'
      : verb + ': no tienes publicaciones gratis disponibles ni saldo suficiente de créditos. Compra créditos e inténtalo de nuevo.';
  }

  async function refresh() {
    state.quota = await fetchQuota();
    state.supported = !!state.quota;
    renderChip();
    renderBanner();
    fillLine(document.getElementById('credits-pub-line'));
    return state.quota;
  }

  function goBuy() {
    closeOverlay();
    const modal = document.getElementById('property-form-modal');
    if (modal) modal.classList.add('hidden');
    const tab = document.querySelector('.admin-tab[data-tab="credits"]');
    if (tab) tab.click();
  }

  document.addEventListener('click', (e) => {
    if (e.target.closest('[data-pub-buy]')) { goBuy(); return; }
    if (e.target.closest('.admin-tab[data-tab="properties"]') || e.target.closest('#new-property-btn')) refresh();
  });
  document.addEventListener('keydown', (e) => { if (e.key === 'Escape') closeOverlay(); });

  const modal = document.getElementById('property-form-modal');
  if (modal) new MutationObserver(() => { if (!modal.classList.contains('hidden')) refresh(); else renderBanner(); }).observe(modal, { attributes: true, attributeFilter: ['class'] });

  // Apenas hay sesión: se procesan las renovaciones automáticas pendientes y se carga el contador
  supabaseClient.auth.onAuthStateChange((event, session) => {
    if (session && session.user) setTimeout(async () => { try { await supabaseClient.rpc('process_auto_renewals'); } catch (e) { /* sin el SQL */ } refresh(); if (typeof loadProperties === 'function' && document.getElementById('property-list')) loadProperties(); }, 0);
  });

  window.UnoPublications = { refresh, fillLine, decorateCard, insufficientMessage: () => insufficientMessage('publicar'), get quota() { return state.quota; }, get supportsAutoRenew() { return state.supported; } };
})();
