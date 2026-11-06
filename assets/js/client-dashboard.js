/* Panel de la cuenta de CLIENTE (quien busca comprar, alquilar, dar en anticrético o reservar una estadía).
 * Reemplaza el menú de agente por un solo espacio, «Mi espacio», pensado para llevar a la persona a su siguiente paso:
 *   · avisos con el próximo paso (pagar una reserva, contactar a quien publica, esperar o buscar alternativas),
 *   · accesos directos a comprar, alquilar, anticrético y estadías,
 *   · Mis solicitudes de contacto y Mis reservas (siempre con su estado),
 *   · Recomendados según lo que ya miró, guardó o pidió, y Favoritos.
 * Datos: RPC my_client_requests / my_client_bookings / my_prefill / change_account_type (supabase/client-accounts.sql); favoritos y propiedades se leen
 * con la sesión (solo las disponibles). Escucha el evento `uno:account` que publica publications.js. */
(function () {
  'use strict';
  const esc = (s) => String(s == null ? '' : s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const root = () => document.getElementById('client-root');
  const COLS = 'id,title,location,price,currency,property_type,operation,photos,rooms,baths,area,code_number,featured,created_at';
  const TYPE = { casa: 'Casa', departamento: 'Departamento', habitacion: 'Habitación', terreno: 'Terreno' };
  const OP = { venta: 'Venta', alquiler: 'Alquiler', anticretico: 'Anticrético', temporal: 'Estadía' };
  const REQ = {
    solicitada: ['wait', 'Esperando respuesta', 'Quien publica el inmueble aún no responde.'],
    rechazada: ['bad', 'No atendida', 'No pudieron atender tu solicitud. Mira otras propiedades parecidas.'],
    aceptada_pendiente_pago: ['wait', 'Aceptada', 'Aceptaron tu solicitud. Falta que Bastet verifique su pago para entregarte el contacto.'],
    comprobante_enviado: ['wait', 'Pago en revisión', 'Bastet está revisando el pago. Pronto recibirás el contacto.'],
    conexion_generada: ['ok', 'Conexión generada', 'Ya puedes contactar a quien publica el inmueble.'],
    cancelada: ['bad', 'Cancelada', '']
  };
  const BK = {
    pendiente_respuesta_anfitrion: ['wait', 'Esperando al anfitrión', 'El anfitrión tiene hasta 2 horas para responder.'],
    rechazada: ['bad', 'No aceptada', 'El anfitrión no pudo aceptar esas fechas. Mira otras estadías.'],
    expirada: ['bad', 'Venció', 'La solicitud venció sin respuesta.'],
    aceptada_pendiente_pago: ['act', 'Falta tu pago del 10 %', 'Paga a Bastet y sube tu comprobante para confirmar la reserva.'],
    comprobante_enviado: ['wait', 'Comprobante enviado', 'Bastet está revisando tu pago.'],
    pago_en_revision: ['wait', 'Pago en revisión', 'Bastet está revisando tu pago.'],
    pago_verificado: ['ok', 'Pago verificado', ''],
    conexion_generada: ['ok', 'Reserva confirmada', 'Ya tienes el contacto del anfitrión.'],
    cancelada: ['bad', 'Cancelada', ''],
    en_disputa: ['bad', 'En revisión', 'Bastet está revisando esta reserva.']
  };
  const ACTIVE_REQ = new Set(['solicitada', 'aceptada_pendiente_pago', 'comprobante_enviado', 'conexion_generada']);
  const ACTIVE_BK = new Set(['pendiente_respuesta_anfitrion', 'aceptada_pendiente_pago', 'comprobante_enviado', 'pago_en_revision', 'pago_verificado', 'conexion_generada']);
  const hiddenByClient = new Set();
  let inClient = false, inCompany = false, loading = false, firstShow = true;

  const money = (p) => {
    const digits = String((p && p.price) || '').replace(/[^0-9]/g, '');
    if (!digits) return '';
    const n = digits.replace(/\B(?=(\d{3})+(?!\d))/g, '.');
    return (p.currency === 'BOB' ? 'Bs ' + n : n + ' USD') + (p.operation === 'temporal' ? ' por noche' : '');
  };
  const city = (p) => String((p && p.location) || '').split(',')[0].trim();
  const code = (p) => (p && p.code_number ? 'BST-' + p.code_number : (p && p.id) || '');
  const link = (p) => '../' + (p.operation === 'temporal' ? 'estadias.html' : 'marketplace.html') + '?p=' + encodeURIComponent(code(p));
  const fdate = (d) => (d ? new Date(String(d).length === 10 ? d + 'T12:00:00' : d).toLocaleDateString('es-BO', { day: '2-digit', month: 'short' }) : '');
  const waLink = (phone, text) => { let d = String(phone || '').replace(/\D/g, ''); if (d.length === 8) d = '591' + d; return 'https://api.whatsapp.com/send?phone=' + d + (text ? '&text=' + encodeURIComponent(text) : ''); };

  /* ───────── Entrar y salir del modo cliente ───────── */
  function applyClientMode() {
    if (!inClient) return;
    document.body.classList.add('is-client');
    document.querySelectorAll('.admin-side .admin-tab').forEach((b) => {
      const keep = b.dataset.tab === (inCompany ? 'company' : 'client') || b.dataset.tab === 'account';
      if (keep) { b.classList.remove('hidden'); return; }
      if (!b.classList.contains('hidden')) hiddenByClient.add(b);
      b.classList.add('hidden');
    });
    document.querySelectorAll('.admin-side .admin-nav-group').forEach((g) => { if (!g.classList.contains('hidden')) { hiddenByClient.add(g); g.classList.add('hidden'); } });
    const bar = document.getElementById('admin-bottombar');
    if (bar) bar.querySelectorAll('.abb-item[data-go]').forEach((b) => { if (b.dataset.go === (inCompany ? 'company' : 'client')) b.classList.remove('hidden'); else { if (!b.classList.contains('hidden')) hiddenByClient.add(b); b.classList.add('hidden'); } });
    const badge = document.getElementById('admin-role-badge'); if (badge) badge.textContent = inCompany ? 'Empresa' : 'Cliente';
    const hint = document.querySelector('#tab-panel-account .admin-toolbar-hint'); if (hint) hint.textContent = (inCompany ? 'Tu nombre y tu acceso. Los datos de la empresa están en «Mi empresa».' : 'Tu nombre y tu acceso. Para publicar inmuebles puedes cambiar el tipo de cuenta desde «Mi espacio».');
    ['profile-avatar-input', 'profile-whatsapp-input', 'profile-facebook-input', 'profile-instagram-input', 'profile-tiktok-input'].forEach((id) => { const f = document.getElementById(id); const w = f && f.closest('.field'); if (w) w.classList.add('hidden'); });
  }
  function leaveClientMode() {
    if (!document.body.classList.contains('is-client')) return;
    document.body.classList.remove('is-client');
    hiddenByClient.forEach((el) => el.classList.remove('hidden')); hiddenByClient.clear();
    document.querySelectorAll('.admin-tab[data-tab="client"], .abb-item[data-go="client"], .abb-item[data-go="company"]').forEach((b) => b.classList.add('hidden'));
    document.querySelectorAll('#tab-panel-account .field.hidden').forEach((f) => f.classList.remove('hidden'));
  }

  document.addEventListener('uno:account', (e) => {
    const a = e.detail;
    inClient = !!(a && a.account && a.account.client === true && a.registered !== false);
    inCompany = inClient && a.account.company === true;
    if (!inClient) { leaveClientMode(); firstShow = true; return; }
    applyClientMode(); setTimeout(applyClientMode, 250); setTimeout(applyClientMode, 900);
    if (inCompany) { if (firstShow) { firstShow = false; const t = document.querySelector('.admin-tab[data-tab="company"]'); if (t) t.click(); } return; }
    if (firstShow) { firstShow = false; const t = document.querySelector('.admin-tab[data-tab="client"]'); if (t) t.click(); }
    else if (!document.getElementById('tab-panel-client').classList.contains('hidden')) render();
  });
  document.addEventListener('click', (e) => {
    const t = e.target.closest('.admin-tab[data-tab="client"]');
    if (t) setTimeout(render, 0);
  });

  /* ───────── Datos ───────── */
  async function loadAll() {
    const c = supabaseClient;
    const [reqs, books, favs, props, pre] = await Promise.all([
      c.rpc('my_client_requests'), c.rpc('my_client_bookings'),
      c.from('property_favorites').select('property_id'),
      c.from('properties').select(COLS).eq('status', 'available').order('featured', { ascending: false }).order('created_at', { ascending: false }).limit(150),
      c.rpc('my_prefill')
    ]);
    const err = [reqs, books].find((r) => r.error);
    if (err) return { error: err.error };
    return { reqs: reqs.data || [], books: books.data || [], favIds: (favs.data || []).map((f) => f.property_id), props: props.data || [], name: pre && pre.data && pre.data.name };
  }

  function card(p, tag) {
    const photo = (p.photos && p.photos[0]) || '';
    const stay = p.operation === 'temporal';
    return '<article class="cl-card">' + (photo ? '<a class="cl-photo" href="' + esc(link(p)) + '"><img src="' + esc(photo) + '" alt="" loading="lazy"></a>' : '') +
      '<div class="cl-card-body"><p class="cl-eyebrow">' + esc([OP[p.operation], TYPE[p.property_type]].filter(Boolean).join(' · ')) + (tag ? ' · <b>' + esc(tag) + '</b>' : '') + '</p>' +
      '<h3>' + esc(p.title) + '</h3><p class="cl-muted">' + esc(city(p)) + '</p><p class="cl-price">' + esc(money(p)) + '</p>' +
      '<a class="btn btn-accent btn-sm" href="' + esc(link(p)) + '">' + (stay ? 'Ver fechas y reservar' : 'Ver y pedir contacto') + '</a></div></article>';
  }

  function statusChip(map, st) { const m = map[st] || ['wait', st, '']; return '<span class="cl-chip cl-' + m[0] + '">' + esc(m[1]) + '</span>'; }

  function render(d) {
    const el = root(); if (!el) return;
    if (!d) {
      if (loading) return; loading = true;
      loadAll().then((r) => { loading = false; render(r); }).catch(() => { loading = false; render({ error: { message: 'No se pudo cargar tu espacio.' } }); });
      if (!el.children.length || el.querySelector('.cl-empty')) el.innerHTML = '<p class="cl-empty">Cargando…</p>';
      return;
    }
    if (d.error) {
      const missing = /function|schema cache/i.test(d.error.message || '');
      el.innerHTML = '<p class="form-error">' + (missing ? 'Tu espacio de cliente todavía no está activo en la base de datos.' : esc(d.error.message)) + '</p>'; return;
    }
    const byId = new Map(d.props.map((p) => [p.id, p]));
    const reqs = d.reqs, books = d.books;
    const activeReqs = reqs.filter((r) => ACTIVE_REQ.has(r.status)), activeBks = books.filter((b) => ACTIVE_BK.has(b.status));
    const touched = new Set(reqs.map((r) => r.property_id).concat(books.map((b) => b.property_id)));
    // Recomendados: lo que se parece a lo que ya guardó, pidió o reservó (misma operación y ciudad), sin repetir lo que ya pidió
    const seeds = d.favIds.concat(Array.from(touched)).map((id) => byId.get(id)).filter(Boolean);
    const ops = new Set(seeds.map((p) => p.operation)), cities = new Set(seeds.map(city));
    const favSet = new Set(d.favIds);
    const rec = d.props.filter((p) => !touched.has(p.id) && !favSet.has(p.id))
      .map((p) => ({ p, s: (ops.has(p.operation) ? 2 : 0) + (cities.has(city(p)) ? 2 : 0) + (p.featured ? 1 : 0) }))
      .sort((a, b) => b.s - a.s).slice(0, 6).map((x) => x.p);
    const favs = d.favIds.map((id) => byId.get(id)).filter((p) => p && !touched.has(p.id)).slice(0, 6);

    // Siguiente paso: el aviso más importante primero
    const nudges = [];
    books.filter((b) => b.status === 'aceptada_pendiente_pago').forEach((b) => {
      const p = byId.get(b.property_id);
      nudges.push('<div class="cl-nudge cl-act"><div><b>Completa tu reserva' + (p ? ' en ' + esc(p.title) : '') + '</b><p>Paga el 10 % a Bastet' + (b.pay_by ? ' antes del ' + esc(new Date(b.pay_by).toLocaleString('es-BO', { day: '2-digit', month: 'short', hour: '2-digit', minute: '2-digit' })) : '') + ' para confirmarla.</p></div><a class="btn btn-accent btn-sm" href="../estadias.html?reserva=' + encodeURIComponent(b.code) + '">Pagar ahora</a></div>');
    });
    reqs.filter((r) => r.status === 'conexion_generada' && r.contact_phone).slice(0, 2).forEach((r) => {
      const p = byId.get(r.property_id);
      nudges.push('<div class="cl-nudge cl-ok"><div><b>Ya puedes contactar' + (p ? ' por ' + esc(p.title) : '') + '</b><p>Bastet verificó la conexión. Escribe ahora para coordinar una visita.</p></div><a class="btn btn-accent btn-sm" target="_blank" rel="noopener" href="' + esc(waLink(r.contact_phone, 'Hola, soy cliente de Bastet. Pedí contacto por ' + (p ? p.title : 'su inmueble') + ' (solicitud ' + r.code + ').')) + '">Escribir por WhatsApp</a></div>');
    });
    const stale = reqs.find((r) => r.status === 'solicitada' && Date.now() - new Date(r.created_at).getTime() > 24 * 3600 * 1000);
    if (stale && rec.length) nudges.push('<div class="cl-nudge"><div><b>¿Sigues esperando respuesta?</b><p>Pide contacto en otras propiedades parecidas: así tienes más opciones mientras tanto.</p></div><a class="btn btn-ghost btn-sm" href="#cl-rec">Ver recomendados</a></div>');
    if (!reqs.length && !books.length) nudges.push('<div class="cl-nudge cl-act"><div><b>Da tu primer paso hoy</b><p>Elige una propiedad y pide contacto, o reserva una estadía en minutos. Solo necesitas tu nombre y WhatsApp.</p></div><a class="btn btn-accent btn-sm" href="#cl-rec">Ver opciones</a></div>');

    const reqRow = (r) => {
      const p = byId.get(r.property_id); const m = REQ[r.status] || ['wait', r.status, ''];
      return '<li class="cl-row"><div class="cl-row-main"><b>' + esc(p ? p.title : 'Inmueble') + '</b><span class="cl-muted">' + esc([OP[r.operation], p ? city(p) : ''].filter(Boolean).join(' · ')) + ' · solicitud ' + esc(r.code) + ' · ' + esc(fdate(r.created_at)) + '</span><span class="cl-muted">' + esc(m[2]) + '</span></div>' +
        '<div class="cl-row-side">' + statusChip(REQ, r.status) +
        (r.status === 'conexion_generada' && r.contact_phone ? '<a class="btn btn-accent btn-sm" target="_blank" rel="noopener" href="' + esc(waLink(r.contact_phone)) + '">WhatsApp</a>' : '') +
        '<a class="btn btn-ghost btn-sm" href="../verificar.html" target="_blank" rel="noopener" data-copy="' + esc(r.code) + '">Verificar</a></div></li>';
    };
    const bkRow = (b) => {
      const p = byId.get(b.property_id); const m = BK[b.status] || ['wait', b.status, ''];
      return '<li class="cl-row"><div class="cl-row-main"><b>' + esc(p ? p.title : 'Estadía') + '</b><span class="cl-muted">' + esc(fdate(b.check_in)) + ' – ' + esc(fdate(b.check_out)) + ' · ' + esc(b.guests) + ' huésped(es) · reserva ' + esc(b.code) + '</span><span class="cl-muted">' + esc(m[2]) + '</span></div>' +
        '<div class="cl-row-side">' + statusChip(BK, b.status) + '<a class="btn ' + (b.status === 'aceptada_pendiente_pago' ? 'btn-accent' : 'btn-ghost') + ' btn-sm" href="../estadias.html?reserva=' + encodeURIComponent(b.code) + '">' + (b.status === 'aceptada_pendiente_pago' ? 'Pagar' : 'Ver reserva') + '</a></div></li>';
    };

    el.innerHTML =
      '<div class="admin-toolbar"><div><h1>' + (d.name ? 'Hola, ' + esc(String(d.name).split(' ')[0]) : 'Mi espacio') + '</h1><p class="admin-toolbar-hint">Tus solicitudes, reservas y recomendados en un solo lugar.</p></div></div>' +
      (nudges.length ? '<div class="cl-nudges">' + nudges.join('') + '</div>' : '') +
      '<section class="cl-quick" aria-label="¿Qué quieres hacer?">' +
        '<a href="../marketplace.html?op=venta"><b>Comprar</b><span>Casas, departamentos y terrenos</span></a>' +
        '<a href="../marketplace.html?op=alquiler"><b>Alquilar</b><span>Contacta a quien publica</span></a>' +
        '<a href="../marketplace.html?op=anticretico"><b>Anticrético</b><span>Opciones disponibles</span></a>' +
        '<a href="../estadias.html"><b>Reservar una estadía</b><span>Por noches, con pago del 10 %</span></a></section>' +
      '<section class="cl-stats"><div><b>' + activeReqs.length + '</b><span>solicitudes activas</span></div><div><b>' + activeBks.length + '</b><span>reservas activas</span></div><div><b>' + d.favIds.length + '</b><span>favoritos</span></div></section>' +
      (activeBks.length || books.length ? '<section class="cl-block"><h2>Mis reservas</h2><ul class="cl-list">' + books.slice(0, 8).map(bkRow).join('') + '</ul></section>' : '') +
      (reqs.length ? '<section class="cl-block"><h2>Mis solicitudes de contacto</h2><ul class="cl-list">' + reqs.slice(0, 10).map(reqRow).join('') + '</ul></section>' : '') +
      '<section class="cl-block" id="cl-rec"><h2>' + (seeds.length ? 'Recomendados para ti' : 'Novedades en Bastet') + '</h2>' +
        (rec.length ? '<div class="cl-grid">' + rec.map((p) => card(p, p.featured ? 'Destacada' : '')).join('') + '</div>' : '<p class="cl-empty">Todavía no hay más propiedades disponibles. Vuelve pronto.</p>') + '</section>' +
      (favs.length ? '<section class="cl-block"><h2>Tus favoritos</h2><div class="cl-grid">' + favs.map((p) => card(p, 'Guardada')).join('') + '</div></section>' : '') +
      '<section class="cl-block cl-publish"><h2>¿Quieres publicar tus inmuebles?</h2><p class="cl-muted">Cambia tu cuenta y empieza a publicar. Es gratis y no vence.</p>' +
        '<div class="cl-actions"><button type="button" class="btn btn-ghost btn-sm" data-switch="propietario">Soy propietario</button><button type="button" class="btn btn-ghost btn-sm" data-switch="agente">Soy agente</button></div></section>';
  }

  /* ───────── Acciones ───────── */
  document.addEventListener('click', async (e) => {
    const sw = e.target.closest('#client-root [data-switch]'); if (!sw) return;
    const type = sw.dataset.switch;
    if (!window.confirm('¿Cambiar tu cuenta a «' + type + '»? Podrás publicar inmuebles y dejarás de ver este espacio de cliente. No se puede volver a cliente por tu cuenta.')) return;
    sw.disabled = true;
    const { error } = await supabaseClient.rpc('change_account_type', { p_type: type });
    if (error) { sw.disabled = false; window.alert(error.message || 'No se pudo cambiar el tipo de cuenta.'); return; }
    location.reload();
  });
  // «Verificar» lleva el código ya copiado al portapapeles, para pegarlo en la página
  document.addEventListener('click', (e) => {
    const v = e.target.closest('#client-root [data-copy]'); if (!v) return;
    try { navigator.clipboard.writeText(v.dataset.copy); } catch (err) { /* sin portapapeles: la persona lo escribe */ }
  });

  // Mientras el espacio está abierto, se actualiza solo (para ver respuestas y pagos verificados)
  setInterval(() => {
    if (!inClient || document.hidden || typeof supabaseClient === 'undefined') return;
    const panel = document.getElementById('tab-panel-client');
    if (panel && !panel.classList.contains('hidden') && !document.querySelector('.modal-overlay')) render();
  }, 60000);
})();
