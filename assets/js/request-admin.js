/* Panel (solo administradores): «Solicitudes de búsqueda» de compradores e inquilinos (botón «Solicitar una propiedad» del sitio).
 * Se muestra dentro de la pestaña de propietarios que quieren vender. El admin ve cada solicitud, contacta por WhatsApp y cambia su
 * estado (Activa / En proceso / Finalizada) con una nota interna. Funciones SQL en supabase/property-requests.sql. Autónomo: `supabaseClient`. */
(function () {
  'use strict';
  const panel = document.getElementById('tab-panel-sell');
  if (!panel) return;
  const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const OPS = { venta: 'Compra', alquiler: 'Alquiler', anticretico: 'Anticrético', temporal: 'Estadía temporal' };
  const TYPES = { casa: 'Casa', departamento: 'Departamento', habitacion: 'Habitación', terreno: 'Terreno', oficina: 'Oficina', local: 'Local comercial', otro: 'Otro' };
  const ST = { active: 'Activa', in_progress: 'En proceso', finished: 'Finalizada' };
  const fdate = (d) => new Date(d).toLocaleDateString('es-BO', { day: '2-digit', month: 'short', year: 'numeric' });
  const n = (v) => Number(v).toLocaleString('es-BO');

  const sec = document.createElement('section');
  sec.className = 'req-admin';
  sec.innerHTML = '<div class="admin-toolbar"><div><h1>Solicitudes de búsqueda</h1><p class="admin-toolbar-hint">Compradores e inquilinos que usaron «Solicitar una propiedad». Contáctalos por WhatsApp y actualiza el estado.</p></div></div><div id="req-board" class="req-board"><p class="req-empty">Cargando…</p></div>';
  panel.appendChild(sec);
  const board = sec.querySelector('#req-board');
  let rows = [], busy = false, filter = 'active';

  function draw() {
    const counts = Object.fromEntries(Object.keys(ST).map((k) => [k, rows.filter((r) => r.status === k).length]));
    const list = rows.filter((r) => r.status === filter);
    board.innerHTML = '<div class="req-tabs">' + Object.entries(ST).map(([k, t]) => '<button type="button" class="req-tab' + (k === filter ? ' is-on' : '') + '" data-filter="' + k + '">' + t + ' (' + counts[k] + ')</button>').join('') + '</div>' +
      (list.length ? list.map((r) => {
        const cur = r.currency === 'BOB' ? 'Bs ' : 'USD ';
        const budget = r.budget_min || r.budget_max ? [r.budget_min ? 'desde ' + cur + n(r.budget_min) : '', r.budget_max ? 'hasta ' + cur + n(r.budget_max) : ''].filter(Boolean).join(' ') : 'Sin presupuesto';
        const wa = 'https://api.whatsapp.com/send?phone=' + r.contact_phone.replace(/[^0-9]/g, '') + '&text=' + encodeURIComponent('Hola ' + r.contact_name.split(' ')[0] + ', te escribimos de Bastet por tu solicitud de propiedad (' + (OPS[r.operation] || '') + ' · ' + (TYPES[r.property_type] || '') + ' en ' + r.city + ').');
        return '<article class="req-card" data-id="' + esc(r.id) + '"><header><b>' + esc((TYPES[r.property_type] || '') + ' · ' + r.city + (r.zone ? ' (' + r.zone + ')' : '')) + '</b><span>' + esc(OPS[r.operation] || '') + '</span></header>' +
          '<p class="req-meta">' + esc(budget) + (r.rooms_min ? ' · ' + r.rooms_min + '+ hab.' : '') + (r.baths_min ? ' · ' + r.baths_min + '+ baños' : '') + (r.area_min || r.area_max ? ' · ' + (r.area_min ? 'desde ' + n(r.area_min) : '') + (r.area_max ? ' hasta ' + n(r.area_max) : '') + ' m²' : '') + '</p>' +
          (r.features && r.features.length ? '<p class="req-meta">' + esc(r.features.join(', ')) + '</p>' : '') + (r.description ? '<p class="req-desc">' + esc(r.description) + '</p>' : '') +
          '<p class="req-contact"><b>' + esc(r.contact_name) + '</b> · ' + esc(r.contact_phone) + (r.contact_email ? ' · ' + esc(r.contact_email) : '') + ' · <small>' + esc(fdate(r.created_at)) + '</small></p>' +
          '<div class="req-actions"><a class="btn btn-primary btn-sm" href="' + esc(wa) + '" target="_blank" rel="noopener">WhatsApp</a>' +
          '<select data-status aria-label="Estado">' + Object.entries(ST).map(([k, t]) => '<option value="' + k + '"' + (k === r.status ? ' selected' : '') + '>' + t + '</option>').join('') + '</select>' +
          '<input type="text" data-note maxlength="200" placeholder="Nota interna" value="' + esc(r.admin_note || '') + '"><button type="button" class="btn btn-ghost btn-sm" data-save>Guardar</button></div></article>';
      }).join('') : '<p class="req-empty">No hay solicitudes en este estado.</p>');
  }

  async function load() {
    if (busy) return; busy = true;
    const { data, error } = await supabaseClient.rpc('admin_property_requests');
    busy = false;
    if (error) { board.innerHTML = '<p class="req-empty">' + (/function|schema cache/i.test(error.message || '') ? 'Las solicitudes de búsqueda todavía no están activadas en la base de datos (falta correr supabase/property-requests.sql).' : esc(error.message)) + '</p>'; return; }
    rows = data || []; draw();
  }
  board.addEventListener('click', async (e) => {
    const f = e.target.closest('[data-filter]'); if (f) { filter = f.dataset.filter; draw(); return; }
    const save = e.target.closest('[data-save]'); if (!save) return;
    const card = save.closest('.req-card');
    const { error } = await supabaseClient.rpc('admin_set_property_request_status', { p_id: card.dataset.id, p_status: card.querySelector('[data-status]').value, p_note: card.querySelector('[data-note]').value });
    if (error) { alert(error.message); return; }
    load();
  });
  // Se carga al abrir la pestaña
  new MutationObserver(() => { if (!panel.classList.contains('hidden')) load(); }).observe(panel, { attributes: true, attributeFilter: ['class'] });
  if (!panel.classList.contains('hidden')) load();
})();
