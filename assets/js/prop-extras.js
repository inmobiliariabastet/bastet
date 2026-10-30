/* Propiedades: favoritos (corazón en cada tarjeta) y vista de mapa con precios (marketplace.html).
 *  · Favoritos: se guardan en este navegador (localStorage). Sincronizarlos con la cuenta queda para una fase posterior (pide SQL).
 *  · Mapa: Leaflet + OpenStreetMap (se carga solo al abrir la vista Mapa). Usa latitude/longitude de la propiedad cuando existen;
 *    si faltan, coloca el pin en el centro de su ciudad con un pequeño desplazamiento fijo y lo avisa («ubicación aproximada»).
 * Autónomo: lo usa main.js como window.PropFavs / window.PropMap. */
(function () {
  'use strict';

  /* ───────── Favoritos ───────── */
  const KEY = 'bastet-prop-favs';
  let favs = new Set();
  try { favs = new Set(JSON.parse(localStorage.getItem(KEY) || '[]')); } catch (e) { favs = new Set(); }
  const listeners = [];
  const save = () => { try { localStorage.setItem(KEY, JSON.stringify([...favs])); } catch (e) { /* sin almacenamiento: no se recuerdan */ } };
  window.PropFavs = {
    has: (id) => favs.has(id),
    toggle(id) { if (favs.has(id)) favs.delete(id); else favs.add(id); save(); listeners.forEach((f) => f()); return favs.has(id); },
    ids: () => [...favs],
    // Quita los guardados que ya no existen (propiedad vendida o vencida)
    prune(validIds) { const ok = new Set(validIds); let ch = false; favs.forEach((id) => { if (!ok.has(id)) { favs.delete(id); ch = true; } }); if (ch) save(); },
    onChange: (f) => listeners.push(f),
  };

  /* ───────── Mapa ───────── */
  const LEAFLET_CSS = 'https://cdnjs.cloudflare.com/ajax/libs/leaflet/1.9.4/leaflet.min.css';
  const LEAFLET_JS = 'https://cdnjs.cloudflare.com/ajax/libs/leaflet/1.9.4/leaflet.min.js';
  const CITY_CENTER = {
    'La Paz': [-16.4897, -68.1193], 'El Alto': [-16.5047, -68.1633], 'Santa Cruz de la Sierra': [-17.7833, -63.1821],
    'Cochabamba': [-17.3895, -66.1568], 'Sucre': [-19.0196, -65.2619], 'Oruro': [-17.9647, -67.106], 'Potosí': [-19.5836, -65.7531],
    'Tarija': [-21.5355, -64.7296], 'Trinidad': [-14.8333, -64.9], 'Cobija': [-11.0267, -68.7692],
  };
  const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const numOrNull = (v) => { if (v === null || v === undefined || v === '') return null; const n = Number(v); return Number.isFinite(n) ? n : null; };
  const hash = (s) => { let h = 0; for (let i = 0; i < s.length; i++) h = (h * 31 + s.charCodeAt(i)) | 0; return h; };

  function loadLeaflet() {
    if (window.L) return Promise.resolve(window.L);
    return new Promise((resolve, reject) => {
      const css = document.createElement('link'); css.rel = 'stylesheet'; css.href = LEAFLET_CSS; document.head.appendChild(css);
      const js = document.createElement('script'); js.src = LEAFLET_JS;
      js.onload = () => resolve(window.L); js.onerror = () => reject(new Error('Leaflet'));
      document.head.appendChild(js);
    });
  }

  function coordsOf(p) {
    const lat = numOrNull(p.latitude), lng = numOrNull(p.longitude);
    if (lat !== null && lng !== null) return { lat, lng, exact: true };
    const city = String(p.location || '').split(',')[0].trim();
    const c = CITY_CENTER[city]; if (!c) return null;
    const h = hash(String(p.id));
    return { lat: c[0] + (((h % 1000) / 1000) - 0.5) * 0.03, lng: c[1] + ((((h >> 10) % 1000) / 1000) - 0.5) * 0.03, exact: false };
  }
  function pinLabel(p) {
    const d = String(p.price || '').replace(/[^0-9]/g, '');
    if (!d) return 'Consultar';
    const n = Number(d);
    const short = n >= 100000 ? Math.round(n / 1000) + 'k' : n.toLocaleString('es-BO');
    return (p.currency === 'BOB' ? 'Bs ' : '$us ') + short + (p.operation === 'temporal' ? '/día' : '');
  }

  let map = null, layer = null, wrap = null;

  function ensureWrap() {
    if (wrap) return wrap;
    wrap = document.getElementById('prop-map-wrap');
    return wrap;
  }

  async function render(list, onOpen) {
    const w = ensureWrap(); if (!w) return;
    const box = w.querySelector('#prop-map'), note = w.querySelector('#prop-map-note'), card = w.querySelector('#prop-map-card');
    card.classList.add('hidden'); card.innerHTML = '';
    const pts = list.map((p) => ({ p, c: coordsOf(p) })).filter((x) => x.c);
    const approx = pts.filter((x) => !x.c.exact).length;
    note.textContent = !list.length ? 'No hay propiedades con estos filtros.' :
      (approx ? approx + ' ' + (approx === 1 ? 'propiedad aparece' : 'propiedades aparecen') + ' en el centro de su ciudad (ubicación aproximada).' : '');
    let L;
    try { L = await loadLeaflet(); } catch (e) { box.innerHTML = '<p class="pm-error">No pudimos cargar el mapa. Revisa tu conexión.</p>'; return; }
    if (!map) {
      box.innerHTML = '';
      map = L.map(box, { scrollWheelZoom: false }).setView([-16.5, -64.7], 5);
      L.tileLayer('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png', { attribution: '&copy; OpenStreetMap', maxZoom: 19 }).addTo(map);
      layer = L.layerGroup().addTo(map);
      map.on('click', () => { card.classList.add('hidden'); card.innerHTML = ''; layer.eachLayer((m) => m.getElement && m.getElement() && m.getElement().classList.remove('is-sel')); });
    }
    layer.clearLayers();
    const bounds = [];
    pts.forEach(({ p, c }) => {
      const icon = L.divIcon({ className: 'pm-icon', html: '<span class="pm-pin' + (c.exact ? '' : ' is-approx') + '">' + esc(pinLabel(p)) + '</span>', iconSize: null });
      const m = L.marker([c.lat, c.lng], { icon, keyboard: true, title: p.title }).addTo(layer);
      m.on('click', () => {
        layer.eachLayer((x) => x.getElement && x.getElement() && x.getElement().classList.remove('is-sel'));
        if (m.getElement()) m.getElement().classList.add('is-sel');
        const photo = (p.photos && p.photos[0]) || '';
        card.innerHTML = '<button type="button" class="pm-card-body">' +
          (photo ? '<img src="' + esc(photo) + '" alt="" loading="lazy">' : '<span class="pm-card-noimg"></span>') +
          '<span class="pm-card-text"><b>' + esc(pinLabel(p)) + '</b><span>' + esc(p.title) + '</span><small>' + esc(p.location || '') + '</small></span></button>';
        card.classList.remove('hidden');
        card.querySelector('button').onclick = () => onOpen && onOpen(p);
      });
      bounds.push([c.lat, c.lng]);
    });
    setTimeout(() => {
      map.invalidateSize();
      if (bounds.length === 1) map.setView(bounds[0], 15);
      else if (bounds.length) map.fitBounds(bounds, { padding: [40, 40], maxZoom: 15 });
    }, 60);
  }

  window.PropMap = { render };
})();
