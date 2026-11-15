const WHATSAPP_PHONE = '59177666205';
const WHATSAPP_GENERIC_MESSAGE = 'Hola Bastet, quiero solicitar una evaluación gratuita para vender mi inmueble, esta es la ubicación del mismo ⬇️';

// Solo dígitos; un celular boliviano de 8 dígitos (empieza con 6 o 7) lleva el código de país 591 para que WhatsApp abra el chat
function normalizePhone(phone) {
  const digits = (phone || '').replace(/[^0-9]/g, '');
  return /^[67][0-9]{7}$/.test(digits) ? '591' + digits : digits;
}

function whatsappUrl(message, phone) {
  return 'https://api.whatsapp.com/send?phone=' + (normalizePhone(phone) || WHATSAPP_PHONE) + '&text=' + encodeURIComponent(message);
}

document.querySelectorAll('[data-whatsapp-generic]').forEach((el) => {
  el.href = whatsappUrl(WHATSAPP_GENERIC_MESSAGE);
});

/* ── Nav ── */
const navbar = document.querySelector('.navbar');
const burger = document.querySelector('.navbar-burger');
const mobilePanel = document.querySelector('.navbar-mobile-panel');

function setMenuOpen(open) {
  mobilePanel.classList.toggle('is-open', open);
  navbar.classList.toggle('is-menu-open', open);
  document.body.classList.toggle('menu-open', open);
}
burger.addEventListener('click', () => setMenuOpen(!mobilePanel.classList.contains('is-open')));
window.matchMedia('(min-width: 1080px)').addEventListener('change', (e) => { if (e.matches) setMenuOpen(false); });
mobilePanel.querySelectorAll('a').forEach((a) => a.addEventListener('click', () => setMenuOpen(false)));

// Al bajar, la barra se vuelve verde de marca con efecto vidrio y el logotipo cambia a su versión clara (blanco oficial)
const navLogo = navbar.querySelector('.navbar-logo-img');
const LOGO_DARK = navLogo ? navLogo.getAttribute('src') : '';
const LOGO_LIGHT = LOGO_DARK.replace('bastet-logo-horizontal-color.webp', 'bastet-logo-horizontal-blanco.webp');
if (navLogo) { const pre = new Image(); pre.src = LOGO_LIGHT; }
function updateNavbarScroll() {
  const scrolled = window.scrollY > 40;
  navbar.classList.toggle('is-scrolled', scrolled);
  if (navLogo && LOGO_LIGHT !== LOGO_DARK) navLogo.setAttribute('src', scrolled && !navbar.classList.contains('is-menu-open') ? LOGO_LIGHT : LOGO_DARK);
}
window.addEventListener('scroll', updateNavbarScroll, { passive: true });
updateNavbarScroll();

/* ── Acceso agentes: entrar con Google (la cuenta se crea sola la primera vez) ── */
const agentModalBackdrop = document.getElementById('agent-modal-backdrop');

async function openAgentModal() {
  setMenuOpen(false);
  // Si ya hay una sesión activa en este navegador, ir directo al panel.
  const { data: { session } } = await supabaseClient.auth.getSession();
  if (session) { window.location.href = 'admin/'; return; }
  agentModalBackdrop.classList.remove('hidden');
  document.getElementById('agent-google').focus();
}

function closeAgentModal() {
  agentModalBackdrop.classList.add('hidden');
}

document.querySelectorAll('[data-agent-access]').forEach((btn) => btn.addEventListener('click', () => openAgentModal()));
document.getElementById('agent-modal-close').addEventListener('click', closeAgentModal);
agentModalBackdrop.addEventListener('click', (e) => { if (e.target === agentModalBackdrop) closeAgentModal(); });
document.addEventListener('keydown', (e) => {
  if (e.key === 'Escape' && !agentModalBackdrop.classList.contains('hidden')) closeAgentModal();
});

function showAgentError(id, message) {
  const el = document.getElementById(id);
  el.textContent = message;
  el.classList.toggle('hidden', !message);
}

// Login con Google: Supabase redirige a Google y vuelve al panel con la sesión.
// La primera vez se crea y habilita la cuenta al instante; el panel valida rol/estado.
document.getElementById('agent-google').addEventListener('click', async () => {
  showAgentError('agent-login-error', '');
  const btn = document.getElementById('agent-google');
  btn.disabled = true;
  const { error } = await supabaseClient.auth.signInWithOAuth({
    provider: 'google',
    options: { redirectTo: window.location.origin + '/admin/' },
  });
  if (error) {
    btn.disabled = false;
    showAgentError('agent-login-error', 'No se pudo iniciar con Google: ' + error.message);
  }
});

/* ── Reveal on scroll ── */
const revealObserver = ('IntersectionObserver' in window)
  ? new IntersectionObserver((entries) => {
      entries.forEach((entry) => {
        if (entry.isIntersecting) {
          entry.target.classList.add('is-visible');
          revealObserver.unobserve(entry.target);
        }
      });
    }, { threshold: 0, rootMargin: '0px 0px -8% 0px' })
  : null;
document.querySelectorAll('.reveal').forEach((el) => {
  if (revealObserver) revealObserver.observe(el);
  else el.classList.add('is-visible');
});

function escapeHtml(str) {
  const div = document.createElement('div');
  div.textContent = str ?? '';
  return div.innerHTML;
}

// Precio con su moneda: "185.000 USD" o "Bs.- 1.200.000" (propiedades en bolivianos)
function formatPrice(price, currency, operation) {
  const base = formatPriceBase(price, currency);
  return operation === 'temporal' && base ? base + ' <span class="price-unit">por día</span>' : base;
}
function formatPriceBase(price, currency) {
  const digits = (price || '').toString().replace(/[^0-9]/g, '');
  if (!digits) return escapeHtml(price || '');
  const n = digits.replace(/\B(?=(\d{3})+(?!\d))/g, '.');
  return currency === 'BOB' ? 'Bs.- ' + n : n + ' USD';
}

const reducedMotion = window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches;

/* ── Carrusel 3D en anillo, genérico (hoy solo lo usan los Testimonios) ──
   Reproduce la misma física: rotación automática + arrastre, con la tarjeta
   resuelta en pointerdown (no en el evento "click") para que no falle si el
   anillo se movió entre el down y el up. */
function createRingCarousel({ stage, radius, size = 12, cull = 50, speed = 5, buildCard, onSelect, onContact, emptyText = 'Próximamente.', brightCenter = false, edgeFade = false, perspective = 1000, cardHalfWidth = 115 }) {
  const step = 360 / size;
  // edgeFade: el anillo ocupa todo el ancho y se desvanece en los bordes con una máscara
  // en CSS (.ring-stage--edge-fade). Aquí solo se ocultan las tarjetas que ya salieron de
  // la pantalla y se suaviza la entrada/salida por ángulo para que nunca aparezcan de golpe.
  const PERSPECTIVE = perspective;       // igual que el perspective del escenario en CSS
  const CARD_HALF_WIDTH = cardHalfWidth; // mitad del ancho de la tarjeta en CSS
  let screenHalfWidth = window.innerWidth / 2;
  if (edgeFade) {
    stage.classList.add('ring-stage--edge-fade');
    window.addEventListener('resize', () => { screenHalfWidth = window.innerWidth / 2; }, { passive: true });
  }
  let cards = [];
  let phase = -2;
  let last = null;
  let rafId = null;
  let dragging = false;
  let moved = false;
  let dragStartX = 0;
  let dragStartPhase = 0;
  let pauseUntil = 0;
  let downItem = null;
  let downOnContact = false; // el pointerdown fue sobre la foto del agente ([data-ring-contact])

  function update() {
    for (let i = 0; i < cards.length; i++) {
      const el = cards[i];
      if (!el) continue;
      let a = ((i * step + phase) % 360 + 540) % 360 - 180;
      if (Math.abs(a) > cull) { el.style.visibility = 'hidden'; continue; }
      el.style.visibility = 'visible';
      const r = (a * Math.PI) / 180, c = Math.cos(r);
      const x = radius * Math.sin(r);
      el.style.transform = 'translate3d(' + x.toFixed(1) + 'px,0,' + (radius * (1 - c)).toFixed(1) + 'px) rotateY(' + (-a).toFixed(1) + 'deg)';
      const brightness = brightCenter ? Math.max(0.88, 1 - 0.8 * (1 / c - 1)) : Math.min(1.05, 0.72 + 0.5 * (1 / c - 1));
      el.style.filter = 'brightness(' + brightness.toFixed(3) + ')';
      if (edgeFade) {
        const z = radius * (1 - c);
        const scale = PERSPECTIVE / (PERSPECTIVE - z);
        if (Math.abs(x) * scale - CARD_HALF_WIDTH * scale > screenHalfWidth + 20) { el.style.visibility = 'hidden'; continue; }
        el.style.opacity = Math.min(1, (cull - Math.abs(a)) / 12).toFixed(3);
      }
      el.style.zIndex = String(Math.round(1000 - Math.abs(a)));
    }
  }

  function startAnim() {
    if (reducedMotion || typeof requestAnimationFrame === 'undefined') return;
    last = null;
    const tick = (t) => {
      if (last == null) last = t;
      const dt = Math.min((t - last) / 1000, 0.1);
      last = t;
      const now = performance.now();
      if (!dragging && !(pauseUntil && now < pauseUntil)) phase -= speed * dt;
      update();
      rafId = requestAnimationFrame(tick);
    };
    rafId = requestAnimationFrame(tick);
  }
  function stopAnim() { if (rafId) cancelAnimationFrame(rafId); rafId = null; }

  function render(items, emptyMessage) {
    stopAnim();
    stage.innerHTML = '';
    cards = [];
    if (!items.length) {
      const empty = document.createElement('div');
      empty.className = 'ring-empty';
      empty.textContent = emptyMessage || emptyText;
      stage.appendChild(empty);
      return;
    }
    for (let i = 0; i < size; i++) {
      const item = items[i % items.length];
      const card = buildCard(item);
      card.__item = item;
      stage.appendChild(card);
      cards.push(card);
    }
    update();
    startAnim();
  }

  stage.addEventListener('pointerdown', (e) => {
    dragging = true;
    moved = false;
    dragStartX = e.clientX;
    dragStartPhase = phase;
    const cardEl = e.target.closest ? e.target.closest('[data-ring-card]') : null;
    downItem = cardEl ? cardEl.__item : null;
    downOnContact = !!(e.target.closest && e.target.closest('[data-ring-contact]'));
    if (stage.setPointerCapture) { try { stage.setPointerCapture(e.pointerId); } catch (err) {} }
  });
  stage.addEventListener('pointermove', (e) => {
    if (!dragging) return;
    const dx = e.clientX - dragStartX;
    if (Math.abs(dx) > 6) moved = true;
    phase = dragStartPhase + dx * 0.18;
    update();
  });
  function end(shouldSelect) {
    if (!dragging) return;
    dragging = false;
    last = null;
    pauseUntil = performance.now() + 1600;
    if (shouldSelect && !moved && downItem) {
      if (downOnContact && onContact) onContact(downItem);
      else if (onSelect) onSelect(downItem);
    }
    downItem = null;
    downOnContact = false;
  }
  stage.addEventListener('pointerup', () => end(true));
  stage.addEventListener('pointercancel', () => end(false));
  stage.addEventListener('pointerleave', () => end(false));

  return { render };
}

/* ── Propiedades: fetch + filtros + grilla de tarjetas + modal ── */
// Este script corre en el inicio (vista previa de 3 propiedades, sin filtros) y en marketplace.html (todas, con filtros).
const HAS_FILTERS = !!document.getElementById('operation-filters');
const PROP_PAGE_SIZE = HAS_FILTERS ? 12 : 3; // tarjetas de entrada; en el Marketplace "Ver más" agrega otra tanda
let propVisibleCount = PROP_PAGE_SIZE;

const propGridEl = document.getElementById('prop-grid');
const propMoreWrapEl = document.getElementById('prop-more-wrap');
const citySelectEl = document.getElementById('city-filter-select');
const modalBackdrop = document.getElementById('property-modal-backdrop');
const modal = document.getElementById('property-modal');

let allProperties = [];
let cityFilter = 'Todas';
let favOnly = false;      // solo guardadas (corazón)
let viewMode = 'list';    // 'list' | 'map' (solo en marketplace)
let operationFilter = ''; // '' (inicio: destacadas) | 'venta' | 'alquiler' | 'anticretico' | 'temporal'
let typeFilter = ''; // '' | 'casa' | 'departamento' | 'habitacion' | 'terreno'
let roomsFilter = ''; // '' = cualquiera; '3' = mínimo 3 habitaciones
const roomsSelectEl = document.getElementById('rooms-filter-select');
const ROOMS_MIN_OPTIONS = [1, 2, 3, 4, 5];
let bathsFilter = ''; // '' = cualquiera; '2' = mínimo 2 baños
const bathsSelectEl = document.getElementById('baths-filter-select');
const BATHS_MIN_OPTIONS = [1, 2, 3, 4];

// "2 baños" -> 2, "5+ baños" -> 5; "—" (no aplica) -> null
function propertyBathsNumber(p) {
  const match = (p.baths || '').match(/\d+/);
  return match ? parseInt(match[0], 10) : null;
}

// "3 habitaciones" -> 3, "6+ habitaciones" -> 6; "Espacio abierto" / "A diseñar" -> null
function propertyRoomsNumber(p) {
  const match = (p.rooms || '').match(/\d+/);
  return match ? parseInt(match[0], 10) : null;
}
const typeSelectEl = document.getElementById('type-filter-select');
let minPriceFilter = ''; // precio mínimo en USD ('' = sin mínimo)
let maxPriceFilter = ''; // precio máximo en USD ('' = sin máximo)
const minPriceEl = document.getElementById('min-price-input');
const maxPriceEl = document.getElementById('max-price-input');
const resultsTitleEl = document.getElementById('prop-results-title');

// Selector con la marca: la lista nativa de <select> no se puede estilizar (el navegador la pinta
// en azul con su propia fuente), así que se reemplaza por un botón + lista propia. El <select>
// queda oculto como fuente de verdad: el resto del código sigue leyendo/escribiendo su valor y
// escuchando su "change"; un MutationObserver copia sus opciones y su clase is-set.
let openBrandSelect = null;
function enhanceSelect(selectEl) {
  const wrap = selectEl.parentElement;
  const label = wrap.querySelector('label[for="' + selectEl.id + '"]');
  const trigger = document.createElement('button');
  trigger.type = 'button';
  trigger.id = selectEl.id + '-trigger';
  trigger.className = 'budget-filter-select brand-select-trigger';
  trigger.setAttribute('aria-haspopup', 'listbox');
  trigger.setAttribute('aria-expanded', 'false');
  const list = document.createElement('ul');
  list.className = 'brand-select-list';
  list.id = selectEl.id + '-list';
  list.setAttribute('role', 'listbox');
  list.tabIndex = -1;
  trigger.setAttribute('aria-controls', list.id);
  if (label) {
    label.htmlFor = trigger.id;
    label.id = label.id || selectEl.id + '-label';
    list.setAttribute('aria-labelledby', label.id);
  }
  selectEl.classList.remove('budget-filter-select');
  selectEl.classList.add('brand-select-native');
  selectEl.tabIndex = -1;
  selectEl.setAttribute('aria-hidden', 'true');
  wrap.classList.add('brand-select');
  selectEl.after(trigger, list);

  let active = -1; // índice de la opción resaltada con el teclado

  // "3 (11)" -> texto "3" + cantidad en una pastilla
  function splitCount(text) {
    const m = text.match(/^(.*?)\s*\((\d+)\)$/);
    return m ? { text: m[1], count: m[2] } : { text, count: null };
  }

  function sync() {
    const opts = [...selectEl.options];
    list.innerHTML = '';
    opts.forEach((o, i) => {
      const { text, count } = splitCount(o.textContent);
      const li = document.createElement('li');
      li.className = 'brand-select-option';
      li.id = selectEl.id + '-opt-' + i;
      li.setAttribute('role', 'option');
      li.dataset.index = i;
      li.setAttribute('aria-selected', String(o.selected));
      if (o.disabled) li.setAttribute('aria-disabled', 'true');
      li.innerHTML = '<span class="brand-select-check" aria-hidden="true"></span><span class="brand-select-text"></span>' +
        (count != null ? '<span class="brand-select-count"></span>' : '');
      li.querySelector('.brand-select-text').textContent = text;
      if (count != null) li.querySelector('.brand-select-count').textContent = count;
      list.appendChild(li);
    });
    const sel = selectEl.options[selectEl.selectedIndex];
    trigger.textContent = sel ? splitCount(sel.textContent).text : '';
    trigger.classList.toggle('is-set', selectEl.classList.contains('is-set'));
  }

  function setActive(i) {
    const items = list.children;
    if (active >= 0 && items[active]) items[active].classList.remove('is-active');
    active = i;
    if (i >= 0 && items[i]) {
      items[i].classList.add('is-active');
      list.setAttribute('aria-activedescendant', items[i].id);
      items[i].scrollIntoView({ block: 'nearest' });
    } else list.removeAttribute('aria-activedescendant');
  }
  // siguiente opción habilitada en la dirección dir (1 / -1)
  function step(from, dir) {
    const opts = selectEl.options;
    for (let i = from + dir; i >= 0 && i < opts.length; i += dir) if (!opts[i].disabled) return i;
    return from;
  }

  function open() {
    if (openBrandSelect && openBrandSelect !== api) openBrandSelect.close(false);
    openBrandSelect = api;
    wrap.classList.add('is-open');
    trigger.setAttribute('aria-expanded', 'true');
    setActive(selectEl.selectedIndex);
    list.focus({ preventScroll: true });
  }
  function close(focusTrigger = true) {
    if (openBrandSelect === api) openBrandSelect = null;
    wrap.classList.remove('is-open');
    trigger.setAttribute('aria-expanded', 'false');
    setActive(-1);
    if (focusTrigger) trigger.focus({ preventScroll: true });
  }
  function choose(i) {
    const o = selectEl.options[i];
    if (!o || o.disabled) return;
    close();
    if (selectEl.selectedIndex === i) return;
    selectEl.selectedIndex = i;
    selectEl.dispatchEvent(new Event('change', { bubbles: true }));
    sync();
  }
  const api = { close };

  trigger.addEventListener('click', () => (wrap.classList.contains('is-open') ? close() : open()));
  trigger.addEventListener('keydown', (e) => {
    if (['ArrowDown', 'ArrowUp', 'Enter', ' '].includes(e.key)) { e.preventDefault(); open(); }
  });
  list.addEventListener('click', (e) => {
    const li = e.target.closest('.brand-select-option');
    if (li) choose(Number(li.dataset.index));
  });
  list.addEventListener('mousemove', (e) => {
    const li = e.target.closest('.brand-select-option');
    if (li && !li.hasAttribute('aria-disabled') && Number(li.dataset.index) !== active) setActive(Number(li.dataset.index));
  });
  list.addEventListener('keydown', (e) => {
    const last = selectEl.options.length - 1;
    if (e.key === 'ArrowDown') { e.preventDefault(); setActive(step(active, 1)); }
    else if (e.key === 'ArrowUp') { e.preventDefault(); setActive(step(active, -1)); }
    else if (e.key === 'Home') { e.preventDefault(); setActive(step(-1, 1)); }
    else if (e.key === 'End') { e.preventDefault(); setActive(step(last + 1, -1)); }
    else if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); choose(active); }
    else if (e.key === 'Escape') { e.preventDefault(); close(); }
    else if (e.key === 'Tab') close(false);
  });
  list.addEventListener('focusout', (e) => {
    if (!wrap.contains(e.relatedTarget) && wrap.classList.contains('is-open')) close(false);
  });

  new MutationObserver(sync).observe(selectEl, { childList: true, attributes: true, attributeFilter: ['class'] });
  selectEl.addEventListener('change', sync);
  sync();
}
document.addEventListener('pointerdown', (e) => {
  if (openBrandSelect && !e.target.closest('.brand-select.is-open')) openBrandSelect.close(false);
});
[citySelectEl, typeSelectEl, roomsSelectEl, bathsSelectEl].filter(Boolean).forEach(enhanceSelect);

// Los precios del filtro están en dólares: una propiedad en bolivianos se compara convertida al tipo de cambio oficial.
const BOB_PER_USD = 6.96;
function propertyPriceNumber(p) {
  const digits = (p.price || '').toString().replace(/[^0-9]/g, '');
  if (!digits) return null;
  const n = parseInt(digits, 10);
  return p.currency === 'BOB' ? Math.round(n / BOB_PER_USD) : n;
}

// Precio mínimo / máximo (USD, inclusivos). Una propiedad sin precio numérico queda fuera si hay algún límite.
function inPriceRange(p) {
  if (minPriceFilter === '' && maxPriceFilter === '') return true;
  const price = propertyPriceNumber(p);
  if (price === null) return false;
  if (minPriceFilter !== '' && price < Number(minPriceFilter)) return false;
  if (maxPriceFilter !== '' && price > Number(maxPriceFilter)) return false;
  return true;
}

// Selector de tipo de inmueble, con la cantidad de cada tipo dentro de la operación elegida.
function buildTypeFilter() {
  const base = propertiesForOperation();
  typeSelectEl.innerHTML = '';
  const any = document.createElement('option');
  any.value = '';
  any.textContent = 'Todos los tipos';
  typeSelectEl.appendChild(any);
  Object.entries(PROPERTY_TYPE_LABELS).forEach(([value, label]) => {
    const count = base.filter((p) => p.property_type === value).length;
    const opt = document.createElement('option');
    opt.value = value;
    opt.textContent = label + ' (' + count + ')';
    opt.disabled = count === 0;
    typeSelectEl.appendChild(opt);
  });
  typeSelectEl.value = typeFilter;
  typeSelectEl.classList.toggle('is-set', typeFilter !== '');
}

typeSelectEl?.addEventListener('change', () => {
  typeFilter = typeSelectEl.value;
  typeSelectEl.classList.toggle('is-set', typeFilter !== '');
  buildRoomsFilter();  // las cantidades de habitaciones y baños dependen del tipo
  buildBathsFilter();
  buildCityFilter();
  renderPropertyGrid();
});

// Selector de habitaciones (mínimo N), con cantidades dentro de la operación y el tipo elegidos.
function buildRoomsFilter() {
  const base = propertiesForOperationAndType();
  roomsSelectEl.innerHTML = '';
  const any = document.createElement('option');
  any.value = '';
  any.textContent = 'Cualquier cantidad';
  roomsSelectEl.appendChild(any);
  ROOMS_MIN_OPTIONS.forEach((min) => {
    const count = base.filter((p) => (propertyRoomsNumber(p) || 0) >= min).length;
    const opt = document.createElement('option');
    opt.value = String(min);
    opt.textContent = min + ' (' + count + ')';
    opt.disabled = count === 0;
    roomsSelectEl.appendChild(opt);
  });
  roomsSelectEl.value = roomsFilter;
  roomsSelectEl.classList.toggle('is-set', roomsFilter !== '');
}

roomsSelectEl?.addEventListener('change', () => {
  roomsFilter = roomsSelectEl.value;
  roomsSelectEl.classList.toggle('is-set', roomsFilter !== '');
  buildBathsFilter();  // las cantidades de baños dependen de las habitaciones
  buildCityFilter();
  renderPropertyGrid();
});

// Selector de baños (mínimo N), con cantidades dentro de operación, tipo y habitaciones elegidos.
function buildBathsFilter() {
  const base = propertiesForOperationTypeAndRooms();
  bathsSelectEl.innerHTML = '';
  const any = document.createElement('option');
  any.value = '';
  any.textContent = 'Cualquier cantidad';
  bathsSelectEl.appendChild(any);
  BATHS_MIN_OPTIONS.forEach((min) => {
    const count = base.filter((p) => (propertyBathsNumber(p) || 0) >= min).length;
    const opt = document.createElement('option');
    opt.value = String(min);
    opt.textContent = min + ' (' + count + ')';
    opt.disabled = count === 0;
    bathsSelectEl.appendChild(opt);
  });
  bathsSelectEl.value = bathsFilter;
  bathsSelectEl.classList.toggle('is-set', bathsFilter !== '');
}

bathsSelectEl?.addEventListener('change', () => {
  bathsFilter = bathsSelectEl.value;
  bathsSelectEl.classList.toggle('is-set', bathsFilter !== '');
  buildCityFilter();
  renderPropertyGrid();
});

// Campos "Precio mínimo / máximo": solo dígitos; al cambiarlos se vuelve a filtrar (con una pequeña espera al teclear).
let priceTimer = null;
function onPriceInput() {
  [minPriceEl, maxPriceEl].forEach((el) => { el.value = el.value.replace(/[^0-9]/g, ''); });
  minPriceFilter = minPriceEl.value;
  maxPriceFilter = maxPriceEl.value;
  [minPriceEl, maxPriceEl].forEach((el) => el.classList.toggle('is-set', el.value !== ''));
  clearTimeout(priceTimer);
  priceTimer = setTimeout(() => { buildCityFilter(); renderPropertyGrid(); }, 250);
}
minPriceEl?.addEventListener('input', onPriceInput);
maxPriceEl?.addEventListener('input', onPriceInput);
const operationFiltersEl = document.getElementById('operation-filters');
let selectedProperty = null;
let selectedPhotoIndex = 0;

// Valor numérico -> con su unidad ("3" -> "3 amb."); si ya trae texto se muestra tal cual.
function withUnit(value, unit) {
  const v = String(value ?? '').trim();
  if (!v) return '';
  return /^\d+([.,]\d+)?$/.test(v) ? v + ' ' + unit : v;
}

// Tarjeta limpia de propiedad (mismo lenguaje que el panel): toda la tarjeta abre la ficha;
// el agente que la publicó queda abajo con su WhatsApp directo y sus redes.
function buildPropertyTile(property) {
  const tile = document.createElement('article');
  const featured = isFeatured(property);
  tile.className = 'prop-tile' + (featured ? ' prop-tile--featured' : '') + (property.operation === 'temporal' ? ' prop-tile--stay' : '');
  tile.tabIndex = 0;
  tile.setAttribute('aria-label', property.title);
  tile.__property = property;

  const firstPhoto = (property.photos && property.photos[0]) || null;
  const operation = PROPERTY_OPERATION_LABELS[property.operation];
  const code = formatPropertyCode(property);
  const eyebrow = [PROPERTY_TYPE_LABELS[property.property_type], property.location].filter(Boolean).map(escapeHtml).join(' · ');
  const facts = [withUnit(property.area, 'm²'), withUnit(property.rooms, 'amb.'), withUnit(property.baths, 'baños')].filter(Boolean).map(escapeHtml);

  tile.innerHTML =
    '<div class="prop-tile-ph">' +
      (firstPhoto
        ? '<img class="prop-tile-img" ' + window.imgThumbAttrs(firstPhoto, 640) + ' alt="' + escapeHtml(property.title) + '" loading="lazy">'
        : '<div class="prop-tile-noimg">' + escapeHtml(property.title || 'BASTET') + '</div>') +
      (window.PropFavs ? '<button type="button" class="prop-tile-fav' + (window.PropFavs.has(property.id) ? ' is-on' : '') + '" data-fav aria-pressed="' + window.PropFavs.has(property.id) + '" aria-label="Guardar en favoritos">' + '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M12 20.500s-7.500-4.600-7.500-10A4.300 4.300 0 0 1 12 7.900a4.300 4.300 0 0 1 7.500 2.600c0 5.400-7.500 10-7.500 10z"/></svg>' + '</button>' : '') +
      '<div class="prop-tile-badges">' +
        (operation ? '<span class="prop-tile-badge">' + operation + '</span>' : '') +
        (featured ? '<span class="prop-tile-badge prop-tile-badge--gold"><svg viewBox="0 0 24 24" aria-hidden="true"><path d="M12 2l2.6 6.4L21 11l-6.4 2.6L12 20l-2.6-6.4L3 11l6.4-2.6z"/></svg>Destacada</span>' : '') +
      '</div>' +
    '</div>' +
    '<div class="prop-tile-body">' +
      (eyebrow ? '<span class="prop-tile-eyebrow">' + eyebrow + '</span>' : '') +
      '<h3 class="prop-tile-title">' + escapeHtml(property.title) + '</h3>' +
      (property.price ? '<div class="prop-tile-price">' + formatPrice(property.price, property.currency, property.operation) + (property.exchange_rate && property.currency !== 'BOB' && property.operation !== 'temporal' ? '<small> · T.C. ' + escapeHtml(property.exchange_rate) + '</small>' : '') + '</div>' : '') +
      (facts.length || code ? '<p class="prop-tile-facts">' + facts.join(' · ') + (code ? '<span class="prop-tile-code">' + code + '</span>' : '') + '</p>' : '') +
    '</div>' +
    buildTileAgentHtml(property);
  return tile;
}

// Mensaje de WhatsApp de una propiedad: empieza con el código para que el agente la
// identifique al instante, y saluda al agente por su nombre si lo tiene.
function propertyWhatsappMessage(p) {
  const code = formatPropertyCode(p);
  const operationLabel = PROPERTY_OPERATION_LABELS[p.operation];
  // Solo se saluda al agente por su nombre si el mensaje le llega a él (la propiedad tiene su
  // WhatsApp); si no, va al número general de Bastet.
  const agentFirstName = p.agent && p.agent.display_name ? p.agent.display_name.trim().split(/\s+/)[0] : '';
  return (code ? '[' + code + '] ' : '') +
    'Hola ' + (agentFirstName || 'Bastet') + ', me interesa la propiedad: ' + p.title +
    (operationLabel ? ' (' + operationLabel.toLowerCase() + ')' : '') +
    ' en ' + p.location + '. ¿Podrían brindarme más información?';
}

const WHATSAPP_ICON_SVG = '<svg viewBox="0 0 24 24" aria-hidden="true"><path fill="currentColor" d="M12 2a10 10 0 0 0-8.6 15.1L2 22l5-1.3A10 10 0 1 0 12 2zm0 18.2c-1.5 0-3-.4-4.3-1.2l-.3-.2-3 .8.8-2.9-.2-.3A8.2 8.2 0 1 1 12 20.2zm4.5-6.1c-.2-.1-1.5-.7-1.7-.8-.2-.1-.4-.1-.6.1l-.8 1c-.1.2-.3.2-.5.1a6.7 6.7 0 0 1-3.3-2.9c-.3-.4.2-.4.7-1.4.1-.2 0-.3 0-.4l-.8-1.8c-.2-.5-.4-.4-.6-.4h-.5a1 1 0 0 0-.7.3 3 3 0 0 0-.9 2.2 5.2 5.2 0 0 0 1.1 2.7 11.8 11.8 0 0 0 4.5 4c1.7.7 2.3.8 3.1.7.5-.1 1.5-.6 1.7-1.2.2-.6.2-1.1.2-1.2-.1-.1-.3-.2-.5-.3z"/></svg>';

// Agente que publicó la propiedad: foto, nombre, redes y botón de WhatsApp directo.
// Sin agente asignado se muestra el gato de Bastet y el contacto va al número general.
function buildTileAgentHtml(property) {
  const agent = property.agent;
  const name = agent && agent.display_name ? agent.display_name : 'Bastet';
  const initial = name.trim().charAt(0).toUpperCase();
  const photo = agent && agent.avatar_url
    ? '<img class="prop-tile-avatar" src="' + escapeHtml(agent.avatar_url) + '" alt="" loading="lazy">'
    : (agent && agent.display_name
      ? '<span class="prop-tile-avatar prop-tile-avatar--initial">' + escapeHtml(initial) + '</span>'
      : '<span class="prop-tile-avatar prop-tile-avatar--brand"><img src="assets/img/bastet-isotipo-cabeza-dorado.webp" alt=""></span>');
  // WhatsApp del agente (su perfil) o, si no lo tiene, el de la propiedad; sin ninguno, el número general de Bastet
  const waIcon = '<a class="prop-tile-cta" href="#" data-tile-wa aria-label="Solicitar contacto con ' + escapeHtml(name) + '">Solicitar contacto</a>';
  const socials = waIcon;
  return (
    '<div class="prop-tile-agent">' +
      '<div class="prop-tile-agent-row">' +
        photo +
        '<span class="prop-tile-agent-who"><span class="prop-tile-agent-label">Publicado por</span><span class="prop-tile-agent-name">' + escapeHtml(name) + '</span></span>' +
        '<span class="prop-tile-socials">' + socials + '</span>' +
      '</div>' +
    '</div>'
  );
}

// Ícono de red social como badge circular con el logo real (assets/img/social-*.svg).
function socialIconLink(url, kind, label) {
  if (!url) return '';
  return '<a class="property-modal-social-link" href="' + escapeHtml(url) + '" target="_blank" rel="noopener" aria-label="' + label + '">' +
    '<img src="assets/img/social-' + kind + '.svg" alt="' + label + '">' +
  '</a>';
}

// Columnas públicas explícitas (sin owner_whatsapp: es el teléfono privado del
// propietario del inmueble, nunca debe llegar al landing público).
const PUBLIC_PROPERTY_COLUMNS = 'id,title,location,address,price,currency,exchange_rate,area,rooms,baths,description,photos,verified,owner_id,featured,featured_until,sort_order,status,created_at,code_number,property_type,operation,floors,has_garage,garage_spots,has_storage,pets_allowed,kids_allowed,latitude,longitude';
// Columnas públicas del agente (nunca email/role/is_active: ver política RLS "public can read active agent public info").
const PUBLIC_AGENT_COLUMNS = 'id,display_name,avatar_url,facebook_url,instagram_url,tiktok_url,agent_verified,owner_verified,public_code';
// Con las conexiones activas (supabase/connections.sql) las propiedades de venta, alquiler y anticrético no muestran un WhatsApp directo:
// el interesado pide contacto con el formulario de la ficha y el agente acepta. Las estadías temporales no entran (tienen su propio flujo).
const waAttrs = (msg, propId) => ' data-wa-prop="' + escapeHtml(String(propId || '')) + '" data-wa-msg="' + escapeHtml(msg || '') + '"';   // el teléfono se pide al hacer clic (contact-shield.js)
const contactGated = (p) => !!(window.Connections && window.Connections.isOn() && p && p.operation !== 'temporal');   // sin operación (listados antiguos) cuenta como venta

async function loadProperties() {
  if (window.Connections) await window.Connections.init();
  const fetchProperties = (columns) => supabaseClient
    .from('properties')
    .select(columns)
    .eq('status', 'available')
    .order('sort_order', { ascending: true });

  // Solo propiedades vigentes (30 días desde su publicación; las vencidas se ocultan hasta que se renueven).
  const fetchActive = (columns) => fetchProperties(columns).or('expires_at.is.null,expires_at.gt.' + new Date().toISOString());
  // Si algún SQL aún no se corrió (moneda, vigencia, plan), esa columna no existe (42703): se reintenta sin ella, de la más nueva a la más antigua.
  const noVerified = PUBLIC_PROPERTY_COLUMNS.replace('verified,', '');   // sin supabase/verification.sql no existe esa columna
  const noCoords = noVerified.replace(',latitude,longitude', '');
  const noCurrency = noCoords.replace('currency,', '');
  const attempts = [
    () => fetchActive(PUBLIC_PROPERTY_COLUMNS),
    () => fetchActive(noVerified),
    () => fetchActive(noCoords),
    () => fetchActive(noCurrency),
    () => fetchProperties(noCurrency),
    () => fetchProperties(noCurrency.replace('featured_until,', '')),
  ];
  let data = null, error = null;
  for (const attempt of attempts) {
    ({ data, error } = await attempt());
    if (!error || error.code !== '42703') break;
  }

  if (error) {
    console.error('Error cargando propiedades:', error);
    allProperties = [];
    if (window.HomeFeed) window.HomeFeed.render([]);
  } else {
    allProperties = data || [];
    if (window.PropFavs) window.PropFavs.prune(allProperties.map((p) => p.id));
    await hideBlockedStays();
    await attachAgentInfo(allProperties);
    if (window.HomeFeed) window.HomeFeed.render(allProperties);   // Inicio: filas de inmuebles y estadías (assets/js/home.js)
  }

  if (HAS_FILTERS) {
    // Búsqueda que viene del inicio (marketplace.html?ciudad=…&op=…&tipo=…): se precargan los filtros
    const qs = new URLSearchParams(window.location.search);
    const op = qs.get('op'), tipo = qs.get('tipo'), ciudad = qs.get('ciudad');
    if (op === 'temporal') { window.location.replace('estadias.html' + (ciudad ? '?ciudad=' + encodeURIComponent(ciudad) : '')); return; }
    if (op && PROPERTY_OPERATION_LABELS[op]) operationFilter = op;
    if (tipo && PROPERTY_TYPE_LABELS[tipo]) typeFilter = tipo;
    if (ciudad && BOLIVIA_CITIES.includes(ciudad)) cityFilter = ciudad;
    rebuildFilters();
  }
  renderPropertyGrid();
  const wantedProp = new URLSearchParams(window.location.search).get('p');
  if (wantedProp) { const found = allProperties.find((x) => x.id === wantedProp || formatPropertyCode(x) === wantedProp); if (found) openProperty(found, { deep: true }); }
}

// Las estadías temporales que el anfitrión marcó como no disponibles hoy se ocultan (vuelven solas al terminar el periodo)
async function hideBlockedStays() {
  const ids = allProperties.filter((p) => p.operation === 'temporal').map((p) => p.id);
  if (!ids.length) return;
  try {
    const { data, error } = await supabaseClient.rpc('stay_blocked_ranges', { p_ids: ids });
    if (error || !data) return;
    const today = new Date(Date.now() - 4 * 3600 * 1000).toISOString().slice(0, 10);
    const off = new Set(data.filter((b) => b.from_date <= today && (!b.to_date || b.to_date >= today)).map((b) => b.property_id));
    if (off.size) allProperties = allProperties.filter((p) => !off.has(p.id));
  } catch (e) { /* sin el SQL de disponibilidad: se muestran todas */ }
}

async function attachAgentInfo(properties) {
  const ownerIds = [...new Set(properties.map((p) => p.owner_id).filter(Boolean))];
  if (!ownerIds.length) return;
  let { data, error } = await supabaseClient.from('profiles').select(PUBLIC_AGENT_COLUMNS).in('id', ownerIds);
  if (error) ({ data, error } = await supabaseClient.from('profiles').select('id,display_name,avatar_url,facebook_url,instagram_url,tiktok_url').in('id', ownerIds));   // sin el SQL de verificación
  if (error || !data) return;
  const agentById = {};
  data.forEach((a) => { agentById[a.id] = a; });
  properties.forEach((p) => { p.agent = p.owner_id ? agentById[p.owner_id] || null : null; });
}

// Filtro por operación (Venta / Alquiler / Anticrético / Temporal). No hay opción "Todas": sin ninguna
// operación elegida se muestran las propiedades destacadas. Volver a pulsar la operación activa la desmarca.
// Se muestran siempre todas las opciones con su cantidad, así el visitante sabe qué hay en cada una.
const isTemporal = (p) => p.operation === 'temporal';

// Íconos de las pestañas de operación (trazo fino, estilo del manual de marca)
const OPERATION_ICONS = {
  venta: '<svg viewBox="0 0 32 32" aria-hidden="true"><path d="M4 15L16 5l12 10"/><path d="M7 13v13h18V13"/><path d="M13 26v-7h6v7"/></svg>',
  alquiler: '<svg viewBox="0 0 32 32" aria-hidden="true"><circle cx="11" cy="16" r="5.5"/><path d="M16.5 16H28M23 16v4M27 16v3"/></svg>',
  anticretico: '<svg viewBox="0 0 32 32" aria-hidden="true"><path d="M16 4l10 4v7c0 6-4 10-10 13C10 25 6 21 6 15V8z"/><path d="M12 16l3 3 5-6"/></svg>',
  temporal: '<svg viewBox="0 0 32 32" aria-hidden="true"><circle cx="16" cy="14" r="5"/><path d="M16 4v2.5M16 21.5V24M6 14h2.5M23.5 14H26M9 7l1.8 1.8M21.2 19.2L23 21M23 7l-1.8 1.8M10.8 19.2L9 21"/><path d="M5 28h22"/></svg>',
};

function buildOperationFilters() {
  const options = Object.entries(PROPERTY_OPERATION_LABELS);
  operationFiltersEl.innerHTML = '';
  options.forEach(([value, label]) => {
    const count = allProperties.filter((p) => p.operation === value).length;
    const btn = document.createElement('button');
    btn.type = 'button';
    btn.setAttribute('role', 'tab');
    btn.setAttribute('aria-selected', String(value === operationFilter));
    btn.className = 'operation-tab' + (value === 'temporal' ? ' operation-tab--stay' : '') + (value === operationFilter ? ' is-active' : '');
    const labelHtml = '<span class="operation-tab-label">' + escapeHtml(value === 'temporal' ? 'Estadías temporales' : label) + '<span class="operation-tab-count">' + count + '</span></span>';
    btn.innerHTML = value === 'temporal'
      ? (OPERATION_ICONS[value] || '') + '<span class="operation-tab-main">' + labelHtml + '<span class="operation-tab-sub">Por noche, con fechas y huéspedes · como un hotel</span></span><svg class="operation-tab-arrow" viewBox="0 0 24 24" aria-hidden="true"><path d="M5 12h14M13 6l6 6-6 6"/></svg>'
      : (OPERATION_ICONS[value] || '') + labelHtml;
    btn.addEventListener('click', () => {
      // Temporal tiene su propia pantalla (estadias.html), al estilo de un buscador de alojamientos
      if (value === 'temporal') { window.location.href = 'estadias.html' + (cityFilter !== 'Todas' ? '?ciudad=' + encodeURIComponent(cityFilter) : ''); return; }
      operationFilter = operationFilter === value ? '' : value;
      cityFilter = 'Todas'; // las ciudades disponibles cambian según la operación
      typeFilter = '';
      roomsFilter = '';
      bathsFilter = '';
      rebuildFilters();
      renderPropertyGrid();
    });
    operationFiltersEl.appendChild(btn);
  });
}

function rebuildFilters() {
  buildOperationFilters();
  buildTypeFilter();
  buildRoomsFilter();
  buildBathsFilter();
  buildCityFilter();
}

// Sin operación elegida: todas menos las temporales (que tienen su propia sección).
function propertiesForOperation() {
  return operationFilter ? allProperties.filter((p) => p.operation === operationFilter) : allProperties.filter((p) => !isTemporal(p));
}

function propertiesForOperationAndType() {
  const base = propertiesForOperation();
  return typeFilter === '' ? base : base.filter((p) => p.property_type === typeFilter);
}

function propertiesForOperationTypeAndRooms() {
  const base = propertiesForOperationAndType();
  if (roomsFilter === '') return base;
  const min = Number(roomsFilter);
  return base.filter((p) => (propertyRoomsNumber(p) || 0) >= min);
}

function propertiesBeforePrice() {
  const base = propertiesForOperationTypeAndRooms();
  if (bathsFilter === '') return base;
  const min = Number(bathsFilter);
  return base.filter((p) => (propertyBathsNumber(p) || 0) >= min);
}

function propertiesForOperationAndPrice() {
  return propertiesBeforePrice().filter(inPriceRange);
}

// Selector de ciudad, con la cantidad de propiedades de cada una según los demás filtros.
// Solo aparecen las ciudades que tienen propiedades.
function buildCityFilter() {
  const base = propertiesForOperationAndPrice();
  const presentCities = new Set(base.map((p) => (p.location || '').split(',')[0].trim()));
  citySelectEl.innerHTML = '';
  const any = document.createElement('option');
  any.value = 'Todas';
  any.textContent = 'Todas las ciudades';
  citySelectEl.appendChild(any);
  BOLIVIA_CITIES.filter((c) => presentCities.has(c)).forEach((city) => {
    const count = base.filter((p) => (p.location || '').startsWith(city)).length;
    const opt = document.createElement('option');
    opt.value = city;
    opt.textContent = city + ' (' + count + ')';
    citySelectEl.appendChild(opt);
  });
  if (cityFilter !== 'Todas' && !presentCities.has(cityFilter)) cityFilter = 'Todas';
  citySelectEl.value = cityFilter;
  citySelectEl.classList.toggle('is-set', cityFilter !== 'Todas');
}

citySelectEl?.addEventListener('change', () => {
  cityFilter = citySelectEl.value;
  citySelectEl.classList.toggle('is-set', cityFilter !== 'Todas');
  renderPropertyGrid();
});

// Con ciudad elegida se muestran TODAS las propiedades de esa ciudad (destacadas o no).
function filteredProperties() {
  let base = propertiesForOperationAndPrice();
  if (favOnly && window.PropFavs) base = base.filter((p) => window.PropFavs.has(p.id));
  if (cityFilter === 'Todas') return base;
  return base.filter((p) => (p.location || '').startsWith(cityFilter));
}

// Destacada = marcada por un admin (featured) o con un destacado vigente (featured_until en el futuro).
function isFeatured(p) {
  return !!p.featured || (!!p.featured_until && new Date(p.featured_until) > new Date());
}

const clearFiltersBtn = document.getElementById('clear-filters');

function anyFilterActive() {
  return favOnly || operationFilter !== '' || typeFilter !== '' || roomsFilter !== '' || bathsFilter !== '' || minPriceFilter !== '' || maxPriceFilter !== '' || cityFilter !== 'Todas';
}

clearFiltersBtn?.addEventListener('click', () => {
  operationFilter = '';
  typeFilter = '';
  roomsFilter = '';
  bathsFilter = '';
  minPriceFilter = '';
  maxPriceFilter = '';
  if (minPriceEl) { minPriceEl.value = ''; minPriceEl.classList.remove('is-set'); }
  if (maxPriceEl) { maxPriceEl.value = ''; maxPriceEl.classList.remove('is-set'); }
  cityFilter = 'Todas';
  favOnly = false;
  rebuildFilters();
  renderPropertyGrid();
});

// Botón «Filtros» (solo en celular): muestra cuántos filtros hay activos y pliega/despliega el panel
const filtersToggleEl = document.getElementById('filters-toggle');
const selectFiltersEl = document.getElementById('select-filters');
function syncFiltersToggle() {
  const badge = document.getElementById('filters-badge');
  if (!badge) return;
  const n = [typeFilter, roomsFilter, bathsFilter, minPriceFilter, maxPriceFilter].filter((v) => v !== '').length + (cityFilter !== 'Todas' ? 1 : 0);
  badge.textContent = n ? String(n) : '';
}
if (filtersToggleEl && selectFiltersEl) {
  filtersToggleEl.addEventListener('click', () => {
    const open = !selectFiltersEl.classList.contains('is-open');
    selectFiltersEl.classList.toggle('is-open', open);
    filtersToggleEl.setAttribute('aria-expanded', String(open));
  });
}

// Barra «Guardadas · Lista | Mapa» del marketplace
function syncViewBar() {
  const favBtn = document.getElementById('view-fav');
  if (!favBtn || !window.PropFavs) return;
  const n = window.PropFavs.ids().filter((id) => allProperties.some((p) => p.id === id)).length;
  favBtn.classList.toggle('is-active', favOnly); favBtn.setAttribute('aria-pressed', String(favOnly));
  const c = document.getElementById('view-fav-count'); if (c) c.textContent = n ? String(n) : '';
  document.querySelectorAll('[data-view]').forEach((b) => { const on = b.dataset.view === viewMode; b.classList.toggle('is-active', on); b.setAttribute('aria-pressed', String(on)); });
}
const viewFavBtn = document.getElementById('view-fav');
if (viewFavBtn) viewFavBtn.addEventListener('click', () => { favOnly = !favOnly; renderPropertyGrid(); });
document.querySelectorAll('[data-view]').forEach((b) => b.addEventListener('click', () => { viewMode = b.dataset.view; renderPropertyGrid(false); }));
if (window.PropFavs) window.PropFavs.onChange(syncViewBar);

function renderPropertyGrid(resetPage = true) {
  // En el Inicio la grilla está oculta (las filas las dibuja home.js): no se construyen tarjetas que nadie ve.
  if (propGridEl.hasAttribute('hidden')) return;
  if (resetPage) propVisibleCount = PROP_PAGE_SIZE;
  syncFiltersToggle();
  clearFiltersBtn?.classList.toggle('hidden', !anyFilterActive());
  const stayView = operationFilter === 'temporal';
  propGridEl.classList.toggle('prop-grid--stay', stayView);

  // Las destacadas van primero; dentro de cada grupo se respeta el orden que define el administrador.
  // (No existen puntuaciones reales de los alojamientos temporales: no se inventa un orden por reseñas.)
  let list = filteredProperties()
    .map((p, i) => ({ p, i }))
    .sort((a, b) => (isFeatured(b.p) - isFeatured(a.p)) || (a.i - b.i))
    .map((x) => x.p);

  // Vista inicial del Marketplace (sin ningún filtro): solo las destacadas. Si todavía no hay ninguna,
  // se muestran las propiedades disponibles (reales) en vez de dejar la página vacía.
  let title = '';
  if (HAS_FILTERS && !anyFilterActive()) {
    const featuredOnly = list.filter(isFeatured);
    if (featuredOnly.length) { list = featuredOnly; title = 'Propiedades destacadas'; }
    else title = 'Propiedades disponibles';
  } else if (HAS_FILTERS) {
    title = (stayView ? 'Alojamientos temporales' : 'Resultados') + ' (' + list.length + ')';
  }
  if (resultsTitleEl) { resultsTitleEl.textContent = title; resultsTitleEl.classList.toggle('hidden', !title); }

  const emptyMessage = (minPriceFilter !== '' || maxPriceFilter !== '' || typeFilter !== '' || roomsFilter !== '' || bathsFilter !== '' || cityFilter !== 'Todas')
    ? 'No tenemos propiedades con esos filtros por ahora. Prueba con otra combinación o escríbenos por WhatsApp y te ayudamos a encontrar una.'
    : stayView
      ? 'Por ahora no tenemos alojamientos temporales publicados. Vuelve pronto o escríbenos por WhatsApp.'
      : operationFilter !== ''
        ? 'Por ahora no tenemos propiedades en ' + PROPERTY_OPERATION_LABELS[operationFilter].toLowerCase() + '. Mira las demás opciones o escríbenos por WhatsApp.'
        : 'Pronto publicaremos nuevas propiedades disponibles.';

  syncViewBar();
  const mapWrapEl = document.getElementById('prop-map-wrap');
  const mapOn = !!(HAS_FILTERS && viewMode === 'map' && mapWrapEl && window.PropMap);
  if (mapWrapEl) mapWrapEl.classList.toggle('hidden', !mapOn);
  propGridEl.classList.toggle('hidden', mapOn);
  if (propMoreWrapEl) propMoreWrapEl.classList.toggle('hidden', mapOn);
  if (mapOn) { window.PropMap.render(list, openProperty); return; }

  propGridEl.innerHTML = '';
  if (!list.length) {
    propGridEl.innerHTML = '<p class="prop-grid-empty">' + escapeHtml(favOnly ? 'Todavía no guardaste propiedades. Toca el corazón de una propiedad para verla aquí.' : emptyMessage) + '</p>';
    if (propMoreWrapEl) propMoreWrapEl.innerHTML = '';
    return;
  }
  list.slice(0, propVisibleCount).forEach((p) => propGridEl.appendChild(buildPropertyTile(p)));

  if (!propMoreWrapEl) return; // en el inicio no hay "Ver más": el botón al Marketplace es fijo
  const remaining = list.length - propVisibleCount;
  propMoreWrapEl.innerHTML = remaining > 0
    ? '<button type="button" class="cta-button cta-button--glass" id="prop-more-btn"><span>Ver más propiedades (' + remaining + ')</span></button>'
    : '';
  const moreBtn = document.getElementById('prop-more-btn');
  if (moreBtn) moreBtn.addEventListener('click', () => { propVisibleCount += PROP_PAGE_SIZE; renderPropertyGrid(false); });
}

// Un solo manejador para toda la grilla: WhatsApp directo con el agente, redes, o abrir la ficha.
propGridEl.addEventListener('click', (e) => {
  const tile = e.target.closest('.prop-tile');
  if (!tile) return;
  const property = tile.__property;
  const favBtn = e.target.closest('[data-fav]');
  if (favBtn) {
    const on = window.PropFavs.toggle(property.id);
    favBtn.classList.toggle('is-on', on); favBtn.setAttribute('aria-pressed', String(on));
    if (favOnly) renderPropertyGrid(false);
    return;
  }
  if (e.target.closest('[data-tile-wa]')) {
    e.preventDefault(); openProperty(property); return;   // el contacto se pide desde la ficha (formulario «Solicitar contacto»)
    trackEvent(property.id, 'whatsapp_click');        // el enlace del ícono abre WhatsApp por sí solo
    return;
  }
  if (e.target.closest('a')) return; // redes sociales: abren su enlace sin abrir la ficha
  openProperty(property);
});
propGridEl.addEventListener('keydown', (e) => {
  if (e.key !== 'Enter' && e.key !== ' ') return;
  const tile = e.target.closest('.prop-tile');
  if (!tile || e.target !== tile) return; // el botón y los enlaces internos mantienen su comportamiento
  e.preventDefault();
  openProperty(tile.__property);
});

/* ── Analítica: vistas y clics a WhatsApp por propiedad (sin datos personales) ── */
function trackEvent(propertyId, eventType) {
  if (!propertyId) return;
  supabaseClient.from('property_events').insert({ property_id: propertyId, event_type: eventType })
    .then(() => {}, () => {});
}

/* ── Formulario "Quiero que me contacten" (clientes interesados) ──
   El visitante nunca escribe en la tabla: llama a la función SQL submit_property_lead, que valida,
   limita abusos y asigna el agente. Si el SQL aún no se corrió, muestra un error genérico. */
const LEAD_CONSENT_TEXT = 'Acepto que mis datos se compartan con el agente de esta propiedad para que me contacte';
const CONNECTION_CONSENT_TEXT = 'Acepto que Bastet comparta mis datos con el agente de esta propiedad cuando acepte mi solicitud y se confirme la conexión';

function buildLeadForm(property) {
  const form = document.createElement('form');
  form.className = 'agent-form lead-form';
  form.noValidate = false;
  form.innerHTML =
    '<h4 class="lead-form-title">' + (contactGated(property) ? 'Solicitar contacto con el agente' : 'Quiero que me contacten') + '</h4>' +
    '<p class="agent-form-hint">' + (contactGated(property)
      ? 'Déjanos tus datos y el agente de esta propiedad decidirá si te contacta. Tus datos se comparten con él solo cuando acepta y Bastet confirma la conexión.'
      : 'Déjanos tus datos y el agente de esta propiedad te escribirá por WhatsApp.') + '</p>' +
    '<label class="agent-field"><span>Nombre *</span><input type="text" name="lead_name" required minlength="3" maxlength="120" autocomplete="name"></label>' +
    '<label class="agent-field"><span>WhatsApp *</span><input type="tel" name="lead_whatsapp" required minlength="7" maxlength="30" placeholder="+591 7xxxxxxx" autocomplete="tel"></label>' +
    '<label class="agent-field"><span>Mensaje (opcional)</span><textarea name="lead_message" rows="3" maxlength="500" placeholder="Ej: Quisiera agendar una visita"></textarea></label>' +
    // Campo trampa: las personas no lo ven; los bots suelen llenarlo.
    '<div class="lead-hp" aria-hidden="true"><label>Sitio web<input type="text" name="lead_website" tabindex="-1" autocomplete="off"></label></div>' +
    '<label class="lead-consent"><input type="checkbox" name="lead_consent" required><span>' + (contactGated(property) ? CONNECTION_CONSENT_TEXT : LEAD_CONSENT_TEXT) + '</span></label>' +
    '<p class="lead-privacy">Más información en nuestra <a href="privacidad.html" target="_blank" rel="noopener">Política de privacidad</a>.</p>' +
    '<p class="agent-form-error hidden" role="alert" data-lead-error></p>' +
    '<button type="submit" class="cta-button cta-button--block" data-lead-submit><span>' + (contactGated(property) ? 'Solicitar contacto' : 'Enviar mis datos') + '</span></button>';

  form.addEventListener('submit', async (e) => {
    e.preventDefault();
    const errorEl = form.querySelector('[data-lead-error]');
    const submitBtn = form.querySelector('[data-lead-submit]');
    const field = (name) => form.elements[name];
    errorEl.classList.add('hidden');

    const showSent = (code) => {
      form.innerHTML = contactGated(property)
        ? '<div class="agent-success"><p class="agent-success-title">¡Solicitud enviada!</p>' +
          '<p class="agent-form-hint">El agente revisará tu solicitud y, si la acepta, te contactará por WhatsApp.' + (code ? ' Tu código de solicitud es <b>' + escapeHtml(code) + '</b>.' : '') + '</p></div>'
        : '<div class="agent-success"><p class="agent-success-title">¡Listo, recibimos tus datos!</p>' +
          '<p class="agent-form-hint">El agente te contactará por WhatsApp lo antes posible.</p></div>';
    };
    if (field('lead_website').value) { showSent(); return; } // bot: se finge éxito y no se envía nada

    submitBtn.disabled = true;
    submitBtn.querySelector('span').textContent = 'Enviando…';
    const gated = contactGated(property);
    const { data: sentCode, error } = gated
      ? await supabaseClient.rpc('request_connection', {
        p_property: property.id,
        p_name: field('lead_name').value.trim(),
        p_phone: field('lead_whatsapp').value.trim(),
        p_email: null,
        p_message: field('lead_message').value.trim() || null,
        p_consent: field('lead_consent').checked,
      })
      : await supabaseClient.rpc('submit_property_lead', {
        p_property_id: property.id,
        p_name: field('lead_name').value.trim(),
        p_whatsapp: field('lead_whatsapp').value.trim(),
        p_message: field('lead_message').value.trim() || null,
        p_consent: field('lead_consent').checked,
      });
    if (error) {
      submitBtn.disabled = false;
      submitBtn.querySelector('span').textContent = contactGated(property) ? 'Solicitar contacto' : 'Enviar mis datos';
      // P0001 = mensaje propio de la función (ya viene en español); cualquier otra cosa, mensaje genérico.
      errorEl.textContent = (error.code === 'P0001' || (gated && error.message)) && error.message
        ? error.message
        : 'No pudimos enviar tus datos. Inténtalo de nuevo o escríbenos por WhatsApp.';
      errorEl.classList.remove('hidden');
      return;
    }
    showSent(gated ? sentCode : null);
  });
  if (window.ClientPrefill) window.ClientPrefill.fill(form, { '[name=lead_name]': 'name', '[name=lead_whatsapp]': 'phone' });
  return form;
}

/* ── Modal ── */
let leadFormNode = null;

function propUrl(code) { const u = new URL(location.href); if (code) u.searchParams.set('p', code); else u.searchParams.delete('p'); return u.pathname + (u.search || '') + u.hash; }

function openAgentProfile(agent) {
  if (!window.AgentProfile || !agent) return;
  const cur = selectedProperty;
  window.AgentProfile.open({
    agent, properties: allProperties, current: cur,
    helpers: { waUrl: whatsappUrl, price: formatPrice },
    onContact: () => { if (cur) trackEvent(cur.id, 'whatsapp_click'); },
    onOpenProperty: (p) => openProperty(p, { swap: true }),
  });
}

function openProperty(property, opts) {
  selectedProperty = property;
  selectedPhotoIndex = 0;
  leadFormNode = buildLeadForm(property);
  modalBackdrop.classList.add('prop-screen'); modal.classList.add('prop-screen');
  renderModal();
  modalBackdrop.classList.remove('hidden');
  document.body.style.overflow = 'hidden';
  modalBackdrop.scrollTop = 0;
  // La ficha tiene su propia dirección (?p=BST-1001): se puede compartir y el botón «atrás» del celular la cierra
  const code = formatPropertyCode(property) || property.id;
  if (opts && opts.swap) history.replaceState(history.state && history.state.prop ? { prop: property.id } : { propDeep: property.id }, '', propUrl(code));
  else if (opts && opts.deep) history.replaceState({ propDeep: property.id }, '', propUrl(code));
  else history.pushState({ prop: property.id }, '', propUrl(code));
  trackEvent(property.id, 'view');
}

function closeProperty(mode) {
  if (window.AgentProfile) window.AgentProfile.close();
  const wasOpen = !modalBackdrop.classList.contains('hidden');
  selectedProperty = null;
  leadFormNode = null;
  modalBackdrop.classList.add('hidden');
  modalBackdrop.classList.remove('prop-screen'); modal.classList.remove('prop-screen');
  document.body.style.overflow = '';
  if (!wasOpen || mode === 'pop') return;
  if (history.state && history.state.prop) history.back();
  else history.replaceState(null, '', propUrl(''));
}
window.addEventListener('popstate', () => { if (!modalBackdrop.classList.contains('hidden')) closeProperty('pop'); });

// Agente que publicó la propiedad, con el ícono de WhatsApp junto a sus redes (reemplaza al botón grande).
// El WhatsApp es el del agente, o el de la propiedad si el agente no puso uno, o el general de Bastet.
function buildAgentSectionHtml(agent, property, message) {
  const hasAgent = !!(agent && (agent.display_name || agent.avatar_url));
  const a = hasAgent ? agent : { display_name: 'Bastet', facebook_url: null, instagram_url: null, tiktok_url: null };
  const initial = (a.display_name || '?').trim().charAt(0).toUpperCase();
  const avatar = a.avatar_url
    ? '<img class="property-modal-agent-avatar" src="' + escapeHtml(a.avatar_url) + '" alt="">'
    : (hasAgent
      ? '<span class="property-modal-agent-avatar property-modal-agent-avatar-placeholder">' + escapeHtml(initial) + '</span>'
      : '<span class="property-modal-agent-avatar property-modal-agent-avatar-placeholder"><img src="assets/img/bastet-isotipo-cabeza-dorado.webp" alt="" style="width:70%;height:70%;object-fit:contain"></span>');
  const waIcon = '<a class="property-modal-cta" id="modal-whatsapp-cta" href="#" aria-label="Solicitar contacto con ' + escapeHtml(a.display_name || 'Bastet') + '">Solicitar contacto</a>';
  agent = a;   // el resto de la función usa `agent`
  const socials = waIcon;
  return (
    '<div class="property-modal-agent' + (hasAgent ? ' is-link' : '') + '"' + (hasAgent ? ' data-agent-open role="button" tabindex="0" aria-label="Ver perfil de ' + escapeHtml(agent.display_name || '') + '"' : '') + '>' +
      avatar +
      '<div class="property-modal-agent-info">' +
        '<p class="property-modal-agent-label">Publicado por</p>' +
        '<p class="property-modal-agent-name">' + escapeHtml(agent.display_name || '') + '</p>' +
        ((agent.agent_verified || agent.owner_verified) ? '<p class="vf-agent">' + (agent.agent_verified ? '✓ Agente verificado por Bastet' : '') + (agent.agent_verified && agent.owner_verified ? ' · ' : '') + (agent.owner_verified ? '✓ Propietario verificado' : '') + '</p>' : '') +
        (hasAgent ? '<p class="property-modal-agent-more">Ver perfil y sus propiedades ›</p>' : '') +
      '</div>' +
      (socials ? '<span class="property-modal-agent-social">' + socials + '</span>' : '') +
    '</div>'
  );
}

function renderModal() {
  if (!selectedProperty) return;
  const p = selectedProperty;
  const photos = (p.photos && p.photos.length) ? p.photos : [];
  const code = formatPropertyCode(p);
  const operationLabel = PROPERTY_OPERATION_LABELS[p.operation];
  // El código va primero para que el agente identifique la propiedad de un vistazo.
  const message = propertyWhatsappMessage(p);
  const features = propertyFeatureList(p).filter((f) => f.label !== 'Tipo' && f.label !== 'Operación');
  const agent = p.agent;
  const faved = !!(window.PropFavs && window.PropFavs.has(p.id));
  const HEART_SVG = '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M12 20.500s-7.500-4.600-7.500-10A4.300 4.300 0 0 1 12 7.900a4.300 4.300 0 0 1 7.500 2.600c0 5.400-7.500 10-7.500 10z"/></svg>';
  const spec = (label, v) => (v ? '<div><p class="property-modal-spec-label">' + label + '</p><p class="property-modal-spec-value">' + escapeHtml(v) + '</p></div>' : '');

  modal.innerHTML =
    '<div class="ps-top">' +
      '<button type="button" class="ps-icon" id="property-modal-close" aria-label="Volver"><svg viewBox="0 0 24 24" aria-hidden="true"><path d="M14.500 5.500L8 12l6.500 6.500"/></svg></button>' +
      '<span class="ps-top-code">' + (code ? escapeHtml(code) : 'Propiedad') + '</span>' +
      '<div class="ps-top-actions">' +
        '<button type="button" class="ps-icon" id="modal-share" aria-label="Compartir"><svg viewBox="0 0 24 24" aria-hidden="true"><path d="M12 3v12M8 7l4-4 4 4M5 13v6h14v-6"/></svg></button>' +
        (window.PropFavs ? '<button type="button" class="ps-icon property-modal-fav' + (faved ? ' is-on' : '') + '" id="modal-fav" aria-pressed="' + faved + '" aria-label="Guardar en favoritos">' + HEART_SVG + '</button>' : '') +
      '</div>' +
    '</div>' +
    '<div class="ps-gallery">' +
      (photos.length
        ? '<div class="ps-track" id="ps-track">' + photos.map((u, i) => '<div class="ps-slide"><img src="' + escapeHtml(u) + '" alt="' + escapeHtml(p.title) + (photos.length > 1 ? ' — foto ' + (i + 1) : '') + '"' + (i ? ' loading="lazy"' : '') + ' draggable="false"></div>').join('') + '</div>' +
          (photos.length > 1 ? '<span class="ps-count" id="ps-count">1 / ' + photos.length + '</span><button type="button" class="ps-nav ps-nav--prev" id="ps-prev" aria-label="Foto anterior">‹</button><button type="button" class="ps-nav ps-nav--next" id="ps-next" aria-label="Foto siguiente">›</button>' : '')
        : '<div class="ps-noimg">' + escapeHtml(p.title) + '</div>') +
    '</div>' +
    '<div class="property-modal-body ps-body">' +
      '<div>' +
        '<div class="property-modal-tags">' +
          (code ? '<span class="property-modal-code">Código ' + code + '</span>' : '') +
          (operationLabel ? '<span class="property-modal-tag">' + operationLabel + '</span>' : '') +
          (PROPERTY_TYPE_LABELS[p.property_type] ? '<span class="property-modal-tag">' + PROPERTY_TYPE_LABELS[p.property_type] + '</span>' : '') +
          (p.verified ? '<span class="property-modal-tag vf-badge">✓ Propiedad verificada</span>' : (window.Connections && window.Connections.verificationRequired() && p.operation !== 'temporal' ? '<span class="property-modal-tag vf-pending">Pendiente de verificación</span>' : '')) +
        '</div>' +
        '<p class="property-modal-price">' + formatPrice(p.price, p.currency, p.operation) + '</p>' +
        (p.exchange_rate && p.currency !== 'BOB' ? '<p class="property-modal-rate">Tipo de cambio aceptado: ' + escapeHtml(p.exchange_rate) + '</p>' : '') +
        '<h3 class="property-modal-title">' + escapeHtml(p.title) + '</h3>' +
        '<p class="property-modal-location">' + escapeHtml(p.location) + (p.address ? ' · ' + escapeHtml(p.address) : '') + '</p>' +
      '</div>' +
      '<div class="property-modal-specs">' + spec('Área', withUnit(p.area, 'm²')) + spec('Ambientes', p.rooms) + spec('Baños', p.baths) + '</div>' +
      (p.description ? '<section class="ps-section"><h4>Descripción</h4><p class="property-modal-desc">' + escapeHtml(p.description).replace(/\n/g, '<br>') + '</p></section>' : '') +
      (features.length
        ? '<section class="ps-section"><h4>Características</h4><div class="property-modal-features">' +
            features.map((f) => '<div class="property-modal-feature"><span class="property-modal-feature-label">' + f.label + '</span><span class="property-modal-feature-value">' + escapeHtml(f.value) + '</span></div>').join('') +
          '</div></section>'
        : '') +
      '<section class="ps-section"><h4>Ubicación</h4><div class="ps-map" id="ps-map"><p class="pm-error">Cargando mapa…</p></div><p class="ps-map-note" id="ps-map-note"></p></section>' +
      buildAgentSectionHtml(p.agent, p, message) +
      '<div id="lead-form-slot"></div>' +
    '</div>' +
    '<div class="ps-bar">' +
      (window.PropFavs ? '<button type="button" class="ps-save' + (faved ? ' is-on' : '') + '" id="ps-save" aria-pressed="' + faved + '">' + HEART_SVG + '<span>' + (faved ? 'Guardada' : 'Guardar') + '</span></button>' : '') +
      '<a class="ps-wa" id="ps-wa" href="#">Solicitar contacto</a>' +
    '</div>';

  // El formulario vive fuera del innerHTML para no perder lo escrito al cambiar de foto.
  const leadSlot = document.getElementById('lead-form-slot');
  if (leadSlot && leadFormNode) leadSlot.appendChild(leadFormNode);

  document.getElementById('property-modal-close').addEventListener('click', () => closeProperty());
  const agentCard = modal.querySelector('[data-agent-open]');
  if (agentCard) {
    const go = (e) => { if (e.target.closest('a')) return; if (e.type === 'keydown' && e.key !== 'Enter' && e.key !== ' ') return; e.preventDefault(); openAgentProfile(p.agent); };
    agentCard.addEventListener('click', go); agentCard.addEventListener('keydown', go);
  }
  const syncFav = (on) => {
    ['modal-fav', 'ps-save'].forEach((id) => { const b = document.getElementById(id); if (b) { b.classList.toggle('is-on', on); b.setAttribute('aria-pressed', String(on)); } });
    const lbl = document.querySelector('#ps-save span'); if (lbl) lbl.textContent = on ? 'Guardada' : 'Guardar';
    propGridEl.querySelectorAll('.prop-tile').forEach((t) => { if (t.__property && t.__property.id === p.id) { const b = t.querySelector('[data-fav]'); if (b) { b.classList.toggle('is-on', on); b.setAttribute('aria-pressed', String(on)); } } });
  };
  const toggleFav = () => { const on = window.PropFavs.toggle(p.id); syncFav(on); if (favOnly && !on) { closeProperty(); renderPropertyGrid(false); } };
  ['modal-fav', 'ps-save'].forEach((id) => { const b = document.getElementById(id); if (b) b.addEventListener('click', toggleFav); });
  // Con conexiones activas el botón lleva al formulario «Solicitar contacto»; sin ellas, abre WhatsApp como siempre
  const goLeadForm = (e) => {
    e.preventDefault();
    const slot = document.getElementById('lead-form-slot');
    if (slot) { slot.scrollIntoView({ behavior: 'smooth', block: 'center' }); const f = slot.querySelector('input'); if (f) setTimeout(() => f.focus({ preventScroll: true }), 350); }
  };
  ['modal-whatsapp-cta', 'ps-wa'].forEach((id) => document.getElementById(id).addEventListener('click', (e) => {
    goLeadForm(e);
  }));
  document.getElementById('modal-share').addEventListener('click', async () => {
    const url = location.origin + location.pathname + '?p=' + encodeURIComponent(code || p.id);
    try {
      if (navigator.share) await navigator.share({ title: p.title, text: p.title + ' — Bastet', url });
      else { await navigator.clipboard.writeText(url); const b = document.getElementById('modal-share'); b.classList.add('is-done'); setTimeout(() => b.classList.remove('is-done'), 1800); }
    } catch (e) { /* el usuario canceló */ }
  });

  // Galería: deslizable con el dedo; el contador sigue a la foto visible y las flechas sirven en escritorio
  const track = document.getElementById('ps-track');
  if (track && photos.length > 1) {
    const count = document.getElementById('ps-count');
    track.addEventListener('scroll', () => { const i = Math.round(track.scrollLeft / Math.max(track.clientWidth, 1)); count.textContent = (Math.min(i, photos.length - 1) + 1) + ' / ' + photos.length; }, { passive: true });
    document.getElementById('ps-prev').addEventListener('click', () => track.scrollBy({ left: -track.clientWidth, behavior: 'smooth' }));
    document.getElementById('ps-next').addEventListener('click', () => track.scrollBy({ left: track.clientWidth, behavior: 'smooth' }));
  }

  // Mapa de ubicación (exacta si el anfitrión fijó el pin; si no, zona aproximada de la ciudad)
  const mapEl = document.getElementById('ps-map');
  if (window.PropMap && window.PropMap.mini) {
    window.PropMap.mini(mapEl, p).then((c) => {
      const note = document.getElementById('ps-map-note'); if (!note) return;
      if (!c) { mapEl.remove(); return; }
      const q = c.exact ? c.lat + ',' + c.lng : [p.address, p.location, 'Bolivia'].filter(Boolean).join(', ');
      note.innerHTML = (c.exact ? '' : 'Ubicación aproximada: la dirección exacta te la confirma el agente. ') + '<a href="https://www.google.com/maps/search/?api=1&query=' + encodeURIComponent(q) + '" target="_blank" rel="noopener">Abrir en Google Maps</a>';
    });
  }
}

modalBackdrop.addEventListener('click', (e) => {
  if (e.target === modalBackdrop && !modalBackdrop.classList.contains('prop-screen')) closeProperty();
});
document.addEventListener('keydown', (e) => {
  if (e.key === 'Escape' && !modalBackdrop.classList.contains('hidden')) closeProperty();
});

loadProperties();

/* ── Testimonios: fetch + carrusel (mismo efecto de anillo que Propiedades) ── */
// Anillo amplio y casi plano: a 18° entre tarjetas caben 4 a lo ancho de una laptop (1366px),
// las de los extremos entrando/saliendo por el desvanecido de los bordes.
const TESTI_RING_SIZE = 20;
const TESTI_RING_RADIUS = 1050;
const testiRingStage = document.getElementById('testi-ring-stage');

function buildTestimonialCard(t) {
  const card = document.createElement('div');
  card.className = 'testi-ring-card';
  card.setAttribute('data-ring-card', '');
  const initial = (t.name || '?').trim().charAt(0).toUpperCase();
  const photo = t.photo_url
    ? '<img class="testi-ring-photo" src="' + escapeHtml(t.photo_url) + '" alt="' + escapeHtml(t.name) + '" loading="lazy">'
    : '<div class="testi-ring-photo testi-ring-photo-placeholder">' + escapeHtml(initial) + '</div>';
  card.innerHTML =
    '<div class="testi-ring-header">' +
      photo +
      '<div class="testi-ring-who"><p class="testi-ring-name">' + escapeHtml(t.name) + '</p><p class="testi-ring-role">' + escapeHtml(t.role_label) + '</p></div>' +
    '</div>' +
    '<p class="testi-ring-quote">&ldquo;' + escapeHtml(t.quote) + '&rdquo;</p>';
  return card;
}

const testimonialRing = testiRingStage ? createRingCarousel({
  stage: testiRingStage,
  radius: TESTI_RING_RADIUS,
  size: TESTI_RING_SIZE,
  buildCard: buildTestimonialCard,
  emptyText: 'Pronto compartiremos las experiencias de nuestros clientes.',
  brightCenter: true,
  cull: 80,
  edgeFade: true,
  perspective: 1200, // .testi-ring-stage { perspective }
  cardHalfWidth: 145, // .testi-ring-card { width: 290px }
}) : null;

async function loadTestimonials() {
  if (!testimonialRing) return;
  const { data, error } = await supabaseClient
    .from('testimonials')
    .select('*')
    .eq('is_active', true)
    .order('sort_order', { ascending: true });

  if (error) {
    console.error('Error cargando testimonios:', error);
    testimonialRing.render([]);
    return;
  }
  testimonialRing.render(data || []);
}

loadTestimonials();

/* ── Franja de logos de empresas aliadas ── */
async function loadPartners() {
  const track = document.getElementById('partners-track');
  if (!track) return; // marketplace.html no tiene la franja de aliados
  const { data, error } = await supabaseClient
    .from('partners')
    .select('*')
    .order('sort_order', { ascending: true });

  if (error || !data || !data.length) {
    document.querySelector('.partners-strip')?.remove();
    return;
  }

  // Los espacios de relleno «Anuncie aquí» se reemplazan por una sola tarjeta «Hospeda a tu gente con nosotros» que lleva a la página Empresas (empresas.html), donde se crea la cuenta de empresa
  const isPlaceholder = (p) => /anuncie-aqui/i.test(p.logo_url || '');
  const isHost = (p) => /hospeda-a-tu-gente/i.test(p.logo_url || '');
  const shown = data.filter((p) => !isPlaceholder(p)).map((p) => (isHost(p) ? { host: true, logo_url: 'assets/img/hospeda-a-tu-gente.webp' } : p))
    .concat(data.some(isPlaceholder) && !data.some(isHost) ? [{ host: true, logo_url: 'assets/img/hospeda-a-tu-gente.webp' }] : []);
  const logosHtml = shown.map((p) => {
    if (p.host) return '<a class="partner-host" href="empresas.html" aria-label="Hospeda a tu gente con nosotros: conoce el alojamiento para empresas"><img src="' + p.logo_url + '" alt="Hospeda a tu gente con nosotros" data-logo="' + p.logo_url + '"></a>';
    const img = '<img src="' + escapeHtml(p.logo_url) + '" alt="' + escapeHtml(p.name || 'Empresa aliada') + '" data-logo="' + escapeHtml(p.logo_url) + '">';
    return p.url
      ? '<a href="' + escapeHtml(p.url) + '" target="_blank" rel="noopener" aria-label="' + escapeHtml(p.name || 'Empresa aliada') + '">' + img + '</a>'
      : img;
  }).join('');
  // El track se duplica una vez para que la animación de scroll sea continua (sin salto visible).
  track.innerHTML = logosHtml + logosHtml;
  // Cada logo se recorta y se dimensiona una vez (el track está duplicado: se aplica a ambas copias)
  const byUrl = new Map();
  track.querySelectorAll('img[data-logo]').forEach((img) => {
    const url = img.dataset.logo;
    if (!byUrl.has(url)) byUrl.set(url, []);
    byUrl.get(url).push(img);
  });
  // El recorte de logos pinta en un <canvas> y recorre píxeles: es lo más pesado del arranque. Se hace de uno en uno,
  // en tiempos libres y solo cuando la cinta está por verse (queda debajo de la portada).
  const runNormalize = () => {
    const items = [...byUrl];
    const next = () => {
      const it = items.shift();
      if (!it) return;
      normalizeLogo(it[0], it[1]);
      (window.requestIdleCallback || setTimeout)(next, { timeout: 400 });
    };
    next();
  };
  const strip = document.querySelector('.partners-strip');
  if (strip && 'IntersectionObserver' in window) {
    const io = new IntersectionObserver((entries) => { if (entries.some((e) => e.isIntersecting)) { io.disconnect(); runNormalize(); } }, { rootMargin: '600px 0px' });
    io.observe(strip);
  } else runNormalize();
}

// Los logos llegan con márgenes blancos o transparentes muy distintos (algunos ocupan menos de la
// mitad de la imagen) y con proporciones distintas, así que unos se ven enormes y otros diminutos.
// Aquí se recorta el margen (lo que es casi blanco o transparente) en un <canvas> y se elige un
// tamaño con el mismo peso visual para todos: los cuadrados y redondos van a la altura máxima y
// los muy anchos (tipo Coca-Cola) se achican un poco para no dominar la cinta.
const LOGO_MAX_H = 56;     // alto máximo en px (la cinta mide 72px: 8px de aire arriba y abajo)
const LOGO_MAX_W = 230;
const LOGO_WIDE_ASPECT = 2.2; // desde esta proporción (ancho/alto) el logo empieza a bajar de alto
function logoSize(aspect) {
  let h = LOGO_MAX_H * Math.min(1, Math.sqrt(LOGO_WIDE_ASPECT / aspect));
  let w = h * aspect;
  if (w > LOGO_MAX_W) { w = LOGO_MAX_W; h = w / aspect; }
  return { w: Math.round(w), h: Math.round(h) };
}
function applyLogoSize(imgs, aspect) {
  const { w, h } = logoSize(aspect);
  imgs.forEach((img) => { img.style.width = w + 'px'; img.style.height = h + 'px'; });
}
function normalizeLogo(url, imgs) {
  const src = new Image();
  src.crossOrigin = 'anonymous';
  src.onload = () => {
    const nw = src.naturalWidth, nh = src.naturalHeight;
    if (!nw || !nh) return;
    applyLogoSize(imgs, nw / nh); // tamaño provisional, por si el recorte falla
    try {
      // 1) Buscar el contenido en una copia chica (máx. 400px de lado)
      const k = 400 / Math.max(nw, nh);
      const aw = Math.max(1, Math.round(nw * k)), ah = Math.max(1, Math.round(nh * k));
      const probe = document.createElement('canvas');
      probe.width = aw; probe.height = ah;
      const pctx = probe.getContext('2d', { willReadFrequently: true });
      pctx.drawImage(src, 0, 0, aw, ah);
      const px = pctx.getImageData(0, 0, aw, ah).data;
      let x0 = aw, y0 = ah, x1 = -1, y1 = -1;
      for (let y = 0; y < ah; y++) {
        for (let x = 0; x < aw; x++) {
          const i = (y * aw + x) * 4;
          const isBg = px[i + 3] < 16 || (px[i] > 235 && px[i + 1] > 235 && px[i + 2] > 235);
          if (isBg) continue;
          if (x < x0) x0 = x; if (x > x1) x1 = x;
          if (y < y0) y0 = y; if (y > y1) y1 = y;
        }
      }
      if (x1 < 0) return; // imagen vacía o toda blanca: se deja como está
      // 2) Rectángulo del contenido en la imagen original (con 1px de aire)
      const sx = Math.max(0, (x0 - 1) / k), sy = Math.max(0, (y0 - 1) / k);
      const sw = Math.min(nw - sx, (x1 - x0 + 3) / k), sh = Math.min(nh - sy, (y1 - y0 + 3) / k);
      const aspect = sw / sh;
      const { w, h } = logoSize(aspect);
      // 3) Dibujar solo el contenido, a la resolución de la pantalla
      const dpr = Math.min(3, Math.max(2, window.devicePixelRatio || 1));
      const out = document.createElement('canvas');
      out.width = Math.round(w * dpr); out.height = Math.round(h * dpr);
      const octx = out.getContext('2d');
      octx.imageSmoothingQuality = 'high';
      octx.drawImage(src, sx, sy, sw, sh, 0, 0, out.width, out.height);
      out.toBlob((blob) => {
        if (!blob) return;
        const trimmed = URL.createObjectURL(blob);
        imgs.forEach((img) => { img.src = trimmed; });
        applyLogoSize(imgs, aspect);
      }, 'image/png');
    } catch (e) {
      // Sin permiso CORS para leer los píxeles: queda con el tamaño provisional
    }
  };
  src.src = url;
}

loadPartners();

// Barra de búsqueda del inicio: las ciudades salen de la misma lista que usa el Marketplace
(function fillHomeSearch() {
  const sel = document.getElementById('home-search-city');
  if (!sel) return;
  BOLIVIA_CITIES.forEach((c) => { const o = document.createElement('option'); o.value = c; o.textContent = c; sel.appendChild(o); });
})();

/* ── Video del hero: reproduce y luego retrocede en cámara lenta (ping-pong), en vez de cortar y reiniciar ── */
(function setupHeroVideo() {
  const video = document.getElementById('hero-video');
  if (!video) return;
  if (reducedMotion) { video.pause(); return; }

  let reversing = false;
  let rafId = null;

  function stepReverse() {
    if (!reversing) return;
    video.currentTime = Math.max(0, video.currentTime - 0.033);
    if (video.currentTime <= 0.03) {
      reversing = false;
      video.currentTime = 0;
      video.play().catch(() => {});
      return;
    }
    rafId = requestAnimationFrame(stepReverse);
  }

  video.addEventListener('timeupdate', () => {
    if (!reversing && video.duration && video.currentTime >= video.duration - 0.08) {
      reversing = true;
      video.pause();
      rafId = requestAnimationFrame(stepReverse);
    }
  });

  video.play().catch(() => {});
})();

/* ── Instalar Bastet como app (PWA): los botones "Instalar app" llevan a la pantalla app.html (mockups, ventajas y descarga) ── */
(function setupInstallApp() {
  if ('serviceWorker' in navigator) navigator.serviceWorker.register('sw.js?v=20261115b').catch(() => {});

  // Si ya está instalada (abierta como app), el botón no se muestra.
  const isStandalone = window.matchMedia('(display-mode: standalone)').matches || window.navigator.standalone;
  if (isStandalone) return;
  document.querySelectorAll('[data-install-app]').forEach((a) => { a.hidden = false; });
})();
