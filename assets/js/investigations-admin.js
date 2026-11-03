/* Panel «Investigaciones» (solo administración, fase 5): ocultar una operación originada por una conexión de Bastet es una falta grave.
 * Aquí se abre la investigación, se suspende la cuenta (reversible), se abre el plazo de descargos (la persona los presenta por su propio enlace),
 * se agrega evidencia, se registra la revisión jurídica y se resuelve por escrito. La base de datos NO deja imponer una penalización ni autorizar la
 * eliminación de la cuenta sin descargos cumplidos y revisión jurídica registrada, y nunca elimina cuentas por sí sola.
 * Reglas en docs/ESPECIFICACION_MAESTRA.md (1.6 y 9.4); SQL en supabase/investigations.sql. Autónomo: usa `supabaseClient`. */
(function () {
  'use strict';

  const root = () => document.getElementById('investigations-root');
  const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const bs = (n) => 'Bs ' + Number(n).toLocaleString('es-BO', { maximumFractionDigits: 2 });
  const ftime = (d) => { const x = new Date(d); return isNaN(x) ? '' : x.toLocaleString('es-BO', { day: '2-digit', month: 'short', year: 'numeric', hour: '2-digit', minute: '2-digit' }); };
  const KIND = { ocultamiento_operacion: 'Ocultamiento de una operación', falta_anfitrion: 'Falta de un anfitrión', otra: 'Otra' };
  const STATUS = { abierta: ['Abierta', 'wait'], descargos: ['En plazo de descargos', 'wait'], revision_juridica: ['En revisión jurídica', 'wait'], resuelta: ['Resuelta', 'ok'], archivada: ['Archivada', 'bad'] };
  const DECISION = { sin_falta: 'Sin falta', amonestacion: 'Amonestación', penalizacion: 'Penalización económica', suspension: 'Suspensión de la cuenta', eliminacion_cuenta: 'Eliminación de la cuenta (autorizada)' };
  const PENALTY = { no_aplica: 'No aplica', propuesta: 'Propuesta', impuesta: 'Impuesta', pagada: 'Pagada', anulada: 'Anulada' };
  let data = { items: [] }, users = [], ops = [], filter = 'abiertas', busy = false;

  function toast(msg, bad) {
    let el = document.getElementById('ct-toast');
    if (!el) { el = document.createElement('div'); el.id = 'ct-toast'; el.setAttribute('role', 'status'); document.body.appendChild(el); }
    el.textContent = msg; el.className = 'ct-toast show' + (bad ? ' is-error' : '');
    clearTimeout(toast.t); toast.t = setTimeout(() => { el.className = 'ct-toast'; }, 5400);
  }

  async function fetchData() {
    const { data: d, error } = await supabaseClient.rpc('admin_investigations');
    if (error) return { error };
    data = d || { items: [] };
    const el = document.getElementById('investigations-count');
    if (el) { const n = data.items.filter((i) => ['abierta', 'descargos', 'revision_juridica'].includes(i.status)).length; el.textContent = n; el.classList.toggle('hidden', !n); }
    return {};
  }
  const open = (i) => ['abierta', 'descargos', 'revision_juridica'].includes(i.status);
  const linkOf = (t) => location.origin + '/descargos.html?t=' + t;

  function card(i) {
    const [label, tone] = STATUS[i.status] || [i.status, 'wait'];
    const descargos = (i.items || []).filter((x) => x.kind === 'descargo');
    let h = '<article class="bk-card" data-id="' + esc(i.id) + '"><header><div><b>' + esc(i.code) + ' · ' + esc(KIND[i.kind] || i.kind) + '</b><span class="bk-code">' + esc(i.subject_name || 'Sin persona') + (i.operation_number ? ' · operación ' + esc(i.operation_number) : '') + '</span></div>' +
      '<span class="bk-chip bk-' + tone + '">' + esc(label) + '</span></header><p class="bk-meta">' + esc(i.summary) + '</p>' +
      '<p class="bk-fine">Abierta el ' + ftime(i.created_at) + (i.suspended ? ' · <b>cuenta suspendida</b> desde el ' + ftime(i.suspended_at) + ' (' + esc(i.suspension_reason || '') + ')' : (i.subject_active === false ? ' · la cuenta está inactiva' : '')) + '</p>';
    if (i.descargos_token) h += '<p class="bk-fine">Descargos: plazo hasta el <b>' + ftime(i.descargos_until) + '</b> · ' + descargos.length + ' presentado(s) · enlace de la persona: <code>' + esc(linkOf(i.descargos_token)) + '</code> <button class="btn btn-ghost btn-sm" data-act="copy" data-link="' + esc(linkOf(i.descargos_token)) + '">Copiar</button></p>';
    else if (open(i)) h += '<p class="bk-fine">Todavía no se abrió el plazo de descargos: sin él no se puede decidir una sanción.</p>';
    if (i.penalty_bs != null) h += '<p class="bk-money">Penalización (' + String(i.penalty_percent).replace('.', ',') + ' % de ' + Number(i.basis_amount).toLocaleString('es-BO') + ' ' + esc(i.basis_currency) + '): <b>' + bs(i.penalty_bs) + '</b> · ' + esc(PENALTY[i.penalty_status]) + ' <small>(congelada en Bs)</small></p>';
    else if (open(i) && i.kind === 'ocultamiento_operacion') h += '<p class="bk-fine">Falta la base de la penalización (precio de la operación).</p>';
    h += '<p class="bk-fine">Revisión jurídica: ' + (i.legal_reviewed_at ? '<b>' + esc(i.legal_reviewer) + '</b> el ' + ftime(i.legal_reviewed_at) + ' — ' + esc(i.legal_concept) : '<b>no registrada</b> (obligatoria para penalizar o eliminar la cuenta)') + '</p>';
    const notes = (i.items || []).filter((x) => x.kind !== 'descargo');
    if (notes.length) h += '<ul class="bk-events">' + notes.map((x) => '<li><b>' + esc(x.kind) + '</b> <small>' + ftime(x.at) + '</small><br>' + esc(x.body) + '</li>').join('') + '</ul>';
    if (descargos.length) h += '<details><summary>Descargos de la persona (' + descargos.length + ')</summary><ul class="bk-events">' + descargos.map((x) => '<li><small>' + ftime(x.at) + '</small><br>' + esc(x.body) + '</li>').join('') + '</ul></details>';
    if (i.status === 'resuelta') h += '<p class="bk-money"><b>Decisión: ' + esc(DECISION[i.decision] || i.decision) + '</b> (' + ftime(i.decided_at) + ')<br><small>' + esc(i.decision_note) + '</small></p>';
    if (i.deletion_authorized) h += '<p class="form-error">La eliminación de la cuenta quedó AUTORIZADA en el registro, pero no se ejecutó: si corresponde, elimínala a mano en la pestaña Usuarios.</p>';
    const acts = [];
    if (open(i)) {
      acts.push('<button class="btn btn-ghost btn-sm" data-act="' + (i.suspended ? 'unsuspend' : 'suspend') + '">' + (i.suspended ? 'Reponer la cuenta' : 'Suspender la cuenta') + '</button>');
      acts.push('<button class="btn btn-ghost btn-sm" data-act="descargos">' + (i.descargos_token ? 'Ampliar plazo de descargos' : 'Abrir plazo de descargos') + '</button>');
      acts.push('<button class="btn btn-ghost btn-sm" data-act="note">Agregar evidencia o nota</button>');
      if (i.kind === 'ocultamiento_operacion') acts.push('<button class="btn btn-ghost btn-sm" data-act="basis">Fijar precio de la operación</button>');
      acts.push('<button class="btn btn-ghost btn-sm" data-act="legal">Registrar revisión jurídica</button>');
      acts.push('<button class="btn btn-primary btn-sm" data-act="resolve">Resolver</button><button class="btn btn-ghost btn-sm" data-act="archive">Archivar</button>');
    }
    if (i.penalty_status === 'impuesta') acts.push('<button class="btn btn-primary btn-sm" data-act="paid">Marcar penalización pagada</button>');
    acts.push('<button class="btn btn-ghost btn-sm" data-act="events">Cronología</button>');
    return h + '<div class="bk-actions">' + acts.join('') + '</div></article>';
  }

  function newForm() {
    return '<section class="bk-settings"><h2>Nueva investigación</h2><p class="bk-fine">Penalización aprobada: <b>' + String(data.penalty_percent || 2.25).replace('.', ',') + ' %</b> del precio de la operación (tres veces la comisión de venta). La cláusula penal, el procedimiento y la sanción deben revisarse con un abogado antes de aplicarse a una persona real.</p>' +
      '<form id="inv-form" class="cx-rule"><label>Tipo<select id="iv-kind">' + Object.keys(KIND).map((k) => '<option value="' + k + '">' + esc(KIND[k]) + '</option>').join('') + '</select></label>' +
      '<label>Operación relacionada<select id="iv-op"><option value="">Ninguna</option>' + ops.map((o) => '<option value="' + esc(o.id) + '">' + esc((o.number || o.code) + ' · ' + (o.title || '') + ' · ' + (o.titular_name || '')) + '</option>').join('') + '</select></label>' +
      '<label>Persona investigada <small>(si hay operación se toma de ella)</small><select id="iv-subject"><option value="">—</option>' + users.map((u) => '<option value="' + esc(u.id) + '">' + esc(u.full_name || u.display_name || u.email) + ' · ' + esc(u.email || '') + '</option>').join('') + '</select></label>' +
      '<label style="grid-column:1/-1">Hechos<textarea id="iv-summary" rows="3" maxlength="2000" required placeholder="Qué ocurrió, cuándo y cómo se detectó"></textarea></label>' +
      '<button class="btn btn-primary btn-sm" type="submit">Abrir investigación</button></form></section>';
  }

  function draw() {
    const el = root(); if (!el) return;
    const shown = data.items.filter((i) => filter === 'todas' || open(i));
    el.innerHTML = newForm() + '<div class="bk-filter"><button class="btn btn-sm ' + (filter === 'abiertas' ? 'btn-primary' : 'btn-ghost') + '" data-filter="abiertas">Abiertas</button><button class="btn btn-sm ' + (filter === 'todas' ? 'btn-primary' : 'btn-ghost') + '" data-filter="todas">Todas</button></div>' +
      (shown.length ? shown.map(card).join('') : '<p class="bk-empty">' + (data.items.length ? 'No hay investigaciones abiertas.' : 'Todavía no hay investigaciones.') + '</p>');
  }

  async function load() {
    const el = root(); if (!el) return;
    el.innerHTML = '<p class="bk-empty">Cargando…</p>';
    const { error } = await fetchData();
    if (error) { el.innerHTML = '<p class="form-error">' + (/function|schema cache/i.test(error.message || '') ? 'Las investigaciones todavía no están activadas en la base de datos (falta correr supabase/investigations.sql).' : esc(error.message)) + '</p>'; return; }
    const [u, o] = await Promise.all([supabaseClient.from('profiles').select('id,email,display_name,full_name').order('email'), supabaseClient.rpc('my_operations')]);
    users = (u && u.data) || []; ops = ((o && o.data && o.data.items) || []).filter((x) => x.status === 'confirmada');
    draw();
  }

  async function run(fn, okMsg) {
    if (busy) return false; busy = true;
    try {
      const { error } = await fn();
      if (error) { toast(error.message || 'No se pudo completar', true); return false; }
      if (okMsg) toast(okMsg);
      await fetchData(); draw();
      return true;
    } finally { busy = false; }
  }
  function modal(html) {
    const prev = document.getElementById('iv-overlay'); if (prev) prev.remove();
    const o = document.createElement('div'); o.className = 'modal-overlay'; o.id = 'iv-overlay';
    o.innerHTML = '<div class="modal-panel op-panel" role="dialog" aria-modal="true">' + html + '</div>';
    document.body.appendChild(o);
    o.addEventListener('click', (e) => { if (e.target === o || e.target.closest('[data-close]')) o.remove(); });
    return o;
  }

  document.addEventListener('click', async (e) => {
    const f = e.target.closest('#investigations-root [data-filter]'); if (f) { filter = f.dataset.filter; draw(); return; }
    const btn = e.target.closest('#investigations-root [data-act]'); if (!btn) return;
    if (btn.dataset.act === 'copy') { try { await navigator.clipboard.writeText(btn.dataset.link); toast('Enlace copiado'); } catch (err) { toast('No se pudo copiar', true); } return; }
    const i = data.items.find((x) => x.id === btn.closest('.bk-card').dataset.id); if (!i) return;
    const ask = (m, d) => window.prompt(m, d || '');
    switch (btn.dataset.act) {
      case 'suspend': { const r = ask('Motivo de la suspensión (queda en el historial):'); if (r) run(() => supabaseClient.rpc('admin_set_suspension', { p_inv: i.id, p_suspend: true, p_reason: r }), 'Cuenta suspendida'); return; }
      case 'unsuspend': { const r = ask('Motivo para reponer la cuenta:'); if (r) run(() => supabaseClient.rpc('admin_set_suspension', { p_inv: i.id, p_suspend: false, p_reason: r }), 'Cuenta repuesta'); return; }
      case 'descargos': { const d = ask('Días de plazo para presentar descargos (1 a 30):', String(data.descargos_days || 5)); if (d) run(() => supabaseClient.rpc('admin_open_descargos', { p_inv: i.id, p_days: Number(d) }), 'Plazo abierto: copia el enlace y envíaselo a la persona'); return; }
      case 'note': { const t = ask('Evidencia o nota (describe el documento o captura y dónde está guardado):'); if (t) run(() => supabaseClient.rpc('admin_add_investigation_item', { p_inv: i.id, p_kind: 'evidencia', p_body: t, p_path: null }), 'Agregado al expediente'); return; }
      case 'basis': { const a = ask('Precio total de la operación (solo el número):'); if (!a) return; const c = (ask('Moneda: USD o BOB', 'USD') || '').toUpperCase(); run(() => supabaseClient.rpc('admin_set_investigation_basis', { p_inv: i.id, p_amount: Number(a), p_currency: c }), 'Base de la penalización fijada'); return; }
      case 'legal': { const r = ask('¿Quién hizo la revisión jurídica? (nombre del abogado)'); if (!r) return; const c = ask('Resume su concepto jurídico (mínimo 20 caracteres):'); if (c) run(() => supabaseClient.rpc('admin_record_legal_review', { p_inv: i.id, p_reviewer: r, p_concept: c }), 'Revisión jurídica registrada'); return; }
      case 'paid': { const n = ask('Nota del pago recibido:', ''); if (n !== null) run(() => supabaseClient.rpc('admin_mark_penalty_paid', { p_inv: i.id, p_note: n }), 'Penalización marcada como pagada'); return; }
      case 'archive': { const n = ask('¿Por qué se archiva?'); if (n) run(() => supabaseClient.rpc('admin_archive_investigation', { p_inv: i.id, p_note: n }), 'Investigación archivada'); return; }
      case 'resolve': {
        const o = modal('<h2>Resolver ' + esc(i.code) + '</h2><p class="bk-fine">La base de datos exige descargos cumplidos y revisión jurídica registrada para penalizar, suspender de forma definitiva o autorizar la eliminación de la cuenta.</p>' +
          '<label>Decisión<select id="rs-dec">' + Object.keys(DECISION).map((k) => '<option value="' + k + '">' + esc(DECISION[k]) + '</option>').join('') + '</select></label>' +
          '<label>Fundamento de la decisión (mínimo 20 caracteres, queda en el historial)<textarea id="rs-note" rows="4" maxlength="4000"></textarea></label><p class="form-error hidden" id="rs-err"></p>' +
          '<div class="modal-form-actions"><button type="button" class="btn btn-ghost" data-close>Cancelar</button><button class="btn btn-primary" id="rs-go" type="button">Resolver</button></div>');
        o.querySelector('#rs-go').addEventListener('click', async () => {
          const dec = o.querySelector('#rs-dec').value;
          if (dec !== 'sin_falta' && !window.confirm('Vas a registrar «' + DECISION[dec] + '». ¿Confirmas?')) return;
          const { error } = await supabaseClient.rpc('admin_resolve_investigation', { p_inv: i.id, p_decision: dec, p_note: o.querySelector('#rs-note').value });
          if (error) { const er = o.querySelector('#rs-err'); er.textContent = error.message || 'No se pudo resolver'; er.classList.remove('hidden'); return; }
          o.remove(); toast('Investigación resuelta'); await fetchData(); draw();
        });
        return;
      }
      case 'events': {
        const { data: ev, error } = await supabaseClient.rpc('investigation_events', { p_inv: i.id });
        if (error) { toast(error.message, true); return; }
        modal('<h2>Cronología · ' + esc(i.code) + '</h2><ul class="bk-events">' + (ev || []).map((z) => '<li><b>' + esc(String(z.event).replace(/_/g, ' ')) + '</b> <small>' + esc(z.actor) + ' · ' + ftime(z.at) + '</small>' + (z.data ? '<br><small>' + esc(JSON.stringify(z.data)) + '</small>' : '') + '</li>').join('') + '</ul><div class="modal-form-actions"><button type="button" class="btn btn-ghost" data-close>Cerrar</button></div>');
        return;
      }
      default: return;
    }
  });
  document.addEventListener('submit', async (e) => {
    if (e.target.id !== 'inv-form') return;
    e.preventDefault();
    const v = (id) => document.getElementById(id).value;
    await run(() => supabaseClient.rpc('admin_open_investigation', { p_kind: v('iv-kind'), p_subject: v('iv-subject') || null, p_operation: v('iv-op') || null, p_connection: null, p_booking: null, p_property: null, p_summary: v('iv-summary') }), 'Investigación abierta');
  });

  const tab = document.querySelector('.admin-tab[data-tab="investigations"]');
  if (tab) tab.addEventListener('click', load);
})();
