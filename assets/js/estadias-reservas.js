/* Reservas de Estadías (huésped): solicitar, seguir la reserva con su código, pagar el 10 % a Bastet con comprobante y cancelar.
 * Reglas y estados: docs/ESPECIFICACION_MAESTRA.md (secciones 3 y 4). Funciones SQL en supabase/stay-bookings.sql.
 * El huésped no necesita cuenta: su código de 10 caracteres es el acceso. El 90 % restante se paga directo al anfitrión: Bastet no lo cobra.
 * Está apagado hasta que un administrador lo activa (stay_settings.enabled); apagado, Estadías consulta por WhatsApp como antes.
 * Autónomo: usa el cliente global `supabaseClient`. Expone window.StayBooking. */
(function () {
  'use strict';

  const KEY = 'bastet-stay-bookings';
  const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const plural = (n, one, many) => (n === 1 ? one : many);
  const money = (n, currency) => { const s = Number(n).toLocaleString('es-BO', { maximumFractionDigits: 2 }); return currency === 'BOB' ? 'Bs ' + s : s + ' USD'; };
  const bs = (n) => 'Bs ' + Number(n).toLocaleString('es-BO', { maximumFractionDigits: 2 });
  const fdate = (iso) => { const d = new Date(String(iso).slice(0, 10) + 'T00:00:00'); return isNaN(d) ? '' : d.toLocaleDateString('es-BO', { day: '2-digit', month: 'short', year: 'numeric' }); };
  const ftime = (iso) => { const d = new Date(iso); return isNaN(d) ? '' : d.toLocaleString('es-BO', { day: '2-digit', month: 'short', hour: '2-digit', minute: '2-digit' }); };
  const waPhone = (v) => { const d = String(v || '').replace(/[^0-9]/g, ''); return /^[67][0-9]{7}$/.test(d) ? '591' + d : d; };
  const MAX_PROOF = 5 * 1024 * 1024;
  const PROOF_TYPES = ['image/jpeg', 'image/png', 'image/webp', 'application/pdf'];

  let on = false;
  const S = window.StayBooking = {};

  const saved = () => { try { return JSON.parse(localStorage.getItem(KEY) || '[]'); } catch (e) { return []; } };
  const remember = (code, title) => { try { const l = saved().filter((x) => x.code !== code); l.unshift({ code, title }); localStorage.setItem(KEY, JSON.stringify(l.slice(0, 10))); } catch (e) { /* sin almacenamiento */ } };

  S.init = async function () {
    try { const { data, error } = await supabaseClient.rpc('stay_booking_enabled'); on = !error && data === true; } catch (e) { on = false; }
    return on;
  };
  S.isOn = () => on;
  S.saved = saved;

  /* ───────── Ventana ───────── */
  function openModal() {
    const prev = document.querySelector('.stay-review-modal.sbk'); if (prev) prev.remove();
    const modal = document.createElement('div');
    modal.className = 'stay-review-modal sbk'; modal.setAttribute('role', 'dialog'); modal.setAttribute('aria-modal', 'true');
    document.body.appendChild(modal); document.body.classList.add('sd-open');
    let timer = null;
    const close = () => {
      clearInterval(timer); modal.remove();
      if (!document.querySelector('.stay-detail:not(.hidden), #stay-detail:not(.hidden)')) document.body.classList.remove('sd-open');
      const u = new URL(location.href); if (u.searchParams.has('reserva')) { u.searchParams.delete('reserva'); history.replaceState(null, '', u.pathname + (u.search || '')); }
    };
    const card = (html) => { modal.innerHTML = '<div class="srm-card sbk-card">' + html + '</div>'; modal.querySelectorAll('[data-close]').forEach((b) => b.addEventListener('click', close)); };
    modal.addEventListener('click', (e) => { if (e.target === modal) close(); });
    modal.addEventListener('keydown', (e) => { if (e.key === 'Escape') close(); });
    return { modal, card, close, setTimer: (t) => { clearInterval(timer); timer = t; } };
  }

  /* ───────── Solicitar ───────── */
  S.request = function (p, sel) {
    const { modal, card, close } = openModal();
    const n = Math.round((new Date(sel.to + 'T00:00:00') - new Date(sel.from + 'T00:00:00')) / 86400000);
    const price = parseInt(String(p.price || '').replace(/[^0-9]/g, ''), 10) || 0;
    const total = price * n;
    const form = () => card(
      '<h2>Solicitar reserva</h2><p class="srm-place"><b>' + esc(p.title) + '</b><br>' + esc(p.location || '') + '</p>' +
      '<ul class="sd-sum sd-sum--detail"><li><span>Fechas</span><b>' + fdate(sel.from) + ' – ' + fdate(sel.to) + '</b></li><li><span>Huéspedes</span><b>' + sel.guests + '</b></li>' +
        '<li><span>' + money(price, p.currency) + ' × ' + n + ' ' + plural(n, 'noche', 'noches') + '</span><b>' + money(total, p.currency) + '</b></li></ul>' +
      '<div class="sbk-how"><b>Cómo funciona</b><ol><li>El anfitrión tiene <b>2 horas</b> para aceptar tu solicitud.</li><li>Si acepta, tienes un plazo (lo verás en tu reserva) para pagar a Bastet el <b>10 %</b> del total (QR o transferencia) y subir tu comprobante.</li>' +
        '<li>Cuando Bastet verifica el pago, te mostramos el WhatsApp del anfitrión.</li><li>El <b>90 %</b> restante lo coordinas directo con el anfitrión: Bastet no lo cobra ni lo garantiza.</li></ol></div>' +
      '<form id="sbk-form" novalidate>' +
        '<label class="srm-label" for="sbk-name">Tu nombre</label><input id="sbk-name" type="text" maxlength="60" autocomplete="name" required>' +
        '<label class="srm-label" for="sbk-phone">Tu WhatsApp</label><input id="sbk-phone" type="tel" maxlength="20" autocomplete="tel" placeholder="+591 7xxxxxxx" required>' +
        '<label class="srm-label" for="sbk-mail">Correo <span>(opcional)</span></label><input id="sbk-mail" type="email" maxlength="120" autocomplete="email">' +
        '<p class="srm-error" id="sbk-error" hidden></p>' +
        '<div class="srm-actions"><button type="button" class="srm-ghost" data-close>Cancelar</button><button type="submit" class="srm-btn" id="sbk-send">Enviar solicitud</button></div>' +
        '<p class="sd-muted sd-fine">Todavía no pagas nada. Guardaremos tu nombre y WhatsApp solo para esta reserva.</p>' +
      '</form>');
    form();
    if (window.ClientPrefill) window.ClientPrefill.fill(modal, { '#sbk-name': 'name', '#sbk-phone': 'phone', '#sbk-mail': 'email' });
    modal.addEventListener('submit', async (e) => {
      if (e.target.id !== 'sbk-form') return;
      e.preventDefault();
      const err = modal.querySelector('#sbk-error'); err.hidden = true;
      const name = modal.querySelector('#sbk-name').value.trim(), phone = modal.querySelector('#sbk-phone').value.trim(), mail = modal.querySelector('#sbk-mail').value.trim();
      if (name.length < 2) { err.textContent = 'Escribe tu nombre.'; err.hidden = false; return; }
      if (phone.replace(/[^0-9]/g, '').length < 7) { err.textContent = 'Escribe un número de WhatsApp válido.'; err.hidden = false; return; }
      const send = modal.querySelector('#sbk-send'); send.disabled = true; send.textContent = 'Enviando…';
      const { data, error } = await supabaseClient.rpc('create_stay_booking', { p_property: p.id, p_from: sel.from, p_to: sel.to, p_guests: sel.guests, p_name: name, p_phone: phone, p_email: mail || null });
      if (error) { err.textContent = error.message || 'No se pudo enviar la solicitud.'; err.hidden = false; send.disabled = false; send.textContent = 'Enviar solicitud'; return; }
      remember(data, p.title);
      close();
      S.openTrack(data, true);
    });
    modal.querySelector('#sbk-name').focus();
  };

  /* ───────── Seguimiento ───────── */
  S.openTrack = async function (code, fresh) {
    const { modal, card, close, setTimer } = openModal();
    const url = new URL(location.href); url.searchParams.set('reserva', code); history.replaceState(null, '', url.pathname + url.search);
    card('<p class="sd-muted">Buscando tu reserva…</p>');
    let busy = false;

    async function load() {
      let b = null;
      try { const { data, error } = await supabaseClient.rpc('get_stay_booking', { p_code: code }); if (!error) b = data; } catch (e) { /* sin red */ }
      if (!b || !b.found) { card('<h2>Reserva no encontrada</h2><p>Revisa que el código esté completo.</p><button type="button" class="srm-btn" data-close>Cerrar</button>'); setTimer(null); return; }
      paint(b);
      // Mientras espera al anfitrión o al comprobante, se actualiza sola
      setTimer(['pendiente_respuesta_anfitrion', 'comprobante_enviado', 'pago_en_revision'].includes(b.status) ? setInterval(() => { const fi = modal.querySelector('input[type=file]'); if (!busy && !(fi && fi.files.length)) load(); }, 30000) : null);
    }

    function head(b) {
      return '<h2>Tu reserva</h2><p class="srm-place"><b>' + esc(b.title) + '</b><br>' + esc(b.location || '') + '<br>' + fdate(b.check_in) + ' – ' + fdate(b.check_out) + ' · ' + b.nights + ' ' + plural(b.nights, 'noche', 'noches') + ' · ' + b.guests + ' ' + plural(b.guests, 'huésped', 'huéspedes') + '</p>' +
        '<p class="sbk-code">Código <b>' + esc(b.code) + '</b></p>';
    }
    function moneyBox(b) {
      return '<ul class="sd-sum sd-sum--detail"><li><span>Total de la estadía</span><b>' + money(b.total, b.currency) + '</b></li>' +
        '<li><span>Pagas a Bastet (' + String(b.fee_percent).replace('.', ',') + ' %)</span><b>' + bs(b.fee_bs) + '</b></li>' +
        '<li><span>Saldo que pagas directo al anfitrión</span><b>' + money(b.balance, b.currency) + '</b></li></ul>';
    }
    const cancelBtn = '<button type="button" class="srm-ghost sbk-cancel" data-cancel>Cancelar reserva</button>';

    function paint(b) {
      let body = head(b);
      switch (b.status) {
        case 'pendiente_respuesta_anfitrion':
          body += '<div class="sbk-state sbk-wait"><b>Esperando al anfitrión</b><p>Tiene hasta el <b>' + ftime(b.respond_by) + '</b> para responder. Esta página se actualiza sola; guarda el enlace para volver.</p></div>' + moneyBox(b) + cancelBtn; break;
        case 'rechazada':
          body += '<div class="sbk-state sbk-bad"><b>El anfitrión no pudo aceptar esta solicitud</b><p>No se cobró nada. Puedes buscar otro alojamiento o elegir otras fechas.</p></div>'; break;
        case 'expirada':
          body += '<div class="sbk-state sbk-bad"><b>La solicitud venció</b><p>El anfitrión no respondió a tiempo o no se completó el pago. No se cobró nada.</p></div>'; break;
        case 'aceptada_pendiente_pago':
          body += '<div class="sbk-state sbk-ok"><b>¡El anfitrión aceptó!</b><p>Para confirmar, paga el 10 % a Bastet y sube tu comprobante' + (b.pay_by ? ' <b>antes del ' + ftime(b.pay_by) + '</b>; si no, la reserva vence' : '') + '.</p></div>' + moneyBox(b) + payBox(b) + cancelBtn; break;
        case 'comprobante_enviado': case 'pago_en_revision':
          body += '<div class="sbk-state sbk-wait"><b>Estamos verificando tu pago</b><p>Cuando Bastet lo confirme te mostramos aquí el WhatsApp del anfitrión. Esta página se actualiza sola.</p></div>' + moneyBox(b) + cancelBtn; break;
        case 'conexion_generada': case 'pago_verificado':
          body += '<div class="sbk-state sbk-ok"><b>Pago verificado: tu reserva está confirmada</b><p>Coordina ahora con ' + esc(b.host_name || 'tu anfitrión') + ' la llegada y el pago del saldo.' + (b.host_whatsapp ? ' Su WhatsApp: <b>' + esc(b.host_whatsapp) + '</b>.' : '') + '</p>' +
            (b.host_whatsapp ? '<a class="sd-cta sbk-wa" target="_blank" rel="noopener" href="https://api.whatsapp.com/send?phone=' + esc(waPhone(b.host_whatsapp)) + '&text=' + encodeURIComponent('Hola, soy ' + b.guest_name + '. Reservé «' + b.title + '» del ' + fdate(b.check_in) + ' al ' + fdate(b.check_out) + ' (código ' + b.code + ').') + '">Escribir al anfitrión por WhatsApp</a>' : '') + '</div>' +
            moneyBox(b) + '<p class="sd-fine sbk-policy">El saldo (' + money(b.balance, b.currency) + ') lo pagas <b>directamente al anfitrión</b>: Bastet no lo recibe ni lo garantiza. ' +
            'Cancelación gratuita durante las ' + b.free_cancel_hours + ' horas siguientes a la confirmación (hasta el ' + ftime(b.free_cancel_until) + '); después se retiene el 20 % del total (10 % para Bastet y 10 % para el anfitrión).</p><p class="sd-fine"><a href="verificar.html?c=' + esc(b.code) + '">Ver la verificación de esta reserva</a></p>' + cancelBtn; break;
        case 'cancelada':
          body += '<div class="sbk-state sbk-bad"><b>Reserva cancelada' + (b.cancelled_by === 'host' ? ' por el anfitrión' : '') + '</b>' + cancelledText(b) + '</div>'; break;
        case 'en_disputa':
          body += '<div class="sbk-state sbk-wait"><b>Reserva en revisión</b><p>Bastet está revisando esta reserva. Si necesitas algo, escríbenos por WhatsApp indicando tu código.</p></div>'; break;
        default: break;
      }
      card(body + '<p class="srm-error" id="sbk-error" hidden></p><div class="srm-actions"><button type="button" class="srm-ghost" data-close>Cerrar</button></div>');
      bind(b);
    }

    function cancelledText(b) {
      const parts = [];
      if (b.cancelled_by === 'host') {
        parts.push('<p>Bastet te devuelve el 100 % de lo que pagaste' + (Number(b.bastet_refund_bs) > 0 ? ' (' + bs(b.bastet_refund_bs) + ')' : '') + '. Si ya le pagaste el saldo al anfitrión, él debe devolvértelo directamente' + (b.host_refund_due ? ' (' + money(b.host_refund_due, b.currency) + ')' : '') + '. Escríbenos por WhatsApp y te ayudamos.</p>');
      } else if (b.late_cancel) {
        parts.push('<p>Cancelaste dentro de las últimas horas previas a la llegada: se retiene el 20 % del total (10 % Bastet y 10 % anfitrión). Si ya pagaste el saldo al anfitrión, debe devolverte ' + money(b.host_refund_due, b.currency) + ' directamente.</p>');
      } else {
        parts.push('<p>Cancelación sin costo.' + (Number(b.bastet_refund_bs) > 0 ? ' Bastet te devuelve ' + bs(b.bastet_refund_bs) + '.' : '') + (b.host_refund_due ? ' Si ya pagaste el saldo al anfitrión, debe devolvértelo directamente (' + money(b.host_refund_due, b.currency) + ').' : '') + '</p>');
      }
      return parts.join('');
    }

    function payBox(b) {
      return '<section class="sbk-pay"><h3>Cómo pagar ' + bs(b.fee_bs) + '</h3>' +
        (b.pay_qr_url ? '<img class="sbk-qr" src="' + esc(b.pay_qr_url) + '" alt="Código QR para pagar a Bastet">' : '') +
        '<p class="sbk-instr">' + esc(b.pay_instructions || '').replace(/\n/g, '<br>') + '</p>' +
        (b.review_note ? '<p class="srm-error">Tu comprobante anterior fue rechazado: ' + esc(b.review_note) + '</p>' : '') +
        '<label class="srm-label" for="sbk-proof">Sube tu comprobante <span>(foto o PDF, hasta 5 MB)</span></label>' +
        '<input id="sbk-proof" type="file" accept="image/jpeg,image/png,image/webp,application/pdf">' +
        '<button type="button" class="srm-btn" data-upload>Enviar comprobante</button></section>';
    }

    function bind(b) {
      const err = modal.querySelector('#sbk-error');
      const fail = (m) => { err.textContent = m; err.hidden = false; };
      const up = modal.querySelector('[data-upload]');
      if (up) up.addEventListener('click', async () => {
        err.hidden = true;
        const f = modal.querySelector('#sbk-proof').files[0];
        if (!f) return fail('Elige la foto o el PDF de tu comprobante.');
        if (!PROOF_TYPES.includes(f.type)) return fail('El comprobante debe ser una foto (JPG, PNG, WebP) o un PDF.');
        if (f.size > MAX_PROOF) return fail('El archivo pesa más de 5 MB. Sube una foto más liviana.');
        busy = true; up.disabled = true; up.textContent = 'Subiendo…';
        const ext = { 'image/jpeg': 'jpg', 'image/png': 'png', 'image/webp': 'webp', 'application/pdf': 'pdf' }[f.type];
        const path = b.code + '/' + Date.now() + '.' + ext;
        const { error: e1 } = await supabaseClient.storage.from('stay-proofs').upload(path, f, { contentType: f.type });
        const { error: e2 } = e1 ? { error: e1 } : await supabaseClient.rpc('attach_stay_proof', { p_code: b.code, p_path: path });
        busy = false;
        if (e2) { up.disabled = false; up.textContent = 'Enviar comprobante'; return fail(e2.message || 'No se pudo subir el comprobante.'); }
        load();
      });
      const cn = modal.querySelector('[data-cancel]');
      if (cn) cn.addEventListener('click', async () => {
        err.hidden = true;
        const paid = b.status === 'conexion_generada';
        const msg = paid && b.is_late_cancel ? 'Ya pasó el plazo de cancelación gratuita: si cancelas se retiene el 20 % del total (10 % Bastet y 10 % anfitrión). ¿Cancelar igual?'
          : paid ? 'Cancelación gratuita. Bastet te devuelve el 10 % que pagó y el anfitrión debe devolverte el saldo si ya se lo pagaste. ¿Cancelar la reserva?'
          : '¿Cancelar esta solicitud? No tiene ningún costo.';
        if (!window.confirm(msg)) return;
        cn.disabled = true;
        const { error } = await supabaseClient.rpc('cancel_stay_booking', { p_code: b.code, p_reason: null });
        if (error) { cn.disabled = false; return fail(error.message || 'No se pudo cancelar.'); }
        load();
      });
    }

    if (!saved().some((x) => x.code === code)) remember(code, '');
    await load();
    if (fresh) { const s = modal.querySelector('.sbk-state'); if (s) s.insertAdjacentHTML('beforebegin', '<p class="sbk-saved">Solicitud enviada. Guarda este enlace para volver a tu reserva: <b>' + esc(location.origin + location.pathname + '?reserva=' + code) + '</b></p>'); }
  };

  S.openFromUrl = function () {
    const code = new URLSearchParams(location.search).get('reserva');
    if (code && /^[A-Za-z0-9]{6,16}$/.test(code)) S.openTrack(code.toUpperCase(), false);
  };
})();
