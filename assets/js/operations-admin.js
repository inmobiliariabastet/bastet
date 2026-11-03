/* Panel «Operaciones» (fase 3): cierre de ventas, alquileres y anticréticos con conexiones de Bastet, comisiones y desistimiento.
 * Titular: «Cerrar operación» (dice a quién vendió; si fue a la persona de la conexión, ella confirma por un enlace), paga la comisión con comprobante,
 * o retira la propiedad con una declaración jurada. Administración: resuelve los casos en revisión, verifica comprobantes, consulta el historial y
 * fija el texto de la declaración jurada. Reglas en docs/ESPECIFICACION_MAESTRA.md (1.3 y 1.5); SQL en supabase/operations.sql.
 * Autónomo: usa `supabaseClient` y `currentProfile`. Expone window.OperationsAdmin { openClosure(property), isOn() }. */
(function () {
  'use strict';

  const root = () => document.getElementById('operations-root');
  const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const isAdmin = () => typeof currentProfile !== 'undefined' && currentProfile && currentProfile.role === 'admin';
  const bs = (n) => 'Bs ' + Number(n).toLocaleString('es-BO', { maximumFractionDigits: 2 });
  const money = (n, c) => { const s = Number(n).toLocaleString('es-BO', { maximumFractionDigits: 2 }); return c === 'BOB' ? 'Bs ' + s : s + ' USD'; };
  const fdate = (d) => { const x = new Date(String(d).slice(0, 10) + 'T00:00:00'); return isNaN(x) ? '' : x.toLocaleDateString('es-BO', { day: '2-digit', month: 'short', year: 'numeric' }); };
  const ftime = (d) => { const x = new Date(d); return isNaN(x) ? '' : x.toLocaleString('es-BO', { day: '2-digit', month: 'short', year: 'numeric', hour: '2-digit', minute: '2-digit' }); };
  const waPhone = (v) => { const d = String(v || '').replace(/[^0-9]/g, ''); return /^[67][0-9]{7}$/.test(d) ? '591' + d : d; };
  const KIND = { venta: 'Venta', alquiler: 'Alquiler', anticretico: 'Anticrético', desistimiento: 'Retiro (desistimiento)' };
  const DONE = { venta: 'vendió', alquiler: 'alquiló', anticretico: 'dio en anticrético' };
  const AMOUNT = { venta: 'Precio total de la venta', alquiler: 'Canon mensual del alquiler', anticretico: 'Monto total entregado en anticrético' };
  const STATUS = {
    pendiente_interesado: ['Esperando confirmación del interesado', 'wait'], en_revision: ['En revisión de Bastet', 'wait'], confirmada: ['Confirmada', 'ok'],
    rechazada: ['Rechazada', 'bad'], desistida: ['Propiedad retirada', 'bad'], cancelada: ['Cancelada', 'bad'],
  };
  const COMM = { no_aplica: 'Sin comisión', exigible: 'Comisión por pagar', comprobante_enviado: 'Comprobante en revisión', pagada: 'Comisión pagada' };
  const PROOF_TYPES = { 'image/jpeg': 'jpg', 'image/png': 'png', 'image/webp': 'webp', 'application/pdf': 'pdf' };
  let data = { items: [], enabled: false }, filter = 'activas', busy = false, enabled = false;

  function toast(msg, bad) {
    let el = document.getElementById('ct-toast');
    if (!el) { el = document.createElement('div'); el.id = 'ct-toast'; el.setAttribute('role', 'status'); document.body.appendChild(el); }
    el.textContent = msg; el.className = 'ct-toast show' + (bad ? ' is-error' : '');
    clearTimeout(toast.t); toast.t = setTimeout(() => { el.className = 'ct-toast'; }, 5200);
  }

  async function fetchData() {
    const { data: d, error } = await supabaseClient.rpc('my_operations');
    if (error) return { error };
    data = d || { items: [] }; enabled = !!data.enabled;
    badge();
    return {};
  }
  function badge() {
    const el = document.getElementById('operations-count'); if (!el) return;
    const adm = isAdmin();
    const n = (data.items || []).filter((o) => (adm ? (o.status === 'en_revision' || o.commission_status === 'comprobante_enviado') : o.commission_status === 'exigible')).length;
    el.textContent = n; el.classList.toggle('hidden', !n);
  }
  const isLive = (o) => ['pendiente_interesado', 'en_revision'].includes(o.status) || ['exigible', 'comprobante_enviado'].includes(o.commission_status);
  const linkOf = (tok) => location.origin + '/confirmar.html?t=' + tok;

  function card(o) {
    const [label, tone] = STATUS[o.status] || [o.status, 'wait'];
    const adm = isAdmin();
    let h = '<article class="bk-card" data-id="' + esc(o.id) + '"><header><div><b>' + esc(o.title || 'Propiedad') + '</b><span class="bk-code">' + esc(o.code) + (o.number ? ' · ' + esc(o.number) : '') + '</span></div>' +
      '<span class="bk-chip bk-' + tone + '">' + esc(label) + '</span></header>' +
      '<p class="bk-meta">' + esc(KIND[o.kind] || o.kind) + (o.counterparty_name ? ' · ' + esc(o.counterparty_name) : '') + (o.amount ? ' · ' + money(o.amount, o.currency) : '') + (o.signed_date ? ' · firmado el ' + fdate(o.signed_date) : '') +
      (adm && o.titular_name ? ' · Titular: ' + esc(o.titular_name) : '') + '</p>';
    if (o.kind === 'desistimiento') h += '<p class="bk-fine">Motivo: ' + esc(o.reason || '—') + ' · declaración jurada v' + esc(o.declaration_version) + ' aceptada el ' + ftime(o.created_at) + '.</p>';
    if (o.status === 'pendiente_interesado') {
      const link = linkOf(o.interested_token);
      const msg = 'Hola, soy el titular de «' + (o.title || 'la propiedad') + '». Para registrar la operación en Bastet necesito que confirmes aquí que ' + (DONE[o.kind] ? 'se concretó ' : '') + 'la ' + (KIND[o.kind] || '').toLowerCase() + ': ' + link;
      h += '<p class="bk-fine">La propiedad sigue activa hasta que la persona de la conexión confirme. Envíale este enlace:</p><p class="bk-contact"><code>' + esc(link) + '</code></p>' +
        '<div class="bk-actions"><button class="btn btn-ghost btn-sm" data-act="copy" data-link="' + esc(link) + '">Copiar enlace</button>' +
        (o.interested_phone ? '<a class="btn btn-primary btn-sm" target="_blank" rel="noopener" href="https://api.whatsapp.com/send?phone=' + esc(waPhone(o.interested_phone)) + '&text=' + encodeURIComponent(msg) + '">Enviar por WhatsApp</a>' : '') + '</div>';
    }
    if (o.status === 'en_revision') h += '<p class="bk-fine">' + (o.to_interested === false ? 'Indicaste que fue a otra persona: Bastet analiza si hay relación con la conexión.' : 'La persona de la conexión no confirmó: Bastet analiza el caso.') + ' La propiedad sigue activa hasta que se resuelva.</p>';
    if (o.admin_note) h += '<p class="bk-fine">Decisión de Bastet: ' + esc(o.admin_note) + '</p>';
    if (o.status === 'confirmada') {
      h += '<p class="bk-money"><b>' + esc(COMM[o.commission_status] || '') + '</b>' + (o.commission_bs != null ? ': ' + bs(o.commission_bs) + ' <small>(' + (o.commission_percent != null ? String(o.commission_percent).replace('.', ',') + ' % de ' + money(o.amount, o.currency) : 'un mes de canon') + ' · congelada)</small>' : '') + '</p>';
      if (o.commission_status === 'exigible' && !adm) {
        h += '<section class="bk-pay"><h3>Paga ' + bs(o.commission_bs) + ' a Bastet</h3>' + (data.pay_qr_url ? '<img class="bk-qr" src="' + esc(data.pay_qr_url) + '" alt="QR de pago a Bastet">' : '') +
          '<p class="bk-fine">' + esc(data.pay_instructions || '').replace(/\n/g, '<br>') + '</p>' + (o.review_note ? '<p class="form-error">Comprobante anterior rechazado: ' + esc(o.review_note) + '</p>' : '') +
          '<label>Comprobante (foto o PDF, hasta 5 MB)<input type="file" data-proof accept="image/jpeg,image/png,image/webp,application/pdf"></label><button class="btn btn-primary btn-sm" data-act="upload">Enviar comprobante</button></section>';
      }
      if (o.commission_status === 'comprobante_enviado' && !adm) h += '<p class="bk-fine">Recibimos tu comprobante el ' + ftime(o.proof_at) + '. Bastet lo está revisando.</p>';
      if (o.commission_status === 'pagada') h += '<p class="bk-fine">Pago verificado el ' + ftime(o.paid_at) + '. Gracias.</p>';
      if (o.cert_code) h += '<p class="bk-fine">Certificado público: <b>' + esc(o.cert_code) + '</b> · <a href="verificar.html?c=' + esc(o.cert_code) + '" target="_blank" rel="noopener">Ver cómo lo consulta el público</a></p>';
    }
    const acts = [];
    if (['pendiente_interesado', 'en_revision'].includes(o.status) && !adm) acts.push('<button class="btn btn-ghost btn-sm" data-act="cancel">Cancelar solicitud</button>');
    if (o.status === 'confirmada') acts.push('<button class="btn btn-ghost btn-sm" data-act="acta">Ver acta de la operación</button>');
    if (adm) {
      if (['en_revision', 'pendiente_interesado'].includes(o.status)) acts.push('<button class="btn btn-primary btn-sm" data-act="resolve-confirm">Confirmar con comisión</button><button class="btn btn-ghost btn-sm" data-act="resolve-free">Cerrar sin comisión</button><button class="btn btn-ghost btn-sm" data-act="resolve-reject">Rechazar</button>');
      if (o.commission_status === 'comprobante_enviado') acts.push('<button class="btn btn-ghost btn-sm" data-act="proof">Ver comprobante</button><button class="btn btn-primary btn-sm" data-act="verify">Verificar pago</button><button class="btn btn-ghost btn-sm" data-act="deny">Rechazar comprobante</button>');
      acts.push('<button class="btn btn-ghost btn-sm" data-act="events">Historial</button>');
    }
    return h + (acts.length ? '<div class="bk-actions">' + acts.join('') + '</div>' : '') + '</article>';
  }

  function adminSettings() {
    if (!isAdmin()) return '';
    return '<section class="bk-settings"><h2>Declaración jurada de desistimiento</h2>' +
      '<p class="bk-fine">Texto que acepta el titular para retirar una propiedad con conexiones de Bastet. <b>Debe redactarlo o revisarlo un abogado en Bolivia.</b> Mientras esté vacío, los titulares no pueden retirar propiedades con conexiones. Versión actual: ' + esc(data.desist_version) + '.</p>' +
      '<form id="op-desist-form"><label>Texto<textarea id="op-desist-text" rows="7" maxlength="20000">' + esc(data.desist_text || '') + '</textarea></label><button class="btn btn-primary btn-sm" type="submit">Guardar declaración</button></form></section>';
  }

  function draw() {
    const el = root(); if (!el) return;
    const shown = (data.items || []).filter((o) => filter === 'todas' || isLive(o));
    el.innerHTML = adminSettings() +
      (!enabled && !isAdmin() ? '<p class="bk-fine">El cierre de operaciones con conexiones todavía no está activo en Bastet.</p>' : '') +
      '<div class="bk-filter"><button class="btn btn-sm ' + (filter === 'activas' ? 'btn-primary' : 'btn-ghost') + '" data-filter="activas">Activas</button><button class="btn btn-sm ' + (filter === 'todas' ? 'btn-primary' : 'btn-ghost') + '" data-filter="todas">Todas</button></div>' +
      (shown.length ? shown.map(card).join('') : '<p class="bk-empty">' + ((data.items || []).length ? 'No hay operaciones activas.' : 'Todavía no hay operaciones. Cuando vendas, alquiles o retires una propiedad con conexiones de Bastet, aparecerá aquí.') + '</p>');
  }

  async function load() {
    const el = root(); if (!el) return;
    el.innerHTML = '<p class="bk-empty">Cargando…</p>';
    const { error } = await fetchData();
    if (error) { el.innerHTML = '<p class="form-error">' + (/function|schema cache/i.test(error.message || '') ? 'Las operaciones todavía no están activadas en la base de datos (falta correr supabase/operations.sql).' : esc(error.message)) + '</p>'; return; }
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
    const { data: s, error } = await supabaseClient.storage.from('connection-proofs').createSignedUrl(path, 600);
    if (error || !s) { toast('No se pudo abrir el archivo', true); return; }
    window.open(s.signedUrl, '_blank', 'noopener');
  }

  function modal(html) {
    const prev = document.getElementById('op-overlay'); if (prev) prev.remove();
    const o = document.createElement('div'); o.className = 'modal-overlay'; o.id = 'op-overlay';
    o.innerHTML = '<div class="modal-panel op-panel" role="dialog" aria-modal="true">' + html + '</div>';
    document.body.appendChild(o);
    o.addEventListener('click', (e) => { if (e.target === o || e.target.closest('[data-close]')) o.remove(); });
    return o;
  }

  /* ───────── Cerrar operación (titular) ───────── */
  async function openClosure(property) {
    if (!property) return;
    const { data: st, error } = await supabaseClient.rpc('closure_state', { p_property: property.id });
    if (error) { toast(error.message || 'No se pudo abrir el cierre', true); return; }
    const op = st.operation;
    if (st.open_operation) { modal('<h2>Ya hay una confirmación en curso</h2><p>Esta propiedad tiene una operación «' + esc((STATUS[st.open_operation.status] || [''])[0]) + '». Revísala en la pestaña <b>Operaciones</b>.</p><div class="modal-form-actions"><button type="button" class="btn btn-ghost" data-close>Cerrar</button></div>'); return; }
    const today = new Date(); today.setMinutes(today.getMinutes() - today.getTimezoneOffset()); const iso = today.toISOString().slice(0, 10);
    const conns = st.connections || [];
    const o = modal('<h2>Cerrar operación</h2><p class="bk-fine"><b>' + esc(st.title) + '</b>' + (st.protected ? ' · tiene conexiones de Bastet: la operación debe registrarse para marcarla como cerrada.' : '') + '</p>' +
      '<div class="op-tabs"><button type="button" class="btn btn-sm btn-primary" data-tab="close">Se ' + esc(DONE[op] || 'cerró') + '</button><button type="button" class="btn btn-sm btn-ghost" data-tab="desist">Retirar sin concretar</button></div>' +
      '<form id="op-close-form"><label>¿A quién se ' + esc(DONE[op] || 'cerró') + '?<select id="op-conn"><option value="">A otra persona (no es de una conexión de Bastet)</option>' +
        conns.map((c) => '<option value="' + esc(c.id) + '">' + esc(c.name) + ' · conexión ' + esc(c.number || c.code) + '</option>').join('') + '</select></label>' +
      '<label>Nombre de la persona<input id="op-buyer" type="text" maxlength="120" required></label>' +
      '<label>' + esc(AMOUNT[op] || 'Monto') + '<input id="op-amount" type="number" min="1" step="0.01" required></label>' +
      '<label>Moneda<select id="op-cur"><option value="USD"' + (property.currency !== 'BOB' ? ' selected' : '') + '>Dólares (USD)</option><option value="BOB"' + (property.currency === 'BOB' ? ' selected' : '') + '>Bolivianos (Bs)</option></select></label>' +
      '<label>Fecha de firma<input id="op-date" type="date" max="' + iso + '" value="' + iso + '" required></label>' +
      '<p class="bk-fine">' + (conns.length ? 'Si fue a la persona de una conexión, ella recibirá un enlace para confirmarlo y la propiedad se cierra al confirmar. Si fue a otra persona, Bastet analiza el caso y la propiedad sigue activa hasta resolverlo.' : 'Bastet revisará la operación y la propiedad seguirá activa hasta resolverlo.') + '</p>' +
      '<p class="form-error hidden" id="op-err"></p><div class="modal-form-actions"><button type="button" class="btn btn-ghost" data-close>Cancelar</button><button class="btn btn-primary" type="submit">Registrar operación</button></div></form>' +
      '<form id="op-desist-modal" class="hidden"><h3>Declaración jurada de desistimiento</h3>' +
        (st.desist_ready ? '<div class="fw-text" tabindex="0">' + esc(st.desist_text) + '</div><label>Motivo del retiro<textarea id="op-reason" rows="3" maxlength="500" required></textarea></label><label class="fw-check"><input type="checkbox" id="op-accept"> Declaro bajo juramento lo anterior y acepto la declaración (versión ' + esc(st.desist_version) + ').</label>'
          : '<p class="bk-fine">La declaración jurada de desistimiento todavía no está disponible. Escribe a Bastet para retirar esta propiedad.</p>') +
        '<p class="form-error hidden" id="op-derr"></p><div class="modal-form-actions"><button type="button" class="btn btn-ghost" data-close>Cancelar</button>' + (st.desist_ready ? '<button class="btn btn-primary" type="submit">Aceptar y retirar la propiedad</button>' : '') + '</div></form>');
    const conn = o.querySelector('#op-conn'), buyer = o.querySelector('#op-buyer');
    conn.addEventListener('change', () => { const c = conns.find((x) => x.id === conn.value); if (c && !buyer.value) buyer.value = c.name.replace(/\.$/, ''); });
    o.querySelectorAll('[data-tab]').forEach((b) => b.addEventListener('click', () => {
      const d = b.dataset.tab === 'desist';
      o.querySelector('#op-close-form').classList.toggle('hidden', d); o.querySelector('#op-desist-modal').classList.toggle('hidden', !d);
      o.querySelectorAll('[data-tab]').forEach((x) => { x.classList.toggle('btn-primary', x === b); x.classList.toggle('btn-ghost', x !== b); });
    }));
    o.querySelector('#op-close-form').addEventListener('submit', async (e) => {
      e.preventDefault();
      const err = o.querySelector('#op-err'); err.classList.add('hidden');
      const { data: r, error: er } = await supabaseClient.rpc('start_property_closure', { p_property: property.id, p_kind: op, p_connection: conn.value || null, p_buyer: buyer.value,
        p_amount: Number(o.querySelector('#op-amount').value), p_currency: o.querySelector('#op-cur').value, p_signed: o.querySelector('#op-date').value });
      if (er) { err.textContent = er.message || 'No se pudo registrar'; err.classList.remove('hidden'); return; }
      o.remove(); toast(r.status === 'pendiente_interesado' ? 'Operación registrada: envía el enlace a la persona para que confirme.' : 'Operación registrada: Bastet la revisará.');
      await fetchData(); const tab = document.querySelector('.admin-tab[data-tab="operations"]'); if (tab) tab.click();
    });
    o.querySelector('#op-desist-modal').addEventListener('submit', async (e) => {
      e.preventDefault();
      const err = o.querySelector('#op-derr'); err.classList.add('hidden');
      const { error: er } = await supabaseClient.rpc('desist_property', { p_property: property.id, p_accept: o.querySelector('#op-accept').checked, p_reason: o.querySelector('#op-reason').value });
      if (er) { err.textContent = er.message || 'No se pudo retirar'; err.classList.remove('hidden'); return; }
      o.remove(); toast('Propiedad retirada. Quedó registrada tu declaración jurada.');
      if (typeof loadProperties === 'function') loadProperties();
      await fetchData();
    });
  }

  async function upload(o, cardEl) {
    const f = cardEl.querySelector('[data-proof]').files[0];
    if (!f) { toast('Elige la foto o el PDF de tu comprobante.', true); return; }
    const ext = PROOF_TYPES[f.type];
    if (!ext) { toast('El comprobante debe ser una foto (JPG, PNG, WebP) o un PDF.', true); return; }
    if (f.size > 5 * 1024 * 1024) { toast('El archivo pesa más de 5 MB.', true); return; }
    const { data: u } = await supabaseClient.auth.getUser(); const uid = u && u.user && u.user.id; if (!uid) return;
    const path = uid + '/' + Date.now() + '.' + ext;
    const up = await supabaseClient.storage.from('connection-proofs').upload(path, f, { contentType: f.type });
    if (up.error) { toast(up.error.message || 'No se pudo subir el archivo', true); return; }
    await run(() => supabaseClient.rpc('attach_operation_proof', { p_id: o.id, p_path: path }), 'Comprobante enviado. Bastet lo revisará.');
  }

  async function showEvents(o) {
    const { data: ev, error } = await supabaseClient.rpc('operation_events', { p_id: o.id });
    if (error) { toast(error.message, true); return; }
    modal('<h2>Historial · ' + esc(o.code) + '</h2><ul class="bk-events">' + (ev || []).map((e) => '<li><b>' + esc(String(e.event).replace(/_/g, ' ')) + '</b> <small>' + esc(e.actor) + ' · ' + ftime(e.at) + '</small>' + (e.data ? '<br><small>' + esc(JSON.stringify(e.data)) + '</small>' : '') + '</li>').join('') + '</ul><div class="modal-form-actions"><button type="button" class="btn btn-ghost" data-close>Cerrar</button></div>');
  }

  /* Acta digital: documento imprimible con los datos de la operación y las aceptaciones registradas */
  async function openActa(o) {
    const { data: a, error } = await supabaseClient.rpc('get_operation_acta', { p_id: o.id });
    if (error) { toast(error.message || 'No se pudo generar el acta', true); return; }
    const w = window.open('', '_blank'); if (!w) { toast('Permite las ventanas emergentes para ver el acta.', true); return; }
    const row = (k, v) => v == null || v === '' ? '' : '<tr><th>' + esc(k) + '</th><td>' + esc(v) + '</td></tr>';
    const p = a.property || {};
    w.document.write('<!doctype html><html lang="es"><head><meta charset="utf-8"><title>Acta ' + esc(a.number) + '</title><style>body{font:14px/1.55 Georgia,serif;max-width:760px;margin:30px auto;padding:0 18px;color:#1E2629}h1{font-size:22px;color:#3D4C3A}table{width:100%;border-collapse:collapse;margin:8px 0 18px}th{text-align:left;width:34%;padding:6px 8px;background:#F4F1EC;border:1px solid #ddd}td{padding:6px 8px;border:1px solid #ddd}.n{font-size:12px;color:#666}button{padding:8px 16px;margin-bottom:16px}@media print{button{display:none}}</style></head><body>' +
      '<button onclick="window.print()">Imprimir / guardar como PDF</button><h1>ACTA DIGITAL DE OPERACIÓN INMOBILIARIA</h1><p>Bastet Real State S.R.L. · Acta N.º <b>' + esc(a.number) + '</b> · Certificado público <b>' + esc(a.cert_code) + '</b></p>' +
      '<h3>Operación</h3><table>' + row('Tipo', KIND[a.kind] || a.kind) + row('Fecha de firma', a.signed_date ? fdate(a.signed_date) : '') + row('Confirmada el', ftime(a.confirmed_at)) + row('Monto', a.amount ? money(a.amount, a.currency) : '') + '</table>' +
      '<h3>Inmueble</h3><table>' + row('Título', p.title) + row('Código', p.code_number ? 'BST-' + p.code_number : '') + row('Ubicación', [p.address, p.location].filter(Boolean).join(', ')) + '</table>' +
      '<h3>Partes</h3><table>' + row('Titular (quien publicó)', a.titular && a.titular.name) + row('Agente verificado por Bastet', a.titular && a.titular.agent_verified ? 'Sí' : 'No') + row('Propietario verificado', a.titular && a.titular.owner_verified ? 'Sí' : 'No') +
        row('Contraparte', a.counterparty && a.counterparty.name) + row('Confirmación de la contraparte', a.counterparty && a.counterparty.confirmed ? 'Confirmó por enlace el ' + ftime(a.counterparty.confirmed_at) : 'No confirmó por enlace (operación decidida por administración)') + '</table>' +
      (a.connection ? '<h3>Conexión de Bastet</h3><table>' + row('Constancia de conexión', a.connection.number) + row('Aceptada el', ftime(a.connection.accepted_at)) + row('Pago verificado el', ftime(a.connection.verified_at)) + row('Contrato marco', a.connection.framework_version ? 'versión ' + a.connection.framework_version : '') + '</table>' : '') +
      '<h3>Comisión</h3><table>' + row('Comisión a Bastet', a.commission && a.commission.bs != null ? bs(a.commission.bs) : 'No aplica') + row('Porcentaje', a.commission && a.commission.percent != null ? a.commission.percent + ' %' : '') + row('Tipo de cambio interno', a.commission && a.commission.rate) + '</table>' +
      '<p class="n">Documento generado por la plataforma con los datos y aceptaciones registrados. El mecanismo de firma y su validez probatoria están pendientes de revisión jurídica en Bolivia; este documento no reemplaza el contrato entre las partes.</p></body></html>');
    w.document.close();
  }

  document.addEventListener('click', async (e) => {
    const f = e.target.closest('#operations-root [data-filter]'); if (f) { filter = f.dataset.filter; draw(); return; }
    const btn = e.target.closest('#operations-root [data-act]'); if (!btn) return;
    if (btn.dataset.act === 'copy') { try { await navigator.clipboard.writeText(btn.dataset.link); toast('Enlace copiado'); } catch (err) { toast('No se pudo copiar: ' + btn.dataset.link, true); } return; }
    const cardEl = btn.closest('.bk-card'); const o = (data.items || []).find((x) => x.id === cardEl.dataset.id); if (!o) return;
    const decide = async (d, msg) => { const n = window.prompt(msg); if (n) run(() => supabaseClient.rpc('admin_resolve_operation', { p_id: o.id, p_decision: d, p_note: n }), 'Decisión registrada'); };
    switch (btn.dataset.act) {
      case 'cancel': if (window.confirm('¿Cancelar esta solicitud de cierre? La propiedad seguirá activa.')) run(() => supabaseClient.rpc('cancel_property_closure', { p_id: o.id }), 'Solicitud cancelada'); return;
      case 'upload': return upload(o, cardEl);
      case 'proof': return signed(o.proof_path);
      case 'verify': if (window.confirm('¿Confirmas que recibiste el pago de ' + bs(o.commission_bs) + '?')) run(() => supabaseClient.rpc('admin_review_operation_proof', { p_id: o.id, p_approve: true, p_note: null }), 'Comisión pagada'); return;
      case 'deny': { const n = window.prompt('Motivo del rechazo (lo verá el titular):'); if (n) run(() => supabaseClient.rpc('admin_review_operation_proof', { p_id: o.id, p_approve: false, p_note: n }), 'Comprobante rechazado'); return; }
      case 'resolve-confirm': return decide('confirmar', 'Explica por qué se atribuye la operación a la conexión (queda en el historial):');
      case 'resolve-free': return decide('sin_comision', 'Explica por qué se cierra sin comisión (queda en el historial):');
      case 'resolve-reject': return decide('rechazar', 'Explica por qué se rechaza (queda en el historial):');
      case 'events': return showEvents(o);
      case 'acta': return openActa(o);
      default: return;
    }
  });
  document.addEventListener('submit', async (e) => {
    if (e.target.id !== 'op-desist-form') return;
    e.preventDefault();
    await run(() => supabaseClient.rpc('admin_update_desist_text', { p_text: document.getElementById('op-desist-text').value }), 'Declaración guardada');
  });

  window.OperationsAdmin = { openClosure, isOn: () => enabled };
  const tab = document.querySelector('.admin-tab[data-tab="operations"]');
  if (tab) {
    tab.addEventListener('click', load);
    const poll = async () => {
      if (typeof supabaseClient === 'undefined' || document.hidden || busy || document.querySelector('.modal-overlay')) return;
      const { error } = await fetchData();
      if (error && /function|schema cache/i.test(error.message || '') && !isAdmin()) tab.classList.add('hidden');
      const panel = document.getElementById('tab-panel-operations');
      if (!error && panel && !panel.classList.contains('hidden') && !document.querySelector('#operations-root textarea:focus, #operations-root input:focus')) draw();
    };
    setTimeout(poll, 3500);
    setInterval(poll, 60000);
  }
})();
