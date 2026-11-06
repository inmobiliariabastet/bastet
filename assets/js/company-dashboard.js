/* Panel de la cuenta EMPRESA («Mi empresa»): un cliente corporativo, no un agente. No publica inmuebles ni usa herramientas de agente.
 * Sirve para gestionar, para la empresa y su gente:
 *   · Alojamiento del equipo: estadías temporales de trabajadores en Bolivia, con tarifa corporativa y atención preferencial,
 *   · Espacios y propiedades: alquilar un espacio para operar (oficina, depósito, local, terreno…) o comprar un inmueble,
 *   · Reservas y contactos: lo que la empresa ya reservó o pidió como cliente (mismas estadías y propiedades del sitio),
 *   · Equipo (trabajadores que viajan sin necesitar cuenta) y los datos de la empresa.
 * Flujo: la empresa solicita la afiliación → Bastet la activa fijando la tarifa corporativa → envía solicitudes → Bastet cotiza y coordina por WhatsApp.
 * SQL: supabase/corporate.sql + supabase/company-client.sql (apagado hasta encenderlo en /admin → Empresas).
 * Autónomo: usa `supabaseClient` y el evento `uno:account` de publications.js (my_account.interest / account.company). */
(function () {
  'use strict';
  const root = () => document.getElementById('company-root');
  const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const fdate = (d) => (d ? new Date(String(d).length === 10 ? d + 'T12:00:00' : d).toLocaleDateString('es-BO', { day: '2-digit', month: 'short', year: 'numeric' }) : '');
  const today = () => new Date(Date.now() - 4 * 3600 * 1000).toISOString().slice(0, 10);
  const RSTATUS = { nueva: ['Recibida', 'wait'], en_gestion: ['En gestión', 'wait'], cotizada: ['Cotizada', 'ok'], confirmada: ['Confirmada', 'ok'], cerrada: ['Cerrada', ''], cancelada: ['Cancelada', 'bad'] };
  const CSTATUS = { solicitada: 'En revisión de Bastet', activa: 'Afiliación activa', suspendida: 'Afiliación suspendida', rechazada: 'Solicitud rechazada' };
  const KIND = { estadia: 'Alojamiento del equipo', espacio: 'Espacio para operar', compra: 'Compra de inmueble' };
  const OP = { alquiler: 'Alquiler', venta: 'Compra', anticretico: 'Anticrético', temporal: 'Estadía' };
  const BK = { pendiente_respuesta_anfitrion: ['wait', 'Esperando al anfitrión'], rechazada: ['bad', 'No aceptada'], expirada: ['bad', 'Venció'], aceptada_pendiente_pago: ['act', 'Falta el pago del 10 %'], comprobante_enviado: ['wait', 'Comprobante enviado'], pago_en_revision: ['wait', 'Pago en revisión'], pago_verificado: ['ok', 'Pago verificado'], conexion_generada: ['ok', 'Reserva confirmada'], cancelada: ['bad', 'Cancelada'], en_disputa: ['bad', 'En revisión'] };
  const RQ = { solicitada: ['wait', 'Esperando respuesta'], rechazada: ['bad', 'No atendida'], aceptada_pendiente_pago: ['wait', 'Aceptada'], comprobante_enviado: ['wait', 'Pago en revisión'], conexion_generada: ['ok', 'Contacto disponible'], cancelada: ['bad', 'Cancelada'] };
  const ACTIVE_BK = new Set(['pendiente_respuesta_anfitrion', 'aceptada_pendiente_pago', 'comprobante_enviado', 'pago_en_revision', 'pago_verificado', 'conexion_generada']);
  const VIEWS = [['resumen', 'Resumen'], ['estadias', 'Alojamiento del equipo'], ['espacios', 'Espacios y propiedades'], ['actividad', 'Reservas y contactos'], ['equipo', 'Equipo'], ['empresa', 'Datos de la empresa']];
  const SPACE_TYPES = ['Oficina', 'Depósito o almacén', 'Local comercial', 'Terreno', 'Casa o departamento para la operación', 'Otro'];
  let state = null, extra = { books: [], reqs: [], props: {} }, busy = false, isCompany = false, view = 'resumen';
  try { view = sessionStorage.getItem('bastet-co-view') || 'resumen'; } catch (e) { /* sin almacenamiento */ }

  function toast(msg, bad) {
    let el = document.getElementById('ct-toast');
    if (!el) { el = document.createElement('div'); el.id = 'ct-toast'; el.setAttribute('role', 'status'); document.body.appendChild(el); }
    el.textContent = msg; el.className = 'ct-toast show' + (bad ? ' is-error' : '');
    clearTimeout(toast.t); toast.t = setTimeout(() => { el.className = 'ct-toast'; }, 5200);
  }
  const cities = () => (typeof BOLIVIA_CITIES !== 'undefined' && Array.isArray(BOLIVIA_CITIES)) ? BOLIVIA_CITIES : [];
  const cityOptions = (sel) => '<option value="">Elige la ciudad</option>' + cities().map((c) => '<option' + (c === sel ? ' selected' : '') + '>' + esc(c) + '</option>').join('');
  const waLink = (phone, text) => { let d = String(phone || '').replace(/\D/g, ''); if (d.length === 8) d = '591' + d; return 'https://api.whatsapp.com/send?phone=' + d + (text ? '&text=' + encodeURIComponent(text) : ''); };

  async function load() {
    const r = root(); if (!r) return;
    if (!state) r.innerHTML = '<p class="property-empty">Cargando tu panel…</p>';
    const c = supabaseClient;
    const [co, bk, rq] = await Promise.all([c.rpc('my_company'), c.rpc('my_client_bookings'), c.rpc('my_client_requests')]);
    if (co.error) { r.innerHTML = '<p class="property-empty">' + (/function|schema cache/i.test(co.error.message || '') ? 'Esta función aún no está disponible.' : esc(co.error.message)) + '</p>'; return; }
    state = co.data;
    extra = { books: (bk.data || []), reqs: (rq.data || []), props: {} };
    const ids = [...new Set(extra.books.map((b) => b.property_id).concat(extra.reqs.map((q) => q.property_id)).filter(Boolean))];
    if (ids.length) {
      const { data } = await c.from('properties').select('id,title,location,operation').in('id', ids);
      (data || []).forEach((p) => { extra.props[p.id] = p; });
    }
    draw();
  }

  const isActive = () => !!(state && state.company && state.company.status === 'activa');
  const pill = (cls, text) => '<span class="cp-pill ' + cls + '">' + esc(text) + '</span>';

  function affiliationForm(c) {
    return '<form class="cp-card cp-form" id="cp-aff"><h2>' + (c ? 'Corrige y vuelve a enviar tu solicitud' : 'Solicita la afiliación de tu empresa') + '</h2>' +
      '<p class="cp-hint">Bastet revisa los datos y activa tu tarifa corporativa y tu atención preferencial.</p>' +
      '<div class="cp-grid">' +
      '<label>Razón social<input name="company_name" required maxlength="120" value="' + esc(c && c.company_name) + '"></label>' +
      '<label>NIT<input name="nit" required maxlength="20" inputmode="numeric" value="' + esc(c && c.nit) + '"></label>' +
      '<label>Persona de contacto<input name="contact_name" required maxlength="120" value="' + esc(c && c.contact_name) + '"></label>' +
      '<label>Cargo<input name="contact_role" maxlength="80" placeholder="Ej: Jefa de Recursos Humanos" value="' + esc(c && c.contact_role) + '"></label>' +
      '<label>WhatsApp de contacto<input name="whatsapp" required maxlength="30" inputmode="tel" placeholder="Ej: 77123456" value="' + esc(c && c.whatsapp) + '"></label>' +
      '<label>Correo (opcional)<input name="email" type="email" maxlength="160" value="' + esc(c && c.email) + '"></label>' +
      '<label>Ciudad sede<select name="city">' + cityOptions(c && c.city) + '</select></label>' +
      '<label>Trabajadores que viajan al año (aprox.)<input name="workers_estimate" type="number" min="1" max="100000" value="' + esc(c && c.workers_estimate) + '"></label>' +
      '</div><label>A dónde viaja tu equipo y con qué frecuencia (opcional)<textarea name="travel_notes" rows="3" maxlength="1000">' + esc(c && c.travel_notes) + '</textarea></label>' +
      '<label class="cp-check"><input type="checkbox" name="consent" required> Acepto que Bastet use los datos de mi empresa para gestionar la afiliación y las solicitudes (<a href="../privacidad.html" target="_blank" rel="noopener">política de privacidad</a>).</label>' +
      '<button type="submit" class="btn btn-accent">Enviar solicitud de afiliación</button></form>';
  }

  /* ───────── Piezas ───────── */
  function hero() {
    const c = state.company;
    const name = c ? c.company_name : 'Tu empresa';
    const st = c ? CSTATUS[c.status] || c.status : 'Sin afiliar';
    const disc = c && c.status === 'activa' && Number(c.discount_percent) > 0 ? '<span class="cx-tag cx-gold">Tarifa corporativa: ' + esc(String(Number(c.discount_percent)).replace('.', ',')) + ' % menos</span>' : '';
    return '<header class="cx-hero"><div><p class="cx-kicker">Cuenta empresa</p><h2>' + esc(name) + '</h2>' +
      '<p class="cx-sub">Alojamiento para tu equipo y espacios para tu operación en Bolivia, con atención preferencial.</p></div>' +
      '<div class="cx-tags"><span class="cx-tag' + (c && c.status === 'activa' ? ' cx-ok' : '') + '">' + esc(st) + '</span>' + disc + '</div></header>';
  }
  function nav() {
    return '<nav class="cx-nav" aria-label="Secciones de tu empresa">' + VIEWS.map((v) => '<button type="button" class="cx-navbtn' + (v[0] === view ? ' is-active' : '') + '" data-cx-go="' + v[0] + '">' + esc(v[1]) + '</button>').join('') + '</nav>';
  }
  function gate() {
    const c = state.company;
    if (!state.enabled && !c) return '<div class="cp-card"><h2>Estamos abriendo el servicio corporativo</h2><p>Tu cuenta de empresa ya está lista. Cuando se habilite, aquí podrás solicitar la afiliación y empezar a gestionar el alojamiento de tu equipo. Mientras tanto puedes explorar y reservar estadías como cualquier cliente.</p><p><a class="btn btn-accent btn-sm" href="../estadias.html">Ver estadías</a></p></div>';
    if (!c) return '<div class="cp-card cx-gate"><h2>Primer paso: afilia tu empresa</h2><p>Con la afiliación activa, Bastet atiende primero tus solicitudes y te aplica la tarifa corporativa. Solo necesitas los datos de tu empresa.</p><button type="button" class="btn btn-accent btn-sm" data-cx-go="empresa">Afiliar mi empresa</button></div>';
    if (c.status === 'solicitada') return '<div class="cp-card cx-gate"><h2>Bastet está revisando tu afiliación</h2><p>Te avisaremos por WhatsApp al <b>' + esc(c.whatsapp) + '</b> cuando esté activa. Mientras tanto puedes reservar estadías como cliente.</p></div>';
    if (c.status === 'suspendida') return '<div class="cp-card cp-warn"><h2>Tu afiliación está suspendida</h2><p>Escríbenos por WhatsApp para reactivarla.</p></div>';
    if (c.status === 'rechazada') return '<div class="cp-card cp-warn"><h2>Tu solicitud fue rechazada</h2><p>Corrige los datos en «Datos de la empresa» y envíala de nuevo, o escríbenos para aclararlo.</p><button type="button" class="btn btn-ghost btn-sm" data-cx-go="empresa">Corregir datos</button></div>';
    return '';
  }
  const reqItem = (q) => {
    const st = RSTATUS[q.status] || [q.status, ''];
    const when = q.kind === 'estadia' ? esc(fdate(q.from_date)) + ' – ' + esc(fdate(q.to_date)) + ' · ' + esc(q.workers_count) + ' trabajador(es)' : esc([OP[q.operation], q.space_type, q.size_text].filter(Boolean).join(' · ')) + (q.from_date ? ' · desde ' + esc(fdate(q.from_date)) : '');
    return '<article class="cp-item"><div class="cp-item-top"><span class="cx-kind">' + esc(KIND[q.kind] || 'Solicitud') + '</span> <b>' + esc(q.city) + '</b> · ' + when + ' <small>' + esc(q.code) + '</small>' +
      '<span class="cp-pill ' + st[1] + '">' + esc(st[0]) + '</span></div>' +
      (q.budget_text ? '<p class="cx-meta">Presupuesto: ' + esc(q.budget_text) + '</p>' : '') +
      (q.admin_quote ? '<p class="cp-quote"><b>Cotización de Bastet:</b> ' + esc(q.admin_quote).replace(/\n/g, '<br>') + '</p>' : '') +
      (['nueva', 'en_gestion', 'cotizada'].includes(q.status) ? '<button type="button" class="btn btn-ghost btn-sm" data-cp-cancel="' + esc(q.id) + '">Cancelar solicitud</button>' : '') + '</article>';
  };
  const reqList = (kinds, empty) => {
    const list = (state.requests || []).filter((q) => kinds.includes(q.kind || 'estadia'));
    return '<div class="cp-card"><h2>Tus solicitudes</h2>' + (list.length ? '<div class="cp-list">' + list.map(reqItem).join('') + '</div>' : '<p class="cp-hint">' + esc(empty) + '</p>') + '</div>';
  };
  const trust = () => '<ul class="cx-trust"><li><b>Atención preferencial</b><span>Bastet atiende primero a las empresas afiliadas.</span></li><li><b>Tarifa corporativa</b><span>Precios reducidos para tu equipo, cotizados por una persona.</span></li><li><b>Pago verificado</b><span>Bastet revisa cada pago antes de confirmar.</span></li><li><b>Datos protegidos</b><span>Solo ves y editas la información de tu empresa.</span></li></ul>';

  /* ───────── Secciones ───────── */
  function viewResumen() {
    const reqs = state.requests || [], open = reqs.filter((q) => ['nueva', 'en_gestion', 'cotizada'].includes(q.status));
    const books = extra.books.filter((b) => ACTIVE_BK.has(b.status));
    const quoted = reqs.filter((q) => q.status === 'cotizada');
    const pay = extra.books.filter((b) => b.status === 'aceptada_pendiente_pago');
    const nudges = [];
    pay.forEach((b) => nudges.push('<div class="cl-nudge cl-act"><div><b>Completa una reserva</b><p>Falta el pago del 10 % a Bastet para confirmarla.</p></div><a class="btn btn-accent btn-sm" href="../estadias.html?reserva=' + encodeURIComponent(b.code) + '">Pagar ahora</a></div>'));
    if (quoted.length) nudges.push('<div class="cl-nudge cl-ok"><div><b>Tienes ' + quoted.length + ' cotización(es) lista(s)</b><p>Revisa el detalle y responde a Bastet por WhatsApp para confirmar.</p></div><button type="button" class="btn btn-accent btn-sm" data-cx-go="estadias">Ver cotizaciones</button></div>');
    const act = isActive();
    return gate() + (nudges.length ? '<div class="cl-nudges">' + nudges.join('') + '</div>' : '') +
      '<section class="cx-actions" aria-label="¿Qué necesita tu empresa?">' +
      '<button type="button" class="cx-action" data-cx-go="estadias"><b>Alojamiento para mi equipo</b><span>Programa estadías de tus trabajadores en cualquier ciudad de Bolivia.</span></button>' +
      '<button type="button" class="cx-action" data-cx-go="espacios" data-cx-kind="espacio"><b>Alquilar un espacio para operar</b><span>Oficinas, depósitos, locales o terrenos para tu operación.</span></button>' +
      '<button type="button" class="cx-action" data-cx-go="espacios" data-cx-kind="compra"><b>Comprar un inmueble</b><span>Una persona de Bastet te acompaña de la búsqueda al cierre.</span></button></section>' +
      '<section class="cl-stats cx-stats"><div><b>' + open.length + '</b><span>solicitudes abiertas</span></div><div><b>' + books.length + '</b><span>reservas activas</span></div><div><b>' + (state.workers || []).length + '</b><span>personas en tu equipo</span></div>' +
      (act && Number(state.company.discount_percent) > 0 ? '<div><b>' + esc(String(Number(state.company.discount_percent)).replace('.', ',')) + ' %</b><span>de tarifa corporativa</span></div>' : '') + '</section>' +
      '<div class="cp-card"><h2>Explorar ahora</h2><p class="cp-hint">También puedes elegir tú mismo y reservar o pedir contacto como cualquier cliente; todo queda en «Reservas y contactos».</p><div class="cx-links">' +
      '<a class="btn btn-ghost btn-sm" href="../estadias.html">Estadías temporales</a><a class="btn btn-ghost btn-sm" href="../marketplace.html?op=alquiler">Alquileres</a><a class="btn btn-ghost btn-sm" href="../marketplace.html?op=venta">Propiedades en venta</a><a class="btn btn-ghost btn-sm" href="../marketplace.html?op=anticretico">Anticrético</a></div></div>' +
      (reqs.length ? '<div class="cp-card"><h2>Últimas solicitudes</h2><div class="cp-list">' + reqs.slice(0, 3).map(reqItem).join('') + '</div></div>' : '') +
      trust();
  }
  function viewEstadias() {
    const g = gate(); if (g && !isActive()) return g;
    const workers = state.workers || [];
    return '<div class="cp-card"><h2>Programar alojamiento para tu equipo</h2><p class="cp-hint">Cuéntanos ciudad, fechas y quiénes viajan. Bastet te responde con una cotización a tarifa corporativa y coordina contigo por WhatsApp.</p>' +
      '<form id="cx-req-estadia" class="cp-form"><div class="cp-grid">' +
      '<label>Ciudad de destino<select name="city" required>' + cityOptions('') + '</select></label>' +
      '<label>Llegada<input name="from_date" type="date" min="' + today() + '" required></label>' +
      '<label>Salida<input name="to_date" type="date" min="' + today() + '" required></label>' +
      '<label>Presupuesto por noche (opcional)<input name="budget_text" maxlength="120" placeholder="Ej: hasta Bs 250 por persona"></label></div>' +
      (workers.length ? '<fieldset class="cx-pick"><legend>¿Quiénes viajan?</legend>' + workers.map((w) => '<label class="cx-chk"><input type="checkbox" name="worker" value="' + esc(w.id) + '"> ' + esc(w.full_name) + (w.job_title ? ' <small>' + esc(w.job_title) + '</small>' : '') + '</label>').join('') + '</fieldset>' +
        '<label>O indica solo la cantidad (si no están en tu lista)<input name="workers_count" type="number" min="1" max="200" placeholder="Ej: 4"></label>' :
        '<label>Trabajadores que viajan<input name="workers_count" type="number" min="1" max="200" required value="1"></label><p class="cp-hint">Agrega a tu equipo en «Equipo» para elegirlos de una lista la próxima vez.</p>') +
      '<label>Detalles (opcional)<textarea name="notes" rows="2" maxlength="1000" placeholder="Tipo de alojamiento, cercanía a la obra, habitaciones individuales, facturación…"></textarea></label>' +
      '<button type="submit" class="btn btn-accent">Solicitar cotización</button></form></div>' + reqList(['estadia'], 'Aún no programaste alojamiento para tu equipo.');
  }
  function viewEspacios() {
    const g = gate(); if (g && !isActive()) return g;
    return '<div class="cp-card"><h2>Alquilar un espacio o comprar un inmueble</h2><p class="cp-hint">Dinos qué necesita tu operación. Una persona de Bastet busca opciones y te las presenta; solo pagas cuando elijas.</p>' +
      '<form id="cx-req-espacio" class="cp-form"><div class="cx-seg" role="radiogroup" aria-label="¿Qué necesitas?"><label><input type="radio" name="kind" value="espacio" checked> Alquilar un espacio</label><label><input type="radio" name="kind" value="compra"> Comprar un inmueble</label></div>' +
      '<div class="cp-grid">' +
      '<label>Ciudad<select name="city" required>' + cityOptions('') + '</select></label>' +
      '<label>Tipo de espacio<select name="space_type" required><option value="">Elige el tipo</option>' + SPACE_TYPES.map((t) => '<option>' + esc(t) + '</option>').join('') + '</select></label>' +
      '<label>Tamaño aproximado<input name="size_text" maxlength="120" placeholder="Ej: 300 m² o 10 oficinas"></label>' +
      '<label>Desde cuándo lo necesitas<input name="from_date" type="date" min="' + today() + '"></label>' +
      '<label>Presupuesto (opcional)<input name="budget_text" maxlength="120" placeholder="Ej: hasta USD 1.500 al mes"></label></div>' +
      '<label>Detalles (opcional)<textarea name="notes" rows="2" maxlength="1000" placeholder="Zona, accesos, seguridad, contrato a nombre de la empresa…"></textarea></label>' +
      '<button type="submit" class="btn btn-accent">Enviar solicitud</button></form></div>' + reqList(['espacio', 'compra'], 'Aún no pediste espacios ni propiedades.');
  }
  function viewActividad() {
    const bk = extra.books, rq = extra.reqs;
    const title = (id, fb) => (extra.props[id] ? extra.props[id].title : fb);
    const bkRow = (b) => { const m = BK[b.status] || ['wait', b.status]; return '<li class="cl-row"><div class="cl-row-main"><b>' + esc(title(b.property_id, 'Estadía')) + '</b><span class="cl-muted">' + esc(fdate(b.check_in)) + ' – ' + esc(fdate(b.check_out)) + ' · ' + esc(b.guests) + ' huésped(es) · reserva ' + esc(b.code) + '</span></div><div class="cl-row-side"><span class="cl-chip cl-' + m[0] + '">' + esc(m[1]) + '</span><a class="btn ' + (b.status === 'aceptada_pendiente_pago' ? 'btn-accent' : 'btn-ghost') + ' btn-sm" href="../estadias.html?reserva=' + encodeURIComponent(b.code) + '">' + (b.status === 'aceptada_pendiente_pago' ? 'Pagar' : 'Ver reserva') + '</a></div></li>'; };
    const rqRow = (q) => { const m = RQ[q.status] || ['wait', q.status]; const p = extra.props[q.property_id]; return '<li class="cl-row"><div class="cl-row-main"><b>' + esc(p ? p.title : 'Inmueble') + '</b><span class="cl-muted">' + esc([OP[q.operation], p ? String(p.location || '').split(',')[0] : ''].filter(Boolean).join(' · ')) + ' · solicitud ' + esc(q.code) + ' · ' + esc(fdate(q.created_at)) + '</span></div><div class="cl-row-side"><span class="cl-chip cl-' + m[0] + '">' + esc(m[1]) + '</span>' + (q.status === 'conexion_generada' && q.contact_phone ? '<a class="btn btn-accent btn-sm" target="_blank" rel="noopener" href="' + esc(waLink(q.contact_phone)) + '">WhatsApp</a>' : '') + '</div></li>'; };
    return '<div class="cp-card"><h2>Reservas de estadías</h2>' + (bk.length ? '<ul class="cl-list">' + bk.slice(0, 15).map(bkRow).join('') + '</ul>' : '<p class="cp-hint">Aún no hay reservas con la cuenta de la empresa. <a href="../estadias.html">Ver estadías</a></p>') + '</div>' +
      '<div class="cp-card"><h2>Solicitudes de contacto</h2>' + (rq.length ? '<ul class="cl-list">' + rq.slice(0, 15).map(rqRow).join('') + '</ul>' : '<p class="cp-hint">Cuando pidas contacto en una propiedad, lo verás aquí con su estado. <a href="../marketplace.html">Ver propiedades</a></p>') + '</div>';
  }
  function viewEquipo() {
    const g = gate(); if (g && !isActive()) return g;
    const workers = state.workers || [];
    return '<div class="cp-card"><h2>Tu equipo (' + workers.length + ')</h2>' +
      (workers.length ? '<div class="cp-list">' + workers.map((w) => '<article class="cp-item cp-worker"><span><b>' + esc(w.full_name) + '</b>' + (w.job_title ? ' · ' + esc(w.job_title) : '') + (w.phone ? ' · ' + esc(w.phone) : '') + (w.ci ? ' · CI ' + esc(w.ci) : '') + '</span>' +
        '<button type="button" class="btn btn-ghost btn-sm" data-cp-remove="' + esc(w.id) + '">Quitar</button></article>').join('') + '</div>' : '<p class="cp-hint">Agrega a las personas que suelen viajar; no necesitan cuenta. Así las eliges de una lista al pedir alojamiento.</p>') +
      '<form id="cp-worker" class="cp-form cp-inline"><label>Nombre completo<input name="full_name" required maxlength="120"></label><label>Cargo<input name="job_title" maxlength="80"></label>' +
      '<label>Teléfono<input name="phone" maxlength="30" inputmode="tel"></label><label>CI<input name="ci" maxlength="20"></label><button type="submit" class="btn btn-accent">Agregar</button></form></div>';
  }
  function viewEmpresa() {
    const c = state.company;
    if (!state.enabled && !c) return gate();
    if (!c || c.status === 'rechazada') return (c ? gate() : '') + affiliationForm(c);
    const row = (k, v) => (v ? '<div><dt>' + esc(k) + '</dt><dd>' + esc(v) + '</dd></div>' : '');
    return gate() + '<div class="cp-card"><h2>Datos de la empresa</h2><dl class="cx-dl">' + row('Razón social', c.company_name) + row('NIT', c.nit) + row('Contacto', c.contact_name + (c.contact_role ? ' · ' + c.contact_role : '')) + row('WhatsApp', c.whatsapp) + row('Correo', c.email) + row('Ciudad sede', c.city) + row('Viajeros al año (aprox.)', c.workers_estimate) + row('Viajes habituales', c.travel_notes) + '</dl>' +
      (state.perks_text ? '<p class="cp-quote">' + esc(state.perks_text) + '</p>' : '') + '<p class="cp-hint">¿Necesitas cambiar algún dato? Escríbenos y lo actualizamos.</p></div>';
  }

  function draw() {
    const r = root(); if (!r || !state) return;
    const fn = { resumen: viewResumen, estadias: viewEstadias, espacios: viewEspacios, actividad: viewActividad, equipo: viewEquipo, empresa: viewEmpresa }[view] || viewResumen;
    r.innerHTML = hero() + nav() + '<div class="cx-body">' + fn() + '</div>';
  }
  function go(v, kind) {
    view = v; try { sessionStorage.setItem('bastet-co-view', v); } catch (e) { /* sin almacenamiento */ }
    if (state) { draw(); if (kind) { const f = document.getElementById('cx-req-espacio'); const rd = f && f.querySelector('input[name=kind][value="' + kind + '"]'); if (rd) rd.checked = true; } window.scrollTo({ top: 0 }); }
  }

  async function run(fn, ok) {
    if (busy) return; busy = true;
    try { const { data, error } = await fn(); if (error) throw new Error(error.message || 'No se pudo completar'); toast(typeof ok === 'function' ? ok(data) : ok); busy = false; await load(); return true; }
    catch (e) { toast(e.message, true); return false; } finally { busy = false; }
  }
  const formData = (f) => Object.fromEntries([...new FormData(f)].map(([k, v]) => [k, typeof v === 'string' ? v.trim() : v]));

  document.addEventListener('submit', (e) => {
    const f = e.target;
    if (f.id === 'cp-aff') {
      e.preventDefault(); const d = formData(f);
      run(() => supabaseClient.rpc('request_company_affiliation', { p: { ...d, workers_estimate: d.workers_estimate ? Number(d.workers_estimate) : null, consent: f.elements.consent.checked } }), 'Solicitud enviada. Bastet la revisará pronto.');
    } else if (f.id === 'cx-req-estadia') {
      e.preventDefault(); const d = formData(f);
      const ids = [...f.querySelectorAll('input[name=worker]:checked')].map((i) => i.value);
      if (!ids.length && !d.workers_count) { toast('Elige quiénes viajan o escribe la cantidad.', true); return; }
      run(() => supabaseClient.rpc('company_submit_request', { p: { kind: 'estadia', city: d.city, from_date: d.from_date, to_date: d.to_date, budget_text: d.budget_text, notes: d.notes, worker_ids: ids, workers_count: d.workers_count ? Number(d.workers_count) : (ids.length || null) } }), (code) => 'Solicitud enviada (' + code + '). Bastet te responderá con una cotización.');
    } else if (f.id === 'cx-req-espacio') {
      e.preventDefault(); const d = formData(f);
      run(() => supabaseClient.rpc('company_submit_request', { p: { kind: d.kind, city: d.city, space_type: d.space_type, size_text: d.size_text, from_date: d.from_date || null, budget_text: d.budget_text, notes: d.notes, operation: d.kind === 'compra' ? 'venta' : 'alquiler' } }), (code) => 'Solicitud enviada (' + code + '). Una persona de Bastet te contactará con opciones.');
    } else if (f.id === 'cp-worker') {
      e.preventDefault(); const d = formData(f);
      run(() => supabaseClient.rpc('company_add_worker', { p_name: d.full_name, p_ci: d.ci || null, p_phone: d.phone || null, p_job: d.job_title || null }), 'Persona agregada a tu equipo');
    }
  });
  document.addEventListener('click', (e) => {
    const g = e.target.closest('#company-root [data-cx-go]');
    if (g) { go(g.dataset.cxGo, g.dataset.cxKind); return; }
    const rm = e.target.closest('[data-cp-remove]'), cn = e.target.closest('[data-cp-cancel]');
    if (rm && confirm('¿Quitar a esta persona de tu equipo?')) run(() => supabaseClient.rpc('company_remove_worker', { p_id: rm.dataset.cpRemove }), 'Persona quitada');
    if (cn && confirm('¿Cancelar esta solicitud?')) run(() => supabaseClient.rpc('company_cancel_request', { p_id: cn.dataset.cpCancel }), 'Solicitud cancelada');
    if (e.target.closest('.admin-tab[data-tab="company"], .abb-item[data-go="company"]')) setTimeout(load, 0);
  });

  document.addEventListener('uno:account', (e) => {
    const a = e.detail || {};
    isCompany = a.exempt !== true && a.interest === 'empresa';
    document.querySelectorAll('.admin-tab[data-tab="company"], .abb-item[data-go="company"]').forEach((t) => t.classList.toggle('hidden', !isCompany));
  });
  // Se actualiza solo mientras está abierto (cotizaciones, pagos verificados)
  setInterval(() => {
    if (!isCompany || document.hidden || typeof supabaseClient === 'undefined') return;
    const panel = document.getElementById('tab-panel-company');
    if (panel && !panel.classList.contains('hidden') && !document.querySelector('.modal-overlay') && !(document.activeElement && document.activeElement.form)) load();
  }, 60000);
})();
