/* Panel «Verificación» (fase 4): tres distintivos independientes (agente, propietario, propiedad), reseñas recibidas y revisión administrativa.
 * Titular: solicita cada distintivo, sube documentos a una carpeta privada y los envía a revisión. Administración: revisa los documentos, marca TODAS las
 * comprobaciones exigidas (sin ellas no se aprueba), aprueba, rechaza (con motivo) o revoca; consulta el historial y decide si las propiedades sin verificar
 * pueden recibir solicitudes de contacto. Reglas en docs/ESPECIFICACION_MAESTRA.md (secciones 5 y 7); SQL en supabase/verification.sql.
 * Autónomo: usa `supabaseClient`, `currentProfile` y la lista `properties` del panel. */
(function () {
  'use strict';

  const root = () => document.getElementById('verification-root');
  const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const isAdmin = () => typeof currentProfile !== 'undefined' && currentProfile && currentProfile.role === 'admin';
  const ftime = (d) => { const x = new Date(d); return isNaN(x) ? '' : x.toLocaleString('es-BO', { day: '2-digit', month: 'short', year: 'numeric', hour: '2-digit', minute: '2-digit' }); };
  const KIND = { agente: 'Agente verificado por Bastet', propietario: 'Propietario verificado', propiedad: 'Propiedad verificada' };
  const STATUS = { borrador: ['Borrador (falta enviar)', 'wait'], en_revision: ['En revisión de Bastet', 'wait'], aprobada: ['Vigente', 'ok'], rechazada: ['Rechazada', 'bad'], revocada: ['Revocada', 'bad'] };
  const CHECK = {
    identidad: 'Identidad personal verificada', telefono: 'Teléfono verificado', documentacion_profesional: 'Documentación profesional revisada', contrato_bastet: 'Contrato directo con Bastet',
    documentacion: 'Identidad y documentación del propietario revisadas', identidad_propietario: 'Identidad del propietario revisada', documentacion_legal: 'Documentación legal revisada', existencia_fisica: 'Existencia física del inmueble comprobada',
  };
  const TYPES = { 'image/jpeg': 'jpg', 'image/png': 'png', 'image/webp': 'webp', 'application/pdf': 'pdf' };
  let data = { items: [], required: {}, me: {} }, reviews = [], required = false, filter = 'activas', busy = false;

  function toast(msg, bad) {
    let el = document.getElementById('ct-toast');
    if (!el) { el = document.createElement('div'); el.id = 'ct-toast'; el.setAttribute('role', 'status'); document.body.appendChild(el); }
    el.textContent = msg; el.className = 'ct-toast show' + (bad ? ' is-error' : '');
    clearTimeout(toast.t); toast.t = setTimeout(() => { el.className = 'ct-toast'; }, 5200);
  }

  async function fetchData() {
    const [v, r, q] = await Promise.all([supabaseClient.rpc('my_verifications'), supabaseClient.rpc('my_profile_reviews'), supabaseClient.rpc('verification_required')]);
    if (v.error) return { error: v.error };
    data = v.data || data; reviews = (r && r.data) || []; required = q && q.data === true;
    badge();
    return {};
  }
  function badge() {
    const el = document.getElementById('verification-count'); if (!el) return;
    const n = isAdmin() ? (data.items || []).filter((x) => x.status === 'en_revision').length : (data.items || []).filter((x) => x.status === 'borrador').length;
    el.textContent = n; el.classList.toggle('hidden', !n);
  }
  const live = (x) => ['borrador', 'en_revision', 'aprobada'].includes(x.status);

  function card(x) {
    const [label, tone] = STATUS[x.status] || [x.status, 'wait'];
    const adm = isAdmin();
    let h = '<article class="bk-card" data-id="' + esc(x.id) + '"><header><div><b>' + esc(KIND[x.kind]) + (x.property_title ? ' · ' + esc(x.property_title) : '') + '</b>' +
      (adm && x.user_name ? '<span class="bk-code">' + esc(x.user_name) + '</span>' : '') + '</div><span class="bk-chip bk-' + tone + '">' + esc(label) + '</span></header>';
    if (x.note) h += '<p class="bk-meta">Nota del solicitante: ' + esc(x.note) + '</p>';
    h += '<p class="bk-fine">' + ((x.docs || []).length ? 'Documentos (' + x.docs.length + '): ' + x.docs.map((d, i) => '<a href="#" data-act="doc" data-i="' + i + '">' + esc(d.label) + '</a>').join(' · ') : 'Todavía no hay documentos.') + '</p>';
    if (x.admin_note) h += '<p class="bk-fine">Decisión de Bastet: ' + esc(x.admin_note) + (x.decided_at ? ' (' + ftime(x.decided_at) + ')' : '') + '</p>';
    const acts = [];
    if (x.status === 'borrador' && !adm) {
      h += '<section class="bk-pay"><label>Describe el documento<input type="text" data-doc-label maxlength="80" placeholder="Ej.: Cédula de identidad, anverso y reverso"></label><label>Archivo (foto o PDF, hasta 8 MB)<input type="file" data-doc-file accept="image/jpeg,image/png,image/webp,application/pdf"></label>' +
        '<button class="btn btn-ghost btn-sm" data-act="add-doc">Agregar documento</button></section>';
      acts.push('<button class="btn btn-primary btn-sm" data-act="submit">Enviar a revisión</button>');
    }
    if (adm && x.status === 'en_revision') {
      const req = (data.required || {})[x.kind] || [];
      h += '<section class="bk-pay"><h3>Comprobaciones obligatorias</h3>' + req.map((k) => '<label class="bk-check"><input type="checkbox" data-check="' + esc(k) + '"' + (x.checks && x.checks[k] ? ' checked' : '') + '> ' + esc(CHECK[k] || k) + '</label>').join('') +
        '<label>Nota para el historial / motivo del rechazo<input type="text" data-review-note maxlength="800"></label></section>';
      acts.push('<button class="btn btn-primary btn-sm" data-act="approve">Aprobar verificación</button><button class="btn btn-ghost btn-sm" data-act="reject">Rechazar</button>');
    }
    if (adm && x.status === 'aprobada') acts.push('<button class="btn btn-ghost btn-sm" data-act="revoke">Revocar</button>');
    if (adm) acts.push('<button class="btn btn-ghost btn-sm" data-act="events">Historial</button>');
    return h + (acts.length ? '<div class="bk-actions">' + acts.join('') + '</div>' : '') + '</article>';
  }

  function mePanel() {
    const m = data.me || {};
    const props = (typeof properties !== 'undefined' ? properties : []).filter((p) => p.status === 'available' && !p.verified && p.owner_id === (currentSession && currentSession.user && currentSession.user.id));
    const chip = (ok, txt) => '<span class="bk-chip ' + (ok ? 'bk-ok' : 'bk-wait') + '">' + (ok ? '✓ ' : '') + esc(txt) + '</span>';
    return '<section class="bk-settings"><h2>Tus distintivos</h2><p class="bk-fine">Son independientes entre sí y no son lo mismo que la reputación. Solo Bastet los concede, tras revisar tus documentos.</p>' +
      '<p>' + chip(m.agent_verified, 'Agente verificado por Bastet') + ' ' + chip(m.owner_verified, 'Propietario verificado') + (m.public_code ? ' <span class="bk-code">Tu código público: <b>' + esc(m.public_code) + '</b> (se consulta en «Verificar»)</span>' : '') + '</p>' +
      '<div class="bk-actions"><button class="btn btn-ghost btn-sm" data-act="new" data-kind="agente"' + (m.agent_verified ? ' disabled' : '') + '>Solicitar verificación de agente</button>' +
      '<button class="btn btn-ghost btn-sm" data-act="new" data-kind="propietario"' + (m.owner_verified ? ' disabled' : '') + '>Solicitar verificación de propietario</button></div>' +
      '<div class="bk-actions"><select id="vf-prop"><option value="">Elige una propiedad…</option>' + props.map((p) => '<option value="' + esc(p.id) + '">' + esc(p.title) + '</option>').join('') + '</select><button class="btn btn-ghost btn-sm" data-act="new" data-kind="propiedad">Verificar esta propiedad</button></div></section>';
  }

  function adminSettings() {
    if (!isAdmin()) return '';
    return '<section class="bk-settings"><h2>Propiedades pendientes de verificación</h2>' +
      '<label class="bk-check"><input type="checkbox" id="vf-required"' + (required ? ' checked' : '') + '> Exigir verificación: las propiedades sin verificar se publican con la etiqueta «Pendiente de verificación» y <b>no reciben solicitudes de contacto</b> hasta verificarse <small>(solo rige con las conexiones activas)</small></label></section>';
  }

  function reviewsHtml() {
    if (!reviews.length) return '';
    return '<section class="bk-settings"><h2>Reseñas recibidas</h2><p class="bk-fine">Solo escriben reseñas quienes concretaron una operación con una conexión de Bastet.</p>' + reviews.map((r) =>
      '<article class="bk-card" data-rid="' + esc(r.id) + '"><header><div><b>' + '★'.repeat(r.rating) + '☆'.repeat(5 - r.rating) + '</b> <span class="bk-code">' + esc(r.reviewer_name) + (r.reviewed ? ' → ' + esc(r.reviewed) : '') + ' · ' + ftime(r.created_at) + '</span></div>' +
      (r.status === 'hidden' ? '<span class="bk-chip bk-bad">Oculta</span>' : '') + '</header>' + (r.comment ? '<p class="bk-meta">«' + esc(r.comment) + '»</p>' : '') +
      (r.reply ? '<p class="bk-fine">Tu respuesta: ' + esc(r.reply) + '</p>' : '') +
      '<div class="bk-actions"><button class="btn btn-ghost btn-sm" data-act="reply">' + (r.reply ? 'Editar respuesta' : 'Responder') + '</button>' +
      (isAdmin() ? '<button class="btn btn-ghost btn-sm" data-act="hide">' + (r.status === 'hidden' ? 'Volver a publicar' : 'Ocultar') + '</button>' : '') + '</div></article>').join('') + '</section>';
  }

  function draw() {
    const el = root(); if (!el) return;
    const shown = (data.items || []).filter((x) => filter === 'todas' || live(x));
    el.innerHTML = adminSettings() + (isAdmin() ? '' : mePanel()) +
      '<div class="bk-filter"><button class="btn btn-sm ' + (filter === 'activas' ? 'btn-primary' : 'btn-ghost') + '" data-filter="activas">Activas</button><button class="btn btn-sm ' + (filter === 'todas' ? 'btn-primary' : 'btn-ghost') + '" data-filter="todas">Todas</button></div>' +
      (shown.length ? shown.map(card).join('') : '<p class="bk-empty">' + ((data.items || []).length ? 'No hay verificaciones activas.' : 'Todavía no hay solicitudes de verificación.') + '</p>') + reviewsHtml();
  }

  async function load() {
    const el = root(); if (!el) return;
    el.innerHTML = '<p class="bk-empty">Cargando…</p>';
    const { error } = await fetchData();
    if (error) { el.innerHTML = '<p class="form-error">' + (/function|schema cache/i.test(error.message || '') ? 'La verificación todavía no está activada en la base de datos (falta correr supabase/verification.sql).' : esc(error.message)) + '</p>'; return; }
    draw();
  }

  async function run(fn, okMsg) {
    if (busy) return false; busy = true;
    try {
      const { error } = await fn();
      if (error) { toast(error.message || 'No se pudo completar', true); return false; }
      if (okMsg) toast(okMsg);
      await fetchData(); draw();
      if (typeof loadProperties === 'function') loadProperties();
      return true;
    } finally { busy = false; }
  }
  async function signed(path) {
    const { data: s, error } = await supabaseClient.storage.from('verification-docs').createSignedUrl(path, 600);
    if (error || !s) { toast('No se pudo abrir el documento', true); return; }
    window.open(s.signedUrl, '_blank', 'noopener');
  }
  function modal(html) {
    const prev = document.getElementById('vf-overlay'); if (prev) prev.remove();
    const o = document.createElement('div'); o.className = 'modal-overlay'; o.id = 'vf-overlay';
    o.innerHTML = '<div class="modal-panel op-panel" role="dialog" aria-modal="true">' + html + '</div>';
    document.body.appendChild(o);
    o.addEventListener('click', (e) => { if (e.target === o || e.target.closest('[data-close]')) o.remove(); });
  }

  async function addDoc(x, cardEl) {
    const label = cardEl.querySelector('[data-doc-label]').value.trim(), f = cardEl.querySelector('[data-doc-file]').files[0];
    if (label.length < 2) { toast('Describe el documento.', true); return; }
    if (!f) { toast('Elige la foto o el PDF.', true); return; }
    const ext = TYPES[f.type];
    if (!ext) { toast('El documento debe ser una foto (JPG, PNG, WebP) o un PDF.', true); return; }
    if (f.size > 8 * 1024 * 1024) { toast('El archivo pesa más de 8 MB.', true); return; }
    const { data: u } = await supabaseClient.auth.getUser(); const uid = u && u.user && u.user.id; if (!uid) return;
    const path = uid + '/' + Date.now() + '.' + ext;
    const up = await supabaseClient.storage.from('verification-docs').upload(path, f, { contentType: f.type });
    if (up.error) { toast(up.error.message || 'No se pudo subir el archivo', true); return; }
    await run(() => supabaseClient.rpc('attach_verification_doc', { p_id: x.id, p_path: path, p_label: label }), 'Documento agregado');
  }

  document.addEventListener('click', async (e) => {
    const f = e.target.closest('#verification-root [data-filter]'); if (f) { filter = f.dataset.filter; draw(); return; }
    const btn = e.target.closest('#verification-root [data-act]'); if (!btn) return;
    e.preventDefault();
    if (btn.dataset.act === 'new') {
      const kind = btn.dataset.kind, prop = kind === 'propiedad' ? document.getElementById('vf-prop').value : null;
      if (kind === 'propiedad' && !prop) { toast('Elige una de tus propiedades.', true); return; }
      return void run(() => supabaseClient.rpc('request_verification', { p_kind: kind, p_property: prop }), 'Solicitud creada: agrega tus documentos y envíala.');
    }
    const act = btn.dataset.act;
    if (act === 'reply' || act === 'hide') {
      const rid = btn.closest('[data-rid]').dataset.rid, r = reviews.find((z) => z.id === rid); if (!r) return;
      if (act === 'hide') return void run(() => supabaseClient.rpc('admin_set_profile_review_status', { p_id: rid, p_status: r.status === 'hidden' ? 'published' : 'hidden' }), 'Reseña actualizada');
      const t = window.prompt('Tu respuesta pública a esta reseña (vacío = quitar):', r.reply || ''); if (t === null) return;
      return void run(() => supabaseClient.rpc('reply_profile_review', { p_id: rid, p_reply: t }), 'Respuesta guardada');
    }
    const cardEl = btn.closest('.bk-card'); const x = (data.items || []).find((z) => z.id === cardEl.dataset.id); if (!x) return;
    const checks = () => { const c = {}; cardEl.querySelectorAll('[data-check]').forEach((i) => { c[i.dataset.check] = i.checked; }); return c; };
    const note = () => (cardEl.querySelector('[data-review-note]') || { value: '' }).value;
    switch (act) {
      case 'doc': return signed(x.docs[Number(btn.dataset.i)].path);
      case 'add-doc': return addDoc(x, cardEl);
      case 'submit': if (window.confirm('¿Enviar a revisión? Después no podrás agregar más documentos.')) run(() => supabaseClient.rpc('submit_verification', { p_id: x.id, p_note: null }), 'Enviada a revisión. Bastet te responderá.'); return;
      case 'approve': return void run(() => supabaseClient.rpc('admin_review_verification', { p_id: x.id, p_decision: 'aprobar', p_checks: checks(), p_note: note() }), 'Verificación aprobada');
      case 'reject': return void run(() => supabaseClient.rpc('admin_review_verification', { p_id: x.id, p_decision: 'rechazar', p_checks: checks(), p_note: note() }), 'Solicitud rechazada');
      case 'revoke': { const n = window.prompt('Motivo de la revocación (queda en el historial):'); if (n) run(() => supabaseClient.rpc('admin_revoke_verification', { p_id: x.id, p_note: n }), 'Verificación revocada'); return; }
      case 'events': {
        const { data: ev, error } = await supabaseClient.rpc('verification_events', { p_id: x.id });
        if (error) { toast(error.message, true); return; }
        modal('<h2>Historial</h2><ul class="bk-events">' + (ev || []).map((z) => '<li><b>' + esc(String(z.event).replace(/_/g, ' ')) + '</b> <small>' + esc(z.actor) + ' · ' + ftime(z.at) + '</small>' + (z.data ? '<br><small>' + esc(JSON.stringify(z.data)) + '</small>' : '') + '</li>').join('') + '</ul><div class="modal-form-actions"><button type="button" class="btn btn-ghost" data-close>Cerrar</button></div>');
        return;
      }
      default: return;
    }
  });
  document.addEventListener('change', (e) => {
    if (e.target.id !== 'vf-required') return;
    run(() => supabaseClient.rpc('admin_set_property_verification_required', { p_required: e.target.checked }), e.target.checked ? 'Ahora se exige la verificación' : 'Ya no se exige la verificación');
  });

  const tab = document.querySelector('.admin-tab[data-tab="verification"]');
  if (tab) {
    tab.addEventListener('click', load);
    const poll = async () => {
      if (typeof supabaseClient === 'undefined' || document.hidden || busy || document.querySelector('.modal-overlay')) return;
      const { error } = await fetchData();
      if (error && /function|schema cache/i.test(error.message || '') && !isAdmin()) tab.classList.add('hidden');
      const panel = document.getElementById('tab-panel-verification');
      if (!error && panel && !panel.classList.contains('hidden') && !document.querySelector('#verification-root input:focus, #verification-root select:focus')) draw();
    };
    setTimeout(poll, 4000);
    setInterval(poll, 90000);
  }
})();
