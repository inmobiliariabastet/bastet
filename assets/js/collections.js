/* Pestaña "Comisiones" (cobranzas). Autónomo (como credits.js y leads.js): usa el cliente global `supabaseClient`;
   admin.js ya muestra/oculta el panel por data-tab.
   El sistema no calcula honorarios por política: el admin carga cada cobranza (venta, % y comisión; la comisión puede
   calcularse como venta × % y el admin la corrige). El agente solo lee las suyas (RLS en Supabase). */
(function () {
  'use strict';

  const STATUS = {
    pending: { label: 'Por cobrar', badge: 'b-gold' },
    in_process: { label: 'En trámite', badge: 'b-warn' },
    paid: { label: 'Cobrada', badge: 'b-ok' },
  };
  const OPERATIONS = { venta: 'Venta', alquiler: 'Alquiler', anticretico: 'Anticrético' };
  const TRASH = '<svg viewBox="0 0 24 24" width="17" height="17" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M3 6h18"/><path d="M8 6V4h8v2"/><path d="M19 6l-1 14H6L5 6"/><path d="M10 11v6M14 11v6"/></svg>';

  const modal = document.getElementById('collection-modal');
  const modalPanel = document.getElementById('collection-modal-panel');
  const state = { rows: [], isAdmin: false, agents: {}, properties: [], filter: 'all', busy: false };

  const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const usd = (n) => Number(n || 0).toLocaleString('es-BO', { minimumFractionDigits: 0, maximumFractionDigits: 2 }) + ' USD';
  const fdate = (d) => (d ? new Date(d.length === 10 ? d + 'T12:00:00' : d).toLocaleDateString('es-BO', { day: '2-digit', month: 'short', year: 'numeric' }) : '—');
  const ref = (id) => 'C-' + String(id).padStart(4, '0');
  const round2 = (n) => Math.round(n * 100) / 100;
  const propLabel = (p) => (p ? (p.code_number ? 'BST-' + p.code_number + ' · ' : '') + (p.title || '') : '');

  async function load() {
    const host = document.getElementById('collections-table');
    if (!host || state.busy) return;
    state.busy = true;
    try {
      const { data: auth } = await supabaseClient.auth.getUser();
      const uid = auth && auth.user && auth.user.id;
      if (!uid) { host.innerHTML = '<p class="property-empty">Inicia sesión para ver tus comisiones.</p>'; return; }
      const me = await supabaseClient.from('profiles').select('role').eq('id', uid).single();
      state.isAdmin = !!(me.data && me.data.role === 'admin');
      document.getElementById('new-collection-btn').classList.toggle('hidden', !state.isAdmin);
      document.getElementById('collections-hint').textContent = state.isAdmin
        ? 'Cobranzas de todos los agentes. Tú cargas cada una: venta, porcentaje y comisión.'
        : 'Tus comisiones por operaciones cerradas. Las carga el administrador.';

      const { data, error } = await supabaseClient
        .from('collections')
        .select('*, properties(title,code_number)')
        .order('created_at', { ascending: false })
        .limit(1000);
      if (error) throw error;
      state.rows = data || [];

      if (state.isAdmin) {
        const [ag, pr] = await Promise.all([
          supabaseClient.from('profiles').select('id,display_name,email').order('email'),
          supabaseClient.from('properties').select('id,title,code_number,owner_id,operation').order('code_number'),
        ]);
        state.agents = {};
        (ag.data || []).forEach((a) => { state.agents[a.id] = a; });
        state.properties = pr.data || [];
      }
      render();
    } catch (e) {
      host.innerHTML = '<p class="form-error">No se pudieron cargar las comisiones. ' + esc((e && e.message) || '') + '</p>';
    } finally {
      state.busy = false;
    }
  }

  const agentName = (id) => {
    if (!id) return 'Sin agente';
    const a = state.agents[id];
    return a ? (a.display_name || a.email) : 'Agente';
  };

  function render() {
    const total = state.rows.reduce((s, r) => s + Number(r.commission_usd), 0);
    const paid = state.rows.filter((r) => r.status === 'paid').reduce((s, r) => s + Number(r.commission_usd), 0);
    document.getElementById('collections-stats').innerHTML =
      '<div class="analytics-stat-card"><p class="analytics-stat-value">' + usd(total) + '</p><p class="analytics-stat-label">Total generado</p></div>' +
      '<div class="analytics-stat-card"><p class="analytics-stat-value stat-ok">' + usd(paid) + '</p><p class="analytics-stat-label">Cobrado</p></div>' +
      '<div class="analytics-stat-card"><p class="analytics-stat-value">' + usd(total - paid) + '</p><p class="analytics-stat-label">Pendiente</p></div>';

    document.querySelectorAll('#collections-filters .request-filter').forEach((b) => b.classList.toggle('is-active', b.dataset.filter === state.filter));

    const rows = state.rows.filter((r) => state.filter === 'all' || r.status === state.filter);
    const host = document.getElementById('collections-table');
    if (!rows.length) {
      host.innerHTML = '<p class="property-empty">' + (state.rows.length ? 'No hay comisiones con este estado.' : 'Todavía no hay comisiones registradas.') + '</p>';
      return;
    }
    host.innerHTML = '<div class="data-table-wrap"><table class="data-table"><thead><tr>' +
      '<th>Ref.</th><th>Propiedad</th>' + (state.isAdmin ? '<th>Agente</th>' : '') +
      '<th class="r">Venta</th><th class="r">%</th><th class="r">Comisión</th><th>Fecha</th><th>Estado</th>' + (state.isAdmin ? '<th></th>' : '') +
      '</tr></thead><tbody>' + rows.map((r) => {
        const st = STATUS[r.status] || { label: r.status, badge: 'b-mute' };
        const label = propLabel(r.properties);
        return '<tr>' +
          '<td class="nw">' + ref(r.id) + '</td>' +
          '<td class="col-prop">' + (label ? esc(label) : '<span class="muted">Sin propiedad</span>') + '<br><span class="muted">' + esc(r.client_name) + ' · ' + esc(OPERATIONS[r.operation] || r.operation) + '</span></td>' +
          (state.isAdmin ? '<td>' + esc(agentName(r.agent_id)) + '</td>' : '') +
          '<td class="r">' + usd(r.sale_price_usd) + '</td>' +
          '<td class="r">' + (r.commission_pct == null ? '—' : Number(r.commission_pct) + '%') + '</td>' +
          '<td class="r"><span class="amt">' + usd(r.commission_usd) + '</span></td>' +
          '<td class="nw">' + (r.status === 'paid' ? fdate(r.paid_at) : fdate(r.due_date)) + '</td>' +
          '<td><span class="badge ' + st.badge + '">' + st.label + '</span></td>' +
          (state.isAdmin
            ? '<td class="data-actions">' +
                (r.status !== 'paid' ? '<button type="button" class="btn btn-ghost btn-sm" data-col-paid="' + r.id + '">Cobrada</button>' : '') +
                '<button type="button" class="btn btn-ghost btn-sm" data-col-edit="' + r.id + '">Editar</button>' +
                '<button type="button" class="btn btn-sm btn-icon btn-trash-gold" data-col-del="' + r.id + '" title="Eliminar" aria-label="Eliminar">' + TRASH + '</button>' +
              '</td>'
            : '') +
          '</tr>';
      }).join('') + '</tbody></table></div>';
  }

  /* ── Formulario (solo admin) ── */
  function openForm(row) {
    const r = row || {};
    const agentOptions = '<option value="">Sin agente</option>' + Object.values(state.agents)
      .map((a) => '<option value="' + esc(a.id) + '"' + (a.id === r.agent_id ? ' selected' : '') + '>' + esc(a.display_name || a.email) + ' (' + esc(a.email) + ')</option>').join('');
    const propOptions = '<option value="">Sin propiedad</option>' + state.properties
      .map((p) => '<option value="' + esc(p.id) + '"' + (p.id === r.property_id ? ' selected' : '') + '>' + esc(propLabel(p)) + '</option>').join('');
    modalPanel.innerHTML =
      '<h2>' + (row ? 'Editar ' + ref(r.id) : 'Nueva cobranza') + '</h2>' +
      '<p id="col-error" class="form-error hidden"></p>' +
      '<form id="col-form">' +
        '<div class="field"><label for="col-property">Propiedad</label><select id="col-property">' + propOptions + '</select></div>' +
        '<div class="field"><label for="col-agent">Agente</label><select id="col-agent">' + agentOptions + '</select></div>' +
        '<div class="field-row">' +
          '<div class="field"><label for="col-client">Cliente</label><input type="text" id="col-client" required maxlength="160" value="' + esc(r.client_name || '') + '"></div>' +
          '<div class="field"><label for="col-op">Operación</label><select id="col-op">' +
            Object.keys(OPERATIONS).map((k) => '<option value="' + k + '"' + ((r.operation || 'venta') === k ? ' selected' : '') + '>' + OPERATIONS[k] + '</option>').join('') + '</select></div>' +
        '</div>' +
        '<div class="field-row-3">' +
          '<div class="field"><label for="col-price">Venta (USD)</label><input type="number" id="col-price" required min="0" step="0.01" value="' + (r.sale_price_usd ?? '') + '"></div>' +
          '<div class="field"><label for="col-pct">% comisión</label><input type="number" id="col-pct" min="0" max="100" step="0.01" value="' + (r.commission_pct ?? '') + '"></div>' +
          '<div class="field"><label for="col-comm">Comisión (USD)</label><input type="number" id="col-comm" required min="0" step="0.01" value="' + (r.commission_usd ?? '') + '"></div>' +
        '</div>' +
        '<p class="field-hint" style="margin:-8px 0 16px;">La comisión se calcula como venta × % mientras no la escribas a mano; puedes corregirla. <button type="button" class="btn btn-ghost btn-sm" id="col-calc">Calcular ahora</button></p>' +
        '<div class="field-row">' +
          '<div class="field"><label for="col-status">Estado</label><select id="col-status">' +
            Object.keys(STATUS).map((k) => '<option value="' + k + '"' + ((r.status || 'pending') === k ? ' selected' : '') + '>' + STATUS[k].label + '</option>').join('') + '</select></div>' +
          '<div class="field"><label for="col-due">Fecha prevista de cobro</label><input type="date" id="col-due" value="' + esc(r.due_date || '') + '"></div>' +
        '</div>' +
        '<div class="field"><label for="col-notes">Notas</label><textarea id="col-notes" rows="3" maxlength="2000">' + esc(r.notes || '') + '</textarea></div>' +
        '<div class="modal-form-actions"><button type="button" class="btn btn-ghost" data-col-close>Cancelar</button><button type="submit" class="btn btn-accent" id="col-save">Guardar</button></div>' +
      '</form>';
    modal.classList.remove('hidden');

    const $ = (id) => modalPanel.querySelector('#' + id);
    let manual = !!row; // al editar, no se pisa la comisión existente hasta que se pida
    const calc = () => {
      const price = parseFloat($('col-price').value);
      const pct = parseFloat($('col-pct').value);
      if (!isNaN(price) && !isNaN(pct)) $('col-comm').value = round2(price * pct / 100);
    };
    $('col-comm').addEventListener('input', () => { manual = true; });
    ['col-price', 'col-pct'].forEach((id) => $(id).addEventListener('input', () => { if (!manual) calc(); }));
    $('col-calc').addEventListener('click', () => { manual = false; calc(); });
    $('col-property').addEventListener('change', () => {
      const p = state.properties.find((x) => x.id === $('col-property').value);
      if (!p) return;
      if (p.owner_id && !$('col-agent').value) $('col-agent').value = p.owner_id;
      if (p.operation && OPERATIONS[p.operation]) $('col-op').value = p.operation;
    });

    $('col-form').addEventListener('submit', async (e) => {
      e.preventDefault();
      const err = $('col-error');
      err.classList.add('hidden');
      const pct = $('col-pct').value;
      const payload = {
        property_id: $('col-property').value || null,
        agent_id: $('col-agent').value || null,
        client_name: $('col-client').value.trim(),
        operation: $('col-op').value,
        sale_price_usd: parseFloat($('col-price').value),
        commission_pct: pct === '' ? null : parseFloat(pct),
        commission_usd: parseFloat($('col-comm').value),
        status: $('col-status').value,
        due_date: $('col-due').value || null,
        notes: $('col-notes').value.trim() || null,
      };
      const btn = $('col-save');
      btn.disabled = true;
      const q = row
        ? supabaseClient.from('collections').update(payload).eq('id', row.id)
        : supabaseClient.from('collections').insert(payload);
      const { error } = await q;
      if (error) {
        btn.disabled = false;
        err.textContent = 'No se pudo guardar: ' + error.message;
        err.classList.remove('hidden');
        return;
      }
      closeModal();
      await load();
    });
  }

  function closeModal() { modal.classList.add('hidden'); modalPanel.innerHTML = ''; }
  const findRow = (id) => state.rows.find((r) => r.id === Number(id));

  document.addEventListener('click', async (e) => {
    const t = e.target;
    if (t.closest('.admin-tab[data-tab="collections"]')) { load(); return; }
    if (t.closest('#new-collection-btn')) { openForm(null); return; }
    if (t.closest('[data-col-close]') || t === modal) { closeModal(); return; }
    const filt = t.closest('#collections-filters .request-filter');
    if (filt) { state.filter = filt.dataset.filter; render(); return; }
    const edit = t.closest('[data-col-edit]');
    if (edit) { const r = findRow(edit.dataset.colEdit); if (r) openForm(r); return; }
    const paid = t.closest('[data-col-paid]');
    if (paid) {
      paid.disabled = true;
      const { error } = await supabaseClient.from('collections').update({ status: 'paid' }).eq('id', Number(paid.dataset.colPaid));
      if (error) { paid.disabled = false; alert('No se pudo marcar como cobrada: ' + error.message); return; }
      await load();
      return;
    }
    const del = t.closest('[data-col-del]');
    if (del) {
      const r = findRow(del.dataset.colDel);
      if (!r || !confirm('¿Eliminar la cobranza ' + ref(r.id) + ' de ' + r.client_name + '? Esta acción no se puede deshacer.')) return;
      const { error } = await supabaseClient.from('collections').delete().eq('id', r.id);
      if (error) { alert('Error al eliminar: ' + error.message); return; }
      await load();
    }
  });
  document.addEventListener('keydown', (e) => { if (e.key === 'Escape' && !modal.classList.contains('hidden')) closeModal(); });
})();
