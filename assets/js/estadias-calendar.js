/* Estadías: calendario público de disponibilidad de la ficha (Flujo B del rediseño móvil).
 * Muestra los días ocupados (los que el anfitrión bloqueó en su panel) y permite elegir llegada y salida tocando dos días; las noches
 * ocupadas no se pueden incluir en la estadía. La elección se comparte con el panel de reserva de estadias.js (mismo estado de fechas).
 * Autónomo: estadias.js lo monta con window.StayCalendar.mount(contenedor, { blocks, getRange, onChange }). */
(function () {
  'use strict';
  const MONTHS = ['enero', 'febrero', 'marzo', 'abril', 'mayo', 'junio', 'julio', 'agosto', 'septiembre', 'octubre', 'noviembre', 'diciembre'];
  const pad = (n) => String(n).padStart(2, '0');
  const iso = (y, m, d) => y + '-' + pad(m + 1) + '-' + pad(d);
  const addDays = (s, k) => { const d = new Date(s + 'T00:00:00Z'); d.setUTCDate(d.getUTCDate() + k); return d.toISOString().slice(0, 10); };
  const todayIso = () => { const d = new Date(); d.setMinutes(d.getMinutes() - d.getTimezoneOffset()); return d.toISOString().slice(0, 10); };
  const fdate = (s) => { const [, m, d] = s.split('-').map(Number); return d + ' ' + MONTHS[m - 1].slice(0, 3); };

  function mount(box, opts) {
    const blocks = opts.blocks || [];
    const today = todayIso();
    const t0 = today.split('-').map(Number);
    let vy = t0[0], vm = t0[1] - 1, notice = '';

    // Días ocupados (un bloqueo sin fecha de regreso se marca por 2 años)
    const busy = new Set();
    blocks.forEach((b) => {
      const last = b.to_date || addDays(today, 730);
      for (let d = b.from_date, i = 0; d <= last && i < 900; d = addDays(d, 1), i++) busy.add(d);
    });
    // ¿Alguna NOCHE entre llegada y salida (salida no incluida) está ocupada?
    const hasBusy = (from, to) => { for (let d = from; d < to; d = addDays(d, 1)) if (busy.has(d)) return true; return false; };

    const r0 = opts.getRange();
    if (r0.from) { const p = r0.from.split('-').map(Number); vy = p[0]; vm = p[1] - 1; }

    function render() {
      const { from, to } = opts.getRange();
      const first = new Date(Date.UTC(vy, vm, 1)), days = new Date(Date.UTC(vy, vm + 1, 0)).getUTCDate();
      const lead = (first.getUTCDay() + 6) % 7;
      let cells = '';
      for (let i = 0; i < lead; i++) cells += '<span></span>';
      for (let d = 1; d <= days; d++) {
        const s = iso(vy, vm, d), past = s < today, isBusy = busy.has(s);
        const sel = from && (s === from || s === to || (to && s > from && s < to));
        // un día ocupado solo sirve como día de salida (la última noche sería la anterior)
        const canCheckout = isBusy && from && !to && s > from && !hasBusy(from, s);
        cells += '<button type="button" class="sc-day' + (past ? ' is-past' : '') + (isBusy ? ' is-busy' : '') + (sel ? ' is-sel' : '') + (s === from ? ' is-start' : '') + (s === to ? ' is-end' : '') + (s === today ? ' is-today' : '') + '" data-day="' + s + '"' +
          (past || (isBusy && !canCheckout) ? ' disabled' : '') + ' aria-label="' + d + ' de ' + MONTHS[vm] + (isBusy ? ', ocupado' : ', disponible') + '">' + d + '</button>';
      }
      const n = from && to ? Math.round((new Date(to) - new Date(from)) / 864e5) : 0;
      const prevDisabled = vy === t0[0] && vm === t0[1] - 1;
      box.innerHTML = '<div class="sc"><div class="sc-nav"><button type="button" data-nav="-1" aria-label="Mes anterior"' + (prevDisabled ? ' disabled' : '') + '>‹</button><b>' + MONTHS[vm] + ' ' + vy + '</b><button type="button" data-nav="1" aria-label="Mes siguiente">›</button></div>' +
        '<div class="sc-week"><span>L</span><span>M</span><span>M</span><span>J</span><span>V</span><span>S</span><span>D</span></div><div class="sc-grid">' + cells + '</div>' +
        '<p class="sc-legend"><i class="is-free"></i> Disponible <i class="is-busy"></i> Ocupado <i class="is-sel"></i> Tu estadía</p>' +
        '<div class="sc-fields"><div><span>Entrada</span><b>' + (from ? fdate(from) : 'Elige un día') + '</b></div><div><span>Salida</span><b>' + (to ? fdate(to) : (from ? 'Elige un día' : '—')) + '</b></div></div>' +
        '<p class="sc-note' + (notice ? ' is-warn' : '') + '" role="status">' + (notice || (n ? n + ' ' + (n === 1 ? 'noche seleccionada.' : 'noches seleccionadas.') : 'Toca el día de llegada y luego el de salida.')) + '</p>' +
        (from ? '<button type="button" class="sc-clear" data-clear>Limpiar fechas</button>' : '') + '</div>';
    }

    box.onclick = (e) => {
      const nav = e.target.closest('[data-nav]');
      if (nav) { vm += Number(nav.dataset.nav); if (vm < 0) { vm = 11; vy--; } if (vm > 11) { vm = 0; vy++; } notice = ''; render(); return; }
      if (e.target.closest('[data-clear]')) { notice = ''; opts.onChange('', ''); return; }
      const day = e.target.closest('[data-day]'); if (!day || day.disabled) return;
      const s = day.dataset.day, { from, to } = opts.getRange();
      notice = '';
      if (!from || to) { opts.onChange(s, ''); return; }
      if (s <= from) { opts.onChange(s, ''); return; }
      if (hasBusy(from, s)) { notice = 'Hay noches ocupadas en ese rango. Elige otras fechas.'; opts.onChange(s, ''); return; }
      opts.onChange(from, s);
    };
    render();
    return { refresh: () => { const r = opts.getRange(); if (r.from) { const p = r.from.split('-').map(Number); vy = p[0]; vm = p[1] - 1; } render(); }, isBusyRange: hasBusy };
  }

  window.StayCalendar = { mount };
})();
