/* Panel: calendario de NO disponibilidad de una estadía temporal. El anfitrión elige en un calendario entre qué fechas el alojamiento
 * no estará disponible (o «desde hoy hasta que yo lo reactive»). Mientras dura, la propiedad se oculta de Estadías y vuelve sola al
 * terminar el periodo. Funciones SQL en supabase/stay-availability.sql (sin el SQL, el botón avisa que falta activarlo).
 * Autónomo: usa el cliente global `supabaseClient`. Expone window.StayAvailability. */
(function () {
  'use strict';
  const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const MONTHS = ['enero', 'febrero', 'marzo', 'abril', 'mayo', 'junio', 'julio', 'agosto', 'septiembre', 'octubre', 'noviembre', 'diciembre'];
  const pad = (n) => String(n).padStart(2, '0');
  const iso = (y, m, d) => y + '-' + pad(m + 1) + '-' + pad(d);
  const todayIso = () => new Date(Date.now() - 4 * 3600 * 1000).toISOString().slice(0, 10); // hora de Bolivia (UTC-4)
  const fmt = (s) => { const [y, m, d] = s.split('-').map(Number); return d + ' ' + MONTHS[m - 1].slice(0, 3) + ' ' + y; };
  const range = (b) => b.to_date ? (b.to_date === b.from_date ? fmt(b.from_date) : fmt(b.from_date) + ' al ' + fmt(b.to_date)) : 'desde ' + fmt(b.from_date) + ' (hasta que lo reactives)';

  let byProp = {};
  async function refresh() {
    const { data, error } = await supabaseClient.rpc('my_stay_blocks');
    if (error) return false;
    byProp = {};
    (data || []).forEach((b) => { (byProp[b.property_id] = byProp[b.property_id] || []).push(b); });
    return true;
  }
  // ¿Está bloqueada hoy? → texto para la tarjeta
  function statusOf(propertyId) {
    const t = todayIso(), list = byProp[propertyId] || [];
    const now = list.find((b) => b.from_date <= t && (!b.to_date || b.to_date >= t));
    if (now) return { now: true, text: now.to_date ? 'No disponible hasta el ' + fmt(now.to_date) : 'No disponible (pausada)' };
    const next = list.find((b) => b.from_date > t);
    return next ? { now: false, text: 'Próximo bloqueo: ' + fmt(next.from_date) } : null;
  }

  function toast(msg, bad) {
    let el = document.getElementById('ct-toast');
    if (!el) { el = document.createElement('div'); el.id = 'ct-toast'; el.setAttribute('role', 'status'); document.body.appendChild(el); }
    el.textContent = msg; el.className = 'ct-toast show' + (bad ? ' is-error' : '');
    clearTimeout(toast.t); toast.t = setTimeout(() => { el.className = 'ct-toast'; }, 4200);
  }

  async function open(property, onChange) {
    const prev = document.getElementById('sav-overlay'); if (prev) prev.remove();
    const o = document.createElement('div');
    o.className = 'modal-overlay'; o.id = 'sav-overlay';
    o.innerHTML = '<div class="modal-panel sav-panel" role="dialog" aria-modal="true"><div id="sav-body"><p>Cargando…</p></div></div>';
    document.body.appendChild(o);
    o.addEventListener('click', (e) => { if (e.target === o || e.target.closest('[data-sav-close]')) o.remove(); });
    const body = o.querySelector('#sav-body');
    const ok = await refresh();
    if (!ok) { body.innerHTML = '<h2>Disponibilidad</h2><p class="form-error">El calendario todavía no está activado en la base de datos (falta correr supabase/stay-availability.sql).</p><div class="modal-form-actions"><button type="button" class="btn btn-ghost" data-sav-close>Cerrar</button></div>'; return; }

    const t0 = todayIso().split('-').map(Number);
    let vy = t0[0], vm = t0[1] - 1, start = null, end = null, open_ended = false;

    const blockedSet = () => { const s = new Set(); (byProp[property.id] || []).forEach((b) => { const last = b.to_date || iso(vy + 2, 0, 1); for (let d = new Date(b.from_date + 'T00:00:00Z'); d.toISOString().slice(0, 10) <= last && s.size < 900; d.setUTCDate(d.getUTCDate() + 1)) s.add(d.toISOString().slice(0, 10)); }); return s; };

    function calendar() {
      const first = new Date(Date.UTC(vy, vm, 1)), days = new Date(Date.UTC(vy, vm + 1, 0)).getUTCDate();
      const lead = (first.getUTCDay() + 6) % 7, today = todayIso(), blocked = blockedSet();
      let cells = '';
      for (let i = 0; i < lead; i++) cells += '<span></span>';
      for (let d = 1; d <= days; d++) {
        const s = iso(vy, vm, d), past = s < today;
        const inSel = start && (s === start || (end && s >= start && s <= end) || (open_ended && s >= start));
        cells += '<button type="button" class="sav-day' + (past ? ' is-past' : '') + (blocked.has(s) ? ' is-blocked' : '') + (inSel ? ' is-sel' : '') + (s === today ? ' is-today' : '') + '" data-day="' + s + '"' + (past ? ' disabled' : '') + '>' + d + '</button>';
      }
      return '<div class="sav-cal"><div class="sav-nav"><button type="button" data-nav="-1" aria-label="Mes anterior">‹</button><b>' + MONTHS[vm] + ' ' + vy + '</b><button type="button" data-nav="1" aria-label="Mes siguiente">›</button></div>' +
        '<div class="sav-week"><span>L</span><span>M</span><span>M</span><span>J</span><span>V</span><span>S</span><span>D</span></div><div class="sav-grid">' + cells + '</div>' +
        '<p class="sav-legend"><i class="is-blocked"></i> ya bloqueado <i class="is-sel"></i> tu selección</p></div>';
    }

    function render() {
      const list = byProp[property.id] || [];
      const picked = start ? (open_ended ? 'Desde ' + fmt(start) + ' hasta que lo reactives' : (end ? 'Del ' + fmt(start) + ' al ' + fmt(end) : 'Desde ' + fmt(start) + ': elige el último día no disponible')) : 'Toca el primer día y luego el último día en que NO estará disponible.';
      body.innerHTML =
        '<h2>Disponibilidad</h2><p class="sav-sub"><b>' + esc(property.title) + '</b></p>' +
        '<p class="sav-hint">Mientras dure el periodo marcado, tu alojamiento se oculta de Estadías Temporales y vuelve a mostrarse solo cuando termine.</p>' +
        calendar() +
        '<p class="sav-picked" id="sav-picked">' + esc(picked) + '</p>' +
        '<label class="sav-check"><input type="checkbox" id="sav-open"' + (open_ended ? ' checked' : '') + '> Sin fecha de regreso (volverá cuando yo lo reactive)</label>' +
        '<input id="sav-note" type="text" maxlength="120" placeholder="Nota privada (opcional): ocupado, mantenimiento…">' +
        '<p id="sav-err" class="form-error hidden"></p>' +
        '<div class="sav-actions"><button type="button" class="btn btn-ghost btn-sm" id="sav-now">Pausar desde hoy</button><button type="button" class="btn btn-primary btn-sm" id="sav-save"' + (start && (end || open_ended) ? '' : ' disabled') + '>Marcar no disponible</button></div>' +
        '<section class="sav-list"><h3>Periodos no disponibles</h3>' + (list.length ? '<ul>' + list.map((b) => '<li><div><b>' + esc(range(b)) + '</b>' + (b.note ? '<small>' + esc(b.note) + '</small>' : '') + '</div><button type="button" class="btn btn-ghost btn-sm" data-del="' + esc(b.id) + '">Reactivar</button></li>').join('') + '</ul>' : '<p class="sav-hint">Ninguno: tu alojamiento está disponible todo el tiempo.</p>') + '</section>' +
        '<div class="modal-form-actions"><button type="button" class="btn btn-ghost" data-sav-close>Cerrar</button></div>';
    }

    async function save(from, to) {
      const err = body.querySelector('#sav-err'); err.classList.add('hidden');
      const { error } = await supabaseClient.rpc('set_stay_block', { p_property: String(property.id), p_from: from, p_to: to, p_note: (body.querySelector('#sav-note').value || '').trim() || null });
      if (error) { err.textContent = error.message; err.classList.remove('hidden'); return; }
      start = end = null; open_ended = false;
      await refresh(); render(); toast('Listo: el alojamiento no aparecerá en esas fechas.');
      if (onChange) onChange();
    }

    body.addEventListener('click', async (e) => {
      const nav = e.target.closest('[data-nav]');
      if (nav) { vm += Number(nav.dataset.nav); if (vm < 0) { vm = 11; vy--; } if (vm > 11) { vm = 0; vy++; } render(); return; }
      const day = e.target.closest('[data-day]');
      if (day) {
        const s = day.dataset.day;
        if (!start || end || open_ended) { start = s; end = null; if (open_ended) open_ended = true; }
        else if (s < start) start = s; else end = s;
        const note = body.querySelector('#sav-note') ? body.querySelector('#sav-note').value : '';
        render(); body.querySelector('#sav-note').value = note; return;
      }
      if (e.target.closest('#sav-save') && start && (end || open_ended)) { await save(start, open_ended ? null : end); return; }
      if (e.target.closest('#sav-now')) { await save(todayIso(), null); return; }
      const del = e.target.closest('[data-del]');
      if (del) {
        const { error } = await supabaseClient.rpc('delete_stay_block', { p_block: del.dataset.del });
        if (error) { toast(error.message, true); return; }
        await refresh(); render(); toast('Fechas reactivadas.'); if (onChange) onChange();
      }
    });
    body.addEventListener('change', (e) => {
      if (e.target.id === 'sav-open') { open_ended = e.target.checked; if (open_ended) end = null; const note = body.querySelector('#sav-note').value; render(); body.querySelector('#sav-note').value = note; }
    });
    render();
  }

  window.StayAvailability = { open, refresh, statusOf };
})();
