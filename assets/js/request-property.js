/* «Solicitar una propiedad» (Flujo C del rediseño móvil): el comprador o inquilino describe lo que busca en 7 pasos y un asesor de Bastet
 * lo atiende. Incluye «Mis solicitudes» con su estado (Activa / En proceso / Finalizada).
 * Autónomo: usa `supabaseClient` y BOLIVIA_CITIES. Envía con submit_property_request() (supabase/property-requests.sql); si ese SQL aún no
 * está activo, avisa con claridad y ofrece WhatsApp. Se abre desde cualquier elemento con [data-request-open] (o con #solicitar en la URL). */
(function () {
  'use strict';

  const WHATSAPP_PHONE = '59177666205';
  const MINE_KEY = 'bastet-my-requests';
  const DRAFT_KEY = 'bastet-request-draft';
  const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const OPS = [
    { v: 'venta', t: 'Comprar', d: 'Quiero comprar una propiedad', label: 'Compra' },
    { v: 'alquiler', t: 'Alquilar', d: 'Quiero alquilar una propiedad', label: 'Alquiler' },
    { v: 'anticretico', t: 'Anticrético', d: 'Quiero una propiedad en anticrético', label: 'Anticrético' },
    { v: 'temporal', t: 'Estadías temporales', d: 'Quiero una estadía por noches o días', label: 'Estadía temporal' },
  ];
  const TYPES = [['casa', 'Casa'], ['departamento', 'Departamento'], ['terreno', 'Terreno'], ['oficina', 'Oficina'], ['local', 'Local comercial'], ['otro', 'Otro']];
  const TYPE_LABEL = Object.fromEntries(TYPES);
  const COMFORTS = ['Jardín', 'Piscina', 'Balcón', 'Terraza', 'Ascensor', 'Aire acondicionado', 'Amoblado', 'Seguridad', 'Parrilla', 'Garaje'];
  const NEARBY = ['Colegios', 'Supermercados', 'Centros comerciales', 'Transporte', 'Parques', 'Hospitales'];
  const STATUS = { active: 'Activa', in_progress: 'En proceso', finished: 'Finalizada' };
  const NAMES = ['Tipo de solicitud', 'Ubicación', 'Características', 'Preferencias', 'Presupuesto', 'Descripción y contacto', 'Revisar'];

  let d = null;             // borrador
  let cur = 0, busy = false, view = 'form', mineTab = 'active';
  let root = null;

  const blank = () => ({ id: (window.crypto && crypto.randomUUID) ? crypto.randomUUID() : 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, (c) => { const r = Math.random() * 16 | 0; return (c === 'x' ? r : (r & 3 | 8)).toString(16); }),
    operation: 'venta', property_type: '', city: '', zone: '', rooms_min: '', baths_min: '', area_min: '', area_max: '', features: [], currency: 'USD', budget_min: '', budget_max: '', description: '', contact_name: '', contact_phone: '', contact_email: '', consent: false });
  try { const s = JSON.parse(sessionStorage.getItem(DRAFT_KEY) || 'null'); d = s && s.id ? Object.assign(blank(), s, { consent: false }) : blank(); } catch (e) { d = blank(); }
  const saveDraft = () => { try { sessionStorage.setItem(DRAFT_KEY, JSON.stringify(d)); } catch (e) { /* sin almacenamiento */ } };
  const mine = () => { try { return JSON.parse(localStorage.getItem(MINE_KEY) || '[]'); } catch (e) { return []; } };
  const saveMine = (list) => { try { localStorage.setItem(MINE_KEY, JSON.stringify(list.slice(0, 30))); } catch (e) { /* sin almacenamiento */ } };

  /* ───────── Estructura del modal (se crea una sola vez) ───────── */
  function ensureRoot() {
    if (root) return root;
    root = document.createElement('div');
    root.className = 'property-modal-backdrop hidden'; root.id = 'rq-backdrop';
    root.innerHTML = '<div class="property-modal rq-modal" role="dialog" aria-modal="true" aria-labelledby="rq-title"><button type="button" class="property-modal-close" id="rq-close" aria-label="Cerrar">✕</button><div class="agent-modal-body"><h2 class="agent-modal-title" id="rq-title">Solicitar una propiedad</h2><div id="rq-body"></div></div></div>';
    document.body.appendChild(root);
    root.addEventListener('click', onClick);
    root.addEventListener('input', onInput);
    root.addEventListener('change', onInput);
    root.addEventListener('keydown', (e) => {
      if (e.key === 'Enter' && view === 'form' && e.target.tagName === 'INPUT' && e.target.type !== 'checkbox') { e.preventDefault(); next(); }
    });
    document.addEventListener('keydown', (e) => { if (e.key === 'Escape' && !root.classList.contains('hidden')) close(); });
    return root;
  }
  const body = () => root.querySelector('#rq-body');
  function open(startView) {
    ensureRoot();
    view = startView || 'form';
    root.classList.remove('hidden'); document.body.style.overflow = 'hidden';
    render();
  }
  function close() { if (!root) return; root.classList.add('hidden'); document.body.style.overflow = ''; }

  /* ───────── Pasos ───────── */
  const chip = (group, value, label, on) => '<button type="button" class="rq-chip' + (on ? ' is-on' : '') + '" data-chip="' + group + '" data-v="' + esc(value) + '" aria-pressed="' + !!on + '">' + esc(label) + '</button>';
  const sel = (id, opts, val) => '<select id="' + id + '" data-f="' + id.slice(3) + '">' + opts.map(([v, t]) => '<option value="' + v + '"' + (String(val) === String(v) ? ' selected' : '') + '>' + t + '</option>').join('') + '</select>';
  const MIN_OPTS = [['', 'Cualquiera'], ['1', '1 o más'], ['2', '2 o más'], ['3', '3 o más'], ['4', '4 o más'], ['5', '5 o más']];

  function stepHtml(i) {
    if (i === 0) return '<h3>¿Qué tipo de solicitud quieres hacer?</h3><div class="sw-ops" role="radiogroup">' + OPS.map((o) =>
      '<button type="button" class="sw-op' + (d.operation === o.v ? ' is-on' : '') + '" role="radio" aria-checked="' + (d.operation === o.v) + '" data-op="' + o.v + '"><span class="sw-op-text"><b>' + o.t + '</b><small>' + o.d + '</small></span><span class="sw-radio" aria-hidden="true"></span></button>').join('') + '</div>';
    if (i === 1) return '<h3>¿Dónde te gustaría?</h3><p class="sw-sub">Indícanos la zona donde te gustaría la propiedad.</p>' +
      '<label class="agent-field"><span>Ciudad *</span><select id="rq-city" data-f="city"><option value="">Selecciona…</option>' + (typeof BOLIVIA_CITIES !== 'undefined' ? BOLIVIA_CITIES : []).map((c) => '<option' + (d.city === c ? ' selected' : '') + '>' + esc(c) + '</option>').join('') + '</select></label>' +
      '<label class="agent-field"><span>Zona o barrio (opcional)</span><input type="text" id="rq-zone" data-f="zone" maxlength="120" value="' + esc(d.zone) + '" placeholder="Ej. Sopocachi, Calacoto"></label>';
    if (i === 2) return '<h3>Características</h3><p class="sw-sub">Define el tipo y el tamaño que necesitas.</p><span class="rq-label">Tipo de inmueble *</span><div class="rq-chips">' + TYPES.map(([v, t]) => chip('type', v, t, d.property_type === v)).join('') + '</div>' +
      '<div class="agent-field-row"><label class="agent-field"><span>Habitaciones</span>' + sel('rq-rooms_min', MIN_OPTS, d.rooms_min) + '</label><label class="agent-field"><span>Baños</span>' + sel('rq-baths_min', MIN_OPTS, d.baths_min) + '</label></div>' +
      '<div class="agent-field-row"><label class="agent-field"><span>Superficie desde (m²)</span><input type="number" id="rq-area_min" data-f="area_min" min="0" inputmode="decimal" value="' + esc(d.area_min) + '"></label><label class="agent-field"><span>Hasta (m²)</span><input type="number" id="rq-area_max" data-f="area_max" min="0" inputmode="decimal" value="' + esc(d.area_max) + '"></label></div>';
    if (i === 3) return '<h3>Preferencias adicionales</h3><p class="sw-sub">Opcional: agrega lo que te gustaría tener cerca o dentro de la propiedad.</p><span class="rq-label">Comodidades</span><div class="rq-chips">' + COMFORTS.map((c) => chip('feat', c, c, d.features.includes(c))).join('') + '</div><span class="rq-label">Servicios cercanos</span><div class="rq-chips">' + NEARBY.map((c) => chip('feat', c, c, d.features.includes(c))).join('') + '</div>';
    if (i === 4) return '<h3>Presupuesto</h3><p class="sw-sub">Indícanos el rango de precio que manejas. Es opcional.</p><span class="rq-label">Moneda</span><div class="rq-chips">' + chip('cur', 'USD', 'Dólares (USD)', d.currency === 'USD') + chip('cur', 'BOB', 'Bolivianos (Bs)', d.currency === 'BOB') + '</div>' +
      '<div class="agent-field-row"><label class="agent-field"><span>Desde</span><input type="number" id="rq-budget_min" data-f="budget_min" min="0" inputmode="decimal" value="' + esc(d.budget_min) + '"></label><label class="agent-field"><span>Hasta</span><input type="number" id="rq-budget_max" data-f="budget_max" min="0" inputmode="decimal" value="' + esc(d.budget_max) + '"></label></div>' +
      (d.operation === 'temporal' ? '<p class="sw-sub">Para estadías, indica el precio por noche.</p>' : '');
    if (i === 5) return '<h3>Descripción y contacto</h3><label class="agent-field"><span>Cuéntanos más (opcional)</span><textarea id="rq-description" data-f="description" rows="4" maxlength="1000" placeholder="Ej. Busco una casa tranquila, con jardín, cerca de un colegio.">' + esc(d.description) + '</textarea></label>' +
      '<label class="agent-field"><span>Nombre completo *</span><input type="text" id="rq-contact_name" data-f="contact_name" maxlength="120" autocomplete="name" value="' + esc(d.contact_name) + '"></label>' +
      '<label class="agent-field"><span>WhatsApp *</span><input type="tel" id="rq-contact_phone" data-f="contact_phone" maxlength="30" autocomplete="tel" placeholder="+591 7xxxxxxx" value="' + esc(d.contact_phone) + '"></label>' +
      '<label class="agent-field"><span>Correo electrónico (opcional)</span><input type="email" id="rq-contact_email" data-f="contact_email" maxlength="160" autocomplete="email" value="' + esc(d.contact_email) + '"></label>';
    const row = (k, v) => '<div><span>' + k + '</span><b>' + (esc(v) || '—') + '</b></div>';
    const block = (t, s, rows) => '<section class="sw-sum-block"><header><h4>' + t + '</h4><button type="button" data-go="' + s + '">Editar</button></header>' + rows + '</section>';
    const cur2 = d.currency === 'BOB' ? 'Bs' : 'USD';
    const budget = d.budget_min || d.budget_max ? [d.budget_min ? 'desde ' + d.budget_min : '', d.budget_max ? 'hasta ' + d.budget_max : ''].filter(Boolean).join(' ') + ' ' + cur2 : '';
    return '<h3>Resumen de tu solicitud</h3><div class="sw-summary">' +
      block('Solicitud', 0, row('Operación', (OPS.find((o) => o.v === d.operation) || {}).label)) +
      block('Ubicación', 1, row('Ciudad', d.city) + row('Zona', d.zone)) +
      block('Características', 2, row('Tipo', TYPE_LABEL[d.property_type]) + row('Habitaciones', d.rooms_min ? d.rooms_min + ' o más' : '') + row('Baños', d.baths_min ? d.baths_min + ' o más' : '') + row('Superficie', [d.area_min ? 'desde ' + d.area_min : '', d.area_max ? 'hasta ' + d.area_max : ''].filter(Boolean).join(' ') + (d.area_min || d.area_max ? ' m²' : ''))) +
      block('Preferencias', 3, row('Elegidas', d.features.join(', '))) +
      block('Presupuesto', 4, row('Rango', budget)) +
      block('Contacto', 5, row('Nombre', d.contact_name) + row('WhatsApp', d.contact_phone) + row('Correo', d.contact_email) + row('Descripción', d.description)) +
      '</div><label class="sell-check rq-consent"><input type="checkbox" id="rq-consent"' + (d.consent ? ' checked' : '') + '><span>Acepto que Bastet use estos datos para buscar propiedades y contactarme. Más información en la <a href="privacidad.html" target="_blank" rel="noopener">política de privacidad</a>.</span></label>';
  }

  function render() {
    if (view === 'done') return renderDone();
    if (view === 'mine') return renderMine();
    const last = cur === NAMES.length - 1;
    body().innerHTML = '<div class="sw-progress"><div class="sw-prog-top"><b>' + NAMES[cur] + '</b><span>Paso ' + (cur + 1) + ' de ' + NAMES.length + '</span></div><div class="sw-bar"><i style="width:' + (((cur + 1) / NAMES.length) * 100) + '%"></i></div></div>' +
      '<div class="sw-step-card rq-step">' + stepHtml(cur) + '</div>' +
      '<div class="sw-nav"><p class="sw-err hidden" id="rq-err" role="alert"></p><div class="sw-nav-row">' +
        '<button type="button" class="sw-prev' + (cur === 0 ? ' sw-invisible' : '') + '" data-act="prev">← Anterior</button>' +
        '<button type="button" class="sw-next" data-act="' + (last ? 'send' : 'next') + '"' + (busy ? ' disabled' : '') + '>' + (last ? (busy ? 'Enviando…' : 'Enviar solicitud') : 'Siguiente →') + '</button></div>' +
        (cur === 0 && mine().length ? '<button type="button" class="rq-link" data-act="mine">Ver mis solicitudes</button>' : '') + '</div>';
    const panelEl = root.querySelector('.property-modal'); if (panelEl) panelEl.scrollTop = 0;
  }
  const err = (m) => { const e = root.querySelector('#rq-err'); if (e) { e.textContent = m; e.classList.remove('hidden'); } };

  function validate(i) {
    if (i === 1 && !d.city) { err('Elige la ciudad donde buscas.'); return false; }
    if (i === 2 && !d.property_type) { err('Elige el tipo de inmueble que buscas.'); return false; }
    if (i === 2 && d.area_min !== '' && d.area_max !== '' && Number(d.area_max) < Number(d.area_min)) { err('La superficie máxima no puede ser menor que la mínima.'); return false; }
    if (i === 4 && d.budget_min !== '' && d.budget_max !== '' && Number(d.budget_max) < Number(d.budget_min)) { err('El presupuesto máximo no puede ser menor que el mínimo.'); return false; }
    if (i === 5) {
      if (d.contact_name.trim().length < 3) { err('Escribe tu nombre completo.'); return false; }
      if (!/^\+?[0-9]{7,15}$/.test(d.contact_phone.replace(/[\s().-]/g, ''))) { err('Escribe un número de WhatsApp válido (solo números; con + si incluye código de país).'); return false; }
      if (d.contact_email && !/^[^@\s]+@[^@\s]+$/.test(d.contact_email.trim())) { err('El correo no parece válido.'); return false; }
    }
    return true;
  }
  function next() { if (validate(cur)) { cur++; render(); } }

  function onInput(e) {
    const t = e.target;
    if (t.id === 'rq-consent') { d.consent = t.checked; return; }
    const f = t.dataset && t.dataset.f; if (!f) return;
    d[f] = t.value; saveDraft();
  }
  function onClick(e) {
    const t = e.target;
    if (t.closest('#rq-close') || t === root) { close(); return; }
    const op = t.closest('[data-op]'); if (op) { d.operation = op.dataset.op; saveDraft(); render(); return; }
    const ch = t.closest('[data-chip]');
    if (ch) {
      const g = ch.dataset.chip, v = ch.dataset.v;
      if (g === 'type') d.property_type = v; else if (g === 'cur') d.currency = v;
      else d.features = d.features.includes(v) ? d.features.filter((x) => x !== v) : [...d.features, v];
      saveDraft(); render(); return;
    }
    const go = t.closest('[data-go]'); if (go) { cur = Number(go.dataset.go); render(); return; }
    const act = t.closest('[data-act]'); if (!act) return;
    const a = act.dataset.act;
    if (a === 'prev') { cur = Math.max(0, cur - 1); render(); }
    else if (a === 'next') next();
    else if (a === 'send') send();
    else if (a === 'mine') { view = 'mine'; render(); }
    else if (a === 'new') { d = blank(); saveDraft(); cur = 0; view = 'form'; render(); }
    else if (a === 'close') close();
    else if (a === 'tab') { mineTab = act.dataset.tab; renderMine(true); }
    else if (a === 'finish') finish(act.dataset.id);
  }

  /* ───────── Envío ───────── */
  const numOrNull = (v) => (v === '' || v === null || v === undefined ? null : Number(v));
  async function send() {
    if (busy) return;
    if (!d.consent) { err('Debes aceptar que usemos tus datos para contactarte.'); return; }
    busy = true; render();
    const payload = { id: d.id, operation: d.operation, property_type: d.property_type, city: d.city, zone: d.zone.trim() || null,
      rooms_min: numOrNull(d.rooms_min), baths_min: numOrNull(d.baths_min), area_min: numOrNull(d.area_min), area_max: numOrNull(d.area_max), features: d.features,
      budget_min: numOrNull(d.budget_min), budget_max: numOrNull(d.budget_max), currency: d.currency, description: d.description.trim() || null,
      contact_name: d.contact_name.trim(), contact_phone: d.contact_phone.replace(/[\s().-]/g, ''), contact_email: d.contact_email.trim() || null, consent: true };
    let msg = '';
    try {
      const { error } = await supabaseClient.rpc('submit_property_request', { p: payload });
      if (error) msg = /function|schema cache|does not exist/i.test(error.message || '') ? 'Esta función se está activando. Mientras tanto, escríbenos por WhatsApp al +591 77666205 y te ayudamos.' : (/violates check/i.test(error.message || '') ? 'Revisa los datos de tu solicitud (presupuesto y superficie).' : (error.message || 'No se pudo enviar.'));
    } catch (e) { msg = 'No pudimos enviar tu solicitud. Revisa tu conexión e inténtalo otra vez.'; }
    busy = false;
    if (msg) { render(); err(msg); return; }
    const list = mine(); list.unshift({ id: d.id }); saveMine(list);
    const sent = d; d = blank(); try { sessionStorage.removeItem(DRAFT_KEY); } catch (e) { /* sin almacenamiento */ }
    cur = 0; view = 'done'; renderDone(sent);
  }

  function afinesUrl(s) {
    const q = new URLSearchParams();
    if (s.operation === 'temporal') return 'estadias.html' + (s.city ? '?ciudad=' + encodeURIComponent(s.city) : '');
    q.set('op', s.operation); if (['casa', 'departamento', 'terreno'].includes(s.property_type)) q.set('tipo', s.property_type); if (s.city) q.set('ciudad', s.city);
    return 'marketplace.html?' + q.toString();
  }
  let lastSent = null;
  function renderDone(s) {
    if (s) lastSent = s;
    const x = lastSent || {};
    const wa = 'https://api.whatsapp.com/send?phone=' + WHATSAPP_PHONE + '&text=' + encodeURIComponent(['Hola Bastet, acabo de enviar una solicitud de propiedad desde la web.', 'Busco: ' + ((OPS.find((o) => o.v === x.operation) || {}).label || '') + ' · ' + (TYPE_LABEL[x.property_type] || '') + ' en ' + (x.city || ''), 'Nombre: ' + (x.contact_name || '')].join('\n'));
    body().innerHTML = '<div class="agent-success rq-done"><span class="rq-check" aria-hidden="true"></span><p class="agent-success-title">Tu solicitud fue enviada</p>' +
      '<p class="agent-form-hint">Un asesor de Bastet la revisará y te contactará por WhatsApp o correo cuando tengamos propiedades que se ajusten a tus preferencias.</p>' +
      '<a class="cta-button" href="' + esc(afinesUrl(x)) + '"><span>Ver propiedades afines</span></a>' +
      '<button type="button" class="cta-button cta-button--glass" data-act="mine"><span>Ver mis solicitudes</span></button>' +
      '<a class="agent-form-link" href="' + esc(wa) + '" target="_blank" rel="noopener">Escribirnos por WhatsApp</a>' +
      '<button type="button" class="agent-form-link" data-act="close">Cerrar</button></div>';
  }

  /* ───────── Mis solicitudes ───────── */
  let mineData = null;
  async function renderMine(keep) {
    view = 'mine';
    if (!keep || !mineData) {
      body().innerHTML = '<p class="sw-sub">Cargando tus solicitudes…</p>';
      const ids = mine().map((m) => m.id);
      try {
        const { data, error } = await supabaseClient.rpc('my_property_requests', { p_ids: ids });
        mineData = error ? null : (data || []);
      } catch (e) { mineData = null; }
    }
    if (!mineData) { body().innerHTML = '<p class="sw-sub">No pudimos cargar tus solicitudes ahora. Inténtalo de nuevo en un momento.</p><button type="button" class="agent-form-link" data-act="new">Hacer una nueva solicitud</button>'; return; }
    const tabs = [['active', 'Activas'], ['in_progress', 'En proceso'], ['finished', 'Finalizadas']];
    const list = mineData.filter((r) => r.status === mineTab);
    const money = (r) => { const c = r.currency === 'BOB' ? 'Bs ' : '$us '; const f = (n) => Number(n).toLocaleString('es-BO'); return r.budget_min || r.budget_max ? [r.budget_min ? c + f(r.budget_min) : '', r.budget_max ? c + f(r.budget_max) : ''].filter(Boolean).join(' – ') : 'Sin presupuesto definido'; };
    body().innerHTML = '<h3 class="rq-h">Mis solicitudes</h3><div class="rq-tabs" role="tablist">' + tabs.map(([k, t]) => '<button type="button" role="tab" class="rq-chip' + (mineTab === k ? ' is-on' : '') + '" data-act="tab" data-tab="' + k + '" aria-selected="' + (mineTab === k) + '">' + t + ' (' + mineData.filter((r) => r.status === k).length + ')</button>').join('') + '</div>' +
      (list.length ? '<ul class="rq-list">' + list.map((r) => '<li><div><b>' + esc((TYPE_LABEL[r.property_type] || '') + ' · ' + r.city) + '</b><small>' + esc((OPS.find((o) => o.v === r.operation) || {}).label || '') + ' · ' + esc(money(r)) + '</small><small>' + esc(new Date(r.created_at).toLocaleDateString('es-BO', { day: '2-digit', month: 'short', year: 'numeric' })) + '</small></div><div class="rq-side"><span class="rq-badge is-' + r.status + '">' + STATUS[r.status] + '</span>' + (r.status !== 'finished' ? '<button type="button" class="rq-link" data-act="finish" data-id="' + esc(r.id) + '">Finalizar</button>' : '') + '</div></li>').join('') + '</ul>' : '<p class="sw-sub">No tienes solicitudes en esta pestaña.</p>') +
      '<button type="button" class="cta-button" data-act="new"><span>Nueva solicitud</span></button>';
  }
  async function finish(id) {
    if (!confirm('¿Ya encontraste lo que buscabas? Finalizaremos esta solicitud.')) return;
    const { error } = await supabaseClient.rpc('finish_property_request', { p_id: id });
    if (error) { alert(error.message || 'No se pudo finalizar.'); return; }
    mineData = null; renderMine();
  }

  /* ───────── Entradas ───────── */
  document.addEventListener('click', (e) => {
    const b = e.target.closest('[data-request-open]'); if (!b) return;
    e.preventDefault(); const mineOnly = b.dataset.requestOpen === 'mine'; if (mineOnly) { open('mine'); } else open('form');
  });
  if (window.location.hash === '#solicitar') { open('form'); history.replaceState(null, '', window.location.pathname + window.location.search); }
  window.BastetRequest = { open };
})();
