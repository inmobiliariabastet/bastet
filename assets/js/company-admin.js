/* Panel «Empresas» (administración): enciende el servicio, fija el descuento corporativo por defecto, activa/suspende empresas y atiende las solicitudes
 * de alojamiento (primero las nuevas): cambia el estado, escribe la cotización y avisa por WhatsApp. SQL: supabase/corporate.sql. */
(function () {
  const KINDS = { estadia: 'Alojamiento del equipo', espacio: 'Espacio para operar', compra: 'Compra de inmueble' };
  'use strict';
  const root = () => document.getElementById('companies-root');
  const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const fdate = (d) => (d ? new Date(String(d).slice(0, 10) + 'T12:00:00').toLocaleDateString('es-BO', { day: '2-digit', month: 'short', year: 'numeric' }) : '');
  const wa = (phone, text) => { let d = String(phone || '').replace(/\D/g, ''); if (d.length === 8) d = '591' + d; return 'https://api.whatsapp.com/send?phone=' + d + (text ? '&text=' + encodeURIComponent(text) : ''); };
  const CST = { solicitada: 'En revisión', activa: 'Activa', suspendida: 'Suspendida', rechazada: 'Rechazada' };
  const RST = { nueva: 'Nueva', en_gestion: 'En gestión', cotizada: 'Cotizada', confirmada: 'Confirmada', cerrada: 'Cerrada', cancelada: 'Cancelada' };
  let data = null, busy = false;

  function toast(msg, bad) {
    let el = document.getElementById('ct-toast');
    if (!el) { el = document.createElement('div'); el.id = 'ct-toast'; el.setAttribute('role', 'status'); document.body.appendChild(el); }
    el.textContent = msg; el.className = 'ct-toast show' + (bad ? ' is-error' : '');
    clearTimeout(toast.t); toast.t = setTimeout(() => { el.className = 'ct-toast'; }, 5200);
  }
  const opts = (map, cur) => Object.keys(map).map((k) => '<option value="' + k + '"' + (k === cur ? ' selected' : '') + '>' + map[k] + '</option>').join('');

  async function load() {
    const r = root(); if (!r) return;
    const { data: d, error } = await supabaseClient.rpc('admin_corporate_overview');
    if (error) { r.innerHTML = '<p class="property-empty">' + (/function|schema cache/i.test(error.message || '') ? 'Corre primero supabase/corporate.sql.' : esc(error.message)) + '</p>'; return; }
    data = d; draw();
  }

  function draw() {
    const r = root(); if (!r || !data) return;
    const s = data.settings || {}, cs = data.companies || [], rq = data.requests || [];
    const badge = document.getElementById('companies-count');
    const open = cs.filter((c) => c.status === 'solicitada').length + rq.filter((q) => q.status === 'nueva').length;
    if (badge) { badge.textContent = open; badge.classList.toggle('hidden', !open); }
    r.innerHTML =
      '<form class="cp-card cp-form" id="cpa-settings"><h2>Servicio de empresas</h2>' +
      '<label class="cp-check"><input type="checkbox" name="enabled"' + (s.enabled ? ' checked' : '') + '> Servicio encendido (las cuentas de empresa pueden pedir la afiliación)</label>' +
      '<div class="cp-grid"><label>Descuento corporativo por defecto (%)<input name="discount" type="number" min="0" max="100" step="0.5" value="' + esc(s.discount_default) + '"></label></div>' +
      '<label>Beneficios que ve la empresa en su panel (opcional)<textarea name="perks" rows="2" maxlength="600">' + esc(s.perks_text) + '</textarea></label>' +
      '<button type="submit" class="btn btn-accent">Guardar</button></form>' +
      '<div class="cp-card"><h2>Solicitudes de empresas (' + rq.length + ')</h2>' + (rq.length ? '<div class="cp-list">' + rq.map((q) =>
        '<article class="cp-item"><div class="cp-item-top"><b>' + esc(q.company_name) + '</b> · <i>' + esc(KINDS[q.kind] || 'Alojamiento del equipo') + '</i> · ' + esc(q.city) + ' · ' + (q.kind === 'espacio' || q.kind === 'compra' ? esc([q.operation, q.space_type, q.size_text].filter(Boolean).join(' · ')) + (q.from_date ? ' · desde ' + esc(fdate(q.from_date)) : '') : esc(fdate(q.from_date)) + ' – ' + esc(fdate(q.to_date)) + ' · ' + esc(q.workers_count) + ' trabajador(es)') +
        (q.budget_text ? ' · ' + esc(q.budget_text) : '') + ' <small>' + esc(q.code) + ' · tarifa ' + esc(Number(q.discount_percent)) + ' %</small></div>' +
        (q.notes ? '<p class="cp-hint">' + esc(q.notes) + '</p>' : '') +
        '<div class="cp-row" data-rq="' + esc(q.id) + '"><select data-f="status">' + opts(RST, q.status) + '</select>' +
        '<textarea data-f="quote" rows="2" maxlength="3000" placeholder="Cotización a tarifa corporativa">' + esc(q.admin_quote) + '</textarea>' +
        '<button type="button" class="btn btn-sm btn-accent" data-act="save-rq">Guardar</button>' +
        '<a class="btn btn-sm btn-ghost" target="_blank" rel="noopener" href="' + esc(wa(q.whatsapp, 'Hola, te escribe Bastet sobre tu solicitud ' + q.code + ' (' + (KINDS[q.kind] || 'alojamiento') + ') en ' + q.city + (q.kind === 'estadia' || !q.kind ? ' (' + fdate(q.from_date) + ' – ' + fdate(q.to_date) + ')' : '') + '. ' + (q.admin_quote ? 'Cotización: ' + q.admin_quote : ''))) + '">WhatsApp</a></div></article>').join('') + '</div>' : '<p class="cp-hint">Sin solicitudes todavía.</p>') + '</div>' +
      '<div class="cp-card"><h2>Empresas (' + cs.length + ')</h2>' + (cs.length ? '<div class="cp-list">' + cs.map((c) =>
        '<article class="cp-item"><div class="cp-item-top"><b>' + esc(c.company_name) + '</b> · NIT ' + esc(c.nit) + ' · ' + esc(c.contact_name) + (c.contact_role ? ' (' + esc(c.contact_role) + ')' : '') + ' · ' + esc(c.workers) + ' trabajador(es) registrados' +
        ' <small>' + esc(c.owner_email || '') + (c.city ? ' · ' + esc(c.city) : '') + (c.workers_estimate ? ' · ~' + esc(c.workers_estimate) + ' viajan al año' : '') + '</small></div>' +
        (c.travel_notes ? '<p class="cp-hint">' + esc(c.travel_notes) + '</p>' : '') +
        '<div class="cp-row" data-co="' + esc(c.id) + '"><select data-f="status">' + opts(CST, c.status) + '</select>' +
        '<label class="cp-mini">Descuento %<input data-f="discount" type="number" min="0" max="100" step="0.5" value="' + esc(Number(c.discount_percent) || '') + '" placeholder="' + esc(s.discount_default) + '"></label>' +
        '<textarea data-f="notes" rows="2" maxlength="2000" placeholder="Notas internas (no las ve la empresa)">' + esc(c.admin_notes) + '</textarea>' +
        '<button type="button" class="btn btn-sm btn-accent" data-act="save-co">Guardar</button>' +
        '<a class="btn btn-sm btn-ghost" target="_blank" rel="noopener" href="' + esc(wa(c.whatsapp, 'Hola, te escribe Bastet sobre la afiliación de ' + c.company_name + '.')) + '">WhatsApp</a></div></article>').join('') + '</div>' : '<p class="cp-hint">Aún no hay empresas.</p>') + '</div>';
  }

  async function run(fn, ok) {
    if (busy) return; busy = true;
    try { const { error } = await fn(); if (error) throw new Error(error.message); toast(ok); await load(); } catch (e) { toast(e.message || 'No se pudo guardar', true); } finally { busy = false; }
  }
  document.addEventListener('submit', (e) => {
    if (e.target.id !== 'cpa-settings') return; e.preventDefault();
    const f = e.target;
    run(() => supabaseClient.rpc('admin_set_corporate_settings', { p_enabled: f.elements.enabled.checked, p_discount_default: Number(f.elements.discount.value), p_perks: f.elements.perks.value.trim() }), 'Guardado');
  });
  document.addEventListener('click', (e) => {
    const b = e.target.closest('[data-act]'); if (!b) return;
    const row = b.closest('.cp-row'), val = (k) => { const el = row.querySelector('[data-f="' + k + '"]'); return el ? el.value : ''; };
    if (b.dataset.act === 'save-rq') run(() => supabaseClient.rpc('admin_update_company_request', { p_id: row.dataset.rq, p_status: val('status'), p_quote: val('quote').trim() }), 'Solicitud actualizada');
    if (b.dataset.act === 'save-co') run(() => supabaseClient.rpc('admin_set_company', { p_id: row.dataset.co, p_status: val('status'), p_discount: val('discount') === '' ? null : Number(val('discount')), p_notes: val('notes').trim() }), 'Empresa actualizada');
  });
  const tab = document.querySelector('.admin-tab[data-tab="companies"]');
  if (tab) tab.addEventListener('click', load);
})();
