/* Propiedades: favoritos (corazón en cada tarjeta) y vista de mapa con precios (marketplace.html).
 *  · Favoritos: se guardan en este navegador (localStorage). Si la persona inicia sesión, además se guardan en su cuenta (tabla
 *    property_favorites, supabase/property-favorites.sql) y se unen con los de otros dispositivos; sin ese SQL siguen solo locales.
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
  /* Cuenta: con sesión iniciada cada cambio también se guarda en property_favorites. Todo es «mejor esfuerzo»: si la tabla no existe
   * (SQL sin correr) o no hay red, los favoritos siguen funcionando en este navegador. */
  const USER_KEY = 'bastet-prop-favs-user';
  let uid = null;
  const sb = () => (typeof supabaseClient !== 'undefined' ? supabaseClient : null);
  const quiet = (q) => { try { Promise.resolve(q).then(() => {}, () => {}); } catch (e) { /* sin red */ } };
  const notify = () => listeners.forEach((f) => f());
  const MAX_FAVS = 30; // mismo tope que la cuenta (supabase/property-favorites.sql)
  let toastTimer = null;
  function toast(msg) {
    let t = document.getElementById('pf-toast');
    if (!t) { t = document.createElement('div'); t.id = 'pf-toast'; t.className = 'pf-toast'; t.setAttribute('role', 'status'); t.setAttribute('aria-live', 'polite'); document.body.appendChild(t); }
    t.textContent = msg; t.classList.add('is-on');
    clearTimeout(toastTimer); toastTimer = setTimeout(() => t.classList.remove('is-on'), 4000);
  }
  function remote(add, id) {
    const c = sb(); if (!uid || !c) return;
    quiet(add ? c.from('property_favorites').upsert({ property_id: id }, { onConflict: 'user_id,property_id', ignoreDuplicates: true })
      : c.from('property_favorites').delete().eq('property_id', id));
  }
  async function pull(user) {
    const c = sb(); if (!c) return;
    try {
      const { data, error } = await c.from('property_favorites').select('property_id');
      if (error || !data) return;
      const remoteIds = new Set(data.map((r) => r.property_id));
      const onlyLocal = [...favs].filter((id) => !remoteIds.has(id));
      if (onlyLocal.length) {
        const rows = onlyLocal.map((id) => ({ property_id: id }));
        const up = await c.from('property_favorites').upsert(rows, { onConflict: 'user_id,property_id', ignoreDuplicates: true });
        // una propiedad que ya no existe hace fallar el lote: se reintenta una por una
        if (up.error) for (const r of rows) await c.from('property_favorites').upsert(r, { onConflict: 'user_id,property_id', ignoreDuplicates: true });
      }
      const before = favs.size;
      remoteIds.forEach((id) => favs.add(id));
      try { localStorage.setItem(USER_KEY, user.id); } catch (e) { /* sin almacenamiento */ }
      save();
      if (favs.size !== before) notify();
    } catch (e) { /* sin la tabla o sin red: quedan los locales */ }
  }
  function onSession(session) {
    const user = session && session.user;
    if (user) { if (uid !== user.id) { uid = user.id; setTimeout(() => pull(user), 0); } return; }
    uid = null;
  }
  function init() {
    const c = sb(); if (!c || !c.auth) return;
    c.auth.getSession().then(({ data }) => onSession(data && data.session)).catch(() => {});
    c.auth.onAuthStateChange((event, session) => {
      if (event === 'SIGNED_OUT') {
        // en un equipo compartido no se deja a la vista lo que guardó la cuenta que salió
        let mine = null; try { mine = localStorage.getItem(USER_KEY); } catch (e) { /* nada */ }
        uid = null;
        if (mine) { favs = new Set(); try { localStorage.removeItem(USER_KEY); } catch (e) { /* nada */ } save(); notify(); }
        return;
      }
      onSession(session);
    });
  }

  window.PropFavs = {
    has: (id) => favs.has(id),
    toggle(id) {
      const on = !favs.has(id);
      if (on && favs.size >= MAX_FAVS) { toast('Llegaste al máximo de ' + MAX_FAVS + ' favoritos. Quita alguno para guardar otro.'); return false; }
      if (on) favs.add(id); else favs.delete(id); save(); remote(on, id); notify(); return on; },
    ids: () => [...favs],
    // Quita de la vista los guardados que ya no existen (propiedad vendida o vencida); en la cuenta se borran solos si la propiedad se elimina
    prune(validIds) { const ok = new Set(validIds); let ch = false; favs.forEach((id) => { if (!ok.has(id)) { favs.delete(id); ch = true; } }); if (ch) save(); },
    onChange: (f) => listeners.push(f),
    signedIn: () => !!uid,
  };
  init();

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

  // Mapa pequeño de la ficha: pin si la ubicación es exacta; si no, un círculo con la zona aproximada de la ciudad
  async function mini(el, p) {
    const c = coordsOf(p);
    if (!c) { el.innerHTML = ''; return null; }
    let L;
    try { L = await loadLeaflet(); } catch (e) { el.innerHTML = '<p class="pm-error">No pudimos cargar el mapa.</p>'; return c; }
    if (!document.body.contains(el)) return c;
    el.innerHTML = '';
    const m = L.map(el, { scrollWheelZoom: false }).setView([c.lat, c.lng], c.exact ? 16 : 13);
    L.tileLayer('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png', { attribution: '&copy; OpenStreetMap', maxZoom: 19 }).addTo(m);
    if (c.exact) L.marker([c.lat, c.lng]).addTo(m);
    else L.circle([c.lat, c.lng], { radius: 1500, color: '#3D4C3A', weight: 1.5, fillColor: '#3D4C3A', fillOpacity: .12 }).addTo(m);
    setTimeout(() => m.invalidateSize(), 250);
    return c;
  }

  window.PropMap = { render, mini };
})();
