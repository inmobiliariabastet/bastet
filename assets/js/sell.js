/* "Vender mi inmueble": formulario del landing para propietarios (datos, inmueble, ubicación en mapa y documentos).
   Autónomo: usa el cliente global `supabaseClient` y BOLIVIA_CITIES. El envío pasa por la función submit_sell_request()
   (supabase/sell-requests.sql); los documentos van a la carpeta privada `sell-documents` de Storage (solo un administrador los ve).
   El mapa es Leaflet con mosaicos de OpenStreetMap (sin clave) oscurecidos por CSS para que no salga verde y se carga solo al abrir el formulario. */
(function () {
  'use strict';

  const WHATSAPP_PHONE = '59177666205';
  const MAX_FILES = 12;
  const MAX_BYTES = 10 * 1024 * 1024;
  const OK_TYPES = ['application/pdf', 'image/jpeg', 'image/png', 'image/webp'];
  const CITY_CENTER = {
    'La Paz': [-16.4955, -68.1336], 'El Alto': [-16.5047, -68.163], 'Santa Cruz de la Sierra': [-17.7833, -63.1821],
    'Cochabamba': [-17.3939, -66.157], 'Sucre': [-19.0333, -65.2627], 'Oruro': [-17.9647, -67.106],
    'Potosí': [-19.5836, -65.7531], 'Tarija': [-21.5355, -64.7296], 'Trinidad': [-14.8333, -64.9], 'Cobija': [-11.0267, -68.7692],
  };
  const BOLIVIA_CENTER = [-16.7, -64.7];
  const DOC_TYPES = [
    { key: 'folio_real', label: 'Folio Real (Derechos Reales)', hint: 'Certificado actualizado de Derechos Reales.' },
    { key: 'testimonio', label: 'Testimonio o escritura de propiedad', hint: 'Documento con el que adquirió el inmueble.' },
    { key: 'impuestos', label: 'Impuestos al día', hint: 'Último pago de impuesto a la propiedad.' },
    { key: 'plano', label: 'Plano o certificado catastral', hint: 'Plano aprobado, certificado catastral o de uso de suelo.' },
    { key: 'ci', label: 'Cédula de identidad del propietario', hint: 'Anverso y reverso.' },
    { key: 'otros', label: 'Otros documentos', hint: 'Poder, sucesión hereditaria, contrato de compra, etc.' },
  ];
  const DOC_LABEL = Object.fromEntries(DOC_TYPES.map((d) => [d.key, d.label]));

  const $ = (id) => document.getElementById(id);
  const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const backdrop = $('sell-modal-backdrop');
  const form = $('sell-form');
  if (!backdrop || !form) return;

  const state = { id: null, files: [], uploaded: new Map(), map: null, marker: null, point: null, sent: null, busy: false };
  let leafletPromise = null;

  /* ───────── Abrir / cerrar ───────── */
  function open() {
    backdrop.classList.remove('hidden');
    document.body.style.overflow = 'hidden';
    if (!state.id) state.id = (window.crypto && crypto.randomUUID) ? crypto.randomUUID() : 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, (c) => { const r = Math.random() * 16 | 0; return (c === 'x' ? r : (r & 3 | 8)).toString(16); });
    if (!state.sent) { form.classList.remove('hidden'); $('sell-success').classList.add('hidden'); }
    initMap();
    setTimeout(() => { const f = $('sell-name'); if (f && !state.sent) f.focus({ preventScroll: true }); }, 60);
  }
  function close() {
    backdrop.classList.add('hidden');
    document.body.style.overflow = '';
  }

  document.querySelectorAll('[data-sell-open]').forEach((b) => b.addEventListener('click', (e) => { e.preventDefault(); open(); }));
  $('sell-modal-close').addEventListener('click', close);
  backdrop.addEventListener('click', (e) => { if (e.target === backdrop) close(); });
  document.addEventListener('keydown', (e) => { if (e.key === 'Escape' && !backdrop.classList.contains('hidden')) close(); });
  if (window.location.hash === '#vender') { history.replaceState(null, '', window.location.pathname); open(); }

  /* ───────── Ciudades ───────── */
  if (typeof BOLIVIA_CITIES !== 'undefined') {
    BOLIVIA_CITIES.forEach((c) => { const o = document.createElement('option'); o.value = c; o.textContent = c; $('sell-city').appendChild(o); });
  }

  /* ───────── Tipo de inmueble: terreno no tiene habitaciones ni construcción ───────── */
  function syncType() {
    const land = $('sell-type').value === 'terreno';
    document.querySelectorAll('[data-sell-building]').forEach((el) => el.classList.toggle('hidden', land));
  }
  $('sell-type').addEventListener('change', syncType);

  /* ───────── Mapa ───────── */
  function loadLeaflet() {
    if (window.L) return Promise.resolve();
    if (leafletPromise) return leafletPromise;
    leafletPromise = new Promise((resolve, reject) => {
      const css = document.createElement('link');
      css.rel = 'stylesheet'; css.href = 'https://cdnjs.cloudflare.com/ajax/libs/leaflet/1.9.4/leaflet.min.css';
      document.head.appendChild(css);
      const js = document.createElement('script');
      js.src = 'https://cdnjs.cloudflare.com/ajax/libs/leaflet/1.9.4/leaflet.min.js';
      js.onload = resolve; js.onerror = () => { leafletPromise = null; reject(new Error('mapa')); };
      document.head.appendChild(js);
    });
    return leafletPromise;
  }

  function setPoint(lat, lng, fly) {
    state.point = { lat: +lat.toFixed(6), lng: +lng.toFixed(6) };
    if (state.map) {
      if (!state.marker) {
        const icon = L.divIcon({ className: 'sell-pin-wrap', html: '<span class="sell-pin"></span>', iconSize: [30, 40], iconAnchor: [15, 38] });
        state.marker = L.marker([lat, lng], { icon, draggable: true }).addTo(state.map);
        state.marker.on('dragend', () => { const p = state.marker.getLatLng(); setPoint(p.lat, p.lng, false); });
      } else state.marker.setLatLng([lat, lng]);
      if (fly) state.map.setView([lat, lng], Math.max(state.map.getZoom(), 17));
    }
    $('sell-map-status').innerHTML = '<b>Ubicación marcada.</b> Si no es exacta, arrastra el pin o toca otro punto del mapa. (' + state.point.lat + ', ' + state.point.lng + ')';
    $('sell-map-status').classList.add('is-set');
    $('sell-map-wrap').classList.remove('has-error');
  }

  async function initMap() {
    if (state.map) { setTimeout(() => state.map.invalidateSize(), 50); return; }
    try { await loadLeaflet(); } catch (e) {
      $('sell-map').innerHTML = '<p class="sell-map-fail">No pudimos cargar el mapa. Revisa tu conexión y vuelve a abrir el formulario, o escribe la dirección con una referencia clara.</p>';
      return;
    }
    if (state.map) return;
    state.map = L.map('sell-map', { center: BOLIVIA_CENTER, zoom: 5, zoomControl: true, attributionControl: true });
    L.tileLayer('https://tile.openstreetmap.org/{z}/{x}/{y}.png', {
      maxZoom: 19,
      attribution: '&copy; <a href="https://www.openstreetmap.org/copyright" target="_blank" rel="noopener">OpenStreetMap</a>',
    }).addTo(state.map);
    if (CITY_CENTER[$('sell-city').value]) state.map.setView(CITY_CENTER[$('sell-city').value], 13);
    state.map.on('click', (e) => setPoint(e.latlng.lat, e.latlng.lng, false));
    setTimeout(() => state.map.invalidateSize(), 80);
    if (state.point) setPoint(state.point.lat, state.point.lng, true);
  }

  $('sell-city').addEventListener('change', () => {
    const c = CITY_CENTER[$('sell-city').value];
    if (c && state.map && !state.point) state.map.setView(c, 13);
  });

  $('sell-geo').addEventListener('click', () => {
    const st = $('sell-map-status');
    if (!navigator.geolocation) { st.textContent = 'Tu navegador no permite obtener la ubicación. Toca el punto en el mapa.'; return; }
    st.textContent = 'Buscando tu ubicación…';
    navigator.geolocation.getCurrentPosition(
      (pos) => setPoint(pos.coords.latitude, pos.coords.longitude, true),
      () => { st.textContent = 'No pudimos obtener tu ubicación (permiso denegado). Busca la dirección o toca el punto en el mapa.'; },
      { enableHighAccuracy: true, timeout: 12000 }
    );
  });

  async function searchPlace() {
    const q = $('sell-search').value.trim();
    const box = $('sell-search-results');
    if (q.length < 3) return;
    box.innerHTML = '<p class="sell-search-msg">Buscando…</p>'; box.classList.remove('hidden');
    const city = $('sell-city').value;
    try {
      const url = 'https://nominatim.openstreetmap.org/search?format=json&limit=5&countrycodes=bo&accept-language=es&q=' + encodeURIComponent(q + (city && !q.toLowerCase().includes(city.toLowerCase().split(' ')[0]) ? ', ' + city : ''));
      const res = await fetch(url, { headers: { Accept: 'application/json' } });
      const list = await res.json();
      if (!list.length) { box.innerHTML = '<p class="sell-search-msg">No encontramos ese lugar. Prueba con otra referencia o toca el punto en el mapa.</p>'; return; }
      box.innerHTML = list.map((r, i) => '<button type="button" data-i="' + i + '">' + esc(r.display_name) + '</button>').join('');
      box.querySelectorAll('button').forEach((b) => b.addEventListener('click', () => {
        const r = list[+b.dataset.i];
        setPoint(+r.lat, +r.lon, true); box.classList.add('hidden');
      }));
    } catch (e) { box.innerHTML = '<p class="sell-search-msg">No pudimos buscar ahora. Toca el punto directamente en el mapa.</p>'; }
  }
  $('sell-search-btn').addEventListener('click', searchPlace);
  $('sell-search').addEventListener('keydown', (e) => { if (e.key === 'Enter') { e.preventDefault(); searchPlace(); } });

  /* ───────── Documentos ───────── */
  const docWrap = $('sell-doc-slots');
  docWrap.innerHTML = DOC_TYPES.map((d) =>
    '<div class="sell-slot" data-type="' + d.key + '"><div class="sell-slot-head"><div><b>' + esc(d.label) + '</b><small>' + esc(d.hint) + '</small></div>' +
    '<label class="sell-attach"><input type="file" accept=".pdf,image/jpeg,image/png,image/webp" multiple hidden data-doc="' + d.key + '"><span>Adjuntar</span></label></div>' +
    '<ul class="sell-files"></ul></div>').join('');

  function renderFiles() {
    docWrap.querySelectorAll('.sell-slot').forEach((slot) => {
      const key = slot.dataset.type;
      const items = state.files.filter((f) => f.type === key);
      slot.querySelector('.sell-files').innerHTML = items.map((f) =>
        '<li><span>' + esc(f.file.name) + ' <em>' + (f.file.size / 1048576 < 0.1 ? Math.max(1, Math.round(f.file.size / 1024)) + ' KB' : (f.file.size / 1048576).toFixed(1) + ' MB') + '</em></span>' +
        '<button type="button" data-rm="' + f.uid + '" aria-label="Quitar ' + esc(f.file.name) + '">✕</button></li>').join('');
      slot.classList.toggle('has-files', items.length > 0);
    });
    $('sell-doc-count').textContent = state.files.length ? state.files.length + ' de ' + MAX_FILES + ' archivos adjuntos' : '';
  }
  let uidSeq = 0;
  docWrap.addEventListener('change', (e) => {
    const input = e.target.closest('input[type=file]');
    if (!input) return;
    const type = input.dataset.doc;
    const err = $('sell-doc-error'); err.classList.add('hidden');
    const problems = [];
    [...input.files].forEach((file) => {
      if (state.files.length >= MAX_FILES) { problems.push('Máximo ' + MAX_FILES + ' archivos.'); return; }
      if (!OK_TYPES.includes(file.type)) { problems.push(file.name + ': solo PDF, JPG, PNG o WEBP.'); return; }
      if (file.size > MAX_BYTES) { problems.push(file.name + ': pesa más de 10 MB.'); return; }
      state.files.push({ uid: ++uidSeq, type, file });
    });
    input.value = '';
    if (problems.length) { err.textContent = [...new Set(problems)].join(' '); err.classList.remove('hidden'); }
    renderFiles();
  });
  docWrap.addEventListener('click', (e) => {
    const rm = e.target.closest('[data-rm]');
    if (rm) { state.files = state.files.filter((f) => String(f.uid) !== rm.dataset.rm); renderFiles(); }
  });

  function docStatus() { const r = form.querySelector('input[name="sell-docs"]:checked'); return r ? r.value : ''; }
  function syncDocs() {
    const s = docStatus();
    $('sell-docs-upload').classList.toggle('hidden', s === 'sin_documentos' || !s);
    const legal = $('sell-legal');
    if (s === 'sin_documentos') { legal.checked = true; legal.disabled = true; } else { legal.disabled = false; }
    $('sell-legal-note').classList.toggle('hidden', s !== 'sin_documentos' && !legal.checked);
    $('sell-legal-note').textContent = s === 'sin_documentos'
      ? 'Nuestro equipo legal revisará tu caso y te orientará para sanear tus papeles antes de publicar.'
      : 'Nuestro equipo legal te contactará para ayudarte a regularizar lo que falte.';
  }
  form.querySelectorAll('input[name="sell-docs"]').forEach((r) => r.addEventListener('change', syncDocs));
  $('sell-legal').addEventListener('change', syncDocs);

  /* ───────── Envío ───────── */
  const v = (id) => $(id).value.trim();
  const num = (id) => { const x = v(id).replace(',', '.'); return x === '' ? null : Number(x); };
  function fail(msg, el) {
    const box = $('sell-error'); box.textContent = msg; box.classList.remove('hidden');
    if (el) { el.scrollIntoView({ behavior: 'smooth', block: 'center' }); if (el.focus) el.focus({ preventScroll: true }); }
    else box.scrollIntoView({ behavior: 'smooth', block: 'center' });
  }
  const ext = (name, mime) => (({ 'application/pdf': 'pdf', 'image/jpeg': 'jpg', 'image/png': 'png', 'image/webp': 'webp' })[mime]) || (name.split('.').pop() || 'bin').toLowerCase().replace(/[^a-z0-9]/g, '').slice(0, 5);
  const rand = () => Math.random().toString(36).slice(2, 8);

  form.addEventListener('submit', async (e) => {
    e.preventDefault();
    if (state.busy) return;
    $('sell-error').classList.add('hidden');
    const phone = v('sell-phone').replace(/[\s().-]/g, '');
    if (!/^\+?[0-9]{7,15}$/.test(phone)) return fail('Escribe un número de WhatsApp válido (solo números; con + si incluye código de país).', $('sell-phone'));
    if (!state.point) { $('sell-map-wrap').classList.add('has-error'); return fail('Marca la ubicación del inmueble en el mapa: busca la dirección, usa tu ubicación o toca el punto exacto.', $('sell-map-wrap')); }
    const ds = docStatus();
    if (!ds) return fail('Cuéntanos si tienes documentos que respalden tu propiedad.', $('sell-docs-group'));
    if (ds !== 'sin_documentos' && ds === 'en_regla' && !state.files.length && !confirm('Indicaste que tienes los documentos en regla pero no adjuntaste ninguno. ¿Enviar de todas formas? (Podrás enviarlos después por WhatsApp.)')) return;
    if (!$('sell-consent').checked) return fail('Debes aceptar que usemos tus datos para contactarte.', $('sell-consent'));

    state.busy = true;
    const btn = $('sell-submit'); btn.disabled = true;
    const label = btn.querySelector('span'); const old = label.textContent;
    try {
      const docs = [];
      const todo = ds === 'sin_documentos' ? [] : state.files;
      let n = 0;
      for (const f of todo) {
        n++; label.textContent = 'Subiendo documentos (' + n + '/' + todo.length + ')…';
        let path = state.uploaded.get(f.uid);
        if (!path) {
          path = state.id + '/' + f.type + '-' + rand() + '.' + ext(f.file.name, f.file.type);
          const up = await supabaseClient.storage.from('sell-documents').upload(path, f.file, { contentType: f.file.type, upsert: false });
          if (up.error) throw new Error('No pudimos subir "' + f.file.name + '": ' + up.error.message);
          state.uploaded.set(f.uid, path);
        }
        docs.push({ type: f.type, name: f.file.name.slice(0, 120), path, size: f.file.size });
      }
      label.textContent = 'Enviando…';
      const land = $('sell-type').value === 'terreno';
      const payload = {
        id: state.id, owner_name: v('sell-name'), owner_ci: v('sell-ci') || null, owner_phone: phone, owner_email: v('sell-email') || null,
        owner_role: $('sell-role').value, property_type: $('sell-type').value, operation: $('sell-operation').value, city: $('sell-city').value,
        zone: v('sell-zone') || null, address: v('sell-address'), latitude: state.point.lat, longitude: state.point.lng,
        price: num('sell-price'), currency: $('sell-currency').value, land_area: num('sell-land'), built_area: land ? null : num('sell-built'),
        rooms: land ? null : num('sell-rooms'), baths: land ? null : num('sell-baths'), description: v('sell-desc') || null,
        doc_status: ds, needs_legal_support: $('sell-legal').checked || ds === 'sin_documentos', documents: docs, consent: true,
      };
      const { error } = await supabaseClient.rpc('submit_sell_request', { p: payload });
      if (error) throw new Error(error.message || 'No se pudo enviar.');
      state.sent = payload;
      showSuccess(payload);
    } catch (err) {
      fail((err && err.message) || 'No pudimos enviar tu solicitud. Inténtalo otra vez o escríbenos por WhatsApp al +591 77666205.');
    } finally {
      state.busy = false; btn.disabled = false; label.textContent = old;
    }
  });

  function showSuccess(p) {
    const lines = [
      'Hola Bastet, acabo de enviar mi solicitud para vender mi inmueble desde la web.',
      'Propietario: ' + p.owner_name,
      'Inmueble: ' + ({ casa: 'Casa', departamento: 'Departamento', terreno: 'Terreno', otro: 'Otro' }[p.property_type]) + ' en ' + p.city + (p.zone ? ' (' + p.zone + ')' : ''),
      'Ubicación: https://www.google.com/maps?q=' + p.latitude + ',' + p.longitude,
      p.needs_legal_support ? 'Necesito apoyo legal para sanear mis documentos.' : 'Documentos: ' + (p.documents.length ? p.documents.length + ' adjuntos' : 'los enviaré por aquí'),
    ];
    $('sell-wa').href = 'https://api.whatsapp.com/send?phone=' + WHATSAPP_PHONE + '&text=' + encodeURIComponent(lines.join('\n'));
    $('sell-success-legal').classList.toggle('hidden', !p.needs_legal_support);
    form.classList.add('hidden'); $('sell-success').classList.remove('hidden');
    backdrop.querySelector('.property-modal').scrollTop = 0;
  }
  $('sell-done').addEventListener('click', close);

  syncType(); syncDocs(); renderFiles();
})();
