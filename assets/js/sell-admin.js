/* Pestaña "Propietarios" (solo administradores): solicitudes de "Vender mi inmueble" que llegan del landing.
   Autónomo (como leads.js): usa `supabaseClient`. Los documentos están en la carpeta privada `sell-documents`;
   se abren con enlaces firmados que vencen a los 10 minutos. RLS: solo un administrador lee y cambia estado/notas. */
(function () {
  'use strict';

  const STAGES = [
    { key: 'new', label: 'Nuevas' },
    { key: 'contacted', label: 'Contactadas' },
    { key: 'review', label: 'En revisión' },
    { key: 'closed', label: 'Cerradas' },
    { key: 'discarded', label: 'Descartadas' },
  ];
  const TYPES = { casa: 'Casa', departamento: 'Departamento', terreno: 'Terreno', otro: 'Otro' };
  const OPS = { venta: 'Venta', anticretico: 'Anticrético', alquiler: 'Alquiler', temporal: 'Temporal (por noche)' };
  const ROLES = { propietario: 'Propietario', copropietario: 'Copropietario', apoderado: 'Apoderado', heredero: 'Heredero' };
  const DOCS = { en_regla: 'Documentos en regla', por_regularizar: 'Falta regularizar', sin_documentos: 'Sin documentos' };
  const DOC_TYPES = { folio_real: 'Folio Real', testimonio: 'Testimonio / escritura', impuestos: 'Impuestos', plano: 'Plano / catastral', ci: 'Cédula de identidad', otros: 'Otros' };

  const board = () => document.getElementById('sell-board');
  const modal = document.getElementById('sell-req-modal');
  const panel = document.getElementById('sell-req-panel');
  const state = { rows: [], busy: false };

  const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const fdate = (d) => new Date(d).toLocaleDateString('es-BO', { day: '2-digit', month: 'short', year: 'numeric' });
  const money = (p, cur) => (p == null ? '—' : (cur === 'BOB' ? 'Bs ' : 'USD ') + Number(p).toLocaleString('es-BO'));
  const m2 = (n) => (n == null ? '—' : Number(n).toLocaleString('es-BO') + ' m²');

  function setCount(n) {
    const el = document.getElementById('sell-count');
    if (!el) return;
    el.textContent = n > 99 ? '99+' : String(n);
    el.classList.toggle('hidden', !n);
  }
  async function refreshCount() {
    const { count, error } = await supabaseClient.from('sell_requests').select('id', { count: 'exact', head: true }).eq('status', 'new');
    if (!error) setCount(count || 0);
  }

  async function load() {
    const host = board();
    if (!host || state.busy) return;
    state.busy = true;
    try {
      const { data, error } = await supabaseClient
        .from('sell_requests')
        .select('id,status,created_at,owner_name,property_type,operation,city,zone,doc_status,needs_legal_support')
        .order('created_at', { ascending: false }).limit(500);
      if (error) throw error;
      state.rows = data || [];
      render();
      setCount(state.rows.filter((r) => r.status === 'new').length);
    } catch (e) {
      host.innerHTML = '<p class="form-error">No se pudieron cargar las solicitudes. ' + esc((e && e.message) || 'Corre supabase/sell-requests.sql si aún no lo hiciste.') + '</p>';
    } finally { state.busy = false; }
  }

  function render() {
    const host = board();
    if (!state.rows.length) { host.innerHTML = '<p class="property-empty">Todavía no hay solicitudes. Aparecerán aquí cuando un propietario use "Vender mi inmueble" en el landing.</p>'; return; }
    host.innerHTML = STAGES.map((st) => {
      const list = state.rows.filter((r) => r.status === st.key);
      return '<section class="lead-col lead-col--' + (st.key === 'discarded' ? 'lost' : st.key) + '"><h2 class="lead-col-title">' + st.label + '<span>' + list.length + '</span></h2>' +
        (list.map((r) =>
          '<button type="button" class="lead-card" data-sell-req="' + r.id + '">' +
            '<b>' + esc(r.owner_name) + '</b>' +
            '<small>' + esc(TYPES[r.property_type] || '') + ' · ' + esc(OPS[r.operation] || '') + ' · ' + esc(r.city) + (r.zone ? ' (' + esc(r.zone) + ')' : '') + '</small>' +
            '<span class="sell-tags"><span class="badge ' + (r.doc_status === 'en_regla' ? 'b-ok' : 'b-warn') + '">' + esc(DOCS[r.doc_status]) + '</span>' +
            (r.needs_legal_support ? '<span class="badge b-gold">Apoyo legal</span>' : '') + '</span>' +
            '<small class="lead-card-date">' + fdate(r.created_at) + '</small>' +
          '</button>').join('') || '<p class="lead-col-empty">—</p>') +
        '</section>';
    }).join('');
  }

  const row = (label, value) => '<div><p class="detail-label">' + label + '</p><p class="detail-value">' + (value || '—') + '</p></div>';

  async function openReq(id) {
    panel.innerHTML = '<p class="credits-muted">Cargando…</p>';
    modal.classList.remove('hidden');
    const { data: r, error } = await supabaseClient.from('sell_requests').select('*').eq('id', id).single();
    if (error || !r) {
      panel.innerHTML = '<p class="form-error">No se pudo abrir esta solicitud.</p><div class="modal-form-actions"><button type="button" class="btn btn-ghost" data-sell-close>Cerrar</button></div>';
      return;
    }
    const digits = String(r.owner_phone || '').replace(/[^0-9]/g, '');
    const first = String(r.owner_name || '').trim().split(/\s+/)[0];
    const wa = 'https://wa.me/' + digits + '?text=' + encodeURIComponent('Hola ' + first + ', te escribo de Bastet por tu solicitud para vender tu inmueble en ' + r.city + '. ¿Cuándo podemos hablar?');
    const map = r.latitude != null ? 'https://www.google.com/maps?q=' + r.latitude + ',' + r.longitude : null;
    const docs = Array.isArray(r.documents) ? r.documents : [];
    panel.innerHTML =
      '<div class="detail-header"><h2>' + esc(r.owner_name) + '</h2><button type="button" class="btn btn-ghost btn-sm" data-sell-close>Cerrar</button></div>' +
      (r.needs_legal_support ? '<p class="sell-legal-flag"><b>Requiere apoyo legal</b> para sanear o regularizar sus documentos.</p>' : '') +
      '<p class="detail-label">Propietario</p><div class="detail-grid">' +
        row('Relación', esc(ROLES[r.owner_role])) + row('Cédula', esc(r.owner_ci)) + row('WhatsApp', esc(r.owner_phone)) + row('Correo', esc(r.owner_email)) + row('Recibida', fdate(r.created_at)) +
      '</div>' +
      '<p class="detail-label">Inmueble</p><div class="detail-grid">' +
        row('Tipo', esc(TYPES[r.property_type])) + row('Operación', esc(OPS[r.operation])) + row('Ciudad', esc(r.city)) + row('Zona', esc(r.zone)) +
        row('Dirección', esc(r.address)) + row(r.operation === 'temporal' ? 'Precio por noche' : 'Precio esperado', esc(money(r.price, r.currency))) + row('Terreno', esc(m2(r.land_area))) + row('Construido', esc(m2(r.built_area))) +
        row('Habitaciones', r.rooms == null ? '' : esc(r.rooms)) + row('Baños', r.baths == null ? '' : esc(r.baths)) +
      '</div>' +
      (r.description ? '<p class="detail-label">Descripción</p><p class="detail-desc">' + esc(r.description) + '</p>' : '') +
      '<div class="detail-contact" style="margin-bottom:18px;">' +
        '<a class="btn btn-accent btn-sm" target="_blank" rel="noopener" href="' + esc(wa) + '">Abrir WhatsApp</a>' +
        (map ? '<a class="btn btn-ghost btn-sm" target="_blank" rel="noopener" href="' + esc(map) + '">Ver ubicación en el mapa</a>' : '') +
      '</div>' +
      '<p class="detail-label">Documentos — ' + esc(DOCS[r.doc_status]) + '</p>' +
      (docs.length
        ? '<ul class="sell-doc-list">' + docs.map((d, i) => '<li><span><b>' + esc(DOC_TYPES[d.type] || 'Documento') + '</b> · ' + esc(d.name) + '</span><button type="button" class="btn btn-ghost btn-sm" data-sell-doc="' + i + '">Abrir</button></li>').join('') + '</ul>'
        : '<p class="detail-desc">No adjuntó documentos.</p>') +
      '<div class="field"><label for="sell-req-stage">Estado</label><select id="sell-req-stage">' +
        STAGES.map((s) => '<option value="' + s.key + '"' + (s.key === r.status ? ' selected' : '') + '>' + s.label + '</option>').join('') + '</select></div>' +
      '<div class="field"><label for="sell-req-notes">Notas internas</label><textarea id="sell-req-notes" rows="4" maxlength="2000" placeholder="Ej: Se agendó visita el jueves. Falta folio real.">' + esc(r.admin_notes || '') + '</textarea></div>' +
      '<p id="sell-req-feedback" class="form-error hidden"></p>' +
      '<div class="modal-form-actions"><button type="button" class="btn btn-danger btn-sm" id="sell-req-delete">Eliminar</button><span style="flex:1"></span><button type="button" class="btn btn-ghost" data-sell-close>Cancelar</button><button type="button" class="btn btn-accent" id="sell-req-save">Guardar</button></div>';

    const fb = panel.querySelector('#sell-req-feedback');
    const fail = (m) => { fb.textContent = m; fb.classList.remove('hidden'); };

    panel.querySelectorAll('[data-sell-doc]').forEach((b) => b.addEventListener('click', async () => {
      const d = docs[+b.dataset.sellDoc];
      b.disabled = true;
      const { data, error: e } = await supabaseClient.storage.from('sell-documents').createSignedUrl(d.path, 600);
      b.disabled = false;
      if (e || !data) return fail('No se pudo abrir el documento: ' + ((e && e.message) || 'sin acceso'));
      window.open(data.signedUrl, '_blank', 'noopener');
    }));

    panel.querySelector('#sell-req-save').addEventListener('click', async (ev) => {
      const btn = ev.currentTarget; btn.disabled = true; fb.classList.add('hidden');
      const { error: e } = await supabaseClient.from('sell_requests').update({
        status: panel.querySelector('#sell-req-stage').value,
        admin_notes: panel.querySelector('#sell-req-notes').value.trim() || null,
      }).eq('id', r.id);
      if (e) { btn.disabled = false; return fail('No se pudo guardar: ' + e.message); }
      closeModal(); await load();
    });

    panel.querySelector('#sell-req-delete').addEventListener('click', async (ev) => {
      if (!confirm('¿Eliminar esta solicitud y sus documentos? No se puede deshacer.')) return;
      const btn = ev.currentTarget; btn.disabled = true;
      if (docs.length) await supabaseClient.storage.from('sell-documents').remove(docs.map((d) => d.path));
      const { error: e } = await supabaseClient.from('sell_requests').delete().eq('id', r.id);
      if (e) { btn.disabled = false; return fail('No se pudo eliminar: ' + e.message); }
      closeModal(); await load();
    });
  }

  function closeModal() { modal.classList.add('hidden'); panel.innerHTML = ''; }

  document.addEventListener('click', (e) => {
    const card = e.target.closest('[data-sell-req]');
    if (card) { openReq(card.dataset.sellReq); return; }
    if (e.target.closest('[data-sell-close]') || e.target === modal) { closeModal(); return; }
    if (e.target.closest('.admin-tab[data-tab="sell"]')) load();
  });
  document.addEventListener('keydown', (e) => { if (e.key === 'Escape' && !modal.classList.contains('hidden')) closeModal(); });

  // El contador de nuevas se carga apenas hay sesión de administrador (para un agente la consulta no devuelve nada).
  supabaseClient.auth.onAuthStateChange((event, session) => { if (session && session.user) setTimeout(refreshCount, 0); });
})();
