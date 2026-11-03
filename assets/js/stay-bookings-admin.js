/* Panel «Reservas» (Estadías temporales). Anfitrión: responde solicitudes en 2 h, ve la conexión, cancela y declara si recibió el 90 % directo.
 * Administración: ve todas, verifica o rechaza comprobantes del 10 %, revisa lo declarado del 90 %, abre disputas, consulta el historial y
 * edita las reglas (interruptor, tipo de cambio interno, instrucciones de pago). Reglas en docs/ESPECIFICACION_MAESTRA.md; SQL en supabase/stay-bookings.sql.
 * Autónomo: usa el cliente global `supabaseClient` y `currentProfile`. */
(function () {
  'use strict';

  const root = () => document.getElementById('bookings-root');
  const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const isAdmin = () => typeof currentProfile !== 'undefined' && currentProfile && currentProfile.role === 'admin';
  const money = (n, c) => { const s = Number(n).toLocaleString('es-BO', { maximumFractionDigits: 2 }); return c === 'BOB' ? 'Bs ' + s : s + ' USD'; };
  const bs = (n) => 'Bs ' + Number(n).toLocaleString('es-BO', { maximumFractionDigits: 2 });
  const fdate = (d) => { const x = new Date(String(d).slice(0, 10) + 'T00:00:00'); return isNaN(x) ? '' : x.toLocaleDateString('es-BO', { day: '2-digit', month: 'short', year: 'numeric' }); };
  const ftime = (d) => { const x = new Date(d); return isNaN(x) ? '' : x.toLocaleString('es-BO', { day: '2-digit', month: 'short', hour: '2-digit', minute: '2-digit' }); };
  const waPhone = (v) => { const d = String(v || '').replace(/[^0-9]/g, ''); return /^[67][0-9]{7}$/.test(d) ? '591' + d : d; };
  const STATUS = {
    pendiente_respuesta_anfitrion: ['Esperando tu respuesta', 'wait'], rechazada: ['Rechazada', 'bad'], expirada: ['Expirada', 'bad'],
    aceptada_pendiente_pago: ['Esperando el pago del huésped', 'wait'], comprobante_enviado: ['Comprobante por verificar', 'wait'], pago_en_revision: ['Pago en revisión', 'wait'],
    pago_verificado: ['Pago verificado', 'ok'], conexion_generada: ['Confirmada', 'ok'], cancelada: ['Cancelada', 'bad'], en_disputa: ['En disputa', 'bad'],
  };
  const DIRECT = { no_recibido: 'No recibió el saldo', recibido_con_comprobante: 'Recibió el saldo (con comprobante)', declarado_sin_comprobante: 'Dice haberlo recibido (sin comprobante)' };
  let list = [], settings = null, busy = false, filter = 'activas';

  function toast(msg, bad) {
    let el = document.getElementById('ct-toast');
    if (!el) { el = document.createElement('div'); el.id = 'ct-toast'; el.setAttribute('role', 'status'); document.body.appendChild(el); }
    el.textContent = msg; el.className = 'ct-toast show' + (bad ? ' is-error' : '');
    clearTimeout(toast.t); toast.t = setTimeout(() => { el.className = 'ct-toast'; }, 4200);
  }

  async function fetchList() {
    const { data, error } = await supabaseClient.rpc('my_stay_bookings');
    if (error) return { error };
    list = data || [];
    badge();
    return {};
  }
  function badge() {
    const el = document.getElementById('bookings-count'); if (!el) return;
    const n = list.filter((b) => b.status === 'pendiente_respuesta_anfitrion' || (isAdmin() && ['comprobante_enviado', 'pago_en_revision'].includes(b.status))).length;
    el.textContent = n; el.classList.toggle('hidden', !n);
  }

  const isLive = (b) => ['pendiente_respuesta_anfitrion', 'aceptada_pendiente_pago', 'comprobante_enviado', 'pago_en_revision', 'pago_verificado', 'conexion_generada', 'en_disputa'].includes(b.status) || b.needs_direct_declaration;

  function card(b) {
    const [label, tone] = STATUS[b.status] || [b.status, 'wait'];
    const adm = isAdmin();
    let h = '<article class="bk-card" data-id="' + esc(b.id) + '"><header><div><b>' + esc(b.title) + '</b><span class="bk-code">' + esc(b.code) + '</span></div><span class="bk-chip bk-' + tone + '">' + esc(label) + '</span></header>' +
      '<p class="bk-meta">' + esc(b.guest_name) + ' · ' + b.guests + ' huésped(es) · ' + fdate(b.check_in) + ' – ' + fdate(b.check_out) + ' (' + b.nights + ' noches)' + (adm && b.host_name ? ' · Anfitrión: ' + esc(b.host_name) : '') + '</p>' +
      '<p class="bk-money">Total ' + money(b.total, b.currency) + ' · Bastet 10 %: <b>' + bs(b.fee_bs) + '</b> · Saldo directo al anfitrión: ' + money(b.balance, b.currency) + '</p>';
    if (b.guest_phone) h += '<p class="bk-contact">Huésped: <a target="_blank" rel="noopener" href="https://api.whatsapp.com/send?phone=' + esc(waPhone(b.guest_phone)) + '">' + esc(b.guest_phone) + '</a>' + (b.guest_email ? ' · ' + esc(b.guest_email) : '') + '</p>';
    else if (b.status !== 'rechazada' && b.status !== 'expirada') h += '<p class="bk-fine">El contacto del huésped se muestra cuando Bastet verifica su pago.</p>';
    if (b.status === 'pendiente_respuesta_anfitrion') h += '<p class="bk-fine">Responde antes del <b>' + ftime(b.respond_by) + '</b> o la solicitud vence.</p><div class="bk-actions"><button class="btn btn-primary btn-sm" data-act="accept">Aceptar</button><button class="btn btn-ghost btn-sm" data-act="reject">Rechazar</button></div>';
    if (b.status === 'aceptada_pendiente_pago' && b.pay_by) h += '<p class="bk-fine">El huésped tiene hasta el <b>' + ftime(b.pay_by) + '</b> para pagar; si no, la reserva vence y las fechas se liberan.</p>';
    if (adm && ['comprobante_enviado', 'pago_en_revision'].includes(b.status)) h += '<div class="bk-actions"><button class="btn btn-ghost btn-sm" data-act="proof">Ver comprobante</button><button class="btn btn-primary btn-sm" data-act="verify">Verificar pago y revelar contacto</button><button class="btn btn-ghost btn-sm" data-act="deny">Rechazar comprobante</button></div>';
    if (b.review_note && b.status === 'aceptada_pendiente_pago') h += '<p class="bk-fine">Último rechazo: ' + esc(b.review_note) + '</p>';
    if (b.status === 'cancelada') {
      h += '<p class="bk-fine">Cancelada por ' + ({ guest: 'el huésped', host: 'el anfitrión', admin: 'administración' }[b.cancelled_by] || '—') + (b.cancel_reason ? ': ' + esc(b.cancel_reason) : '') + '. ' +
        (b.late_cancel ? 'Cancelación tardía: se retiene el 20 % (10 % Bastet, 10 % anfitrión ' + money(b.host_retention, b.currency) + '). ' : '') +
        (Number(b.bastet_refund_bs) > 0 ? 'Bastet devuelve ' + bs(b.bastet_refund_bs) + '. ' : '') +
        (b.host_refund_due ? 'El anfitrión debe devolver directo al huésped hasta ' + money(b.host_refund_due, b.currency) + ' si recibió el saldo.' : '') + '</p>';
    }
    if (b.direct_status) h += '<p class="bk-fine">Saldo directo: <b>' + esc(DIRECT[b.direct_status]) + '</b>' + (b.direct_amount ? ' · ' + money(b.direct_amount, b.currency) + ' el ' + fdate(b.direct_date) + (b.direct_method ? ' (' + esc(b.direct_method) + ')' : '') : '') +
      ' · Revisión: ' + esc(b.direct_review || 'pendiente') + (b.direct_review_note ? ' — ' + esc(b.direct_review_note) : '') + '</p>';
    const acts = [];
    if (['conexion_generada', 'en_disputa'].includes(b.status) || (b.status === 'cancelada' && b.verified_at)) acts.push('<button class="btn btn-ghost btn-sm" data-act="declare">' + (b.needs_direct_declaration ? '⚠ Declarar si recibiste el saldo' : 'Declarar saldo recibido') + '</button>');
    if (['aceptada_pendiente_pago', 'comprobante_enviado', 'pago_en_revision', 'conexion_generada'].includes(b.status)) acts.push('<button class="btn btn-ghost btn-sm" data-act="hostcancel">Cancelar reserva</button>');
    if (adm) {
      if (['aceptada_pendiente_pago', 'conexion_generada'].includes(b.status) && b.guest_phone) acts.push('<button class="btn btn-primary btn-sm" data-act="notifyguest">' + (b.status === 'conexion_generada' ? 'Avisar al huésped: reserva confirmada' : 'Avisar al huésped por WhatsApp') + '</button>');
      if (b.status === 'pendiente_respuesta_anfitrion' && b.host_whatsapp) acts.push('<button class="btn btn-primary btn-sm" data-act="notify">Avisar al anfitrión por WhatsApp</button>');
      if (b.direct_proof_path) acts.push('<button class="btn btn-ghost btn-sm" data-act="directproof">Ver constancia del saldo</button>');
      if (b.direct_status) acts.push('<button class="btn btn-ghost btn-sm" data-act="directreview">Revisar saldo declarado</button>');
      if (['conexion_generada', 'cancelada'].includes(b.status)) acts.push('<button class="btn btn-ghost btn-sm" data-act="dispute">Abrir disputa</button>');
      if (b.status === 'en_disputa') acts.push('<button class="btn btn-ghost btn-sm" data-act="closedispute">Cerrar disputa</button>');
      acts.push('<button class="btn btn-ghost btn-sm" data-act="events">Historial</button>');
    }
    if (acts.length) h += '<div class="bk-actions">' + acts.join('') + '</div>';
    return h + '</article>';
  }

  function settingsCard() {
    if (!isAdmin() || !settings) return '';
    return '<section class="bk-settings"><h2>Reglas de reservas</h2><form id="bk-settings-form">' +
      '<label class="bk-check"><input type="checkbox" id="bk-enabled"' + (settings.enabled ? ' checked' : '') + '> Reservas con pago del 10 % activas en Estadías <small>(apagado: el sitio sigue consultando por WhatsApp)</small></label>' +
      '<label>Tipo de cambio interno de Bastet (Bs por USD)<input id="bk-rate" type="number" step="0.0001" min="0.01" value="' + esc(settings.bob_per_usd) + '"></label>' +
      '<label>Instrucciones de pago (cuenta bancaria, titular, referencia)<textarea id="bk-instr" rows="4" maxlength="1500">' + esc(settings.pay_instructions) + '</textarea></label>' +
      '<label>Horas que tiene el huésped para pagar tras la aceptación <small>(vacío = sin plazo)</small><input id="bk-pw" type="number" min="1" max="720" step="1" value="' + esc(settings.pay_window_hours ?? '') + '"></label>' +
      '<label>Enlace de la imagen del QR de pago <small>(opcional)</small><input id="bk-qr" type="url" maxlength="400" value="' + esc(settings.pay_qr_url || '') + '"></label>' +
      '<p class="bk-fine">Fijos por la especificación: comisión ' + esc(String(settings.fee_percent).replace('.', ',')) + ' %, respuesta del anfitrión ' + esc(settings.response_hours) + ' h, cancelación gratuita durante ' + esc(settings.free_cancel_hours) + ' h desde que se verifica el pago. ' +
      '</p>' +
      '<button class="btn btn-primary btn-sm" type="submit">Guardar reglas</button></form></section>';
  }

  function draw() {
    const el = root(); if (!el) return;
    const shown = list.filter((b) => filter === 'todas' || isLive(b));
    el.innerHTML = settingsCard() +
      '<div class="bk-filter"><button class="btn btn-sm ' + (filter === 'activas' ? 'btn-primary' : 'btn-ghost') + '" data-filter="activas">Activas</button><button class="btn btn-sm ' + (filter === 'todas' ? 'btn-primary' : 'btn-ghost') + '" data-filter="todas">Todas (18 meses)</button></div>' +
      (shown.length ? shown.map(card).join('') : '<p class="bk-empty">' + (list.length ? 'No hay reservas activas.' : 'Todavía no hay solicitudes de reserva.') + '</p>');
  }

  async function load() {
    const el = root(); if (!el) return;
    el.innerHTML = '<p class="bk-empty">Cargando…</p>';
    const { error } = await fetchList();
    if (error) { el.innerHTML = '<p class="form-error">' + (/function|schema cache/i.test(error.message || '') ? 'Las reservas todavía no están activadas en la base de datos (falta correr supabase/stay-bookings.sql).' : esc(error.message)) + '</p>'; return; }
    if (isAdmin()) { const r = await supabaseClient.rpc('get_stay_settings'); settings = r.error ? null : r.data; }
    draw();
  }

  async function run(fn, okMsg) {
    if (busy) return; busy = true;
    try { const { error } = await fn(); if (error) toast(error.message || 'No se pudo completar', true); else { if (okMsg) toast(okMsg); await fetchList(); draw(); } } finally { busy = false; }
  }
  async function signed(path) {
    const { data, error } = await supabaseClient.storage.from('stay-proofs').createSignedUrl(path, 600);
    if (error || !data) { toast('No se pudo abrir el archivo', true); return; }
    window.open(data.signedUrl, '_blank', 'noopener');
  }

  function declareModal(b) {
    const o = document.createElement('div'); o.className = 'modal-overlay';
    o.innerHTML = '<div class="modal-panel" role="dialog" aria-modal="true"><h2>Saldo directo del huésped</h2>' +
      '<p class="bk-fine">Bastet no cobra ni garantiza este saldo (' + money(b.balance, b.currency) + '). Declara con honestidad si lo recibiste; administración puede pedirte el comprobante.</p>' +
      '<form id="bk-declare"><label>¿Recibiste el saldo?<select id="bk-ds"><option value="no_recibido">No lo recibí</option><option value="recibido_con_comprobante">Sí, con comprobante</option><option value="declarado_sin_comprobante">Sí, sin comprobante</option></select></label>' +
      '<div id="bk-dfields" class="hidden"><label>Importe recibido (' + (b.currency === 'BOB' ? 'Bs' : 'USD') + ')<input id="bk-da" type="number" min="0" step="0.01"></label><label>Fecha<input id="bk-dd" type="date"></label>' +
      '<label>Medio de pago<input id="bk-dm" type="text" maxlength="60" placeholder="QR, transferencia, efectivo…"></label><label id="bk-dfl" class="hidden">Comprobante (foto o PDF, hasta 5 MB)<input id="bk-df" type="file" accept="image/jpeg,image/png,image/webp,application/pdf"></label></div>' +
      '<p class="form-error hidden" id="bk-derr"></p><div class="modal-form-actions"><button type="button" class="btn btn-ghost" data-close>Cerrar</button><button class="btn btn-primary" type="submit">Guardar declaración</button></div></form></div>';
    document.body.appendChild(o);
    const sel = o.querySelector('#bk-ds');
    sel.addEventListener('change', () => { o.querySelector('#bk-dfields').classList.toggle('hidden', sel.value === 'no_recibido'); o.querySelector('#bk-dfl').classList.toggle('hidden', sel.value !== 'recibido_con_comprobante'); });
    o.addEventListener('click', (e) => { if (e.target === o || e.target.closest('[data-close]')) o.remove(); });
    o.querySelector('#bk-declare').addEventListener('submit', async (e) => {
      e.preventDefault();
      const err = o.querySelector('#bk-derr'); err.classList.add('hidden');
      let path = null; const f = o.querySelector('#bk-df').files[0];
      try {
        if (sel.value === 'recibido_con_comprobante') {
          if (!f) throw new Error('Adjunta el comprobante o elige «Sí, sin comprobante».');
          if (f.size > 5 * 1024 * 1024) throw new Error('El archivo pesa más de 5 MB.');
          const ext = { 'image/jpeg': 'jpg', 'image/png': 'png', 'image/webp': 'webp', 'application/pdf': 'pdf' }[f.type];
          if (!ext) throw new Error('El comprobante debe ser una foto o un PDF.');
          path = 'host/' + b.id + '/' + Date.now() + '.' + ext;
          const up = await supabaseClient.storage.from('stay-proofs').upload(path, f, { contentType: f.type });
          if (up.error) throw up.error;
        }
        const { error } = await supabaseClient.rpc('host_declare_direct_payment', { p_booking: b.id, p_status: sel.value,
          p_amount: sel.value === 'no_recibido' ? null : Number(o.querySelector('#bk-da').value) || null, p_date: sel.value === 'no_recibido' ? null : (o.querySelector('#bk-dd').value || null),
          p_method: o.querySelector('#bk-dm').value || null, p_proof_path: path });
        if (error) throw error;
        o.remove(); toast('Declaración guardada'); await fetchList(); draw();
      } catch (ex) { err.textContent = ex.message || 'No se pudo guardar'; err.classList.remove('hidden'); }
    });
  }

  async function showEvents(b) {
    const { data, error } = await supabaseClient.rpc('stay_booking_events', { p_booking: b.id });
    if (error) { toast(error.message, true); return; }
    const o = document.createElement('div'); o.className = 'modal-overlay';
    o.innerHTML = '<div class="modal-panel" role="dialog" aria-modal="true"><h2>Historial · ' + esc(b.code) + '</h2><ul class="bk-events">' + (data || []).map((e) =>
      '<li><b>' + esc(e.event.replace(/_/g, ' ')) + '</b> <small>' + esc(e.actor) + ' · ' + ftime(e.at) + '</small>' + (e.from || e.to ? '<br><small>' + esc(e.from || '—') + ' → ' + esc(e.to || '—') + '</small>' : '') +
      (e.data ? '<br><small>' + esc(JSON.stringify(e.data)) + '</small>' : '') + '</li>').join('') + '</ul><div class="modal-form-actions"><button type="button" class="btn btn-ghost" data-close>Cerrar</button></div></div>';
    document.body.appendChild(o);
    o.addEventListener('click', (e) => { if (e.target === o || e.target.closest('[data-close]')) o.remove(); });
  }

  document.addEventListener('click', async (e) => {
    const f = e.target.closest('#bookings-root [data-filter]'); if (f) { filter = f.dataset.filter; draw(); return; }
    const btn = e.target.closest('#bookings-root [data-act]'); if (!btn) return;
    const b = list.find((x) => x.id === btn.closest('.bk-card').dataset.id); if (!b) return;
    const id = b.id;
    switch (btn.dataset.act) {
      case 'accept': return run(() => supabaseClient.rpc('host_respond_stay_booking', { p_booking: id, p_accept: true }), 'Aceptaste la solicitud: el huésped ya puede pagar a Bastet.');
      case 'reject': if (window.confirm('¿Rechazar esta solicitud?')) run(() => supabaseClient.rpc('host_respond_stay_booking', { p_booking: id, p_accept: false }), 'Solicitud rechazada'); return;
      case 'notify': {
        const msg = 'Hola' + (b.host_name ? ' ' + b.host_name.split(' ')[0] : '') + ', tienes una solicitud de reserva de ' + b.guest_name + ' para «' + b.title + '» del ' + fdate(b.check_in) + ' al ' + fdate(b.check_out) + ' (' + b.nights + ' noches). Responde antes del ' + ftime(b.respond_by) + ' en https://bastet.uno/admin/ (pestaña Reservas).';
        window.open('https://api.whatsapp.com/send?phone=' + waPhone(b.host_whatsapp) + '&text=' + encodeURIComponent(msg), '_blank', 'noopener'); return;
      }
      case 'notifyguest': {
        const link = 'https://bastet.uno/estadias.html?reserva=' + b.code;
        const msg = b.status === 'conexion_generada'
          ? 'Hola ' + b.guest_name.split(' ')[0] + ', tu pago fue verificado y tu reserva de «' + b.title + '» está confirmada. Mira aquí el WhatsApp del anfitrión: ' + link
          : 'Hola ' + b.guest_name.split(' ')[0] + ', el anfitrión aceptó tu reserva de «' + b.title + '» del ' + fdate(b.check_in) + ' al ' + fdate(b.check_out) + '. Para confirmarla paga el 10 % (' + bs(b.fee_bs) + ') y sube tu comprobante' + (b.pay_by ? ' antes del ' + ftime(b.pay_by) : '') + ' aquí: ' + link;
        window.open('https://api.whatsapp.com/send?phone=' + waPhone(b.guest_phone) + '&text=' + encodeURIComponent(msg), '_blank', 'noopener'); return;
      }
      case 'proof': return signed(b.proof_path);
      case 'directproof': return signed(b.direct_proof_path);
      case 'verify': if (window.confirm('¿Confirmas que recibiste el pago de ' + bs(b.fee_bs) + '? Se revelará el contacto entre huésped y anfitrión.')) run(() => supabaseClient.rpc('admin_review_stay_proof', { p_booking: id, p_approve: true, p_note: null }), 'Pago verificado: contacto revelado'); return;
      case 'deny': { const n = window.prompt('Motivo del rechazo (lo verá el huésped):'); if (n) run(() => supabaseClient.rpc('admin_review_stay_proof', { p_booking: id, p_approve: false, p_note: n }), 'Comprobante rechazado'); return; }
      case 'hostcancel': { const n = window.prompt('Motivo de la cancelación (obligatorio). Bastet devolverá el 10 % al huésped; tú debes devolver directo el saldo si lo recibiste:'); if (n) run(() => supabaseClient.rpc('host_cancel_stay_booking', { p_booking: id, p_reason: n }), 'Reserva cancelada'); return; }
      case 'declare': return declareModal(b);
      case 'directreview': { const v = window.prompt('Estado de la revisión: revisado, controvertido o pendiente', b.direct_review || 'revisado'); if (!v) return; const n = window.prompt('Nota (opcional):', b.direct_review_note || ''); run(() => supabaseClient.rpc('admin_review_direct_payment', { p_booking: id, p_review: v.trim().toLowerCase(), p_note: n }), 'Revisión guardada'); return; }
      case 'dispute': { const n = window.prompt('Motivo de la disputa:'); if (n) run(() => supabaseClient.rpc('admin_set_stay_dispute', { p_booking: id, p_open: true, p_note: n }), 'Disputa abierta'); return; }
      case 'closedispute': { const n = window.prompt('Resolución:'); if (n) run(() => supabaseClient.rpc('admin_set_stay_dispute', { p_booking: id, p_open: false, p_note: n }), 'Disputa cerrada'); return; }
      case 'events': return showEvents(b);
      default: return;
    }
  });
  document.addEventListener('submit', async (e) => {
    if (e.target.id !== 'bk-settings-form') return;
    e.preventDefault();
    const { error } = await supabaseClient.rpc('admin_update_stay_settings', { p_enabled: document.getElementById('bk-enabled').checked, p_bob_per_usd: Number(document.getElementById('bk-rate').value),
      p_pay_instructions: document.getElementById('bk-instr').value, p_pay_qr_url: document.getElementById('bk-qr').value,
      p_pay_window_hours: document.getElementById('bk-pw').value === '' ? null : Number(document.getElementById('bk-pw').value) });
    if (error) { toast(error.message, true); return; }
    toast('Reglas guardadas'); load();
  });

  // Mientras el panel está abierto, se actualiza solo (para ver solicitudes nuevas dentro de las 2 horas)
  setInterval(async () => {
    if (typeof supabaseClient === 'undefined' || document.hidden || busy || document.querySelector('.modal-overlay')) return;
    const { error } = await fetchList();
    const panel = document.getElementById('tab-panel-bookings');
    if (!error && panel && !panel.classList.contains('hidden') && !document.querySelector('#bookings-root form :focus')) draw();
  }, 60000);

  const tab = document.querySelector('.admin-tab[data-tab="bookings"]');
  if (tab) {
    tab.addEventListener('click', load);
    // El contador se carga al entrar al panel (sin esperar a que abran la pestaña)
    // Si la base de datos aún no tiene las reservas, solo el administrador ve la pestaña (con el aviso de qué SQL falta)
    setTimeout(async () => {
      if (typeof supabaseClient === 'undefined') return;
      const { error } = await fetchList();
      if (error && /function|schema cache/i.test(error.message || '') && !isAdmin()) tab.classList.add('hidden');
    }, 2500);
  }
})();
