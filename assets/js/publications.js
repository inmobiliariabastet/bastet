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
  /* Tarjeta "Publicaciones gratis este mes" (panel > Propiedades). Datos reales de my_publication_quota():
     free_left / free_total (cupo), resets_on (renovación), validity_days (duración), cost (créditos por publicar o renovar), balance (saldo). */
  const ICON = {
    doc: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M14 3H7a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V8z"/><path d="M14 3v5h5"/><path d="M9.5 15.5V12l2.5-2 2.5 2v3.5zM9 18h6"/></svg>',
    calendar: '<svg viewBox="0 0 24 24" aria-hidden="true"><rect x="3.5" y="5" width="17" height="15.5" rx="2.5"/><path d="M3.5 10h17M8 3v4M16 3v4M8 14h.01M12 14h.01M16 14h.01M8 17.5h.01M12 17.5h.01"/></svg>',
    info: '<svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="12" r="9"/><path d="M12 11v5.5M12 7.7v.01"/></svg>',
    renew: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M20 12a8 8 0 1 1-2.4-5.7M20 4v4h-4"/></svg>',
    coins: '<svg viewBox="0 0 24 24" aria-hidden="true"><ellipse cx="12" cy="6" rx="7" ry="3"/><path d="M5 6v6c0 1.7 3.1 3 7 3s7-1.3 7-3V6M5 12v6c0 1.7 3.1 3 7 3s7-1.3 7-3v-6"/></svg>',
    arrow: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M5 12h14M13 6l6 6-6 6"/></svg>',
  };

  function circles(q) {
    let h = '';
    for (let i = 0; i < q.free_total; i++) h += '<i class="pq-dot' + (i < q.free_left ? ' is-on' : '') + '"></i>';
    return '<span class="pq-dots" aria-hidden="true">' + h + '</span>';
  }

  function chipHtml(q) {
    const days = q.validity_days || 30;
    if (q.exempt) {
      return '<div class="pq-main"><div class="pq-top"><span class="pq-badge">' + ICON.doc + '</span><div class="pq-text"><h2 class="pq-title">Administrador</h2>' +
        '<p class="pq-renew">Publicas y renuevas propiedades <b>sin límite y sin costo en créditos</b>.</p></div></div>' +
        '<div class="pq-notes"><p class="pq-note"><span class="pq-note-ico">' + ICON.info + '</span><span>Cada publicación dura ' + days + ' días en UNO Marketplace Inmobiliario.</span></p></div></div>';
    }
    const credits = q.balance === 1 ? 'crédito disponible' : 'créditos disponibles';
    return '<div class="pq-main">' +
        '<div class="pq-top">' +
          '<span class="pq-badge">' + ICON.doc + '</span>' +
          '<div class="pq-count" aria-label="' + q.free_left + ' de ' + q.free_total + ' publicaciones gratis disponibles"><div class="pq-num"><b>' + q.free_left + '</b><span>/ ' + q.free_total + '</span></div>' + circles(q) + '</div>' +
          '<div class="pq-text"><h2 class="pq-title">Publicaciones gratis este mes</h2>' +
            '<p class="pq-renew"><span class="pq-ico">' + ICON.calendar + '</span><span>Tus <b>' + q.free_total + ' publicaciones gratis</b> se renuevan el ' + esc(dayOfMonth(q.resets_on)) + '.</span></p></div>' +
        '</div>' +
        '<div class="pq-notes">' +
          '<p class="pq-note"><span class="pq-note-ico">' + ICON.info + '</span><span>Cada publicación dura ' + days + ' días en UNO Marketplace Inmobiliario.</span></p>' +
          '<p class="pq-note"><span class="pq-note-ico">' + ICON.renew + '</span><span>Puedes renovar una publicación con un cupo gratis o con ' + q.cost + ' créditos.</span></p>' +
        '</div>' +
      '</div>' +
      '<aside class="pq-credits" aria-label="Créditos">' +
        '<div class="pq-credits-top"><span class="pq-coin">' + ICON.coins + '</span><div><b class="pq-balance">' + q.balance + '</b><span>' + credits + '</span></div></div>' +
        '<p class="pq-cost">Renueva una publicación por <b>' + q.cost + ' créditos</b>.</p>' +
        '<button type="button" class="pq-btn" data-pub-buy><span>Ver opciones</span>' + ICON.arrow + '</button>' +
      '</aside>';
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

  /* Confirmación antes de publicar una propiedad NUEVA que ya no entra en el cupo gratis: pide aprobar el descuento de créditos.
     Devuelve una promesa: true = seguir con la publicación, false = el agente canceló (o no le alcanzan los créditos). */
  async function confirmPublish(title) {
    await refresh();
    const q = state.quota;
    if (!q || q.exempt || q.free_left > 0) return true;       // sin el SQL, administrador o con cupo gratis: no hay nada que aprobar
    const days = q.validity_days || 30;
    const enough = q.balance >= q.cost;
    closeOverlay();
    return new Promise((resolve) => {
      const o = document.createElement('div');
      o.className = 'modal-overlay'; o.id = 'pub-overlay';
      o.innerHTML = '<div class="modal-panel pub-modal" role="dialog" aria-modal="true" aria-labelledby="pub-confirm-title"><h2 id="pub-confirm-title">Confirmar publicación</h2>' +
        '<p><b>' + esc(title) + '</b></p>' +
        '<p>Ya usaste tus ' + q.free_total + ' publicaciones gratis de este mes, por eso esta propiedad se publica con créditos.</p>' +
        (enough
          ? '<p class="pub-modal-new">Se descontarán <b>' + q.cost + ' créditos</b> de tu saldo (' + q.balance + ' → ' + (q.balance - q.cost) + ') y la publicación durará <b>' + days + ' días</b>.</p>' +
            '<p class="pub-modal-fine">El descuento no se devuelve si luego eliminas la propiedad.</p>'
          : '<p class="pub-modal-low">Tu saldo (' + q.balance + ') no alcanza para los ' + q.cost + ' créditos que cuesta publicar. Compra créditos para continuar.</p>') +
        '<div class="modal-form-actions"><button type="button" class="btn btn-ghost" data-pub-cancel>Cancelar</button>' +
        (enough ? '<button type="button" class="btn btn-accent" id="pub-confirm-ok">Publicar por ' + q.cost + ' créditos</button>'
                : '<button type="button" class="btn btn-accent" data-pub-buy>Comprar créditos</button>') + '</div></div>';
      document.body.appendChild(o);
      const done = (ok) => { document.removeEventListener('keydown', onKey, true); closeOverlay(); resolve(ok); };
      const onKey = (e) => { if (e.key === 'Escape') { e.stopPropagation(); done(false); } };
      document.addEventListener('keydown', onKey, true);
      o.addEventListener('click', (e) => { if (e.target === o || e.target.closest('[data-pub-cancel]')) done(false); else if (e.target.closest('[data-pub-buy]')) { document.removeEventListener('keydown', onKey, true); resolve(false); } });
      const ok = o.querySelector('#pub-confirm-ok');
      if (ok) { ok.addEventListener('click', () => done(true)); ok.focus(); }
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

  window.UnoPublications = { refresh, fillLine, decorateCard, confirmPublish, insufficientMessage: () => insufficientMessage('publicar'), get quota() { return state.quota; }, get supportsAutoRenew() { return state.supported; } };
})();
