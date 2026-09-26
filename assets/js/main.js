const WHATSAPP_PHONE = '59177666205';
const WHATSAPP_GENERIC_MESSAGE = 'Hola Bastet, quiero solicitar una evaluación gratuita para vender mi inmueble, esta es la ubicación del mismo ⬇️';

function normalizePhone(phone) {
  return (phone || '').replace(/[^0-9]/g, '');
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
}
burger.addEventListener('click', () => setMenuOpen(!mobilePanel.classList.contains('is-open')));
mobilePanel.querySelectorAll('a').forEach((a) => a.addEventListener('click', () => setMenuOpen(false)));

window.addEventListener('scroll', () => {
  navbar.classList.toggle('is-scrolled', window.scrollY > 40);
}, { passive: true });

/* ── Acceso agentes: iniciar sesión (y saltar al panel) o solicitar una cuenta ── */
const agentModalBackdrop = document.getElementById('agent-modal-backdrop');
const agentLoginForm = document.getElementById('agent-login-form');
const agentRequestForm = document.getElementById('agent-request-form');
const agentRequestSuccess = document.getElementById('agent-request-success');

BOLIVIA_CITIES.forEach((city) => {
  const opt = document.createElement('option');
  opt.value = city;
  opt.textContent = city;
  document.getElementById('req-city').appendChild(opt);
});

function setAgentTab(tab) {
  document.querySelectorAll('.agent-tab').forEach((b) => b.classList.toggle('is-active', b.dataset.agentTab === tab));
  // Tras enviar una solicitud, la pestaña muestra el mensaje de éxito en vez del formulario.
  const sent = agentRequestSuccess.dataset.sent === '1';
  agentLoginForm.classList.toggle('hidden', tab !== 'login');
  agentRequestForm.classList.toggle('hidden', tab !== 'request' || sent);
  agentRequestSuccess.classList.toggle('hidden', tab !== 'request' || !sent);
}

async function openAgentModal(tab = 'login') {
  setMenuOpen(false);
  // Si ya hay una sesión activa en este navegador, ir directo al panel.
  const { data: { session } } = await supabaseClient.auth.getSession();
  if (session) { window.location.href = 'admin/'; return; }
  setAgentTab(tab);
  agentModalBackdrop.classList.remove('hidden');
  document.getElementById(tab === 'request' ? 'req-name' : 'agent-login-email').focus();
}

function closeAgentModal() {
  agentModalBackdrop.classList.add('hidden');
}

document.querySelectorAll('[data-agent-access]').forEach((btn) => btn.addEventListener('click', () => openAgentModal()));
// El panel enlaza a /#solicitar-cuenta ("¿No tienes una cuenta?") para abrir directo el formulario.
if (window.location.hash === '#solicitar-cuenta') {
  history.replaceState(null, '', window.location.pathname);
  openAgentModal('request');
}
document.querySelectorAll('.agent-tab').forEach((btn) => btn.addEventListener('click', () => setAgentTab(btn.dataset.agentTab)));
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

agentLoginForm.addEventListener('submit', async (e) => {
  e.preventDefault();
  showAgentError('agent-login-error', '');
  const btn = document.getElementById('agent-login-submit');
  btn.disabled = true;
  const { error } = await supabaseClient.auth.signInWithPassword({
    email: document.getElementById('agent-login-email').value.trim(),
    password: document.getElementById('agent-login-password').value,
  });
  if (error) {
    btn.disabled = false;
    showAgentError('agent-login-error', /invalid login credentials/i.test(error.message)
      ? 'Correo o contraseña incorrectos.'
      : /email not confirmed/i.test(error.message)
        ? 'Debes confirmar tu correo antes de iniciar sesión.'
        : 'No se pudo iniciar sesión: ' + error.message);
    return;
  }
  // La sesión queda guardada en este navegador; el panel la retoma (y valida rol/estado).
  window.location.href = 'admin/';
});

// "¿Olvidaste tu contraseña?": usa el correo ya escrito arriba y manda el enlace directo.
document.getElementById('agent-forgot').addEventListener('click', async () => {
  const emailInput = document.getElementById('agent-login-email');
  const note = document.getElementById('agent-forgot-note');
  const email = emailInput.value.trim();
  showAgentError('agent-login-error', '');
  note.classList.add('hidden');
  if (!email || !emailInput.checkValidity()) {
    showAgentError('agent-login-error', 'Escribe arriba el correo de tu cuenta y vuelve a hacer clic en "¿Olvidaste tu contraseña?".');
    emailInput.focus();
    return;
  }
  const btn = document.getElementById('agent-forgot');
  btn.disabled = true;
  const { error } = await supabaseClient.auth.resetPasswordForEmail(email, {
    redirectTo: window.location.origin + '/admin/',
  });
  btn.disabled = false;
  if (error) {
    showAgentError('agent-login-error', /rate limit/i.test(error.message)
      ? 'Ya pediste varios enlaces seguidos. Espera unos minutos y vuelve a intentarlo.'
      : 'No se pudo enviar el enlace: ' + error.message);
    return;
  }
  // Mismo mensaje exista o no la cuenta (no se revela qué correos están registrados).
  note.innerHTML = 'Si <strong>' + escapeHtml(email) + '</strong> tiene una cuenta de agente en Bastet, te llegará un correo con un enlace para crear una nueva contraseña (revisa también la carpeta de spam).' +
    ' ¿No tienes cuenta? <a href="#" data-agent-go-request>Solicítala aquí</a>.';
  note.classList.remove('hidden');
  note.querySelector('[data-agent-go-request]').addEventListener('click', (ev) => { ev.preventDefault(); setAgentTab('request'); });
});

agentRequestForm.addEventListener('submit', async (e) => {
  e.preventDefault();
  showAgentError('agent-request-error', '');
  const value = (id) => document.getElementById(id).value.trim();
  const btn = document.getElementById('agent-request-submit');
  btn.disabled = true;
  const { error } = await supabaseClient.from('agent_requests').insert({
    full_name: value('req-name'),
    whatsapp: value('req-whatsapp'),
    email: value('req-email'),
    city: value('req-city') || null,
    experience: value('req-experience') || null,
    company: value('req-company') || null,
    message: value('req-message') || null,
  });
  btn.disabled = false;
  if (error) {
    showAgentError('agent-request-error', 'No pudimos enviar tu solicitud. Revisa los datos o escríbenos por WhatsApp al +591 77666205.');
    return;
  }
  agentRequestForm.reset();
  agentRequestSuccess.dataset.sent = '1';
  setAgentTab('request');
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
    }, { threshold: 0.15 })
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

function formatPriceUSD(price) {
  const digits = (price || '').toString().replace(/[^0-9]/g, '');
  if (!digits) return escapeHtml(price || '');
  return digits.replace(/\B(?=(\d{3})+(?!\d))/g, '.') + ' USD';
}

const reducedMotion = window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches;

/* ── Carrusel 3D en anillo, genérico (lo usan Propiedades y Testimonios) ──
   Reproduce la misma física: rotación automática + arrastre, con la tarjeta
   resuelta en pointerdown (no en el evento "click") para que no falle si el
   anillo se movió entre el down y el up. */
function createRingCarousel({ stage, radius, size = 12, cull = 50, speed = 5, buildCard, onSelect, onContact, emptyText = 'Próximamente.', brightCenter = false, edgeFade = false }) {
  const step = 360 / size;
  // edgeFade: el anillo ocupa todo el ancho y se desvanece en los bordes con una máscara
  // en CSS (.ring-stage--edge-fade). Aquí solo se ocultan las tarjetas que ya salieron de
  // la pantalla y se suaviza la entrada/salida por ángulo para que nunca aparezcan de golpe.
  const PERSPECTIVE = 1000; // igual que .ring-stage { perspective }
  const CARD_HALF_WIDTH = 115;
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
      const brightness = brightCenter ? (1 - 0.8 * (1 / c - 1)) : Math.min(1.05, 0.72 + 0.5 * (1 / c - 1));
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

/* ── Propiedades: fetch + city filter + carrusel + modal ── */
const RING_SIZE = 12;
const RING_RADIUS = 520;

const ringStage = document.getElementById('ring-stage');
const cityFiltersEl = document.getElementById('city-filters');
const modalBackdrop = document.getElementById('property-modal-backdrop');
const modal = document.getElementById('property-modal');

let allProperties = [];
let cityFilter = 'Todas';
let operationFilter = 'todas'; // 'todas' | 'venta' | 'alquiler' | 'anticretico'
let typeFilter = ''; // '' | 'casa' | 'departamento' | 'terreno'
let roomsFilter = ''; // '' = cualquiera; '3' = 3 o más habitaciones
const roomsSelectEl = document.getElementById('rooms-filter-select');
const ROOMS_MIN_OPTIONS = [1, 2, 3, 4, 5];
let bathsFilter = ''; // '' = cualquiera; '2' = 2 o más baños
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
let budgetFilter = ''; // índice del rango elegido en budgetRanges(), '' = cualquier presupuesto
const budgetSelectEl = document.getElementById('budget-filter-select');

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

  // "3 o más (11)" -> texto "3 o más" + cantidad en una pastilla
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
[typeSelectEl, roomsSelectEl, bathsSelectEl, budgetSelectEl].forEach(enhanceSelect);

// Rangos de presupuesto (USD) según la operación: un alquiler mensual no se busca
// con los mismos montos que una compra o un anticrético. [mínimo exclusivo, máximo inclusivo]
const BUDGET_RANGES = {
  venta: [[0, 50000], [50000, 100000], [100000, 200000], [200000, 500000], [500000, Infinity]],
  alquiler: [[0, 300], [300, 600], [600, 1000], [1000, 2000], [2000, Infinity]],
  anticretico: [[0, 20000], [20000, 40000], [40000, 60000], [60000, Infinity]],
};
function budgetRanges() { return BUDGET_RANGES[operationFilter] || BUDGET_RANGES.venta; }

function propertyPriceNumber(p) {
  const digits = (p.price || '').toString().replace(/[^0-9]/g, '');
  return digits ? parseInt(digits, 10) : null;
}

function formatUSDNumber(n) { return n.toString().replace(/\B(?=(\d{3})+(?!\d))/g, '.'); }

function budgetRangeLabel([min, max]) {
  const suffix = operationFilter === 'alquiler' ? ' USD/mes' : ' USD';
  if (min === 0) return 'Hasta ' + formatUSDNumber(max) + suffix;
  if (max === Infinity) return 'Más de ' + formatUSDNumber(min) + suffix;
  return formatUSDNumber(min) + ' – ' + formatUSDNumber(max) + suffix;
}

function inBudgetRange(p, [min, max]) {
  const price = propertyPriceNumber(p);
  return price !== null && price > min && price <= max;
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

typeSelectEl.addEventListener('change', () => {
  typeFilter = typeSelectEl.value;
  cityFilter = 'Todas';
  typeSelectEl.classList.toggle('is-set', typeFilter !== '');
  buildRoomsFilter();  // las cantidades de habitaciones, baños y presupuesto dependen del tipo
  buildBathsFilter();
  buildBudgetFilter();
  buildCityFilters();
  renderPropertyRing();
});

// Selector "N o más habitaciones", con cantidades dentro de la operación y el tipo elegidos.
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
    opt.textContent = min + ' o más (' + count + ')';
    opt.disabled = count === 0;
    roomsSelectEl.appendChild(opt);
  });
  roomsSelectEl.value = roomsFilter;
  roomsSelectEl.classList.toggle('is-set', roomsFilter !== '');
}

roomsSelectEl.addEventListener('change', () => {
  roomsFilter = roomsSelectEl.value;
  cityFilter = 'Todas';
  roomsSelectEl.classList.toggle('is-set', roomsFilter !== '');
  buildBathsFilter();  // las cantidades de baños y de presupuesto dependen de las habitaciones
  buildBudgetFilter();
  buildCityFilters();
  renderPropertyRing();
});

// Selector "N o más baños", con cantidades dentro de operación, tipo y habitaciones elegidos.
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
    opt.textContent = min + ' o más (' + count + ')';
    opt.disabled = count === 0;
    bathsSelectEl.appendChild(opt);
  });
  bathsSelectEl.value = bathsFilter;
  bathsSelectEl.classList.toggle('is-set', bathsFilter !== '');
}

bathsSelectEl.addEventListener('change', () => {
  bathsFilter = bathsSelectEl.value;
  cityFilter = 'Todas';
  bathsSelectEl.classList.toggle('is-set', bathsFilter !== '');
  buildBudgetFilter(); // las cantidades por rango dependen de los baños
  buildCityFilters();
  renderPropertyRing();
});

// Opciones del selector con la cantidad de propiedades de cada rango (dentro de la
// operación, el tipo, las habitaciones y los baños elegidos); los rangos vacíos quedan deshabilitados.
function buildBudgetFilter() {
  const base = propertiesBeforeBudget();
  budgetSelectEl.innerHTML = '';
  const any = document.createElement('option');
  any.value = '';
  any.textContent = 'Cualquier presupuesto';
  budgetSelectEl.appendChild(any);
  budgetRanges().forEach((range, i) => {
    const count = base.filter((p) => inBudgetRange(p, range)).length;
    const opt = document.createElement('option');
    opt.value = String(i);
    opt.textContent = budgetRangeLabel(range) + ' (' + count + ')';
    opt.disabled = count === 0;
    budgetSelectEl.appendChild(opt);
  });
  budgetSelectEl.value = budgetFilter;
  budgetSelectEl.classList.toggle('is-set', budgetFilter !== '');
}

budgetSelectEl.addEventListener('change', () => {
  budgetFilter = budgetSelectEl.value;
  cityFilter = 'Todas';
  budgetSelectEl.classList.toggle('is-set', budgetFilter !== '');
  buildCityFilters();
  renderPropertyRing();
});
const operationFiltersEl = document.getElementById('operation-filters');
let selectedProperty = null;
let selectedPhotoIndex = 0;

function placeholderImgHtml(title) {
  return '<div class="ring-card-img-placeholder">' + escapeHtml(title || 'BASTET') + '</div>';
}

function buildPropertyCard(property) {
  const card = document.createElement('div');
  card.className = 'ring-card' + (property.featured ? ' ring-card--featured' : '');
  card.setAttribute('data-ring-card', '');
  const firstPhoto = (property.photos && property.photos[0]) || null;
  card.innerHTML = firstPhoto
    ? '<img class="ring-card-img" src="' + escapeHtml(firstPhoto) + '" alt="' + escapeHtml(property.title) + '" loading="lazy">'
    : placeholderImgHtml(property.title);
  const priceLine = property.price
    ? '<span class="ring-card-price">' + formatPriceUSD(property.price) + (property.exchange_rate ? ' · ' + escapeHtml(property.exchange_rate) : '') + '</span>'
    : '';
  const featuredIcon = property.featured
    ? '<img class="ring-card-featured-icon" src="assets/img/bastet-icon-gold.png" alt="Destacada">'
    : '';
  const metaLine = [PROPERTY_TYPE_LABELS[property.property_type], formatPropertyCode(property)].filter(Boolean).join(' · ');
  const operationBadge = PROPERTY_OPERATION_LABELS[property.operation]
    ? '<span class="ring-card-operation">' + PROPERTY_OPERATION_LABELS[property.operation] + '</span>'
    : '';
  card.innerHTML +=
    '<div class="ring-card-overlay"></div>' +
    '<div class="ring-card-label">' +
      operationBadge +
      '<span class="ring-card-title-row">' + featuredIcon + '<span class="ring-card-title-text">' + escapeHtml(property.title) + '</span></span>' +
      priceLine +
      (metaLine ? '<span class="ring-card-meta">' + escapeHtml(metaLine) + '</span>' : '') +
    '</div>' +
    buildAgentBadgeHtml(property.agent);
  return card;
}

// Solo avatar + nombre (sin redes: las redes se ven en el modal al abrir la propiedad).
// Mensaje de WhatsApp de una propiedad: empieza con el código para que el agente la
// identifique al instante, y saluda al agente por su nombre si lo tiene.
function propertyWhatsappMessage(p) {
  const code = formatPropertyCode(p);
  const operationLabel = PROPERTY_OPERATION_LABELS[p.operation];
  // Solo se saluda al agente por su nombre si el mensaje le llega a él (la propiedad tiene su
  // WhatsApp); si no, va al número general de Bastet.
  const agentFirstName = p.whatsapp && p.agent && p.agent.display_name ? p.agent.display_name.trim().split(/\s+/)[0] : '';
  return (code ? '[' + code + '] ' : '') +
    'Hola ' + (agentFirstName || 'Bastet') + ', me interesa la propiedad: ' + p.title +
    (operationLabel ? ' (' + operationLabel.toLowerCase() + ')' : '') +
    ' en ' + p.location + '. ¿Podrían brindarme más información?';
}

const WHATSAPP_ICON_SVG = '<svg viewBox="0 0 24 24" aria-hidden="true"><path fill="currentColor" d="M12 2a10 10 0 0 0-8.6 15.1L2 22l5-1.3A10 10 0 1 0 12 2zm0 18.2c-1.5 0-3-.4-4.3-1.2l-.3-.2-3 .8.8-2.9-.2-.3A8.2 8.2 0 1 1 12 20.2zm4.5-6.1c-.2-.1-1.5-.7-1.7-.8-.2-.1-.4-.1-.6.1l-.8 1c-.1.2-.3.2-.5.1a6.7 6.7 0 0 1-3.3-2.9c-.3-.4.2-.4.7-1.4.1-.2 0-.3 0-.4l-.8-1.8c-.2-.5-.4-.4-.6-.4h-.5a1 1 0 0 0-.7.3 3 3 0 0 0-.9 2.2 5.2 5.2 0 0 0 1.1 2.7 11.8 11.8 0 0 0 4.5 4c1.7.7 2.3.8 3.1.7.5-.1 1.5-.6 1.7-1.2.2-.6.2-1.1.2-1.2-.1-.1-.3-.2-.5-.3z"/></svg>';

// Foto del agente sobre la tarjeta: al tocarla se abre WhatsApp con el agente (ver onContact).
// Sin agente asignado se muestra el gato de Bastet y el contacto va al número general.
function buildAgentBadgeHtml(agent) {
  const name = agent && agent.display_name ? agent.display_name : 'Bastet';
  const initial = name.trim().charAt(0).toUpperCase();
  const photo = agent && agent.avatar_url
    ? '<img class="ring-card-agent-avatar" src="' + escapeHtml(agent.avatar_url) + '" alt="">'
    : (agent && agent.display_name
      ? '<span class="ring-card-agent-avatar ring-card-agent-avatar-placeholder">' + escapeHtml(initial) + '</span>'
      : '<span class="ring-card-agent-avatar ring-card-agent-avatar-brand"><img src="assets/img/bastet-gato-dorado.png" alt=""></span>');
  return (
    '<div class="ring-card-agent" data-ring-contact role="button" aria-label="Consultar por WhatsApp con ' + escapeHtml(name) + '" title="Consultar por WhatsApp con ' + escapeHtml(name) + '">' +
      '<span class="ring-card-agent-photo">' + photo + '<span class="ring-card-agent-wa">' + WHATSAPP_ICON_SVG + '</span></span>' +
      '<span class="ring-card-agent-text">' +
        '<span class="ring-card-agent-name">' + escapeHtml(name) + '</span>' +
        '<span class="ring-card-agent-cta">Consultar por WhatsApp</span>' +
      '</span>' +
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

const propertyRing = createRingCarousel({
  stage: ringStage,
  radius: RING_RADIUS,
  size: RING_SIZE,
  buildCard: buildPropertyCard,
  onSelect: (property) => openProperty(property),
  // Clic en la foto del agente: WhatsApp directo con el agente, ya con el código de la propiedad
  onContact: (property) => {
    trackEvent(property.id, 'whatsapp_click');
    window.open(whatsappUrl(propertyWhatsappMessage(property), property.whatsapp), '_blank', 'noopener');
  },
  emptyText: 'Pronto publicaremos nuevas propiedades disponibles.',
  cull: 80,
  edgeFade: true,
});

// Columnas públicas explícitas (sin owner_whatsapp: es el teléfono privado del
// propietario del inmueble, nunca debe llegar al landing público).
const PUBLIC_PROPERTY_COLUMNS = 'id,title,location,address,price,exchange_rate,area,rooms,baths,description,photos,whatsapp,owner_id,featured,sort_order,status,created_at,code_number,property_type,operation,floors,has_garage,garage_spots,has_storage,pets_allowed,kids_allowed';
// Columnas públicas del agente (nunca email/role/is_active: ver política RLS "public can read active agent public info").
const PUBLIC_AGENT_COLUMNS = 'id,display_name,avatar_url,facebook_url,instagram_url,tiktok_url';

async function loadProperties() {
  const { data, error } = await supabaseClient
    .from('properties')
    .select(PUBLIC_PROPERTY_COLUMNS)
    .eq('status', 'available')
    .order('sort_order', { ascending: true });

  if (error) {
    console.error('Error cargando propiedades:', error);
    allProperties = [];
  } else {
    allProperties = data || [];
    await attachAgentInfo(allProperties);
  }

  buildOperationFilters();
  buildTypeFilter();
  buildRoomsFilter();
  buildBathsFilter();
  buildBudgetFilter();
  buildCityFilters();
  renderPropertyRing();
}

async function attachAgentInfo(properties) {
  const ownerIds = [...new Set(properties.map((p) => p.owner_id).filter(Boolean))];
  if (!ownerIds.length) return;
  const { data, error } = await supabaseClient
    .from('profiles')
    .select(PUBLIC_AGENT_COLUMNS)
    .in('id', ownerIds);
  if (error || !data) return;
  const agentById = {};
  data.forEach((a) => { agentById[a.id] = a; });
  properties.forEach((p) => { p.agent = p.owner_id ? agentById[p.owner_id] || null : null; });
}

// Filtro por operación (Todas / Venta / Alquiler / Anticrético). Se muestran siempre las
// tres opciones con su cantidad, así el visitante sabe qué hay disponible en cada una.
function buildOperationFilters() {
  const options = [['todas', 'Todas']].concat(Object.entries(PROPERTY_OPERATION_LABELS));
  operationFiltersEl.innerHTML = '';
  options.forEach(([value, label]) => {
    const count = value === 'todas' ? allProperties.length : allProperties.filter((p) => p.operation === value).length;
    const btn = document.createElement('button');
    btn.type = 'button';
    btn.setAttribute('role', 'tab');
    btn.setAttribute('aria-selected', String(value === operationFilter));
    btn.className = 'operation-tab' + (value === operationFilter ? ' is-active' : '');
    btn.innerHTML = escapeHtml(label) + '<span class="operation-tab-count">' + count + '</span>';
    btn.addEventListener('click', () => {
      operationFilter = value;
      cityFilter = 'Todas'; // las ciudades disponibles cambian según la operación
      budgetFilter = '';     // y los rangos de presupuesto también
      typeFilter = '';
      roomsFilter = '';
      bathsFilter = '';
      buildOperationFilters();
      buildTypeFilter();
      buildRoomsFilter();
      buildBathsFilter();
      buildBudgetFilter();
      buildCityFilters();
      renderPropertyRing();
    });
    operationFiltersEl.appendChild(btn);
  });
}

function propertiesForOperation() {
  return operationFilter === 'todas' ? allProperties : allProperties.filter((p) => p.operation === operationFilter);
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

function propertiesBeforeBudget() {
  const base = propertiesForOperationTypeAndRooms();
  if (bathsFilter === '') return base;
  const min = Number(bathsFilter);
  return base.filter((p) => (propertyBathsNumber(p) || 0) >= min);
}

function propertiesForOperationAndBudget() {
  const base = propertiesBeforeBudget();
  if (budgetFilter === '') return base;
  const range = budgetRanges()[Number(budgetFilter)];
  return range ? base.filter((p) => inBudgetRange(p, range)) : base;
}

function buildCityFilters() {
  const presentCities = new Set(propertiesForOperationAndBudget().map((p) => (p.location || '').split(',')[0].trim()));
  const cities = ['Todas'].concat(BOLIVIA_CITIES.filter((c) => presentCities.has(c)));

  cityFiltersEl.innerHTML = '';
  if (cities.length <= 1) return;

  cities.forEach((city) => {
    const btn = document.createElement('button');
    btn.type = 'button';
    btn.className = 'city-pill' + (city === cityFilter ? ' is-active' : '');
    btn.textContent = city;
    btn.addEventListener('click', () => {
      cityFilter = city;
      buildCityFilters();
      renderPropertyRing();
    });
    cityFiltersEl.appendChild(btn);
  });
}

function filteredProperties() {
  const base = propertiesForOperationAndBudget();
  if (cityFilter === 'Todas') return base;
  const filtered = base.filter((p) => (p.location || '').startsWith(cityFilter));
  return filtered.length ? filtered : base;
}

const FEATURED_WEIGHT = 3; // una propiedad destacada aparece ~3x más seguido en el carrusel

function buildRingPool(list) {
  const pool = [];
  list.forEach((p) => {
    const copies = p.featured ? FEATURED_WEIGHT : 1;
    for (let i = 0; i < copies; i++) pool.push(p);
  });
  for (let i = pool.length - 1; i > 0; i--) {
    const j = Math.floor(Math.random() * (i + 1));
    [pool[i], pool[j]] = [pool[j], pool[i]];
  }
  return pool;
}

const clearFiltersBtn = document.getElementById('clear-filters');

function anyFilterActive() {
  return operationFilter !== 'todas' || typeFilter !== '' || roomsFilter !== '' || bathsFilter !== '' || budgetFilter !== '' || cityFilter !== 'Todas';
}

clearFiltersBtn.addEventListener('click', () => {
  operationFilter = 'todas';
  typeFilter = '';
  roomsFilter = '';
  bathsFilter = '';
  budgetFilter = '';
  cityFilter = 'Todas';
  buildOperationFilters();
  buildTypeFilter();
  buildRoomsFilter();
  buildBathsFilter();
  buildBudgetFilter();
  buildCityFilters();
  renderPropertyRing();
});

function renderPropertyRing() {
  clearFiltersBtn.classList.toggle('hidden', !anyFilterActive());
  const emptyMessage = (budgetFilter !== '' || typeFilter !== '' || roomsFilter !== '' || bathsFilter !== '')
    ? 'No tenemos propiedades con esos filtros por ahora. Prueba con otra combinación o escríbenos por WhatsApp y te ayudamos a encontrar una.'
    : operationFilter !== 'todas'
      ? 'Por ahora no tenemos propiedades en ' + PROPERTY_OPERATION_LABELS[operationFilter].toLowerCase() + '. Mira las demás opciones o escríbenos por WhatsApp.'
      : '';
  propertyRing.render(buildRingPool(filteredProperties()), emptyMessage);
}

/* ── Analítica: vistas y clics a WhatsApp por propiedad (sin datos personales) ── */
function trackEvent(propertyId, eventType) {
  if (!propertyId) return;
  supabaseClient.from('property_events').insert({ property_id: propertyId, event_type: eventType })
    .then(() => {}, () => {});
}

/* ── Modal ── */
function openProperty(property) {
  selectedProperty = property;
  selectedPhotoIndex = 0;
  renderModal();
  modalBackdrop.classList.remove('hidden');
  trackEvent(property.id, 'view');
}

function closeProperty() {
  selectedProperty = null;
  modalBackdrop.classList.add('hidden');
}

function buildAgentSectionHtml(agent) {
  if (!agent || (!agent.display_name && !agent.avatar_url)) return '';
  const initial = (agent.display_name || '?').trim().charAt(0).toUpperCase();
  const avatar = agent.avatar_url
    ? '<img class="property-modal-agent-avatar" src="' + escapeHtml(agent.avatar_url) + '" alt="">'
    : '<span class="property-modal-agent-avatar property-modal-agent-avatar-placeholder">' + escapeHtml(initial) + '</span>';
  const socials =
    socialIconLink(agent.facebook_url, 'facebook', 'Facebook') +
    socialIconLink(agent.instagram_url, 'instagram', 'Instagram') +
    socialIconLink(agent.tiktok_url, 'tiktok', 'TikTok');
  return (
    '<div class="property-modal-agent">' +
      avatar +
      '<div class="property-modal-agent-info">' +
        '<p class="property-modal-agent-label">Publicado por</p>' +
        '<p class="property-modal-agent-name">' + escapeHtml(agent.display_name || '') + '</p>' +
      '</div>' +
      (socials ? '<span class="property-modal-agent-social">' + socials + '</span>' : '') +
    '</div>'
  );
}

function renderModal() {
  if (!selectedProperty) return;
  const p = selectedProperty;
  const photos = (p.photos && p.photos.length) ? p.photos : [];
  const hasPhotos = photos.length > 0;
  const currentPhoto = hasPhotos ? photos[selectedPhotoIndex] : null;

  const code = formatPropertyCode(p);
  const operationLabel = PROPERTY_OPERATION_LABELS[p.operation];
  // El código va primero para que el agente identifique la propiedad de un vistazo.
  const message = propertyWhatsappMessage(p);
  const features = propertyFeatureList(p);

  modal.innerHTML =
    '<button class="property-modal-close" aria-label="Cerrar" id="property-modal-close">×</button>' +
    '<div class="property-modal-gallery">' +
      (currentPhoto
        ? '<img class="property-modal-img" src="' + escapeHtml(currentPhoto) + '" alt="' + escapeHtml(p.title) + '">'
        : '<div class="ring-card-img-placeholder" style="height:100%;">' + escapeHtml(p.title) + '</div>') +
      (photos.length > 1
        ? '<button class="property-modal-nav property-modal-nav--prev" id="modal-prev" aria-label="Foto anterior">‹</button>' +
          '<button class="property-modal-nav property-modal-nav--next" id="modal-next" aria-label="Foto siguiente">›</button>' +
          '<div class="property-modal-dots">' +
            photos.map((_, i) => '<span class="property-modal-dot' + (i === selectedPhotoIndex ? ' is-active' : '') + '"></span>').join('') +
          '</div>'
        : '') +
    '</div>' +
    '<div class="property-modal-body">' +
      '<div>' +
        '<div class="property-modal-tags">' +
          (code ? '<span class="property-modal-code">Código ' + code + '</span>' : '') +
          (operationLabel ? '<span class="property-modal-tag">' + operationLabel + '</span>' : '') +
          (PROPERTY_TYPE_LABELS[p.property_type] ? '<span class="property-modal-tag">' + PROPERTY_TYPE_LABELS[p.property_type] + '</span>' : '') +
        '</div>' +
        '<p class="property-modal-location">' + escapeHtml(p.location) + '</p>' +
        '<h3 class="property-modal-title">' + escapeHtml(p.title) + '</h3>' +
        '<p class="property-modal-price">' + formatPriceUSD(p.price) + '</p>' +
        (p.exchange_rate ? '<p class="property-modal-rate">Tipo de cambio aceptado: ' + escapeHtml(p.exchange_rate) + '</p>' : '') +
      '</div>' +
      '<div class="property-modal-specs">' +
        '<div><p class="property-modal-spec-label">Área</p><p class="property-modal-spec-value">' + escapeHtml(p.area) + '</p></div>' +
        '<div><p class="property-modal-spec-label">Ambientes</p><p class="property-modal-spec-value">' + escapeHtml(p.rooms) + '</p></div>' +
        '<div><p class="property-modal-spec-label">Baños</p><p class="property-modal-spec-value">' + escapeHtml(p.baths) + '</p></div>' +
      '</div>' +
      (features.filter((f) => f.label !== 'Tipo' && f.label !== 'Operación').length
        ? '<div class="property-modal-features">' +
            features.filter((f) => f.label !== 'Tipo' && f.label !== 'Operación').map((f) =>
              '<div class="property-modal-feature"><span class="property-modal-feature-label">' + f.label + '</span><span class="property-modal-feature-value">' + escapeHtml(f.value) + '</span></div>'
            ).join('') +
          '</div>'
        : '') +
      '<p class="property-modal-desc">' + escapeHtml(p.description) + '</p>' +
      buildAgentSectionHtml(p.agent) +
      '<a class="cta-button cta-button--block cta-button--arrow" id="modal-whatsapp-cta" style="margin-top:8px;" href="' + whatsappUrl(message, p.whatsapp) + '" target="_blank" rel="noopener"><span>Consultar por WhatsApp</span></a>' +
    '</div>';

  document.getElementById('property-modal-close').addEventListener('click', closeProperty);
  document.getElementById('modal-whatsapp-cta').addEventListener('click', () => trackEvent(p.id, 'whatsapp_click'));
  const prevBtn = document.getElementById('modal-prev');
  const nextBtn = document.getElementById('modal-next');
  if (prevBtn) prevBtn.addEventListener('click', () => { selectedPhotoIndex = (selectedPhotoIndex - 1 + photos.length) % photos.length; renderModal(); });
  if (nextBtn) nextBtn.addEventListener('click', () => { selectedPhotoIndex = (selectedPhotoIndex + 1) % photos.length; renderModal(); });
}

modalBackdrop.addEventListener('click', (e) => {
  if (e.target === modalBackdrop) closeProperty();
});
document.addEventListener('keydown', (e) => {
  if (e.key === 'Escape' && !modalBackdrop.classList.contains('hidden')) closeProperty();
});

loadProperties();

/* ── Testimonios: fetch + carrusel (mismo efecto de anillo que Propiedades) ── */
const TESTI_RING_SIZE = 10;
const TESTI_RING_RADIUS = 640;
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
  const { data, error } = await supabaseClient
    .from('partners')
    .select('*')
    .order('sort_order', { ascending: true });

  if (error || !data || !data.length) {
    document.querySelector('.partners-strip')?.remove();
    return;
  }

  const logosHtml = data.map((p) => {
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
  byUrl.forEach((imgs, url) => normalizeLogo(url, imgs));
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
