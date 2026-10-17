/* Estadías: calificaciones y reseñas, mapa de ubicación, lugares cercanos y guía de la ciudad (ficha del alojamiento).
 *  · Reseñas: solo las escriben huéspedes que recibieron un ENLACE de reseña del anfitrión (estadias.html?resena=CÓDIGO), una vez por enlace.
 *    Funciones SQL en supabase/stays.sql. Si ese SQL aún no se corrió, todo lo de reseñas simplemente no se muestra.
 *  · Mapa: OpenStreetMap con Leaflet (se carga solo al abrir una ficha). Usa latitud/longitud de la propiedad; si faltan, geocodifica la
 *    dirección con Nominatim y guarda el resultado en el navegador.
 *  · Lugares cercanos: se consultan en vivo a OpenStreetMap (Overpass) con las coordenadas del alojamiento; no se envía ningún dato personal.
 *  · Guía de la ciudad: lista escrita a mano en city-guides.js.
 * Autónomo: usa el cliente global `supabaseClient`. Lo carga estadias.html antes de estadias.js, que lo llama como `window.StayExtras`. */
(function () {
  'use strict';

  const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const plural = (n, one, many) => (n === 1 ? one : many);
  const LEAFLET_CSS = 'https://cdnjs.cloudflare.com/ajax/libs/leaflet/1.9.4/leaflet.min.css';
  const LEAFLET_JS = 'https://cdnjs.cloudflare.com/ajax/libs/leaflet/1.9.4/leaflet.min.js';
  const OVERPASS = ['https://overpass-api.de/api/interpreter', 'https://overpass.kumi.systems/api/interpreter'];
  const PRIOR_AVG = 4.2, PRIOR_WEIGHT = 3;      // para ordenar: una sola reseña de 5★ no supera a un alojamiento con muchas de 4,8★

  const X = { ratings: {}, hasReviews: true };
  window.StayExtras = X;

  /* ───────── Calificaciones ───────── */
  X.starsHtml = (avg) => '<span class="stars" style="--fill:' + Math.max(0, Math.min(100, (Number(avg) / 5) * 100)).toFixed(0) + '%" aria-hidden="true">★★★★★</span>';
  X.fmtAvg = (avg) => Number(avg).toFixed(1).replace('.', ',');
  X.of = (id) => X.ratings[id] || null;
  // Puntaje para ordenar «Recomendados»: promedio ponderado por cantidad de reseñas (sin reseñas = promedio neutro)
  X.score = (id) => { const r = X.ratings[id]; return r ? (r.n * r.avg + PRIOR_WEIGHT * PRIOR_AVG) / (r.n + PRIOR_WEIGHT) : PRIOR_AVG; };
  // «Mejor calificado»: promedio alto con suficientes reseñas
  X.isTop = (id) => { const r = X.ratings[id]; return !!r && r.n >= 3 && r.avg >= 4.7; };

  X.loadRatings = async function (ids) {
    X.ratings = {};
    if (!ids || !ids.length) return;
    try {
      const { data, error } = await supabaseClient.rpc('list_stay_ratings', { p_ids: ids });
      if (error) { X.hasReviews = false; return; }
      (data || []).forEach((r) => { X.ratings[r.property_id] = { avg: Number(r.avg_rating), n: r.review_count }; });
    } catch (e) { X.hasReviews = false; }
  };

  /* ───────── Utilidades ───────── */
  const cityOf = (p) => String(p.location || '').split(',')[0].trim();
  const num = (v) => { const n = Number(v); return Number.isFinite(n) ? n : null; };
  function distM(a, b) {
    const R = 6371000, rad = (d) => d * Math.PI / 180;
    const dLat = rad(b.lat - a.lat), dLng = rad(b.lng - a.lng);
    const h = Math.sin(dLat / 2) ** 2 + Math.cos(rad(a.lat)) * Math.cos(rad(b.lat)) * Math.sin(dLng / 2) ** 2;
    return 2 * R * Math.asin(Math.sqrt(h));
  }
  const fmtDist = (m) => (m < 950 ? Math.max(10, Math.round(m / 10) * 10) + ' m' : (m / 1000).toFixed(1).replace('.', ',') + ' km');
  const gmapsSearch = (q) => 'https://www.google.com/maps/search/?api=1&query=' + encodeURIComponent(q);
  function timeAgo(iso) {
    const d = new Date(iso); if (isNaN(d)) return '';
    return d.toLocaleDateString('es-BO', { month: 'long', year: 'numeric' });
  }
  function loadOnce(tag, url, attrs) {
    return new Promise((resolve, reject) => {
      const exist = document.querySelector('[data-extra="' + url + '"]');
      if (exist) { exist.addEventListener('load', resolve); if (exist.dataset.done) resolve(); return; }
      const el = document.createElement(tag);
      el.dataset.extra = url;
      Object.assign(el, attrs);
      el.onload = () => { el.dataset.done = '1'; resolve(); };
      el.onerror = () => reject(new Error('No se pudo cargar ' + url));
      document.head.appendChild(el);
    });
  }
  const loadLeaflet = async () => {
    if (window.L) return window.L;
    await loadOnce('link', LEAFLET_CSS, { rel: 'stylesheet', href: LEAFLET_CSS });
    await loadOnce('script', LEAFLET_JS, { src: LEAFLET_JS });
    return window.L;
  };

  /* ───────── Coordenadas del alojamiento ───────── */
  async function getCoords(p) {
    const lat = num(p.latitude), lng = num(p.longitude);
    if (lat !== null && lng !== null) return { lat, lng, exact: true };
    const key = 'stay-geo:' + p.id;
    try { const c = JSON.parse(localStorage.getItem(key) || 'null'); if (c && c.lat) return { lat: c.lat, lng: c.lng, exact: false }; } catch (e) { /* sin caché */ }
    try {
      // primero la dirección completa; si no aparece, solo la ciudad
      const city = String(p.location || '').replace(/,\s*Bolivia\s*$/i, '');
      for (const q of [[p.address, city, 'Bolivia'], [city, 'Bolivia']].map((a) => a.filter(Boolean).join(', '))) {
        const r = await fetch('https://nominatim.openstreetmap.org/search?format=jsonv2&limit=1&countrycodes=bo&q=' + encodeURIComponent(q), { headers: { 'Accept-Language': 'es' } });
        const j = await r.json();
        if (j && j[0]) {
          const c = { lat: parseFloat(j[0].lat), lng: parseFloat(j[0].lon) };
          try { localStorage.setItem(key, JSON.stringify(c)); } catch (e) { /* sin almacenamiento */ }
          return { lat: c.lat, lng: c.lng, exact: false };
        }
      }
    } catch (e) { /* sin red o servicio ocupado */ }
    return null;
  }

  /* ───────── Lugares cercanos (OpenStreetMap / Overpass) ───────── */
  async function fetchNearby(c, id) {
    const key = 'stay-nearby:' + id + ':' + c.lat.toFixed(4) + ',' + c.lng.toFixed(4);
    try { const cached = JSON.parse(sessionStorage.getItem(key) || 'null'); if (cached) return cached; } catch (e) { /* sin caché */ }
    const q = '[out:json][timeout:15];(' +
      'nwr(around:1500,' + c.lat + ',' + c.lng + ')["tourism"~"^(attraction|museum|viewpoint|gallery|zoo|theme_park)$"]["name"];' +
      'nwr(around:1500,' + c.lat + ',' + c.lng + ')["historic"]["name"];' +
      'nwr(around:1500,' + c.lat + ',' + c.lng + ')["leisure"="park"]["name"];' +
      'nwr(around:1200,' + c.lat + ',' + c.lng + ')["amenity"~"^(restaurant|cafe|marketplace)$"]["name"];' +
      'nwr(around:1500,' + c.lat + ',' + c.lng + ')["shop"~"^(mall|supermarket)$"]["name"];' +
      ');out center 150;';
    for (const url of OVERPASS) {
      try {
        const ctl = new AbortController(); const t = setTimeout(() => ctl.abort(), 14000);
        const r = await fetch(url, { method: 'POST', body: 'data=' + encodeURIComponent(q), headers: { 'Content-Type': 'application/x-www-form-urlencoded' }, signal: ctl.signal });
        clearTimeout(t);
        if (!r.ok) continue;
        const j = await r.json();
        const seen = new Set(), out = [];
        (j.elements || []).forEach((e) => {
          const t = e.tags || {}, name = t.name; if (!name) return;
          const pt = e.type === 'node' ? { lat: e.lat, lng: e.lon } : (e.center ? { lat: e.center.lat, lng: e.center.lon } : null);
          if (!pt) return;
          let group, label;
          if (t.tourism) { group = 'visit'; label = { attraction: 'Atracción', museum: 'Museo', viewpoint: 'Mirador', gallery: 'Galería', zoo: 'Zoológico', theme_park: 'Parque temático' }[t.tourism] || 'Para visitar'; }
          else if (t.historic) { group = 'visit'; label = 'Sitio histórico'; }
          else if (t.leisure === 'park') { group = 'visit'; label = 'Parque'; }
          else if (t.amenity === 'restaurant' || t.amenity === 'cafe') { group = 'eat'; label = t.amenity === 'cafe' ? 'Café' : 'Restaurante'; }
          else { group = 'shop'; label = t.amenity === 'marketplace' ? 'Mercado' : (t.shop === 'mall' ? 'Centro comercial' : 'Supermercado'); }
          const k = group + '|' + name.toLowerCase(); if (seen.has(k)) return; seen.add(k);
          out.push({ group, label, name, dist: Math.round(distM(c, pt)), lat: pt.lat, lng: pt.lng });
        });
        out.sort((a, b) => a.dist - b.dist);
        try { sessionStorage.setItem(key, JSON.stringify(out)); } catch (e) { /* sin caché */ }
        return out;
      } catch (e) { /* se prueba con el siguiente servidor */ }
    }
    return null;
  }

  function nearbyHtml(list, city) {
    if (list === null) return '<p class="sd-muted">No pudimos cargar los lugares cercanos ahora. Puedes verlos en el mapa.</p>';
    const groups = [['visit', 'Para visitar cerca', 8], ['eat', 'Comer y tomar algo', 6], ['shop', 'Compras y mercados', 4]];
    const html = groups.map(([g, title, max]) => {
      const items = list.filter((x) => x.group === g).slice(0, max);
      if (!items.length) return '';
      return '<div class="sd-near-group"><h3>' + title + '</h3><ul class="sd-near">' + items.map((x) =>
        '<li><a href="' + esc(gmapsSearch(x.name + ' ' + city + ' Bolivia')) + '" target="_blank" rel="noopener"><span class="sd-near-name">' + esc(x.name) + '</span><span class="sd-near-meta">' + esc(x.label) + ' · a ' + fmtDist(x.dist) + '</span></a></li>').join('') + '</ul></div>';
    }).join('');
    return html || '<p class="sd-muted">No encontramos lugares registrados muy cerca de este alojamiento. Mira las sugerencias de la ciudad.</p>';
  }

  function cityGuideHtml(city) {
    const key = Object.keys(window.CITY_GUIDES || {}).find((k) => k.toLowerCase() === city.toLowerCase());
    const items = key ? window.CITY_GUIDES[key] : null;
    if (!items) return '';
    return '<div class="sd-near-group sd-city"><h3>Qué hacer en ' + esc(key) + '</h3><ul class="sd-guide">' + items.map((x) =>
      '<li><a href="' + esc(gmapsSearch(x.n + ' ' + key + ' Bolivia')) + '" target="_blank" rel="noopener"><span class="sd-guide-t">' + esc(x.t) + '</span><b>' + esc(x.n) + '</b><span>' + esc(x.d) + '</span></a></li>').join('') +
      '</ul><p class="sd-muted sd-fine">Sugerencias generales de la ciudad. Confirma horarios y precios antes de ir.</p></div>';
  }

  /* ───────── Reseñas ───────── */
  async function fetchReviews(id) {
    try {
      const { data, error } = await supabaseClient.rpc('list_stay_reviews', { p_property: id, p_limit: 40 });
      if (error) return null;
      return data || [];
    } catch (e) { return null; }
  }
  function reviewsHtml(list, id) {
    const r = X.of(id);
    const head = r
      ? '<div class="sd-rev-sum"><div class="sd-rev-big">' + X.fmtAvg(r.avg) + '</div><div>' + X.starsHtml(r.avg) + '<p>' + r.n + ' ' + plural(r.n, 'reseña', 'reseñas') + ' de huéspedes</p></div></div>'
      : '<p class="sd-muted">Todavía no tiene reseñas.</p>';
    let dist = '';
    if (r && list && list.length) {
      const c = [0, 0, 0, 0, 0]; list.forEach((x) => { c[x.rating - 1]++; });
      const total = list.length;
      dist = '<div class="sd-rev-dist">' + [5, 4, 3, 2, 1].map((s) => '<div><span>' + s + ' ★</span><i><b style="width:' + Math.round((c[s - 1] / total) * 100) + '%"></b></i><span>' + c[s - 1] + '</span></div>').join('') + '</div>';
    }
    const items = (list || []).map((x) =>
      '<article class="sd-review"><header><b>' + esc(x.guest_name) + '</b>' + X.starsHtml(x.rating) + '<time>' + esc(timeAgo(x.created_at)) + '</time></header>' +
      (x.comment ? '<p>' + esc(x.comment).replace(/\n/g, '<br>') + '</p>' : '') +
      (x.host_reply ? '<div class="sd-reply"><b>Respuesta del anfitrión</b><p>' + esc(x.host_reply).replace(/\n/g, '<br>') + '</p></div>' : '') + '</article>').join('');
    return head + dist + (items ? '<div class="sd-rev-list">' + items + '</div>' : '') +
      '<p class="sd-muted sd-fine">Solo reseñan huéspedes que se alojaron: el anfitrión les envía un enlace personal de un solo uso. ¿Te alojaste aquí? Pídele tu enlace.</p>';
  }

  /* ───────── Montaje en la ficha ───────── */
  X.mount = function (p, detail) {
    const main = detail.querySelector('.sd-main');
    const note = detail.querySelector('.sd-note');
    if (!main) return;
    const city = cityOf(p);
    const wrap = document.createElement('div');
    wrap.innerHTML =
      '<section class="sd-section" id="sd-loc"><h2>Ubicación</h2><p class="sd-addr">' + esc(p.address && p.address.toLowerCase().includes(city.toLowerCase()) ? p.address : [p.address, p.location].filter(Boolean).join(' · ')) + '</p>' +
        '<div class="sd-map" id="sd-map" aria-label="Mapa de la ubicación"><p class="sd-muted">Cargando mapa…</p></div><div class="sd-map-links" id="sd-map-links"></div></section>' +
      '<section class="sd-section" id="sd-explore"><h2>Qué visitar y explorar</h2><div id="sd-nearby"><p class="sd-muted">Buscando lugares cerca del alojamiento…</p></div><div id="sd-cityguide">' + cityGuideHtml(city) + '</div></section>' +
      (X.hasReviews ? '<section class="sd-section" id="sd-reviews"><h2>Reseñas y calificación</h2><div id="sd-reviews-body"><p class="sd-muted">Cargando reseñas…</p></div></section>' : '');
    [...wrap.children].forEach((el) => (note ? main.insertBefore(el, note) : main.appendChild(el)));

    // calificación junto al título (si ya tiene reseñas)
    const r = X.of(p.id);
    const place = detail.querySelector('.sd-place');
    if (r && place) place.insertAdjacentHTML('afterend', '<a class="sd-rating" href="#sd-reviews" data-goto="sd-reviews">' + X.starsHtml(r.avg) + ' <b>' + X.fmtAvg(r.avg) + '</b> · ' + r.n + ' ' + plural(r.n, 'reseña', 'reseñas') + '</a>');

    // mapa + cercanos
    getCoords(p).then(async (c) => {
      const mapEl = detail.querySelector('#sd-map'), links = detail.querySelector('#sd-map-links');
      if (!mapEl) return;
      if (!c) { mapEl.innerHTML = '<p class="sd-muted">No pudimos ubicar este alojamiento en el mapa.</p>'; detail.querySelector('#sd-nearby').innerHTML = ''; return; }
      links.innerHTML = '<a href="' + esc('https://www.google.com/maps/search/?api=1&query=' + c.lat + ',' + c.lng) + '" target="_blank" rel="noopener">Abrir en Google Maps</a>' +
        '<a href="' + esc('https://www.google.com/maps/dir/?api=1&destination=' + c.lat + ',' + c.lng) + '" target="_blank" rel="noopener">Cómo llegar</a>' +
        (c.exact ? '' : '<span class="sd-muted">Ubicación aproximada según la dirección.</span>');
      try {
        const L = await loadLeaflet();
        if (!detail.contains(mapEl)) return;
        mapEl.innerHTML = '';
        const map = L.map(mapEl, { scrollWheelZoom: false }).setView([c.lat, c.lng], c.exact ? 16 : 15);
        L.tileLayer('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png', { attribution: '&copy; OpenStreetMap', maxZoom: 19 }).addTo(map);
        L.marker([c.lat, c.lng]).addTo(map).bindPopup(esc(p.title));
        setTimeout(() => map.invalidateSize(), 250);
      } catch (e) { mapEl.innerHTML = '<p class="sd-muted">No pudimos cargar el mapa. Usa «Abrir en Google Maps».</p>'; }
      const list = await fetchNearby(c, p.id);
      const nb = detail.querySelector('#sd-nearby'); if (nb) nb.innerHTML = nearbyHtml(list, city);
    });

    // reseñas
    if (X.hasReviews) fetchReviews(p.id).then((list) => {
      const body = detail.querySelector('#sd-reviews-body'); if (!body) return;
      if (list === null) { const sec = detail.querySelector('#sd-reviews'); if (sec) sec.remove(); return; }
      body.innerHTML = reviewsHtml(list, p.id);
    });
  };

  /* ───────── Formulario de reseña (enlace del anfitrión) ───────── */
  X.openReviewFromUrl = async function (onDone) {
    const token = new URLSearchParams(location.search).get('resena');
    if (!token) return;
    const modal = document.createElement('div');
    modal.className = 'stay-review-modal'; modal.setAttribute('role', 'dialog'); modal.setAttribute('aria-modal', 'true');
    document.body.appendChild(modal); document.body.classList.add('sd-open');
    const close = () => { modal.remove(); document.body.classList.remove('sd-open'); const u = new URL(location.href); u.searchParams.delete('resena'); history.replaceState(null, '', u.pathname + (u.search || '')); };
    const card = (html) => { modal.innerHTML = '<div class="srm-card">' + html + '</div>'; };
    card('<p class="sd-muted">Verificando tu enlace…</p>');
    let inv = null;
    try { const { data, error } = await supabaseClient.rpc('get_review_invite', { p_token: token }); if (!error) inv = data; } catch (e) { /* sin red */ }
    if (!inv || !inv.valid) {
      card('<h2>' + (inv && inv.used ? 'Este enlace ya se usó' : 'Enlace no válido') + '</h2><p>' + (inv && inv.used ? '¡Gracias! Tu reseña ya fue publicada.' : 'Revisa que el enlace esté completo o pídele uno nuevo a tu anfitrión.') + '</p><button type="button" class="srm-btn" data-close>Ver alojamientos</button>');
      modal.querySelector('[data-close]').addEventListener('click', close);
      return;
    }
    let rating = 0;
    card('<h2>¿Cómo fue tu estadía?</h2><p class="srm-place"><b>' + esc(inv.title) + '</b><br>' + esc(inv.location || '') + '</p>' +
      '<form id="srm-form" novalidate>' +
        '<label class="srm-label">Tu calificación</label><div class="srm-stars" role="radiogroup" aria-label="Calificación de 1 a 5 estrellas">' +
          [1, 2, 3, 4, 5].map((n) => '<button type="button" role="radio" aria-checked="false" data-star="' + n + '" aria-label="' + n + ' ' + plural(n, 'estrella', 'estrellas') + '">★</button>').join('') + '</div>' +
        '<label class="srm-label" for="srm-name">Tu nombre</label><input id="srm-name" type="text" maxlength="60" autocomplete="name" value="' + esc(inv.guest_name || '') + '" required>' +
        '<label class="srm-label" for="srm-text">Cuéntanos tu experiencia <span>(opcional)</span></label><textarea id="srm-text" rows="5" maxlength="1200" placeholder="Limpieza, ubicación, atención del anfitrión…"></textarea>' +
        '<p class="srm-error" id="srm-error" hidden></p>' +
        '<div class="srm-actions"><button type="button" class="srm-ghost" data-close>Ahora no</button><button type="submit" class="srm-btn" id="srm-send">Publicar mi reseña</button></div>' +
        '<p class="sd-muted sd-fine">Tu reseña será pública con tu nombre y la inicial de tu apellido. El enlace sirve una sola vez.</p>' +
      '</form>');
    const stars = [...modal.querySelectorAll('[data-star]')];
    const paint = (n) => stars.forEach((b) => { const on = Number(b.dataset.star) <= n; b.classList.toggle('is-on', on); b.setAttribute('aria-checked', String(Number(b.dataset.star) === rating)); });
    stars.forEach((b) => { b.addEventListener('click', () => { rating = Number(b.dataset.star); paint(rating); }); b.addEventListener('mouseenter', () => paint(Number(b.dataset.star))); b.addEventListener('mouseleave', () => paint(rating)); });
    modal.querySelector('[data-close]').addEventListener('click', close);
    modal.querySelector('#srm-form').addEventListener('submit', async (e) => {
      e.preventDefault();
      const err = modal.querySelector('#srm-error'); err.hidden = true;
      const name = modal.querySelector('#srm-name').value.trim();
      if (!rating) { err.textContent = 'Elige de 1 a 5 estrellas.'; err.hidden = false; return; }
      if (name.length < 2) { err.textContent = 'Escribe tu nombre.'; err.hidden = false; return; }
      const send = modal.querySelector('#srm-send'); send.disabled = true; send.textContent = 'Publicando…';
      const { error } = await supabaseClient.rpc('submit_stay_review', { p_token: token, p_name: name, p_rating: rating, p_comment: modal.querySelector('#srm-text').value });
      if (error) { err.textContent = error.message || 'No se pudo publicar tu reseña.'; err.hidden = false; send.disabled = false; send.textContent = 'Publicar mi reseña'; return; }
      card('<h2>¡Gracias por tu reseña!</h2><p>Ya está publicada y ayuda a otros viajeros a elegir mejor.</p><button type="button" class="srm-btn" data-close>Ver alojamientos</button>');
      modal.querySelector('[data-close]').addEventListener('click', () => { close(); if (onDone) onDone(); });
    });
  };
})();
