/* Verificar (verificar.html): detalle público de una RESERVA de Estadías a partir de su código de 10 caracteres.
 * Muestra si el pago del 10 % está verificado, el historial, la ubicación y fotos del inmueble, el WhatsApp del anfitrión (solo con pago
 * verificado) y un calendario con las fechas apartadas. Nunca hay datos de contacto del huésped. Datos: RPC verify_stay_booking
 * (supabase/stay-bookings.sql). Expone window.VerifyStay.html(reserva) → { cls, html }. */
(function () {
  'use strict';
  const MONTHS = ['enero', 'febrero', 'marzo', 'abril', 'mayo', 'junio', 'julio', 'agosto', 'septiembre', 'octubre', 'noviembre', 'diciembre'];
  const esc = (s) => String(s == null ? '' : s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const pad = (n) => String(n).padStart(2, '0');
  const addDays = (s, k) => { const d = new Date(s + 'T00:00:00Z'); d.setUTCDate(d.getUTCDate() + k); return d.toISOString().slice(0, 10); };
  const fdate = (s) => { const [y, m, d] = String(s).slice(0, 10).split('-').map(Number); return d + ' de ' + MONTHS[m - 1] + ' de ' + y; };
  const ftime = (iso) => new Date(iso).toLocaleString('es-BO', { timeZone: 'America/La_Paz', day: 'numeric', month: 'long', year: 'numeric', hour: '2-digit', minute: '2-digit', hourCycle: 'h23' });
  const money = (n, c) => { const s = Number(n).toLocaleString('es-BO', { maximumFractionDigits: 2 }); return c === 'BOB' ? 'Bs ' + s : s + ' USD'; };
  const waPhone = (v) => { const d = String(v || '').replace(/[^0-9]/g, ''); return /^[67][0-9]{7}$/.test(d) ? '591' + d : d; };
  const EVENTS = {
    solicitada: 'Solicitud de reserva enviada', aceptada: 'El anfitrión aceptó la solicitud', rechazada: 'El anfitrión no pudo aceptar la solicitud',
    expirada_sin_respuesta: 'La solicitud venció sin respuesta del anfitrión', expirada_sin_pago: 'La reserva venció sin el pago del 10 %',
    comprobante_enviado: 'El huésped envió su comprobante de pago', comprobante_rechazado: 'Bastet rechazó el comprobante (el huésped puede enviar otro)',
    pago_verificado_y_conexion: 'Pago del 10 % verificado por Bastet · contacto habilitado', cancelada_por_huesped: 'Reserva cancelada por el huésped',
    cancelada_por_anfitrion: 'Reserva cancelada por el anfitrión', disputa_abierta: 'Bastet abrió una revisión de la reserva', disputa_cerrada: 'Bastet cerró la revisión',
  };

  // Calendario de solo lectura: noches de esta reserva, día de salida y noches ocupadas por otras reservas
  function calendar(b) {
    const mine = new Set(); for (let d = b.check_in; d < b.check_out; d = addDays(d, 1)) mine.add(d);
    const busy = new Set(); (b.busy || []).forEach((r) => { for (let d = r.from, i = 0; d <= r.to && i < 400; d = addDays(d, 1), i++) busy.add(d); });
    const [y0, m0] = b.check_in.split('-').map(Number), [y1, m1] = b.check_out.split('-').map(Number);
    let y = y0, m = m0 - 1, out = '', guard = 0;
    while ((y < y1 || (y === y1 && m <= m1 - 1)) && guard++ < 4) {
      const first = new Date(Date.UTC(y, m, 1)), days = new Date(Date.UTC(y, m + 1, 0)).getUTCDate(), lead = (first.getUTCDay() + 6) % 7;
      let cells = ''; for (let i = 0; i < lead; i++) cells += '<span></span>';
      for (let d = 1; d <= days; d++) {
        const s = y + '-' + pad(m + 1) + '-' + pad(d);
        const cls = mine.has(s) ? ' is-mine' : s === b.check_out ? ' is-out' : busy.has(s) ? ' is-busy' : '';
        cells += '<i class="vs-day' + cls + '">' + d + '</i>';
      }
      out += '<div class="vs-month"><b>' + MONTHS[m] + ' ' + y + '</b><div class="vs-week"><span>L</span><span>M</span><span>M</span><span>J</span><span>V</span><span>S</span><span>D</span></div><div class="vs-grid">' + cells + '</div></div>';
      m++; if (m > 11) { m = 0; y++; }
    }
    return '<div class="vs-cal">' + out + '</div><p class="vs-legend"><i class="is-mine"></i> Noches apartadas <i class="is-out"></i> Día de salida <i class="is-busy"></i> Ocupado por otra reserva</p>';
  }

  function html(b) {
    let cls, head;
    const done = b.status === 'cancelada', dead = ['rechazada', 'expirada'].includes(b.status);
    if (b.verified) { cls = 'is-ok'; head = '<h2>✓ Reserva verificada</h2><p>El pago del 10 % fue verificado por Bastet el <b>' + esc(ftime(b.verified_at)) + '</b> (hora de Bolivia). Esta reserva es auténtica.</p>'; }
    else if (done) { cls = 'is-bad'; head = '<h2>Reserva cancelada</h2><p>Esta reserva existe en Bastet, pero fue cancelada' + (b.cancelled_by === 'host' ? ' por el anfitrión' : b.cancelled_by === 'guest' ? ' por el huésped' : '') + ' y ya no está vigente.</p>'; }
    else if (dead) { cls = 'is-bad'; head = '<h2>Reserva no concretada</h2><p>Esta solicitud existe en Bastet, pero no se concretó (' + (b.status === 'rechazada' ? 'el anfitrión no pudo aceptarla' : 'venció') + ').</p>'; }
    else { cls = 'is-wait'; head = '<h2>Reserva en proceso</h2><p>Esta reserva existe en Bastet, pero <b>todavía no tiene el pago verificado</b>. Hasta entonces no está confirmada.</p>'; }

    const photos = (b.photos || []).slice(0, 6);
    const map = b.latitude != null && b.longitude != null ? ' · <a href="https://www.google.com/maps?q=' + encodeURIComponent(b.latitude + ',' + b.longitude) + '" target="_blank" rel="noopener">Ver en el mapa</a>' : '';
    const events = (b.events || []).filter((e) => EVENTS[e.event]);
    return { cls, html: head +
      '<dl><div><dt>Código de reserva</dt><dd>' + esc(b.code) + '</dd></div>' +
      '<div><dt>Inmueble</dt><dd>' + esc(b.title) + '</dd></div>' +
      '<div><dt>Ubicación</dt><dd>' + esc([b.address, b.location].filter(Boolean).join(', ')) + map + '</dd></div>' +
      '<div><dt>Fechas</dt><dd>' + esc(fdate(b.check_in)) + ' → ' + esc(fdate(b.check_out)) + ' · ' + b.nights + (b.nights === 1 ? ' noche' : ' noches') + ' · ' + b.guests + (b.guests === 1 ? ' huésped' : ' huéspedes') + '</dd></div>' +
      '<div><dt>A nombre de</dt><dd>' + esc(b.guest_name) + '</dd></div>' +
      '<div><dt>Total de la estadía</dt><dd>' + esc(money(b.total, b.currency)) + ' <small>(Bs ' + Number(b.fee_bs).toLocaleString('es-BO', { maximumFractionDigits: 2 }) + ' se pagan a Bastet; el saldo de ' + esc(money(b.balance, b.currency)) + ' se paga directo al anfitrión)</small></dd></div>' +
      (b.verified && b.host_whatsapp ? '<div><dt>Anfitrión</dt><dd>' + esc(b.host_name || '') + '<br><a class="vs-wa" target="_blank" rel="noopener" href="https://api.whatsapp.com/send?phone=' + esc(waPhone(b.host_whatsapp)) + '&text=' + encodeURIComponent('Hola, consulto por la reserva ' + b.code + ' de «' + b.title + '».') + '">Escribir al anfitrión por WhatsApp</a></dd></div>' : '') +
      '</dl>' +
      (photos.length ? '<h3 class="vs-h">Fotos del inmueble</h3><div class="vs-photos">' + photos.map((u, i) => '<img src="' + esc(u) + '" alt="' + esc(b.title) + ' — foto ' + (i + 1) + '" loading="lazy">').join('') + '</div>' : '') +
      '<h3 class="vs-h">Calendario de la reserva</h3>' + calendar(b) +
      (events.length ? '<h3 class="vs-h">Historial</h3><ol class="vs-hist">' + events.map((e) => '<li><b>' + esc(EVENTS[e.event]) + '</b><small>' + esc(ftime(e.at)) + '</small></li>').join('') + '</ol>' : '') };
  }

  window.VerifyStay = { html };
})();
