/* Panel «Mi empresa» (cuentas de tipo empresa): afiliación corporativa, trabajadores y solicitudes de alojamiento para el equipo.
 * Flujo: la empresa pide la afiliación → Bastet la revisa y la activa fijando la tarifa corporativa → la empresa registra trabajadores y envía
 * solicitudes (ciudad, fechas, cuántos viajan) → Bastet cotiza y coordina por WhatsApp. SQL: supabase/corporate.sql (todo apagado hasta encenderlo en /admin → Empresas).
 * Autónomo: usa `supabaseClient` y el evento `uno:account` de publications.js (my_account.interest). */
(function () {
  'use strict';
  const root = () => document.getElementById('company-root');
  const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const fdate = (d) => (d ? new Date(d + 'T12:00:00').toLocaleDateString('es-BO', { day: '2-digit', month: 'short', year: 'numeric' }) : '');
  const today = () => new Date(Date.now() - 4 * 3600 * 1000).toISOString().slice(0, 10);
  const RSTATUS = { nueva: ['Recibida', 'wait'], en_gestion: ['En gestión', 'wait'], cotizada: ['Cotizada', 'ok'], confirmada: ['Confirmada', 'ok'], cerrada: ['Cerrada', ''], cancelada: ['Cancelada', 'bad'] };
  const CSTATUS = { solicitada: 'En revisión de Bastet', activa: 'Afiliación activa', suspendida: 'Afiliación suspendida', rechazada: 'Solicitud rechazada' };
  let state = null, busy = false, isCompany = false;

  function toast(msg, bad) {
    let el = document.getElementById('ct-toast');
    if (!el) { el = document.createElement('div'); el.id = 'ct-toast'; el.setAttribute('role', 'status'); document.body.appendChild(el); }
    el.textContent = msg; el.className = 'ct-toast show' + (bad ? ' is-error' : '');
    clearTimeout(toast.t); toast.t = setTimeout(() => { el.className = 'ct-toast'; }, 5200);
  }
  const cities = () => (typeof BOLIVIA_CITIES !== 'undefined' && Array.isArray(BOLIVIA_CITIES)) ? BOLIVIA_CITIES : [];
  const cityOptions = (sel) => '<option value="">Elige la ciudad</option>' + cities().map((c) => '<option' + (c === sel ? ' selected' : '') + '>' + esc(c) + '</option>').join('');

  async function load() {
    const r = root(); if (!r) return;
    const { data, error } = await supabaseClient.rpc('my_company');
    if (error) { r.innerHTML = '<p class="property-empty">' + (/function|schema cache/i.test(error.message || '') ? 'Esta función aún no está disponible.' : esc(error.message)) + '</p>'; return; }
    state = data; draw();
  }

  function affiliationForm(c) {
    return '<form class="cp-card cp-form" id="cp-aff"><h2>' + (c ? 'Corrige y vuelve a enviar tu solicitud' : 'Solicita la afiliación de tu empresa') + '</h2>' +
      '<p class="cp-hint">Bastet revisa los datos y activa tu tarifa corporativa para el alojamiento de tus trabajadores.</p>' +
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

  function draw() {
    const r = root(); if (!r || !state) return;
    if (!state.enabled && !state.company) {
      r.innerHTML = '<div class="cp-card"><h2>Afiliación de empresas</h2><p>Estamos abriendo el servicio de alojamiento corporativo. Tu cuenta de empresa ya está lista: cuando se habilite, aquí podrás solicitar la afiliación.</p></div>';
      return;
    }
    const c = state.company;
    if (!c || c.status === 'rechazada') {
      r.innerHTML = (c ? '<div class="cp-card cp-warn"><h2>Tu solicitud fue rechazada</h2><p>' + 'Puedes corregir los datos y enviarla de nuevo, o escribirnos por WhatsApp para aclararlo.</p></div>' : '') + affiliationForm(c);
      return;
    }
    const head = '<div class="cp-card cp-head"><div><h2>' + esc(c.company_name) + '</h2><p>NIT ' + esc(c.nit) + ' · Contacto: ' + esc(c.contact_name) + '</p></div>' +
      '<div class="cp-pills"><span class="cp-pill ' + (c.status === 'activa' ? 'ok' : c.status === 'suspendida' ? 'bad' : 'wait') + '">' + esc(CSTATUS[c.status] || c.status) + '</span>' +
      (c.status === 'activa' && Number(c.discount_percent) > 0 ? '<span class="cp-pill ok">Tarifa corporativa: ' + esc(String(Number(c.discount_percent)).replace('.', ',')) + ' % menos</span>' : '') + '</div></div>';
    if (c.status === 'solicitada') { r.innerHTML = head + '<div class="cp-card"><p>Bastet está revisando tu solicitud. Te avisaremos por WhatsApp al <b>' + esc(c.whatsapp) + '</b> cuando tu afiliación esté activa.</p></div>'; return; }
    if (c.status === 'suspendida') { r.innerHTML = head + '<div class="cp-card cp-warn"><p>Tu afiliación está suspendida. Escríbenos por WhatsApp para reactivarla.</p></div>'; return; }

    const workers = state.workers || [], reqs = state.requests || [];
    r.innerHTML = head +
      (state.perks_text ? '<div class="cp-card"><p>' + esc(state.perks_text) + '</p></div>' : '') +
      '<div class="cp-card"><h2>Solicitar alojamiento para tu equipo</h2><form id="cp-req" class="cp-form"><div class="cp-grid">' +
      '<label>Ciudad de destino<select name="city" required>' + cityOptions('') + '</select></label>' +
      '<label>Trabajadores que viajan<input name="workers_count" type="number" min="1" max="200" value="' + Math.max(1, Math.min(workers.length, 200)) + '" required></label>' +
      '<label>Llegada<input name="from_date" type="date" min="' + today() + '" required></label>' +
      '<label>Salida<input name="to_date" type="date" min="' + today() + '" required></label>' +
      '<label>Presupuesto por noche (opcional)<input name="budget_text" maxlength="120" placeholder="Ej: hasta Bs 250 por persona"></label>' +
      '</div><label>Detalles (opcional)<textarea name="notes" rows="2" maxlength="1000" placeholder="Tipo de alojamiento, cercanía a la obra, habitaciones individuales…"></textarea></label>' +
      '<button type="submit" class="btn btn-accent">Enviar solicitud</button></form></div>' +
      '<div class="cp-card"><h2>Tus solicitudes</h2>' + (reqs.length ? '<div class="cp-list">' + reqs.map((q) => {
        const st = RSTATUS[q.status] || [q.status, ''];
        return '<article class="cp-item"><div class="cp-item-top"><b>' + esc(q.city) + '</b> · ' + esc(fdate(q.from_date)) + ' – ' + esc(fdate(q.to_date)) + ' · ' + esc(q.workers_count) + ' trabajador(es) <small>' + esc(q.code) + '</small>' +
          '<span class="cp-pill ' + st[1] + '">' + esc(st[0]) + '</span></div>' +
          (q.admin_quote ? '<p class="cp-quote"><b>Cotización de Bastet:</b> ' + esc(q.admin_quote).replace(/\n/g, '<br>') + '</p>' : '') +
          (['nueva', 'en_gestion', 'cotizada'].includes(q.status) ? '<button type="button" class="btn btn-ghost btn-sm" data-cp-cancel="' + esc(q.id) + '">Cancelar solicitud</button>' : '') + '</article>';
      }).join('') + '</div>' : '<p class="cp-hint">Aún no enviaste solicitudes.</p>') + '</div>' +
      '<div class="cp-card"><h2>Tus trabajadores (' + workers.length + ')</h2>' +
      (workers.length ? '<div class="cp-list">' + workers.map((w) => '<article class="cp-item cp-worker"><span><b>' + esc(w.full_name) + '</b>' + (w.job_title ? ' · ' + esc(w.job_title) : '') + (w.phone ? ' · ' + esc(w.phone) : '') + (w.ci ? ' · CI ' + esc(w.ci) : '') + '</span>' +
        '<button type="button" class="btn btn-ghost btn-sm" data-cp-remove="' + esc(w.id) + '">Quitar</button></article>').join('') + '</div>' : '<p class="cp-hint">Agrega a las personas que suelen viajar; no necesitan cuenta.</p>') +
      '<form id="cp-worker" class="cp-form cp-inline"><label>Nombre completo<input name="full_name" required maxlength="120"></label><label>Cargo<input name="job_title" maxlength="80"></label>' +
      '<label>Teléfono<input name="phone" maxlength="30" inputmode="tel"></label><label>CI<input name="ci" maxlength="20"></label><button type="submit" class="btn btn-accent">Agregar</button></form></div>';
  }

  async function run(fn, ok) {
    if (busy) return; busy = true;
    try { const { data, error } = await fn(); if (error) throw new Error(error.message || 'No se pudo completar'); toast(typeof ok === 'function' ? ok(data) : ok); await load(); return true; }
    catch (e) { toast(e.message, true); return false; } finally { busy = false; }
  }
  const formData = (f) => Object.fromEntries([...new FormData(f)].map(([k, v]) => [k, typeof v === 'string' ? v.trim() : v]));

  document.addEventListener('submit', (e) => {
    const f = e.target;
    if (f.id === 'cp-aff') {
      e.preventDefault(); const d = formData(f);
      run(() => supabaseClient.rpc('request_company_affiliation', { p: { ...d, workers_estimate: d.workers_estimate ? Number(d.workers_estimate) : null, consent: f.elements.consent.checked } }), 'Solicitud enviada. Bastet la revisará pronto.');
    } else if (f.id === 'cp-req') {
      e.preventDefault(); const d = formData(f);
      run(() => supabaseClient.rpc('company_submit_request', { p: { ...d, workers_count: Number(d.workers_count) } }), (code) => 'Solicitud enviada (' + code + '). Bastet te responderá con una cotización.');
    } else if (f.id === 'cp-worker') {
      e.preventDefault(); const d = formData(f);
      run(() => supabaseClient.rpc('company_add_worker', { p_name: d.full_name, p_ci: d.ci || null, p_phone: d.phone || null, p_job: d.job_title || null }), 'Trabajador agregado');
    }
  });
  document.addEventListener('click', (e) => {
    const rm = e.target.closest('[data-cp-remove]'), cn = e.target.closest('[data-cp-cancel]');
    if (rm && confirm('¿Quitar a este trabajador de tu lista?')) run(() => supabaseClient.rpc('company_remove_worker', { p_id: rm.dataset.cpRemove }), 'Trabajador quitado');
    if (cn && confirm('¿Cancelar esta solicitud de alojamiento?')) run(() => supabaseClient.rpc('company_cancel_request', { p_id: cn.dataset.cpCancel }), 'Solicitud cancelada');
    if (e.target.closest('.admin-tab[data-tab="company"]')) setTimeout(load, 0);
  });

  document.addEventListener('uno:account', (e) => {
    const a = e.detail || {};
    isCompany = a.exempt !== true && a.interest === 'empresa';
    const tab = document.querySelector('.admin-tab[data-tab="company"]');
    if (tab) tab.classList.toggle('hidden', !isCompany);
  });
})();
