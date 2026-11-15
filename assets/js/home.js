/* Inicio de bastet.uno (index.html): buscador con cuatro modos (comprar, alquilar, anticrético, estadías por noche), filas de inmuebles y
 * estadías estilo carrusel, botón para registrarse como anfitrión y testimonios.
 *  · Buscador: arma el enlace a marketplace.html (op, ciudad, tipo) o a estadias.html (ciudad, llegada, salida, huespedes).
 *  · Filas: main.js carga las propiedades y llama a window.HomeFeed.render(lista); cada tarjeta abre la ficha en marketplace.html?p= o estadias.html?p=.
 *  · Anfitrión: el botón lo maneja assets/js/host-signup.js (todas las páginas públicas).
 *  · Testimonios: tabla testimonials (activos, por orden), uno grande que rota solo y una tira para elegir. */
(function () {
  'use strict';
  const esc = (s) => String(s == null ? '' : s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const reduced = window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  const today = () => new Date(Date.now() - 4 * 3600 * 1000).toISOString().slice(0, 10);   // hora de Bolivia (UTC-4)
  const addDays = (iso, n) => { const d = new Date(iso + 'T12:00:00'); d.setDate(d.getDate() + n); return d.toISOString().slice(0, 10); };

  /* ───────── Buscador ───────── */
  const form = document.getElementById('home-search');
  if (form) {
    const tabs = [...form.querySelectorAll('.hm-tab')];
    const from = form.elements.llegada, to = form.elements.salida;
    from.min = today(); to.min = addDays(today(), 1);
    from.addEventListener('change', () => {
      to.min = addDays(from.value || today(), 1);
      if (to.value && to.value <= (from.value || '')) to.value = '';
      if (from.value && !to.value) to.value = addDays(from.value, 1);
    });
    const setMode = (mode) => {
      form.dataset.mode = mode;
      tabs.forEach((t) => { const on = t.dataset.mode === mode; t.classList.toggle('is-active', on); t.setAttribute('aria-selected', on ? 'true' : 'false'); });
    };
    tabs.forEach((t) => t.addEventListener('click', () => setMode(t.dataset.mode)));
    form.addEventListener('submit', (e) => {
      e.preventDefault();
      const mode = form.dataset.mode, q = new URLSearchParams(), city = form.elements.ciudad.value;
      if (city) q.set('ciudad', city);
      if (mode === 'temporal') {
        if (from.value) q.set('llegada', from.value);
        if (from.value && to.value) q.set('salida', to.value);
        const g = form.elements.huespedes.value; if (g && g !== '2') q.set('huespedes', g);
        location.href = 'estadias.html' + (q.toString() ? '?' + q.toString() : '');
        return;
      }
      q.set('op', mode);
      if (form.elements.tipo.value) q.set('tipo', form.elements.tipo.value);
      location.href = 'marketplace.html?' + q.toString();
    });
  }

  /* ───────── Filas de inmuebles y estadías ───────── */
  const TYPE = { casa: 'Casa', departamento: 'Departamento', habitacion: 'Habitación', terreno: 'Terreno' };
  const cityOf = (p) => String(p.location || '').split(',')[0].trim();
  const codeOf = (p) => (p.code_number ? 'BST-' + p.code_number : p.id);
  const price = (p) => {
    const d = String(p.price || '').replace(/[^0-9]/g, '');
    if (!d) return '';
    return (p.currency === 'BOB' ? 'Bs ' + d.replace(/\B(?=(\d{3})+(?!\d))/g, '.') : d.replace(/\B(?=(\d{3})+(?!\d))/g, '.') + ' USD');
  };
  const heart = '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M12 20.500s-7.500-4.600-9.200-9.300C1.700 8 3.500 4.800 6.800 4.800c2 0 3.500 1.100 5.200 3.100 1.700-2 3.200-3.100 5.200-3.100 3.300 0 5.100 3.200 4 6.400-1.700 4.700-9.200 9.300-9.200 9.300z"/></svg>';

  function card(p, X) {
    const stay = p.operation === 'temporal';
    const photo = (p.photos && p.photos[0]) || '';
    const r = stay && X ? X.of(p.id) : null;
    const url = (stay ? 'estadias.html' : 'marketplace.html') + '?p=' + encodeURIComponent(codeOf(p));
    const fav = window.PropFavs && window.PropFavs.has(p.id);
    const badge = p.featured ? 'Destacada' : (p.verified ? 'Verificada' : '');
    return '<article class="hm-card"><a class="hm-card-link" href="' + esc(url) + '">' +
      '<div class="hm-card-photo">' + (photo ? '<img ' + window.imgThumbAttrs(photo, 640) + ' alt="" loading="lazy" decoding="async">' : '') +
      (badge ? '<span class="hm-badge">' + esc(badge) + '</span>' : '') + '</div>' +
      '<div class="hm-card-text"><div class="hm-card-row"><h3>' + esc(p.title) + '</h3>' + (r ? '<span class="hm-rate">★ ' + esc(String(r.avg.toFixed(1)).replace('.', ',')) + '</span>' : '') + '</div>' +
      '<p class="hm-card-meta">' + esc([TYPE[p.property_type], cityOf(p)].filter(Boolean).join(' en ')) + '</p>' +
      '<p class="hm-card-price"><b>' + esc(price(p)) + '</b>' + (stay ? ' por noche' : '') + '</p></div></a>' +
      '<button type="button" class="hm-heart' + (fav ? ' is-on' : '') + '" data-fav="' + esc(p.id) + '" aria-pressed="' + (fav ? 'true' : 'false') + '" aria-label="Guardar ' + esc(p.title) + '">' + heart + '</button></article>';
  }

  function row(title, list, moreHref, X) {
    if (!list.length) return '';
    return '<section class="hm-row"><div class="hm-row-head"><h2>' + esc(title) + '</h2>' +
      '<div class="hm-row-ctrl"><a class="hm-more" href="' + esc(moreHref) + '">Ver todas</a><button type="button" class="hm-arrow" data-dir="-1" aria-label="Anteriores"><svg viewBox="0 0 24 24" aria-hidden="true"><path d="M15 5l-7 7 7 7"/></svg></button><button type="button" class="hm-arrow" data-dir="1" aria-label="Siguientes"><svg viewBox="0 0 24 24" aria-hidden="true"><path d="M9 5l7 7-7 7"/></svg></button></div></div>' +
      '<div class="hm-rail" tabindex="0">' + list.slice(0, 14).map((p) => card(p, X)).join('') + '</div></section>';
  }

  const byFeatured = (a, b) => (b.featured ? 1 : 0) - (a.featured ? 1 : 0);

  async function render(list) {
    const host = document.getElementById('hm-feed'); if (!host) return;
    const all = (list || []).slice();
    const X = window.StayExtras || null;
    const stays = all.filter((p) => p.operation === 'temporal').sort(byFeatured);
    if (X && stays.length) { try { await X.loadRatings(stays.map((p) => p.id)); } catch (e) { /* sin calificaciones: se omite la estrella */ } }
    const of = (op) => all.filter((p) => (p.operation || 'venta') === op).sort(byFeatured);
    // Ciudades con más estadías: una fila por cada una, como «cerca de ti»
    const counts = {}; stays.forEach((p) => { const c = cityOf(p); if (c) counts[c] = (counts[c] || 0) + 1; });
    const topCities = Object.keys(counts).sort((a, b) => counts[b] - counts[a]).slice(0, 2).filter((c) => counts[c] >= 2);
    let html = row('Estadías por noche', stays, 'estadias.html', X);
    topCities.forEach((c) => { html += row('Estadías en ' + c, stays.filter((p) => cityOf(p) === c), 'estadias.html?ciudad=' + encodeURIComponent(c), X); });
    html += row('Inmuebles en venta', of('venta'), 'marketplace.html?op=venta', X);
    html += row('En alquiler', of('alquiler'), 'marketplace.html?op=alquiler', X);
    html += row('En anticrético', of('anticretico'), 'marketplace.html?op=anticretico', X);
    host.innerHTML = html || '<p class="hm-loading">Pronto verás aquí inmuebles y estadías. <a href="marketplace.html">Explorar propiedades</a></p>';
  }
  window.HomeFeed = { render };

  const feed = document.getElementById('hm-feed');
  if (feed) {
    feed.addEventListener('click', (e) => {
      const arrow = e.target.closest('.hm-arrow');
      if (arrow) {
        const rail = arrow.closest('.hm-row').querySelector('.hm-rail');
        rail.scrollBy({ left: Number(arrow.dataset.dir) * rail.clientWidth * 0.85, behavior: reduced ? 'auto' : 'smooth' });
        return;
      }
      const h = e.target.closest('.hm-heart');
      if (h && window.PropFavs) {
        e.preventDefault();
        const on = window.PropFavs.toggle(h.dataset.fav);
        h.classList.toggle('is-on', !!on); h.setAttribute('aria-pressed', on ? 'true' : 'false');
      }
    });
  }

  /* ───────── Testimonios ───────── */
  const stage = document.getElementById('hm-testi');
  async function loadTesti() {
    if (!stage || typeof supabaseClient === 'undefined') return;
    const { data, error } = await supabaseClient.from('testimonials').select('*').eq('is_active', true).order('sort_order', { ascending: true });
    const list = (!error && data) ? data.filter((t) => t.quote) : [];
    if (!list.length) { const sec = stage.closest('.hm-testi'); if (sec) sec.remove(); return; }
    let i = 0, timer = null;
    const avatar = (t, cls) => t.photo_url ? '<img class="' + cls + '" src="' + esc(t.photo_url) + '" alt="' + esc(t.name) + '" loading="lazy">' : '<span class="' + cls + ' hm-avatar-ph">' + esc((t.name || '?').trim().charAt(0).toUpperCase()) + '</span>';
    stage.innerHTML = '<figure class="hm-quote" aria-live="polite"></figure>' +
      '<div class="hm-testi-nav"><div class="hm-people" role="tablist" aria-label="Elegir testimonio">' +
        list.map((t, k) => '<button type="button" role="tab" class="hm-person" data-k="' + k + '" aria-label="' + esc(t.name) + '">' + avatar(t, 'hm-person-img') + '</button>').join('') + '</div>' +
      '<div class="hm-row-ctrl"><button type="button" class="hm-arrow hm-arrow--light" data-t="-1" aria-label="Anterior"><svg viewBox="0 0 24 24" aria-hidden="true"><path d="M15 5l-7 7 7 7"/></svg></button><button type="button" class="hm-arrow hm-arrow--light" data-t="1" aria-label="Siguiente"><svg viewBox="0 0 24 24" aria-hidden="true"><path d="M9 5l7 7-7 7"/></svg></button></div></div>';
    const fig = stage.querySelector('.hm-quote'), people = [...stage.querySelectorAll('.hm-person')];
    const show = (k) => {
      i = (k + list.length) % list.length; const t = list[i];
      fig.innerHTML = '<blockquote><p>' + esc(t.quote) + '</p></blockquote><figcaption>' + avatar(t, 'hm-quote-img') + '<span><b>' + esc(t.name) + '</b>' + (t.role_label ? '<small>' + esc(t.role_label) + '</small>' : '') + '</span></figcaption>';
      people.forEach((b, n) => { b.classList.toggle('is-on', n === i); b.setAttribute('aria-selected', n === i ? 'true' : 'false'); });
    };
    const restart = () => { clearInterval(timer); if (!reduced && list.length > 1) timer = setInterval(() => show(i + 1), 8000); };
    stage.addEventListener('click', (e) => {
      const p = e.target.closest('.hm-person'), a = e.target.closest('[data-t]');
      if (p) show(Number(p.dataset.k)); else if (a) show(i + Number(a.dataset.t)); else return;
      restart();
    });
    stage.addEventListener('mouseenter', () => clearInterval(timer));
    stage.addEventListener('mouseleave', restart);
    show(0); restart();
  }
  loadTesti();
})();
