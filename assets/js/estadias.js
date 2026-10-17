/* Estadías temporales (estadias.html): pantalla dedicada a los alojamientos por noche, al estilo Airbnb / Booking.
 * Buscador (destino, llegada, salida, huéspedes), filtros, tarjetas con carrusel de fotos y favoritos, y una ficha a pantalla completa
 * con galería y un panel de reserva que calcula las noches y envía la consulta al anfitrión por WhatsApp.
 * No hay calendario de disponibilidad: las fechas solo sirven para el cálculo y para la consulta, y el anfitrión confirma la disponibilidad.
 * Calificaciones, reseñas, mapa y lugares cercanos viven en estadias-extras.js (window.StayExtras). Autónomo: usa el cliente global `supabaseClient`. */
(function () {
  'use strict';

  const WHATSAPP_GENERAL = '59177666205';
  const BOB_PER_USD = 6.96;
  const FAV_KEY = 'bastet-stay-favs';
  const DAY = 86400000;

  const $ = (id) => document.getElementById(id);
  const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const plural = (n, one, many) => (n === 1 ? one : many);

  /* ───────── Cabecera: menú, barra con vidrio y acceso de agentes (igual que en las demás páginas) ───────── */
  const navbar = document.querySelector('.navbar');
  const burger = document.querySelector('.navbar-burger');
  const mobilePanel = document.querySelector('.navbar-mobile-panel');
  function setMenuOpen(open) {
    mobilePanel.classList.toggle('is-open', open);
    navbar.classList.toggle('is-menu-open', open);
    document.body.classList.toggle('menu-open', open);
    updateNavbarScroll();
  }
  burger.addEventListener('click', () => setMenuOpen(!mobilePanel.classList.contains('is-open')));
  window.matchMedia('(min-width: 1080px)').addEventListener('change', (e) => { if (e.matches) setMenuOpen(false); });
  mobilePanel.querySelectorAll('a').forEach((a) => a.addEventListener('click', () => setMenuOpen(false)));

  const navLogo = navbar.querySelector('.navbar-logo-img');
  const LOGO_DARK = navLogo ? navLogo.getAttribute('src') : '';
  const LOGO_LIGHT = LOGO_DARK.replace('bastet-logo-horizontal-color.png', 'bastet-logo-horizontal-blanco.png');
  if (navLogo) { const pre = new Image(); pre.src = LOGO_LIGHT; }
  function updateNavbarScroll() {
    const scrolled = window.scrollY > 40;
    navbar.classList.toggle('is-scrolled', scrolled);
    if (navLogo && LOGO_LIGHT !== LOGO_DARK) navLogo.setAttribute('src', scrolled && !navbar.classList.contains('is-menu-open') ? LOGO_LIGHT : LOGO_DARK);
  }
  window.addEventListener('scroll', updateNavbarScroll, { passive: true });
  updateNavbarScroll();

  const agentBackdrop = $('agent-modal-backdrop');
  document.querySelectorAll('[data-agent-access]').forEach((btn) => btn.addEventListener('click', async () => {
    setMenuOpen(false);
    const { data: { session } } = await supabaseClient.auth.getSession();
    if (session) { window.location.href = 'admin/'; return; }
    agentBackdrop.classList.remove('hidden');
    $('agent-google').focus();
  }));
  const closeAgent = () => agentBackdrop.classList.add('hidden');
  $('agent-modal-close').addEventListener('click', closeAgent);
  agentBackdrop.addEventListener('click', (e) => { if (e.target === agentBackdrop) closeAgent(); });
  $('agent-google').addEventListener('click', async () => {
    const err = $('agent-login-error'); err.classList.add('hidden');
    const btn = $('agent-google'); btn.disabled = true;
    const { error } = await supabaseClient.auth.signInWithOAuth({ provider: 'google', options: { redirectTo: window.location.origin + '/admin/' } });
    if (error) { btn.disabled = false; err.textContent = 'No se pudo iniciar con Google: ' + error.message; err.classList.remove('hidden'); }
  });

  /* ───────── Datos ───────── */
  let stays = [];
  const state = { city: 'Todas', type: '', rooms: '', price: '', sort: 'rec', favsOnly: false, from: '', to: '', guests: 2 };
  let blocks = {};
  // ¿Hay un bloqueo que choque con las noches de [from, to)? Con `today` solo se mira ese día.
  const blockedBetween = (p, from, to, today) => (blocks[p.id] || []).some((b) => today ? (b.from_date <= from && (!b.to_date || b.to_date >= from)) : (b.from_date < to && (!b.to_date || b.to_date >= from)));
  let favs = new Set();
  try { favs = new Set(JSON.parse(localStorage.getItem(FAV_KEY) || '[]')); } catch (e) { favs = new Set(); }
  const saveFavs = () => { try { localStorage.setItem(FAV_KEY, JSON.stringify([...favs])); } catch (e) { /* sin almacenamiento: no se recuerdan */ } };

  const PUBLIC_PROPERTY_COLUMNS = 'id,title,location,address,price,currency,exchange_rate,area,rooms,baths,description,photos,whatsapp,owner_id,featured,featured_until,sort_order,status,created_at,code_number,property_type,operation,floors,has_garage,garage_spots,has_storage,pets_allowed,kids_allowed,expires_at,latitude,longitude';
  const PUBLIC_AGENT_COLUMNS = 'id,display_name,avatar_url,contact_whatsapp';

  async function load() {
    const fetchStays = (columns) => supabaseClient.from('properties').select(columns).eq('status', 'available').eq('operation', 'temporal')
      .or('expires_at.is.null,expires_at.gt.' + new Date().toISOString()).order('sort_order', { ascending: true });
    let res = await fetchStays(PUBLIC_PROPERTY_COLUMNS);
    // Si falta alguna columna (SQL de ubicación o de vencimiento sin correr), se reintenta sin ella
    if (res.error && res.error.code === '42703') res = await fetchStays(PUBLIC_PROPERTY_COLUMNS.replace(',latitude,longitude', ''));
    if (res.error && res.error.code === '42703') res = await supabaseClient.from('properties').select(PUBLIC_PROPERTY_COLUMNS.replace(',latitude,longitude', '').replace(',expires_at', '')).eq('status', 'available').eq('operation', 'temporal').order('sort_order', { ascending: true });
    stays = res.error ? [] : (res.data || []);
    const ids = [...new Set(stays.map((p) => p.owner_id).filter(Boolean))];
    if (ids.length) {
      const { data } = await supabaseClient.from('profiles').select(PUBLIC_AGENT_COLUMNS).in('id', ids);
      const by = {}; (data || []).forEach((a) => { by[a.id] = a; });
      stays.forEach((p) => { p.agent = by[p.owner_id] || null; });
    }
    favs = new Set([...favs].filter((id) => stays.some((p) => p.id === id)));
    if (window.StayExtras) await window.StayExtras.loadRatings(stays.map((p) => p.id));
    // Fechas no disponibles que marcó el anfitrión (sin el SQL no hay bloqueos y se muestra todo)
    blocks = {};
    if (stays.length) {
      const { data: bl, error: be } = await supabaseClient.rpc('stay_blocked_ranges', { p_ids: stays.map((p) => p.id) });
      if (!be) (bl || []).forEach((b) => { (blocks[b.property_id] = blocks[b.property_id] || []).push(b); });
    }
    stays = stays.filter((p) => !blockedBetween(p, todayIso(), todayIso(), true));
    fromUrl();
    buildCityOptions();
    buildTypeChips();
    syncControls();
    render();
    const open = new URLSearchParams(location.search).get('p');
    if (open) { const p = stays.find((x) => x.id === open || formatPropertyCode(x) === open); if (p) openDetail(p, false); }
    if (window.StayExtras) window.StayExtras.openReviewFromUrl(async () => { await window.StayExtras.loadRatings(stays.map((p) => p.id)); render(); });
  }

  /* ───────── Utilidades ───────── */
  const num = (v) => { const d = String(v ?? '').replace(/[^0-9]/g, ''); return d ? parseInt(d, 10) : null; };
  const nightlyUSD = (p) => { const n = num(p.price); return n === null ? null : (p.currency === 'BOB' ? n / BOB_PER_USD : n); };
  const roomsOf = (p) => { const m = String(p.rooms || '').match(/\d+/); return m ? parseInt(m[0], 10) : null; };
  const money = (n, currency) => { const s = Math.round(n).toString().replace(/\B(?=(\d{3})+(?!\d))/g, '.'); return currency === 'BOB' ? 'Bs.- ' + s : s + ' USD'; };
  const cityOf = (p) => (p.location || '').split(',')[0].trim();
  const fdate = (iso) => { const d = new Date(iso + 'T00:00:00'); return isNaN(d) ? '' : d.toLocaleDateString('es-BO', { day: '2-digit', month: 'short' }); };
  const nights = () => { if (!state.from || !state.to) return 0; const n = Math.round((new Date(state.to + 'T00:00:00') - new Date(state.from + 'T00:00:00')) / DAY); return n > 0 ? n : 0; };
  const todayIso = () => { const d = new Date(); d.setMinutes(d.getMinutes() - d.getTimezoneOffset()); return d.toISOString().slice(0, 10); };
  // «2 habitaciones · 1 baño · 50 m²»: los datos pueden venir solo con el número o ya con su texto
  const unit = (v, one, many) => { const t = String(v ?? '').trim(); if (!t) return ''; if (/^\d+$/.test(t)) return t + ' ' + plural(parseInt(t, 10), one, many); return /^\d+([.,]\d+)?$/.test(t) ? t + ' ' + many : t; };
  const factsOf = (p) => [unit(p.rooms, 'habitación', 'habitaciones'), unit(p.baths, 'baño', 'baños'), /^\d+([.,]\d+)?$/.test(String(p.area ?? '').trim()) ? p.area + ' m²' : String(p.area ?? '').trim()].filter(Boolean);

  const isFeatured = (p) => !!p.featured || (!!p.featured_until && new Date(p.featured_until) > new Date());
  const waPhone = (p) => { const d = String((p.agent && p.agent.contact_whatsapp) || p.whatsapp || '').replace(/[^0-9]/g, ''); return /^[67][0-9]{7}$/.test(d) ? '591' + d : (d || WHATSAPP_GENERAL); };
  const firstName = (p) => (p.agent && p.agent.display_name ? p.agent.display_name.trim().split(/\s+/)[0] : '');
  const track = (id, type) => { if (id) supabaseClient.from('property_events').insert({ property_id: id, event_type: type }).then(() => {}, () => {}); };

  function waLink(p) {
    const n = nights();
    const dates = n ? ' del ' + fdate(state.from) + ' al ' + fdate(state.to) + ' (' + n + ' ' + plural(n, 'noche', 'noches') + ')' : '';
    const msg = '[' + (formatPropertyCode(p) || 'Bastet') + '] Hola ' + (firstName(p) || 'Bastet') + ', quisiera reservar «' + p.title + '» en ' + p.location + dates +
      ' para ' + state.guests + ' ' + plural(state.guests, 'huésped', 'huéspedes') + '. ¿Está disponible?';
    return 'https://api.whatsapp.com/send?phone=' + waPhone(p) + '&text=' + encodeURIComponent(msg);
  }

  /* ───────── URL (se puede compartir una búsqueda) ───────── */
  function fromUrl() {
    const q = new URLSearchParams(location.search);
    if (q.get('ciudad') && BOLIVIA_CITIES.includes(q.get('ciudad'))) state.city = q.get('ciudad');
    const f = q.get('llegada'), t = q.get('salida');
    if (/^\d{4}-\d{2}-\d{2}$/.test(f || '') && f >= todayIso()) state.from = f;
    if (/^\d{4}-\d{2}-\d{2}$/.test(t || '') && t > state.from && state.from) state.to = t;
    const g = parseInt(q.get('huespedes'), 10); if (g >= 1 && g <= 16) state.guests = g;
  }
  function toUrl() {
    const q = new URLSearchParams();
    if (state.city !== 'Todas') q.set('ciudad', state.city);
    if (state.from) q.set('llegada', state.from);
    if (state.to) q.set('salida', state.to);
    if (state.guests !== 2) q.set('huespedes', state.guests);
    const open = document.body.dataset.open; if (open) q.set('p', open);
    history.replaceState(null, '', location.pathname + (q.toString() ? '?' + q.toString() : ''));
  }

  /* ───────── Buscador y filtros ───────── */
  function buildCityOptions() {
    const present = new Set(stays.map(cityOf));
    const sel = $('st-city'); sel.innerHTML = '<option value="Todas">Todas las ciudades</option>';
    BOLIVIA_CITIES.filter((c) => present.has(c)).forEach((c) => {
      const n = stays.filter((p) => cityOf(p) === c).length;
      sel.insertAdjacentHTML('beforeend', '<option value="' + esc(c) + '">' + esc(c) + ' (' + n + ')</option>');
    });
    if (state.city !== 'Todas' && !present.has(state.city)) state.city = 'Todas';
  }
  function buildTypeChips() {
    const types = [...new Set(stays.map((p) => p.property_type).filter(Boolean))];
    const box = $('st-types');
    box.innerHTML = '<button type="button" class="stays-chip" data-type="">Todos</button>' + types.map((t) => '<button type="button" class="stays-chip" data-type="' + esc(t) + '">' + esc(PROPERTY_TYPE_LABELS[t] || t) + '</button>').join('');
  }
  function syncControls() {
    $('st-city').value = state.city;
    const today = todayIso();
    $('st-from').min = today; $('st-to').min = state.from || today;
    $('st-from').value = state.from; $('st-to').value = state.to;
    $('st-guests').textContent = state.guests;
    $('st-types').querySelectorAll('.stays-chip').forEach((b) => { const on = b.dataset.type === state.type; b.classList.toggle('is-active', on); b.setAttribute('aria-pressed', String(on)); });
    $('st-rooms').value = state.rooms; $('st-price').value = state.price; $('st-sort').value = state.sort;
    $('st-favs').classList.toggle('is-active', state.favsOnly); $('st-favs').setAttribute('aria-pressed', String(state.favsOnly));
    const n = nights();
    $('st-date-hint').textContent = n ? n + ' ' + plural(n, 'noche', 'noches') + ' · del ' + fdate(state.from) + ' al ' + fdate(state.to) + '. El anfitrión confirma la disponibilidad y el precio final.'
      : 'Las fechas sirven para calcular tu estadía y para tu consulta: el anfitrión confirma la disponibilidad.';
  }

  $('st-city').addEventListener('change', (e) => { state.city = e.target.value; render(); toUrl(); });
  $('st-from').addEventListener('change', (e) => {
    state.from = e.target.value;
    if (state.to && state.to <= state.from) state.to = '';
    syncControls(); render(); toUrl();
    if (state.from && !state.to) $('st-to').focus();
  });
  $('st-to').addEventListener('change', (e) => { state.to = e.target.value; syncControls(); render(); toUrl(); });
  const setGuests = (d) => { state.guests = Math.min(16, Math.max(1, state.guests + d)); $('st-guests').textContent = state.guests; toUrl(); refreshBooking(); };
  $('st-guests-minus').addEventListener('click', () => setGuests(-1));
  $('st-guests-plus').addEventListener('click', () => setGuests(1));
  $('stays-search').addEventListener('submit', (e) => { e.preventDefault(); render(); document.querySelector('.stays-results').scrollIntoView({ behavior: 'smooth', block: 'start' }); });
  $('st-types').addEventListener('click', (e) => { const b = e.target.closest('.stays-chip'); if (!b) return; state.type = b.dataset.type; syncControls(); render(); });
  $('st-rooms').addEventListener('change', (e) => { state.rooms = e.target.value; render(); });
  $('st-price').addEventListener('change', (e) => { state.price = e.target.value; render(); });
  $('st-sort').addEventListener('change', (e) => { state.sort = e.target.value; render(); });
  $('st-favs').addEventListener('click', () => { state.favsOnly = !state.favsOnly; syncControls(); render(); });
  $('st-clear').addEventListener('click', () => { Object.assign(state, { city: 'Todas', type: '', rooms: '', price: '', sort: 'rec', favsOnly: false }); syncControls(); render(); toUrl(); });

  function filtered() {
    let list = stays.filter((p) => {
      if (state.city !== 'Todas' && cityOf(p) !== state.city) return false;
      if (state.type && p.property_type !== state.type) return false;
      if (state.rooms && (roomsOf(p) || 0) < Number(state.rooms)) return false;
      if (state.favsOnly && !favs.has(p.id)) return false;
      if (state.from && state.to && blockedBetween(p, state.from, state.to, false)) return false;
      if (state.price) {
        const [lo, hi] = state.price.split('-'); const v = nightlyUSD(p);
        if (v === null || v < Number(lo || 0) || (hi && v > Number(hi))) return false;
      }
      return true;
    });
    const idx = new Map(stays.map((p, i) => [p.id, i]));
    list.sort((a, b) => {
      if (state.sort === 'asc') return (nightlyUSD(a) ?? 1e12) - (nightlyUSD(b) ?? 1e12);
      if (state.sort === 'desc') return (nightlyUSD(b) ?? -1) - (nightlyUSD(a) ?? -1);
      if (state.sort === 'new') return new Date(b.created_at) - new Date(a.created_at);
      const X = window.StayExtras;
      if (state.sort === 'rating' && X) return (X.score(b.id) - X.score(a.id)) || (idx.get(a.id) - idx.get(b.id));
      // Recomendados: destacados primero y, dentro de cada grupo, los mejor calificados
      return (isFeatured(b) - isFeatured(a)) || (X ? X.score(b.id) - X.score(a.id) : 0) || (idx.get(a.id) - idx.get(b.id));
    });
    return list;
  }

  /* ───────── Tarjetas ───────── */
  const HEART = '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M12 20.5s-7.5-4.6-7.5-10A4.3 4.3 0 0 1 12 7.9a4.3 4.3 0 0 1 7.5 2.6c0 5.400-7.500 10-7.500 10z"/></svg>';
  const CHEV_L = '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M14.500 5.500L8 12l6.500 6.500"/></svg>';
  const CHEV_R = '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M9.500 5.500L16 12l-6.500 6.500"/></svg>';

  function priceBlock(p) {
    const n = nights(), base = num(p.price);
    if (base === null) return '<div class="stay-price">Consultar precio</div>';
    const nightly = '<b>' + money(base, p.currency) + '</b> <span>por noche</span>';
    return '<div class="stay-price">' + nightly + '</div>' +
      (n ? '<div class="stay-total">' + n + ' ' + plural(n, 'noche', 'noches') + ': <b>' + money(base * n, p.currency) + '</b> <span>(estimado)</span></div>' : '');
  }

  function ratingChip(p) {
    const X = window.StayExtras; if (!X || !X.hasReviews) return '';
    const r = X.of(p.id);
    return r ? '<span class="stay-rating" title="' + r.n + ' ' + plural(r.n, 'reseña', 'reseñas') + '"><i>★</i> ' + X.fmtAvg(r.avg) + ' <small>(' + r.n + ')</small></span>' : '<span class="stay-rating stay-rating--new">Nuevo</span>';
  }

  function card(p) {
    const photos = (p.photos && p.photos.length) ? p.photos : [];
    const facts = factsOf(p);
    const el = document.createElement('article');
    el.className = 'stay-card'; el.dataset.id = p.id; el.tabIndex = 0;
    el.setAttribute('aria-label', p.title);
    el.innerHTML =
      '<div class="stay-media">' +
        (photos.length
          ? '<div class="stay-slides">' + photos.map((u, i) => '<img src="' + esc(u) + '" alt="' + esc(p.title) + (photos.length > 1 ? ' — foto ' + (i + 1) : '') + '" loading="' + (i ? 'lazy' : 'eager') + '" draggable="false">').join('') + '</div>'
          : '<div class="stay-noimg">' + esc(p.title) + '</div>') +
        (isFeatured(p) ? '<span class="stay-badge">Destacada</span>' : (window.StayExtras && window.StayExtras.isTop(p.id) ? '<span class="stay-badge stay-badge--top">★ Mejor calificado</span>' : '')) +
        '<button type="button" class="stay-fav' + (favs.has(p.id) ? ' is-on' : '') + '" data-fav aria-label="Guardar en favoritos" aria-pressed="' + favs.has(p.id) + '">' + HEART + '</button>' +
        (photos.length > 1 ? '<button type="button" class="stay-arrow stay-arrow--prev" data-slide="-1" aria-label="Foto anterior">' + CHEV_L + '</button><button type="button" class="stay-arrow stay-arrow--next" data-slide="1" aria-label="Foto siguiente">' + CHEV_R + '</button>' +
          '<div class="stay-dots" aria-hidden="true">' + photos.slice(0, 7).map((_, i) => '<i' + (i === 0 ? ' class="is-on"' : '') + '></i>').join('') + '</div>' : '') +
      '</div>' +
      '<div class="stay-body">' +
        '<div class="stay-row"><span class="stay-place">' + esc(PROPERTY_TYPE_LABELS[p.property_type] || 'Alojamiento') + ' · ' + esc(p.location || '') + '</span>' + ratingChip(p) + '</div>' +
        '<h3 class="stay-name">' + esc(p.title) + '</h3>' +
        (facts.length ? '<p class="stay-facts">' + facts.map(esc).join(' · ') + '</p>' : '') +
        priceBlock(p) +
      '</div>';
    el.__p = p;
    return el;
  }

  // Botón «Más filtros» (solo celular): pliega el panel y muestra cuántos filtros hay activos
  const panel = $('st-filter-panel'), toggle = $('st-filters-toggle');
  function syncFiltersBadge() {
    const n = (state.rooms ? 1 : 0) + (state.price ? 1 : 0) + (state.sort !== 'rec' ? 1 : 0) + (state.favsOnly ? 1 : 0);
    $('st-filters-badge').textContent = n ? String(n) : '';
  }
  toggle.addEventListener('click', () => {
    const open = !panel.classList.contains('is-open');
    panel.classList.toggle('is-open', open);
    toggle.setAttribute('aria-expanded', String(open));
  });

  function render() {
    syncFiltersBadge();
    const list = filtered();
    const grid = $('st-grid');
    grid.innerHTML = '';
    const active = state.city !== 'Todas' || state.type || state.rooms || state.price || state.favsOnly;
    $('st-clear').classList.toggle('hidden', !active);
    const where = state.city !== 'Todas' ? ' en ' + state.city : '';
    $('st-count').textContent = stays.length ? list.length + ' ' + plural(list.length, 'alojamiento', 'alojamientos') + where : 'Estadías temporales';
    if (!list.length) {
      grid.innerHTML = '<div class="stays-empty"><h3>' + (stays.length ? 'No encontramos alojamientos con esos filtros' : 'Pronto tendremos alojamientos para ti') + '</h3><p>' +
        (stays.length ? 'Prueba con otras fechas, otra ciudad o quita algún filtro.' : 'Todavía no hay estadías temporales publicadas. Escríbenos y te ayudamos a encontrar dónde alojarte.') + '</p>' +
        '<a class="stays-cta-btn" target="_blank" rel="noopener" href="https://api.whatsapp.com/send?phone=' + WHATSAPP_GENERAL + '&text=' + encodeURIComponent('Hola Bastet, busco un alojamiento temporal.') + '">Escribir por WhatsApp</a></div>';
      return;
    }
    list.forEach((p) => grid.appendChild(card(p)));
  }

  const grid = $('st-grid');
  function slide(media, dir) {
    const box = media.querySelector('.stay-slides'); if (!box) return;
    box.scrollBy({ left: dir * box.clientWidth, behavior: 'smooth' });
  }
  grid.addEventListener('scroll', (e) => {
    const box = e.target; if (!box.classList || !box.classList.contains('stay-slides')) return;
    const i = Math.round(box.scrollLeft / Math.max(box.clientWidth, 1));
    box.parentElement.querySelectorAll('.stay-dots i').forEach((d, k) => d.classList.toggle('is-on', k === Math.min(i, 6)));
  }, true);
  grid.addEventListener('click', (e) => {
    const cardEl = e.target.closest('.stay-card'); if (!cardEl) return;
    const p = cardEl.__p;
    const fav = e.target.closest('[data-fav]');
    if (fav) { toggleFav(p.id); fav.classList.toggle('is-on', favs.has(p.id)); fav.setAttribute('aria-pressed', String(favs.has(p.id))); if (state.favsOnly) render(); return; }
    const arrow = e.target.closest('[data-slide]');
    if (arrow) { slide(cardEl.querySelector('.stay-media'), Number(arrow.dataset.slide)); return; }
    openDetail(p, true);
  });
  grid.addEventListener('keydown', (e) => { if ((e.key === 'Enter' || e.key === ' ') && e.target.classList.contains('stay-card')) { e.preventDefault(); openDetail(e.target.__p, true); } });
  function toggleFav(id) { if (favs.has(id)) favs.delete(id); else favs.add(id); saveFavs(); }

  /* ───────── Ficha a pantalla completa ───────── */
  const detail = $('stay-detail');
  let current = null;

  // Solo lo que el alojamiento SÍ ofrece, con iconos de línea
  const ic = (d) => '<svg viewBox="0 0 24 24" aria-hidden="true" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round">' + d + '</svg>';
  const OFFER_ICONS = {
    rooms: ic('<path d="M3 19V6M3 15h18v4M21 15v-3a3 3 0 0 0-3-3h-7v6"/><circle cx="7" cy="11.500" r="1.500"/>'),
    baths: ic('<path d="M4 12h16v2a5 5 0 0 1-5 5H9a5 5 0 0 1-5-5v-2zM6 12V6a2 2 0 0 1 3.500-1.300M7 19l-1 2M17 19l1 2"/>'),
    area: ic('<path d="M4 9V4h5M20 9V4h-5M4 15v5h5M20 15v5h-5"/>'),
    floors: ic('<path d="M4 20V9l8-5 8 5v11M4 20h16M9 20v-5h6v5"/>'),
    garage: ic('<path d="M3 11l2-5h14l2 5M3 11v6h18v-6M3 11h18M7 17v2M17 17v2"/><circle cx="7.500" cy="14" r=".6"/><circle cx="16.500" cy="14" r=".6"/>'),
    storage: ic('<rect x="4" y="4" width="16" height="16" rx="2"/><path d="M4 12h16M10 8h4M10 16h4"/>'),
    pets: ic('<circle cx="6" cy="10" r="1.800"/><circle cx="10" cy="6" r="1.800"/><circle cx="14" cy="6" r="1.800"/><circle cx="18" cy="10" r="1.800"/><path d="M12 11c-3 0-5 2.500-5 5 0 2 1.500 3 3 2.500 1-.3 1.500-.5 2-.5s1 .2 2 .5c1.500.5 3-.5 3-2.500 0-2.500-2-5-5-5z"/>'),
    kids: ic('<circle cx="12" cy="7" r="3"/><path d="M6 20v-2a6 6 0 0 1 12 0v2M9 14.500L12 17l3-2.500"/>'),
  };
  function offeredList(p) {
    const out = [];
    const [r, b, a] = [unit(p.rooms, 'habitación', 'habitaciones'), unit(p.baths, 'baño', 'baños'), /^\d+([.,]\d+)?$/.test(String(p.area ?? '').trim()) ? p.area + ' m²' : String(p.area ?? '').trim()];
    if (r && p.property_type !== 'terreno') out.push({ icon: OFFER_ICONS.rooms, text: r });
    if (b && p.property_type !== 'terreno') out.push({ icon: OFFER_ICONS.baths, text: b });
    if (a) out.push({ icon: OFFER_ICONS.area, text: a });
    if (p.property_type === 'terreno') return out;
    if (p.floors) out.push({ icon: OFFER_ICONS.floors, text: p.floors === 1 ? '1 planta' : p.floors + ' plantas' });
    if (p.has_garage === true) out.push({ icon: OFFER_ICONS.garage, text: p.garage_spots ? 'Garaje para ' + p.garage_spots + (p.garage_spots === 1 ? ' auto' : ' autos') : 'Garaje' });
    if (p.has_storage === true) out.push({ icon: OFFER_ICONS.storage, text: 'Baulera' });
    if (p.pets_allowed === true) out.push({ icon: OFFER_ICONS.pets, text: 'Se aceptan mascotas' });
    if (p.kids_allowed === true) out.push({ icon: OFFER_ICONS.kids, text: 'Se aceptan niños' });
    return out;
  }

  function openDetail(p, push) {
    current = p;
    const photos = (p.photos && p.photos.length) ? p.photos : [];
    const features = offeredList(p);
    const facts = factsOf(p);
    const host = p.agent && p.agent.display_name ? p.agent.display_name : 'Bastet';
    const gallery = photos.length
      ? '<div class="sd-gallery sd-gallery--' + Math.min(photos.length, 5) + '">' + photos.slice(0, 5).map((u, i) => '<button type="button" class="sd-photo" data-photo="' + i + '" aria-label="Ver foto ' + (i + 1) + '"><img src="' + esc(u) + '" alt="' + esc(p.title) + ' — foto ' + (i + 1) + '"></button>').join('') +
        (photos.length > 1 ? '<button type="button" class="sd-allphotos" data-photo="0">Mostrar las ' + photos.length + ' fotos</button>' : '') + '</div>'
      : '<div class="sd-gallery sd-gallery--0"><div class="stay-noimg">' + esc(p.title) + '</div></div>';
    detail.innerHTML =
      '<div class="sd-top"><button type="button" class="sd-back" data-close aria-label="Volver a los alojamientos">' + CHEV_L + '<span>Volver</span></button>' +
        '<div class="sd-actions"><button type="button" class="sd-share" data-share aria-label="Compartir"><svg viewBox="0 0 24 24" aria-hidden="true"><path d="M12 3v12M8 7l4-4 4 4M5 13v6h14v-6"/></svg><span>Compartir</span></button>' +
        '<button type="button" class="sd-save' + (favs.has(p.id) ? ' is-on' : '') + '" data-fav aria-pressed="' + favs.has(p.id) + '">' + HEART + '<span>Guardar</span></button></div></div>' +
      '<div class="sd-inner">' +
        '<h1 class="sd-title" id="sd-title">' + esc(p.title) + '</h1>' +
        '<p class="sd-place">' + esc(PROPERTY_TYPE_LABELS[p.property_type] || 'Alojamiento') + ' · ' + esc(p.location || '') + (p.address ? ' · ' + esc(p.address) : '') + (formatPropertyCode(p) ? ' · <span class="sd-code">' + esc(formatPropertyCode(p)) + '</span>' : '') + '</p>' +
        gallery +
        '<div class="sd-layout">' +
          '<div class="sd-main">' +
            '<div class="sd-host">' + (p.agent && p.agent.avatar_url ? '<img class="sd-avatar" src="' + esc(p.agent.avatar_url) + '" alt="">' : '<span class="sd-avatar sd-avatar--initial">' + esc(host.charAt(0).toUpperCase()) + '</span>') +
              '<div><h2>Anfitrión: ' + esc(host) + '</h2>' + (facts.length ? '<p>' + facts.map(esc).join(' · ') + '</p>' : '') + '</div></div>' +
            (p.description ? '<section class="sd-section"><h2>Sobre este alojamiento</h2><p class="sd-desc">' + esc(p.description).replace(/\n/g, '<br>') + '</p></section>' : '') +
            (features.length ? '<section class="sd-section"><h2>Lo que ofrece</h2><ul class="sd-offers">' + features.map((f) => '<li>' + f.icon + '<span>' + esc(f.text) + '</span></li>').join('') + '</ul></section>' : '') +
            '<section class="sd-section sd-note"><h2>Cómo reservar</h2><p>Elige tus fechas y toca «Consultar disponibilidad»: abrimos un WhatsApp con tu consulta lista para enviar al anfitrión. Él confirma la disponibilidad, el precio final y la forma de pago. No se cobra nada en este sitio.</p></section>' +
          '</div>' +
          '<aside class="sd-book" aria-label="Reserva"><div id="sd-booking"></div></aside>' +
        '</div>' +
      '</div>' +
      '<div class="sd-mobilebar" id="sd-mobilebar"></div>';
    detail.classList.remove('hidden'); document.body.classList.add('sd-open'); detail.scrollTop = 0;
    document.body.dataset.open = formatPropertyCode(p) || p.id;
    if (push) history.pushState({ stay: p.id }, '', location.href); toUrl();
    refreshBooking();
    if (window.StayExtras) window.StayExtras.mount(p, detail);
    detail.querySelector('.sd-back').focus({ preventScroll: true });
    track(p.id, 'view');
  }

  function refreshBooking() {
    const p = current; const box = $('sd-booking'); if (!p || !box) return;
    const n = nights(), base = num(p.price), today = todayIso();
    box.innerHTML =
      '<div class="sd-price">' + (base !== null ? '<b>' + money(base, p.currency) + '</b> <span>por noche</span>' : '<b>Consultar precio</b>') + '</div>' +
      '<div class="sd-dates">' +
        '<label><span>Llegada</span><input type="date" id="sd-from" min="' + today + '" value="' + esc(state.from) + '"></label>' +
        '<label><span>Salida</span><input type="date" id="sd-to" min="' + esc(state.from || today) + '" value="' + esc(state.to) + '"></label>' +
        '<div class="sd-guests"><span>Huéspedes</span><div class="stays-stepper"><button type="button" data-g="-1" aria-label="Menos huéspedes">−</button><output>' + state.guests + '</output><button type="button" data-g="1" aria-label="Más huéspedes">+</button></div></div>' +
      '</div>' +
      (n && base !== null ? '<ul class="sd-sum"><li><span>' + money(base, p.currency) + ' × ' + n + ' ' + plural(n, 'noche', 'noches') + '</span><b>' + money(base * n, p.currency) + '</b></li><li class="sd-sum-total"><span>Total estimado</span><b>' + money(base * n, p.currency) + '</b></li></ul><p class="sd-fine">Estimado: el anfitrión confirma el precio final y la disponibilidad.</p>'
        : '<p class="sd-fine">Elige llegada y salida para calcular tu estadía.</p>') +
      '<a class="sd-cta" id="sd-wa" target="_blank" rel="noopener" href="' + esc(waLink(p)) + '">Consultar disponibilidad por WhatsApp</a>';
    const mb = $('sd-mobilebar');
    if (mb) mb.innerHTML = '<div>' + (base !== null ? '<b>' + money(base, p.currency) + '</b> <span>por noche</span>' : '<b>Consultar precio</b>') + (n && base !== null ? '<small>' + n + ' ' + plural(n, 'noche', 'noches') + ': ' + money(base * n, p.currency) + '</small>' : '') + '</div><a class="sd-cta" target="_blank" rel="noopener" href="' + esc(waLink(p)) + '" data-wa>Consultar</a>';
  }

  detail.addEventListener('click', (e) => {
    if (e.target.closest('[data-close]')) { closeDetail(true); return; }
    const go = e.target.closest('[data-goto]'); if (go) { e.preventDefault(); const t = $(go.dataset.goto); if (t) t.scrollIntoView({ behavior: 'smooth', block: 'start' }); return; }
    if (e.target.closest('[data-fav]') && current) { toggleFav(current.id); e.target.closest('[data-fav]').classList.toggle('is-on', favs.has(current.id)); const cardFav = grid.querySelector('.stay-card[data-id="' + current.id + '"] [data-fav]'); if (cardFav) cardFav.classList.toggle('is-on', favs.has(current.id)); if (state.favsOnly) render(); return; }
    if (e.target.closest('[data-share]') && current) { shareStay(); return; }
    const ph = e.target.closest('[data-photo]'); if (ph) { openLightbox(Number(ph.dataset.photo)); return; }
    const g = e.target.closest('[data-g]'); if (g) { state.guests = Math.min(16, Math.max(1, state.guests + Number(g.dataset.g))); $('st-guests').textContent = state.guests; toUrl(); refreshBooking(); return; }
    if (e.target.closest('#sd-wa, [data-wa]') && current) track(current.id, 'whatsapp_click');
  });
  detail.addEventListener('change', (e) => {
    if (e.target.id === 'sd-from') { state.from = e.target.value; if (state.to && state.to <= state.from) state.to = ''; syncControls(); render(); toUrl(); refreshBooking(); if (state.from && !state.to) { const t = $('sd-to'); if (t) t.focus(); } }
    if (e.target.id === 'sd-to') { state.to = e.target.value; syncControls(); render(); toUrl(); refreshBooking(); }
  });

  async function shareStay() {
    const url = location.origin + location.pathname + '?p=' + encodeURIComponent(formatPropertyCode(current) || current.id);
    try {
      if (navigator.share) await navigator.share({ title: current.title, text: current.title + ' — Bastet', url });
      else { await navigator.clipboard.writeText(url); const b = detail.querySelector('[data-share] span'); if (b) { b.textContent = 'Enlace copiado'; setTimeout(() => { b.textContent = 'Compartir'; }, 2000); } }
    } catch (e) { /* el usuario canceló */ }
  }

  function closeDetail(fromUi) {
    if (detail.classList.contains('hidden')) return;
    detail.classList.add('hidden'); document.body.classList.remove('sd-open'); delete document.body.dataset.open; current = null; closeLightbox();
    if (fromUi && history.state && history.state.stay) history.back(); else toUrl();
    toUrl();
  }
  window.addEventListener('popstate', () => { if (!detail.classList.contains('hidden')) closeDetail(false); });

  /* ───────── Visor de fotos ───────── */
  const lb = $('stay-lightbox'); let lbIndex = 0;
  function openLightbox(i) {
    const photos = (current && current.photos) || []; if (!photos.length) return;
    lbIndex = Math.min(Math.max(i, 0), photos.length - 1);
    lb.innerHTML = '<button type="button" class="lb-close" data-lb="close" aria-label="Cerrar">✕</button>' +
      (photos.length > 1 ? '<button type="button" class="lb-nav lb-prev" data-lb="-1" aria-label="Anterior">' + CHEV_L + '</button><button type="button" class="lb-nav lb-next" data-lb="1" aria-label="Siguiente">' + CHEV_R + '</button>' : '') +
      '<img id="lb-img" alt=""><p class="lb-count" id="lb-count"></p>';
    lb.classList.remove('hidden'); showLb();
  }
  function showLb() { const photos = current.photos; $('lb-img').src = photos[lbIndex]; $('lb-img').alt = current.title + ' — foto ' + (lbIndex + 1); $('lb-count').textContent = (lbIndex + 1) + ' / ' + photos.length; }
  function closeLightbox() { lb.classList.add('hidden'); lb.innerHTML = ''; }
  lb.addEventListener('click', (e) => {
    const b = e.target.closest('[data-lb]');
    if (!b) { if (e.target === lb) closeLightbox(); return; }
    if (b.dataset.lb === 'close') { closeLightbox(); return; }
    const n = current.photos.length; lbIndex = (lbIndex + Number(b.dataset.lb) + n) % n; showLb();
  });
  document.addEventListener('keydown', (e) => {
    if (!lb.classList.contains('hidden')) {
      if (e.key === 'Escape') closeLightbox();
      else if (e.key === 'ArrowRight' || e.key === 'ArrowLeft') { const n = current.photos.length; lbIndex = (lbIndex + (e.key === 'ArrowRight' ? 1 : -1) + n) % n; showLb(); }
      return;
    }
    if (e.key === 'Escape' && !detail.classList.contains('hidden')) closeDetail(true);
  });

  load();
})();
