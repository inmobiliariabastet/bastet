/* «Vender mi inmueble» en pasos (Flujo D del rediseño móvil). Es una capa SOBRE el formulario de sell.js: no cambia ningún campo,
 * validación ni el envío (submit_sell_request); solo muestra una sección a la vez con indicador de avance, tarjetas para elegir la
 * operación y una pantalla final «Revisar y enviar». Si este archivo no carga, el formulario sigue funcionando completo como antes.
 * Pasos: 1 Operación · 2 Propietario · 3 Inmueble · 4 Ubicación · 5 Documentos · 6 Revisar y enviar. */
(function () {
  'use strict';
  const $ = (id) => document.getElementById(id);
  const form = $('sell-form');
  const backdrop = $('sell-modal-backdrop');
  if (!form || !backdrop) return;
  const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

  const sections = [...form.querySelectorAll(':scope > .sell-section')];
  if (sections.length !== 4) return;
  const consent = form.querySelector('.sell-consent');
  const errBox = $('sell-error');
  const submit = $('sell-submit');
  const select = $('sell-operation');

  const OPS = [
    { v: 'venta', t: 'Venta', d: 'Quiero vender mi propiedad' },
    { v: 'alquiler', t: 'Alquiler', d: 'Quiero alquilar mi propiedad' },
    { v: 'anticretico', t: 'Anticrético', d: 'Quiero entregarla en anticrético' },
    { v: 'temporal', t: 'Estadías temporales', d: 'Quiero alquilarla por noches o días' },
  ];

  /* Paso 1: tarjetas de operación (el select original queda sincronizado y oculto) */
  const opStep = document.createElement('section');
  opStep.className = 'sw-step-card';
  opStep.innerHTML = '<h3>¿Qué quieres hacer con tu propiedad?</h3><p class="sw-sub">Elige una opción; un asesor te acompaña en el resto.</p><div class="sw-ops" role="radiogroup" aria-label="Tipo de operación">' +
    OPS.map((o) => '<button type="button" class="sw-op" role="radio" data-op="' + o.v + '" aria-checked="false"><span class="sw-op-text"><b>' + o.t + '</b><small>' + o.d + '</small></span><span class="sw-radio" aria-hidden="true"></span></button>').join('') + '</div>';
  const opField = select.closest('.agent-field');
  if (opField) opField.classList.add('sw-hidden');
  function syncOps() { opStep.querySelectorAll('.sw-op').forEach((b) => { const on = b.dataset.op === select.value; b.classList.toggle('is-on', on); b.setAttribute('aria-checked', String(on)); }); }
  opStep.addEventListener('click', (e) => {
    const b = e.target.closest('.sw-op'); if (!b) return;
    select.value = b.dataset.op; select.dispatchEvent(new Event('change', { bubbles: true })); syncOps();
  });

  /* Paso 6: revisar + consentimiento + envío */
  const review = document.createElement('section');
  review.className = 'sw-step-card';
  review.innerHTML = '<h3>Revisa y envía</h3><p class="sw-sub">Comprueba que todo esté bien. Puedes volver a cualquier paso para corregirlo.</p><div id="sw-summary" class="sw-summary"></div>';
  [consent, errBox, submit].forEach((el) => review.appendChild(el));

  const steps = [
    { el: opStep, name: 'Operación' }, { el: sections[0], name: 'Propietario' }, { el: sections[1], name: 'Inmueble' },
    { el: sections[2], name: 'Ubicación' }, { el: sections[3], name: 'Documentos' }, { el: review, name: 'Revisar' },
  ];
  steps.forEach((s) => { s.el.classList.add('sw-step'); });
  const hint = form.querySelector('.agent-form-hint');
  form.insertBefore(opStep, sections[0]);
  form.appendChild(review);

  /* Indicador y navegación */
  const prog = document.createElement('div');
  prog.className = 'sw-progress';
  prog.innerHTML = '<div class="sw-prog-top"><b id="sw-prog-name"></b><span id="sw-prog-n"></span></div><div class="sw-bar"><i id="sw-bar-fill"></i></div>';
  form.insertBefore(prog, form.firstChild);
  const nav = document.createElement('div');
  nav.className = 'sw-nav';
  nav.innerHTML = '<p class="sw-err hidden" id="sw-err" role="alert"></p><div class="sw-nav-row"><button type="button" class="sw-prev" id="sw-prev">← Anterior</button><button type="button" class="sw-next" id="sw-next">Siguiente →</button></div>';
  form.appendChild(nav);
  const prev = $('sw-prev'), next = $('sw-next'), swErr = $('sw-err');

  let cur = 0;
  function stepErr(msg, el) {
    swErr.textContent = msg; swErr.classList.remove('hidden');
    if (el && el.focus) { try { el.scrollIntoView({ behavior: 'smooth', block: 'center' }); el.focus({ preventScroll: true }); } catch (e) { /* sin foco */ } }
  }
  function validate(i) {
    swErr.classList.add('hidden');
    if (i === 1) {
      if ($('sell-name').value.trim().length < 3) { stepErr('Escribe tu nombre completo.', $('sell-name')); return false; }
      if (!/^\+?[0-9]{7,15}$/.test($('sell-phone').value.trim().replace(/[\s().-]/g, ''))) { stepErr('Escribe un número de WhatsApp válido (solo números; con + si incluye código de país).', $('sell-phone')); return false; }
    }
    if (i === 2) {
      for (const el of steps[2].el.querySelectorAll('[required]')) { if (!el.checkValidity()) { el.reportValidity(); stepErr('Completa los campos obligatorios (*) de este paso.', el); return false; } }
    }
    if (i === 3 && !$('sell-map-status').classList.contains('is-set')) {
      $('sell-map-wrap').classList.add('has-error'); stepErr('Marca la ubicación del inmueble: busca la dirección, usa tu ubicación o toca el punto exacto en el mapa.', $('sell-map-wrap')); return false;
    }
    if (i === 4 && !form.querySelector('input[name="sell-docs"]:checked')) { stepErr('Cuéntanos si tienes documentos que respalden tu propiedad.', $('sell-docs-group')); return false; }
    return true;
  }
  const val = (id) => { const e = $(id); return e ? e.value.trim() : ''; };
  const opt = (id) => { const e = $(id); return e && e.selectedOptions[0] ? e.selectedOptions[0].textContent.trim() : ''; };
  function buildSummary() {
    const doc = form.querySelector('input[name="sell-docs"]:checked');
    const docTxt = doc ? doc.closest('.sell-choice').querySelector('b').textContent : '—';
    const pt = $('sell-map-status').classList.contains('is-set') ? 'Marcada en el mapa' : 'Sin marcar';
    const row = (k, v) => '<div><span>' + k + '</span><b>' + (esc(v) || '—') + '</b></div>';
    const block = (title, step, rows) => '<section class="sw-sum-block"><header><h4>' + title + '</h4><button type="button" data-go="' + step + '">Editar</button></header>' + rows + '</section>';
    const land = $('sell-type').value === 'terreno';
    $('sw-summary').innerHTML =
      block('Operación', 0, row('Tipo', opt('sell-operation'))) +
      block('Propietario', 1, row('Nombre', val('sell-name')) + row('Rol', opt('sell-role')) + row('WhatsApp', val('sell-phone')) + row('Correo', val('sell-email'))) +
      block('Inmueble', 2, row('Tipo', opt('sell-type')) + row('Ciudad', opt('sell-city') + (val('sell-zone') ? ' · ' + val('sell-zone') : '')) + row('Dirección', val('sell-address')) +
        row($('sell-price-label').textContent, val('sell-price') ? val('sell-price') + ' ' + opt('sell-currency') : '') + row('Terreno', val('sell-land') ? val('sell-land') + ' m²' : '') +
        (land ? '' : row('Construida', val('sell-built') ? val('sell-built') + ' m²' : '') + row('Habitaciones / baños', [val('sell-rooms'), val('sell-baths')].filter(Boolean).join(' / ')))) +
      block('Ubicación', 3, row('Mapa', pt)) +
      block('Documentos', 4, row('Estado', docTxt) + row('Adjuntos', ($('sell-doc-count').textContent || 'Ninguno')));
  }
  function show(i) {
    cur = Math.max(0, Math.min(steps.length - 1, i));
    steps.forEach((s, k) => s.el.classList.toggle('sw-hidden', k !== cur));
    if (hint) hint.classList.toggle('sw-hidden', cur !== 0);
    $('sw-prog-name').textContent = steps[cur].name;
    $('sw-prog-n').textContent = 'Paso ' + (cur + 1) + ' de ' + steps.length;
    $('sw-bar-fill').style.width = (((cur + 1) / steps.length) * 100) + '%';
    prev.classList.toggle('sw-invisible', cur === 0);
    next.classList.toggle('sw-hidden', cur === steps.length - 1);
    swErr.classList.add('hidden');
    syncOps();
    if (cur === steps.length - 1) buildSummary();
    // el mapa necesita recalcular su tamaño al volverse visible
    if (cur === 3) { [60, 350, 900].forEach((t) => setTimeout(() => window.dispatchEvent(new Event('resize')), t)); }
    const panelEl = backdrop.querySelector('.property-modal'); if (panelEl) panelEl.scrollTop = 0;
  }
  next.addEventListener('click', () => { if (validate(cur)) show(cur + 1); });
  prev.addEventListener('click', () => show(cur - 1));
  form.addEventListener('click', (e) => { const g = e.target.closest('[data-go]'); if (g) show(Number(g.dataset.go)); });
  // Enter en un campo avanza de paso en vez de enviar el formulario antes de tiempo
  form.addEventListener('keydown', (e) => {
    if (e.key !== 'Enter' || e.target.tagName === 'TEXTAREA' || e.target.tagName === 'BUTTON' || e.target.id === 'sell-search') return;
    if (cur < steps.length - 1) { e.preventDefault(); if (validate(cur)) show(cur + 1); }
  });

  // «Ver mis publicaciones» en la pantalla de confirmación (requiere cuenta; el panel ya existe)
  const done = $('sell-done');
  if (done && !$('sw-mine')) {
    const a = document.createElement('a');
    a.id = 'sw-mine'; a.className = 'cta-button cta-button--glass'; a.href = 'admin/'; a.innerHTML = '<span>Ver mis publicaciones</span>';
    done.parentNode.insertBefore(a, done);
  }

  syncOps();
  show(0);
})();
