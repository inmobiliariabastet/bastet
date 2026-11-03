/* Panel «Conexiones» (venta, alquiler y anticrético). Titular (agente, empresa o propietario): acepta o rechaza solicitudes de contacto, ve la tarifa
 * congelada, paga a Bastet con comprobante y, con el pago verificado, ve los datos del interesado. Administración: verifica comprobantes, cancela,
 * consulta el historial y gestiona los ajustes (interruptor, instrucciones de pago, contrato marco) y la matriz de tarifas.
 * Reglas en docs/ESPECIFICACION_MAESTRA.md (sección 1); SQL en supabase/connections.sql. Autónomo: usa `supabaseClient` y `currentProfile`. */
(function () {
  'use strict';

  const root = () => document.getElementById('connections-root');
  const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const isAdmin = () => typeof currentProfile !== 'undefined' && currentProfile && currentProfile.role === 'admin';
  const bs = (n) => 'Bs ' + Number(n).toLocaleString('es-BO', { maximumFractionDigits: 2 });
  const ftime = (d) => { const x = new Date(d); return isNaN(x) ? '' : x.toLocaleString('es-BO', { day: '2-digit', month: 'short', year: 'numeric', hour: '2-digit', minute: '2-digit' }); };
  const waPhone = (v) => { const d = String(v || '').replace(/[^0-9]/g, ''); return /^[67][0-9]{7}$/.test(d) ? '591' + d : d; };
  const OP = { venta: 'Venta', alquiler: 'Alquiler', anticretico: 'Anticrético' };
  const WHO = { comprador: 'Comprador', arrendatario: 'Arrendatario', anticresista: 'Anticresista' };
  const STATUS = {
    solicitada: ['Esperando tu respuesta', 'wait'], rechazada: ['Rechazada', 'bad'], aceptada_pendiente_pago: ['Pendiente de pago', 'wait'],
    comprobante_enviado: ['Comprobante en revisión', 'wait'], conexion_generada: ['Conexión generada', 'ok'], cancelada: ['Cancelada', 'bad'],
  };
  const PROOF_TYPES = { 'image/jpeg': 'jpg', 'image/png': 'png', 'image/webp': 'webp', 'application/pdf': 'pdf' };
  let data = { items: [], enabled: false }, cfg = null, filter = 'activas', busy = false, editing = null;

  function toast(msg, bad) {
    let el = document.getElementById('ct-toast');
    if (!el) { el = document.createElement('div'); el.id = 'ct-toast'; el.setAttribute('role', 'status'); document.body.appendChild(el); }
    el.textContent = msg; el.className = 'ct-toast show' + (bad ? ' is-error' : '');
    clearTimeout(toast.t); toast.t = setTimeout(() => { el.className = 'ct-toast'; }, 4800);
  }

  async function fetchData() {
    const { data: d, error } = await supabaseClient.rpc('my_connections');
    if (error) return { error };
    data = d || { items: [] };
    badge();
    return {};
  }
  function badge() {
    const el = document.getElementById('connections-count'); if (!el) return;
    const n = (data.items || []).filter((c) => (isAdmin() ? c.status === 'comprobante_enviado' : c.status === 'solicitada')).length;
    el.textContent = n; el.classList.toggle('hidden', !n);
  }
  const isLive = (c) => ['solicitada', 'aceptada_pendiente_pago', 'comprobante_enviado', 'conexion_generada'].includes(c.status);

  function card(c) {
    const [label, tone] = STATUS[c.status] || [c.status, 'wait'];
    const adm = isAdmin();
    let h = '<article class="bk-card" data-id="' + esc(c.id) + '"><header><div><b>' + esc(c.title) + '</b><span class="bk-code">' + esc(c.code) + (c.property_code ? ' · ' + esc(c.property_code) : '') + '</span></div>' +
      '<span class="bk-chip bk-' + tone + '">' + esc(label) + '</span></header>' +
      '<p class="bk-meta">' + esc(OP[c.operation] || c.operation) + ' · ' + esc(WHO[c.interested_type] || '') + ': <b>' + esc(c.interested_name) + '</b> · ' + ftime(c.created_at) + (adm && c.titular_name ? ' · Titular: ' + esc(c.titular_name) : '') + '</p>' +
      (c.message ? '<p class="bk-meta">«' + esc(c.message) + '»</p>' : '');
    if (c.interested_phone) h += '<p class="bk-contact">Contacto: <a target="_blank" rel="noopener" href="https://api.whatsapp.com/send?phone=' + esc(waPhone(c.interested_phone)) + '&text=' + encodeURIComponent('Hola ' + String(c.interested_name).split(' ')[0] + ', te escribo por tu interés en «' + c.title + '» (Bastet).') + '">' + esc(c.interested_phone) + '</a>' + (c.interested_email ? ' · ' + esc(c.interested_email) : '') + '</p>';
    else if (['solicitada', 'aceptada_pendiente_pago', 'comprobante_enviado'].includes(c.status)) h += '<p class="bk-fine">Los datos de contacto del interesado se muestran cuando Bastet verifica el pago de la tarifa de conexión.</p>';
    if (c.number) h += '<p class="bk-fine">Constancia <b>' + esc(c.number) + '</b> · aceptada el ' + ftime(c.accepted_at) + (c.framework_version ? ' · contrato marco v' + esc(c.framework_version) : '') + '</p>';
    if (c.fee_bs != null) h += '<p class="bk-money">Tarifa de conexión: <b>' + bs(c.fee_bs) + '</b> <small>(congelada al aceptar)</small>' + (adm && c.fee_calc ? ' · regla: ' + esc(c.fee_calc.rule_label || ('#' + c.fee_calc.rule_id)) + (c.fee_calc.provisional ? ' (provisional)' : '') + ' · inmueble ≈ ' + bs(c.fee_calc.value_bs || 0) : '') + '</p>';
    if (c.status === 'solicitada') h += '<p class="bk-fine">Si aceptas, nace la obligación de pagar la tarifa de conexión a Bastet. El interesado verá tu respuesta cuando lo contactes.</p><div class="bk-actions"><button class="btn btn-primary btn-sm" data-act="accept">Aceptar solicitud</button><button class="btn btn-ghost btn-sm" data-act="reject">Rechazar</button></div>';
    if (c.status === 'aceptada_pendiente_pago' && !adm) {
      h += '<section class="bk-pay"><h3>Paga ' + bs(c.fee_bs) + ' a Bastet</h3>' + (data.pay_qr_url ? '<img class="bk-qr" src="' + esc(data.pay_qr_url) + '" alt="QR de pago a Bastet">' : '') +
        '<p class="bk-fine">' + esc(data.pay_instructions || '').replace(/\n/g, '<br>') + '</p>' + (c.review_note ? '<p class="form-error">Comprobante anterior rechazado: ' + esc(c.review_note) + '</p>' : '') +
        '<label>Comprobante (foto o PDF, hasta 5 MB)<input type="file" data-proof accept="image/jpeg,image/png,image/webp,application/pdf"></label><button class="btn btn-primary btn-sm" data-act="upload">Enviar comprobante</button></section>';
    }
    if (c.status === 'comprobante_enviado' && !adm) h += '<p class="bk-fine">Recibimos tu comprobante el ' + ftime(c.proof_at) + '. Cuando Bastet lo verifique verás aquí los datos del interesado.</p>';
    if (c.status === 'conexion_generada') h += '<p class="bk-fine">Pago verificado el ' + ftime(c.verified_at) + '.</p>';
    const acts = [];
    if (adm) {
      if (c.status === 'comprobante_enviado') acts.push('<button class="btn btn-ghost btn-sm" data-act="proof">Ver comprobante</button><button class="btn btn-primary btn-sm" data-act="verify">Verificar pago y generar conexión</button><button class="btn btn-ghost btn-sm" data-act="deny">Rechazar comprobante</button>');
      if (['solicitada', 'aceptada_pendiente_pago', 'comprobante_enviado', 'conexion_generada'].includes(c.status)) acts.push('<button class="btn btn-ghost btn-sm" data-act="cancel">Cancelar</button>');
      acts.push('<button class="btn btn-ghost btn-sm" data-act="events">Historial</button>');
    }
    return h + (acts.length ? '<div class="bk-actions">' + acts.join('') + '</div>' : '') + '</article>';
  }

  function rulesHtml() {
    if (!isAdmin() || !cfg) return '';
    const s = cfg.settings, types = (typeof PROPERTY_TYPE_LABELS !== 'undefined') ? PROPERTY_TYPE_LABELS : {};
    const e = editing && cfg.rules.find((r) => r.id === editing) || {};
    const opt = (v, cur, lab) => '<option value="' + esc(v) + '"' + (v === cur ? ' selected' : '') + '>' + esc(lab) + '</option>';
    return '<section class="bk-settings"><h2>Ajustes de conexiones</h2><form id="cx-settings">' +
      '<label class="bk-check"><input type="checkbox" id="cx-enabled"' + (s.enabled ? ' checked' : '') + '> Solicitudes de contacto con tarifa activas <small>(apagado: el sitio sigue con WhatsApp directo)</small></label>' +
      '<label>Instrucciones de pago de la tarifa (cuenta, titular, referencia)<textarea id="cx-instr" rows="3" maxlength="1500">' + esc(s.pay_instructions) + '</textarea></label>' +
      '<label>Enlace de la imagen del QR <small>(opcional)</small><input id="cx-qr" type="url" maxlength="400" value="' + esc(s.pay_qr_url || '') + '"></label>' +
      '<label>Contrato marco — versión ' + esc(s.framework_version) + ' <small>(lo aceptan los titulares antes de publicar; <b>debe revisarlo un abogado en Bolivia</b>. Si cambias el texto, todos deberán aceptar la versión nueva)</small><textarea id="cx-fw" rows="8" maxlength="60000">' + esc(s.framework_text) + '</textarea></label>' +
      '<button class="btn btn-primary btn-sm" type="submit">Guardar ajustes</button></form></section>' +
      '<section class="bk-settings"><h2>Matriz de tarifas por conexión</h2>' +
      '<p class="bk-fine">Rangos fijos: ' + cfg.bounds.map((b) => esc(OP[b.operation]) + ' Bs ' + b.min_bs + '–' + b.max_bs).join(' · ') + '. Gana la regla más específica (tipo de inmueble y rango de valor) y, a igualdad, la de mayor prioridad. Los cambios no afectan a conexiones ya aceptadas.</p>' +
      '<table class="cx-table"><thead><tr><th>Operación</th><th>Tipo</th><th>Valor del inmueble (Bs)</th><th>Tarifa</th><th>Prior.</th><th></th></tr></thead><tbody>' +
      cfg.rules.map((r) => '<tr class="' + (r.active ? '' : 'is-off') + '"><td>' + esc(OP[r.operation]) + '</td><td>' + esc(r.property_type ? (types[r.property_type] || r.property_type) : 'Cualquiera') + '</td><td>' + (r.value_min_bs != null ? Number(r.value_min_bs).toLocaleString('es-BO') : '0') + ' – ' + (r.value_max_bs != null ? Number(r.value_max_bs).toLocaleString('es-BO') : '∞') + '</td><td><b>' + bs(r.fee_bs) + '</b>' + (r.provisional ? ' <span class="bk-chip bk-wait">provisional</span>' : '') + (r.active ? '' : ' <span class="bk-chip bk-bad">inactiva</span>') + '</td><td>' + r.priority + '</td><td><button class="btn btn-ghost btn-sm" data-rule-edit="' + r.id + '">Editar</button> <button class="btn btn-ghost btn-sm" data-rule-del="' + r.id + '">Eliminar</button></td></tr>').join('') +
      '</tbody></table>' +
      '<form id="cx-rule" class="cx-rule"><h3>' + (editing ? 'Editar regla #' + editing : 'Nueva regla') + '</h3>' +
      '<label>Operación<select id="cr-op">' + Object.keys(OP).map((k) => opt(k, e.operation || 'venta', OP[k])).join('') + '</select></label>' +
      '<label>Tipo de inmueble<select id="cr-type"><option value="">Cualquiera</option>' + Object.keys(types).map((k) => opt(k, e.property_type || '', types[k])).join('') + '</select></label>' +
      '<label>Valor mínimo (Bs) <small>(vacío = sin mínimo)</small><input id="cr-min" type="number" min="0" step="1" value="' + esc(e.value_min_bs ?? '') + '"></label>' +
      '<label>Valor máximo (Bs) <small>(vacío = sin máximo)</small><input id="cr-max" type="number" min="0" step="1" value="' + esc(e.value_max_bs ?? '') + '"></label>' +
      '<label>Tarifa (Bs)<input id="cr-fee" type="number" min="0" step="1" required value="' + esc(e.fee_bs ?? '') + '"></label>' +
      '<label>Prioridad<input id="cr-prio" type="number" step="1" value="' + esc(e.priority ?? 0) + '"></label>' +
      '<label>Nombre de la regla<input id="cr-label" type="text" maxlength="100" value="' + esc(e.label || '') + '"></label>' +
      '<label class="bk-check"><input id="cr-active" type="checkbox"' + (e.active === false ? '' : ' checked') + '> Activa</label>' +
      '<button class="btn btn-primary btn-sm" type="submit">' + (editing ? 'Guardar cambios' : 'Agregar regla') + '</button>' + (editing ? ' <button class="btn btn-ghost btn-sm" type="button" data-rule-cancel>Cancelar edición</button>' : '') + '</form>' +
      (cfg.history.length ? '<h3>Historial de cambios</h3><ul class="bk-events">' + cfg.history.map((h) => '<li><b>' + esc(h.action) + '</b> regla #' + h.rule_id + ' <small>' + ftime(h.at) + '</small>' + (h.after ? '<br><small>' + esc(h.after.operation) + ' · ' + bs(h.after.fee_bs) + (h.before ? ' (antes ' + bs(h.before.fee_bs) + ')' : '') + '</small>' : (h.before ? '<br><small>' + esc(h.before.operation) + ' · ' + bs(h.before.fee_bs) + '</small>' : '')) + '</li>').join('') + '</ul>' : '') +
      '</section>';
  }

  function draw() {
    const el = root(); if (!el) return;
    const shown = (data.items || []).filter((c) => filter === 'todas' || isLive(c));
    el.innerHTML = rulesHtml() +
      (!data.enabled && !isAdmin() ? '<p class="bk-fine">Las solicitudes de contacto con tarifa todavía no están activas en Bastet.</p>' : '') +
      '<div class="bk-filter"><button class="btn btn-sm ' + (filter === 'activas' ? 'btn-primary' : 'btn-ghost') + '" data-filter="activas">Activas</button><button class="btn btn-sm ' + (filter === 'todas' ? 'btn-primary' : 'btn-ghost') + '" data-filter="todas">Todas</button></div>' +
      (shown.length ? shown.map(card).join('') : '<p class="bk-empty">' + ((data.items || []).length ? 'No hay conexiones activas.' : 'Todavía no hay solicitudes de contacto.') + '</p>');
  }

  async function load() {
    const el = root(); if (!el) return;
    el.innerHTML = '<p class="bk-empty">Cargando…</p>';
    const { error } = await fetchData();
    if (error) { el.innerHTML = '<p class="form-error">' + (/function|schema cache/i.test(error.message || '') ? 'Las conexiones todavía no están activadas en la base de datos (falta correr supabase/connections.sql).' : esc(error.message)) + '</p>'; return; }
    if (isAdmin()) { const r = await supabaseClient.rpc('get_connection_settings'); cfg = r.error ? null : r.data; }
    draw();
  }
  async function reloadAll() { await fetchData(); if (isAdmin()) { const r = await supabaseClient.rpc('get_connection_settings'); cfg = r.error ? cfg : r.data; } draw(); }

  async function run(fn, okMsg) {
    if (busy) return; busy = true;
    try {
      const { error } = await fn();
      if (error) {
        if (error.hint === 'framework' || /contrato marco/i.test(error.message || '')) {
          toast('Primero debes aceptar el contrato marco de Bastet.', true);
          if (window.UnoPublications && window.UnoPublications.ensureFramework) { busy = false; if (await window.UnoPublications.ensureFramework()) toast('Contrato marco aceptado: vuelve a intentarlo.'); }
        } else toast(error.message || 'No se pudo completar', true);
      } else { if (okMsg) toast(okMsg); await reloadAll(); }
    } finally { busy = false; }
  }
  async function signed(path) {
    const { data: s, error } = await supabaseClient.storage.from('connection-proofs').createSignedUrl(path, 600);
    if (error || !s) { toast('No se pudo abrir el archivo', true); return; }
    window.open(s.signedUrl, '_blank', 'noopener');
  }

  async function showEvents(c) {
    const { data: ev, error } = await supabaseClient.rpc('connection_events', { p_id: c.id });
    if (error) { toast(error.message, true); return; }
    const o = document.createElement('div'); o.className = 'modal-overlay';
    o.innerHTML = '<div class="modal-panel" role="dialog" aria-modal="true"><h2>Historial · ' + esc(c.code) + '</h2><ul class="bk-events">' + (ev || []).map((e) => '<li><b>' + esc(String(e.event).replace(/_/g, ' ')) + '</b> <small>' + esc(e.actor) + ' · ' + ftime(e.at) + '</small>' + (e.data ? '<br><small>' + esc(JSON.stringify(e.data)) + '</small>' : '') + '</li>').join('') + '</ul><div class="modal-form-actions"><button type="button" class="btn btn-ghost" data-close>Cerrar</button></div></div>';
    document.body.appendChild(o);
    o.addEventListener('click', (e) => { if (e.target === o || e.target.closest('[data-close]')) o.remove(); });
  }

  async function upload(c, card) {
    const f = card.querySelector('[data-proof]').files[0];
    if (!f) { toast('Elige la foto o el PDF de tu comprobante.', true); return; }
    const ext = PROOF_TYPES[f.type];
    if (!ext) { toast('El comprobante debe ser una foto (JPG, PNG, WebP) o un PDF.', true); return; }
    if (f.size > 5 * 1024 * 1024) { toast('El archivo pesa más de 5 MB.', true); return; }
    const { data: u } = await supabaseClient.auth.getUser();
    const uid = u && u.user && u.user.id; if (!uid) return;
    const path = uid + '/' + Date.now() + '.' + ext;
    const up = await supabaseClient.storage.from('connection-proofs').upload(path, f, { contentType: f.type });
    if (up.error) { toast(up.error.message || 'No se pudo subir el archivo', true); return; }
    await run(() => supabaseClient.rpc('attach_connection_proof', { p_id: c.id, p_path: path }), 'Comprobante enviado. Bastet lo revisará.');
  }

  document.addEventListener('click', async (e) => {
    const f = e.target.closest('#connections-root [data-filter]'); if (f) { filter = f.dataset.filter; draw(); return; }
    const ed = e.target.closest('#connections-root [data-rule-edit]'); if (ed) { editing = Number(ed.dataset.ruleEdit); draw(); const form = document.getElementById('cx-rule'); if (form) form.scrollIntoView({ behavior: 'smooth', block: 'center' }); return; }
    if (e.target.closest('#connections-root [data-rule-cancel]')) { editing = null; draw(); return; }
    const del = e.target.closest('#connections-root [data-rule-del]');
    if (del) { if (window.confirm('¿Eliminar esta regla? Las conexiones ya aceptadas conservan su tarifa.')) run(() => supabaseClient.rpc('admin_delete_fee_rule', { p_id: Number(del.dataset.ruleDel) }), 'Regla eliminada'); return; }
    const btn = e.target.closest('#connections-root [data-act]'); if (!btn) return;
    const cardEl = btn.closest('.bk-card'); const c = (data.items || []).find((x) => x.id === cardEl.dataset.id); if (!c) return;
    switch (btn.dataset.act) {
      case 'accept': if (window.confirm('¿Aceptar esta solicitud? Al aceptar nace la obligación de pagar la tarifa de conexión a Bastet.')) run(() => supabaseClient.rpc('respond_connection', { p_id: c.id, p_accept: true }), 'Aceptaste la solicitud. Paga la tarifa para ver los datos del interesado.'); return;
      case 'reject': if (window.confirm('¿Rechazar esta solicitud?')) run(() => supabaseClient.rpc('respond_connection', { p_id: c.id, p_accept: false }), 'Solicitud rechazada'); return;
      case 'upload': return upload(c, cardEl);
      case 'proof': return signed(c.proof_path);
      case 'verify': if (window.confirm('¿Confirmas que recibiste el pago de ' + bs(c.fee_bs) + '? Se mostrarán los datos del interesado al titular.')) run(() => supabaseClient.rpc('admin_review_connection_proof', { p_id: c.id, p_approve: true, p_note: null }), 'Pago verificado: conexión generada'); return;
      case 'deny': { const n = window.prompt('Motivo del rechazo (lo verá el titular):'); if (n) run(() => supabaseClient.rpc('admin_review_connection_proof', { p_id: c.id, p_approve: false, p_note: n }), 'Comprobante rechazado'); return; }
      case 'cancel': { const n = window.prompt('Motivo de la cancelación (obligatorio):'); if (n) run(() => supabaseClient.rpc('admin_cancel_connection', { p_id: c.id, p_note: n }), 'Conexión cancelada'); return; }
      case 'events': return showEvents(c);
      default: return;
    }
  });
  document.addEventListener('submit', async (e) => {
    if (e.target.id === 'cx-settings') {
      e.preventDefault();
      await run(() => supabaseClient.rpc('admin_update_connection_settings', { p_enabled: document.getElementById('cx-enabled').checked, p_pay_instructions: document.getElementById('cx-instr').value,
        p_pay_qr_url: document.getElementById('cx-qr').value, p_framework_text: document.getElementById('cx-fw').value }), 'Ajustes guardados');
    }
    if (e.target.id === 'cx-rule') {
      e.preventDefault();
      const num = (id) => { const v = document.getElementById(id).value; return v === '' ? null : Number(v); };
      await run(async () => { const r = await supabaseClient.rpc('admin_save_fee_rule', { p_id: editing, p_operation: document.getElementById('cr-op').value, p_property_type: document.getElementById('cr-type').value || null,
        p_min_bs: num('cr-min'), p_max_bs: num('cr-max'), p_fee_bs: num('cr-fee'), p_priority: num('cr-prio') || 0, p_label: document.getElementById('cr-label').value, p_active: document.getElementById('cr-active').checked });
        if (!r.error) editing = null; return r; }, 'Regla guardada');
    }
  });

  const tab = document.querySelector('.admin-tab[data-tab="connections"]');
  if (tab) {
    tab.addEventListener('click', load);
    // Contador de la pestaña (solicitudes por responder; comprobantes por verificar para administración); se oculta si falta el SQL
    const poll = async () => {
      if (typeof supabaseClient === 'undefined' || document.hidden || busy || document.querySelector('.modal-overlay')) return;
      const { error } = await fetchData();
      if (error && /function|schema cache/i.test(error.message || '') && !isAdmin()) tab.classList.add('hidden');
      const panel = document.getElementById('tab-panel-connections');
      if (!error && panel && !panel.classList.contains('hidden') && !document.querySelector('#connections-root form :focus, #connections-root input:focus')) draw();
    };
    setTimeout(poll, 3000);
    setInterval(poll, 60000);
  }
})();
