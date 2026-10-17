/* Publicaciones y plan: tarjeta con el plan, las propiedades activas y los destacados usados; vigencia de cada publicación
   (hasta el fin del periodo pagado) y aviso al publicar. Las reglas las aplica la base de datos (supabase/subscriptions.sql);
   aquí solo se muestran. Usa el cliente global `supabaseClient`; admin.js llama a UnoPublications.refresh(), decorateCard()
   y confirmPublish(). Publica el estado del plan en `UnoPublications.subscription` y con el evento `uno:subscription`. */
(function () {
  'use strict';

  const DAY = 86400000;
  const MONTHS = ['enero', 'febrero', 'marzo', 'abril', 'mayo', 'junio', 'julio', 'agosto', 'septiembre', 'octubre', 'noviembre', 'diciembre'];
  const state = { sub: null };

  const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const longDate = (iso) => { const d = new Date(iso); return isNaN(d) ? '' : d.getDate() + ' de ' + MONTHS[d.getMonth()]; };
  const plural = (n, one, many) => (n === 1 ? one : many);

  async function fetchSubscription() {
    try {
      const { data, error } = await supabaseClient.rpc('my_subscription');
      if (error || !data) return null;          // si el SQL de suscripciones aún no se corrió, nada de esto se muestra
      return data;
    } catch (e) { return null; }
  }

  const ICON = {
    doc: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M14 3H7a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V8z"/><path d="M14 3v5h5"/><path d="M9.5 15.5V12l2.5-2 2.5 2v3.5zM9 18h6"/></svg>',
    calendar: '<svg viewBox="0 0 24 24" aria-hidden="true"><rect x="3.5" y="5" width="17" height="15.5" rx="2.5"/><path d="M3.5 10h17M8 3v4M16 3v4M8 14h.01M12 14h.01M16 14h.01M8 17.5h.01M12 17.5h.01"/></svg>',
    info: '<svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="12" r="9"/><path d="M12 11v5.5M12 7.7v.01"/></svg>',
    star: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M12 3.5l2.6 5.3 5.9.9-4.3 4.1 1 5.8L12 16.8 6.8 19.6l1-5.8-4.3-4.1 5.9-.9z"/></svg>',
    arrow: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M5 12h14M13 6l6 6-6 6"/></svg>',
  };

  const hasPlan = (s) => !!s && (s.status === 'active' || s.status === 'canceling');
  const isAdminSub = (s) => !!s && s.exempt === true;

  function circles(used, total) {
    let h = '';
    const n = Math.min(total, 15);                       // más de 15 puntos no caben: se resume con el número
    for (let i = 0; i < n; i++) h += '<i class="pq-dot' + (total <= 15 && i < used ? ' is-on' : '') + '"></i>';
    return total <= 15 ? '<span class="pq-dots" aria-hidden="true">' + h + '</span>' : '';
  }

  /* ───────── Tarjeta del plan (panel > Propiedades) ───────── */
  function chipHtml(s) {
    if (isAdminSub(s)) {
      return '<div class="pq-main"><div class="pq-top"><span class="pq-badge">' + ICON.doc + '</span><div class="pq-text"><h2 class="pq-title">Administrador</h2>' +
        '<p class="pq-renew">Publicas y destacas propiedades <b>sin plan ni límites</b>.</p></div></div></div>';
    }
    if (!hasPlan(s)) {
      const expired = s && s.status === 'expired';
      return '<div class="pq-main"><div class="pq-top"><span class="pq-badge">' + ICON.doc + '</span><div class="pq-text">' +
        '<h2 class="pq-title">' + (expired ? (s.source === 'trial' ? 'Tu prueba gratuita terminó' : 'Tu plan venció') : 'Aún no tienes un plan') + '</h2>' +
        '<p class="pq-renew">' + (expired ? 'Tus propiedades dejan de verse al terminar el periodo pagado. ' : '') + 'Elige un plan para publicar y destacar propiedades.</p></div></div></div>' +
        '<aside class="pq-credits" aria-label="Plan"><button type="button" class="pq-btn" data-pub-buy><span>' + (expired ? 'Renovar mi plan' : 'Ver planes') + '</span>' + ICON.arrow + '</button></aside>';
    }
    const pl = s.plan, u = s.usage;
    const left = Math.max(pl.max_active_properties - u.active_properties, 0);
    const days = Math.max(Math.ceil((new Date(s.period_end).getTime() - Date.now()) / DAY), 0);
    return '<div class="pq-main">' +
        '<div class="pq-top">' +
          '<span class="pq-badge">' + ICON.doc + '</span>' +
          '<div class="pq-count" aria-label="' + u.active_properties + ' de ' + pl.max_active_properties + ' propiedades activas"><div class="pq-num"><b>' + u.active_properties + '</b><span>/ ' + pl.max_active_properties + '</span></div>' + circles(u.active_properties, pl.max_active_properties) + '</div>' +
          '<div class="pq-text"><h2 class="pq-title">' + (s.source === 'trial' ? 'Prueba gratuita · ' + esc(pl.name) : 'Plan ' + esc(pl.name)) + '</h2>' +
            '<p class="pq-renew"><span class="pq-ico">' + ICON.calendar + '</span><span>Propiedades activas. ' + (left > 0 ? 'Te ' + plural(left, 'queda', 'quedan') + ' <b>' + left + '</b> ' + plural(left, 'cupo', 'cupos') + '. ' : '<b>Llegaste al límite</b> de tu plan. ') +
            (s.source === 'trial' ? 'Tu prueba termina el ' : s.status === 'canceling' ? 'No se renovará: termina el ' : 'Vigente hasta el ') + '<b>' + esc(longDate(s.period_end)) + '</b> (' + days + ' ' + plural(days, 'día', 'días') + ').</span></p></div>' +
        '</div>' +
        '<div class="pq-notes">' +
          '<p class="pq-note"><span class="pq-note-ico">' + ICON.info + '</span><span>Tus propiedades se muestran en Bastet hasta el fin del periodo pagado. Vendidas o vencidas no ocupan cupo.</span></p>' +
        '</div>' +
      '</div>' +
      '<aside class="pq-credits" aria-label="Destacados">' +
        '<div class="pq-credits-top"><span class="pq-coin">' + ICON.star + '</span><div><b class="pq-balance">' + Math.max(pl.max_featured_per_period - u.featured_used, 0) + '</b><span>' + plural(pl.max_featured_per_period - u.featured_used, 'destacado disponible', 'destacados disponibles') + '</span></div></div>' +
        '<p class="pq-cost">Usaste <b>' + u.featured_used + ' de ' + pl.max_featured_per_period + '</b> destacados este periodo.</p>' +
        '<button type="button" class="pq-btn" data-pub-buy><span>Mi suscripción</span>' + ICON.arrow + '</button>' +
      '</aside>';
  }

  function renderChip() {
    const el = document.getElementById('pub-quota');
    if (!el) return;
    el.classList.toggle('hidden', !state.sub);
    if (state.sub) el.innerHTML = chipHtml(state.sub);
  }

  // Aviso dentro del formulario "Nueva propiedad" (no aparece al editar)
  function renderBanner() {
    const el = document.getElementById('property-form-pub');
    if (!el) return;
    const modal = document.getElementById('property-form-modal');
    const title = document.getElementById('property-form-title-heading');
    const isNew = modal && !modal.classList.contains('hidden') && title && title.textContent.trim() === 'Nueva propiedad';
    const s = state.sub;
    if (!isNew || !s || isAdminSub(s)) { el.classList.add('hidden'); el.innerHTML = ''; return; }
    el.classList.remove('hidden', 'is-low');
    if (!hasPlan(s)) {
      el.classList.add('is-low');
      el.innerHTML = '<b>No puedes publicar todavía.</b> ' + (s.status === 'expired' ? 'Tu plan venció.' : 'Necesitas un plan activo.') + ' <button type="button" class="ct-link" data-pub-buy>Ver planes</button>';
      return;
    }
    const used = s.usage.active_properties, max = s.plan.max_active_properties;
    if (used >= max) {
      el.classList.add('is-low');
      el.innerHTML = '<b>Llegaste al límite de ' + max + ' propiedades activas</b> del plan ' + esc(s.plan.name) + '. Marca alguna como vendida o cambia de plan. <button type="button" class="ct-link" data-pub-buy>Ver planes</button>';
    } else {
      el.innerHTML = 'Esta será tu propiedad activa <b>' + (used + 1) + ' de ' + max + '</b> del plan ' + esc(s.plan.name) + '. Se mantiene publicada mientras ' + (s.source === 'trial' ? 'dure tu prueba gratuita (hasta el ' : 'tu suscripción esté vigente (hasta el ') + '<b>' + esc(longDate(s.period_end)) + '</b>).';
    }
  }

  /* Las publicaciones están activas mientras el plan (o la prueba de 7 días) esté vigente: no hay cuenta regresiva por
     propiedad. Solo si el plan venció la tarjeta se marca como oculta del sitio. */
  function decorateCard(card, p) {
    if (!p || !p.expires_at || p.status === 'sold') return;       // sin el SQL (o vendida) la tarjeta queda como antes
    const expired = new Date(p.expires_at).getTime() <= Date.now();
    card.classList.toggle('is-expired', expired);
    if (!expired || card.querySelector('.pub-expired-badge')) return;
    const badge = document.createElement('span'); badge.className = 'badge b-bad pub-expired-badge'; badge.textContent = 'Oculta del sitio · suscripción vencida';
    const ph = card.querySelector('.prop-ph'); if (ph && ph.firstChild) ph.insertBefore(badge, ph.firstChild.nextSibling);
  }

  /* ───────── Ventanas ───────── */
  function toast(msg, isError) {
    let el = document.getElementById('ct-toast');
    if (!el) { el = document.createElement('div'); el.id = 'ct-toast'; el.setAttribute('role', 'status'); document.body.appendChild(el); }
    el.textContent = msg;
    el.className = 'ct-toast show' + (isError ? ' is-error' : '');
    clearTimeout(toast.t);
    toast.t = setTimeout(() => { el.className = 'ct-toast'; }, 4200);
  }

  const closeOverlay = () => { const o = document.getElementById('pub-overlay'); if (o) o.remove(); };

  function openOverlay(html) {
    closeOverlay();
    const o = document.createElement('div');
    o.className = 'modal-overlay'; o.id = 'pub-overlay';
    o.innerHTML = '<div class="modal-panel pub-modal" role="dialog" aria-modal="true">' + html + '</div>';
    document.body.appendChild(o);
    o.addEventListener('click', (e) => { if (e.target === o || e.target.closest('[data-pub-close]')) closeOverlay(); });
    return o;
  }

  async function renewDialog(p) {
    await refresh();
    const s = state.sub;
    if (!isAdminSub(s) && !hasPlan(s)) {
      const o = openOverlay('<h2>Renovar publicación</h2><p><b>' + esc(p.title) + '</b></p><p class="pub-modal-low">Tu plan no está vigente. Renueva tu suscripción y tus propiedades vuelven a mostrarse.</p>' +
        '<div class="modal-form-actions"><button type="button" class="btn btn-ghost" data-pub-close>Cerrar</button><button type="button" class="btn btn-accent" data-pub-buy>Ver planes</button></div>');
      return o;
    }
    const until = isAdminSub(s) ? null : s.period_end;
    const o = openOverlay('<h2>Renovar publicación</h2><p><b>' + esc(p.title) + '</b></p>' +
      '<p>' + (until ? 'Se mostrará hasta el <b>' + esc(longDate(until)) + '</b> (fin del periodo de tu plan). No tiene costo adicional.' : 'Como administrador, renovar es gratis.') + '</p>' +
      '<p id="pub-modal-error" class="form-error hidden"></p>' +
      '<div class="modal-form-actions"><button type="button" class="btn btn-ghost" data-pub-close>Cancelar</button><button type="button" class="btn btn-accent" id="pub-confirm">Renovar</button></div>');
    const confirm = o.querySelector('#pub-confirm');
    confirm.addEventListener('click', async () => {
      confirm.disabled = true; confirm.textContent = 'Renovando…';
      const { error } = await supabaseClient.rpc('renew_property', { p_property_id: p.id });
      if (error) {
        const err = o.querySelector('#pub-modal-error');
        err.textContent = 'No se renovó: ' + (error.message || 'error');
        err.classList.remove('hidden'); confirm.disabled = false; confirm.textContent = 'Reintentar';
        return;
      }
      closeOverlay();
      toast('Publicación renovada.');
      if (typeof loadProperties === 'function') loadProperties();
      refresh();
    });
  }

  /* Antes de publicar una propiedad NUEVA: sin plan o con el cupo lleno no se deja avanzar (la base de datos lo exige igual).
     Devuelve una promesa: true = seguir, false = no se puede publicar. */
  async function confirmPublish() {
    await refresh();
    const s = state.sub;
    if (!s || isAdminSub(s)) return true;               // sin el SQL o administrador: nada que validar aquí
    if (!hasPlan(s)) {
      openOverlay('<h2>Necesitas un plan para publicar</h2><p>' + (s.status === 'expired' ? 'Tu plan venció.' : 'Todavía no tienes un plan activo.') + ' Elige uno y un administrador confirmará tu pago.</p>' +
        '<div class="modal-form-actions"><button type="button" class="btn btn-ghost" data-pub-close>Cerrar</button><button type="button" class="btn btn-accent" data-pub-buy>Ver planes</button></div>');
      return false;
    }
    if (s.usage.active_properties >= s.plan.max_active_properties) {
      openOverlay('<h2>Llegaste al límite de tu plan</h2><p>El plan <b>' + esc(s.plan.name) + '</b> permite <b>' + s.plan.max_active_properties + '</b> propiedades activas y ya tienes ' + s.usage.active_properties + '. Marca alguna como vendida o cambia a un plan mayor.</p>' +
        '<div class="modal-form-actions"><button type="button" class="btn btn-ghost" data-pub-close>Cerrar</button><button type="button" class="btn btn-accent" data-pub-buy>Ver planes</button></div>');
      return false;
    }
    return true;
  }

  /* Destacar una propiedad desde su tarjeta: confirma cuánto cupo se usa y llama a feature_property (la base de datos aplica el límite
     del plan: 1, 3 o 3 destacados por periodo; el administrador no tiene límite). */
  async function featureProperty(p) {
    await refresh();
    const s = state.sub;
    const admin = isAdminSub(s);
    const buy = '<button type="button" class="btn btn-accent" data-pub-buy>Ver planes</button>';
    const close = '<button type="button" class="btn btn-ghost" data-pub-close>Cerrar</button>';
    if (!admin && !hasPlan(s)) {
      openOverlay('<h2>Necesitas un plan para destacar</h2><p>Destacar pone tu propiedad primero en el sitio con la etiqueta «Destacada». Elige un plan y un administrador confirmará tu pago.</p><div class="modal-form-actions">' + close + buy + '</div>');
      return;
    }
    const max = admin ? Infinity : s.plan.max_featured_per_period;
    const left = admin ? Infinity : max - s.usage.featured_used;
    if (left <= 0) {
      openOverlay('<h2>Ya usaste tus destacados</h2><p>Tu plan <b>' + esc(s.plan.name) + '</b> incluye <b>' + max + '</b> ' + plural(max, 'destacado', 'destacados') + ' por periodo y ya los usaste. Se renuevan cuando renueves tu plan, o puedes cambiar a un plan con más destacados.</p><div class="modal-form-actions">' + close + buy + '</div>');
      return;
    }
    const o = openOverlay('<h2>Destacar propiedad</h2><p><b>' + esc(p.title) + '</b></p>' +
      '<p>Aparecerá primero en el sitio con la etiqueta <b>Destacada</b> durante <b>30 días</b>. ' + (admin ? 'Como administrador no gastas cupo.' : 'Usará <b>1</b> de tus <b>' + left + '</b> ' + plural(left, 'destacado disponible', 'destacados disponibles') + ' de este periodo.') + '</p>' +
      '<p id="pub-modal-error" class="form-error hidden"></p>' +
      '<div class="modal-form-actions"><button type="button" class="btn btn-ghost" data-pub-close>Cancelar</button><button type="button" class="btn btn-accent" id="pub-feature-go">Destacar ahora</button></div>');
    const go = o.querySelector('#pub-feature-go');
    go.addEventListener('click', async () => {
      go.disabled = true; go.textContent = 'Destacando…';
      const { error } = await supabaseClient.rpc('feature_property', { p_property_id: String(p.id), p_service: null });
      if (error) {
        const err = o.querySelector('#pub-modal-error');
        err.textContent = 'No se pudo destacar: ' + (error.message || 'error');
        err.classList.remove('hidden'); go.disabled = false; go.textContent = 'Reintentar';
        return;
      }
      closeOverlay();
      toast('Propiedad destacada por 30 días.');
      if (typeof loadProperties === 'function') loadProperties();
      refresh();
    });
  }

  async function refresh() {
    state.sub = await fetchSubscription();
    renderChip();
    renderBanner();
    document.dispatchEvent(new CustomEvent('uno:subscription', { detail: state.sub }));
    return state.sub;
  }

  function goBuy() {
    closeOverlay();
    const modal = document.getElementById('property-form-modal');
    if (modal) modal.classList.add('hidden');
    const tab = document.querySelector('.admin-tab[data-tab="subscription"]');
    if (tab) tab.click();
  }

  document.addEventListener('click', (e) => {
    if (e.target.closest('[data-pub-buy]')) { goBuy(); return; }
    if (e.target.closest('.admin-tab[data-tab="properties"]') || e.target.closest('#new-property-btn')) refresh();
  });
  document.addEventListener('keydown', (e) => { if (e.key === 'Escape') closeOverlay(); });

  const modal = document.getElementById('property-form-modal');
  if (modal) new MutationObserver(() => { if (!modal.classList.contains('hidden')) refresh(); else renderBanner(); }).observe(modal, { attributes: true, attributeFilter: ['class'] });

  // Apenas hay sesión se carga el plan (y las renovaciones automáticas antiguas ya no hacen nada)
  supabaseClient.auth.onAuthStateChange((event, session) => {
    if (session && session.user) setTimeout(async () => { await refresh(); if (typeof loadProperties === 'function' && document.getElementById('property-list')) loadProperties(); }, 0);
  });

  window.UnoPublications = {
    refresh, decorateCard, confirmPublish, featureProperty,
    insufficientMessage: () => 'No se pudo publicar: revisa tu plan en la pestaña Suscripción.',
    fillLine: () => {}, supportsAutoRenew: false,
    get subscription() { return state.sub; },
  };
})();
