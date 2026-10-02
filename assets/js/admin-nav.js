/* Menú lateral del panel: cajón en celular/tablet. El cambio de pestaña lo sigue haciendo admin.js
   (los botones del menú conservan class="admin-tab" y data-tab). */
(function () {
  'use strict';
  const side = document.getElementById('admin-side');
  const scrim = document.getElementById('admin-scrim');
  const burger = document.getElementById('admin-burger');
  if (!side || !scrim || !burger) return;

  function setOpen(open) {
    side.classList.toggle('open', open);
    scrim.classList.toggle('open', open);
    burger.setAttribute('aria-expanded', open ? 'true' : 'false');
    document.body.style.overflow = open ? 'hidden' : '';
  }

  burger.addEventListener('click', () => setOpen(!side.classList.contains('open')));
  scrim.addEventListener('click', () => setOpen(false));
  document.addEventListener('keydown', (e) => { if (e.key === 'Escape') setOpen(false); });
  // Al elegir una sección: se cierra el cajón y se vuelve arriba.
  side.addEventListener('click', (e) => {
    if (e.target.closest('.admin-tab')) { setOpen(false); window.scrollTo({ top: 0 }); }
  });
  // Si la ventana pasa a escritorio, el cajón no debe quedar abierto ni bloquear el scroll.

  // Barra inferior (celular/tablet): los accesos rápidos activan las mismas pestañas del menú lateral y "Más" abre el cajón con el resto.
  const bar = document.getElementById('admin-bottombar');
  if (bar) {
    const quick = [...bar.querySelectorAll('[data-go]')];
    const more = bar.querySelector('[data-more]');
    const sideTab = (key) => side.querySelector('.admin-tab[data-tab="' + key + '"]');
    const sync = () => {
      const active = side.querySelector('.admin-tab.is-active');
      const key = active ? active.dataset.tab : '';
      let matched = false;
      quick.forEach((b) => { const on = b.dataset.go === key; matched = matched || on; b.classList.toggle('is-active', on); });
      more.classList.toggle('is-active', !matched);
      // Los contadores del menú (clientes nuevos, solicitudes pendientes) se reflejan en la barra
      const num = (id) => { const el = document.getElementById(id); return el && !el.classList.contains('hidden') ? (parseInt(el.textContent, 10) || 0) : 0; };
      const setBadge = (id, n) => { const b = document.getElementById(id); if (!b) return; b.textContent = n > 99 ? '99+' : String(n); b.classList.toggle('hidden', !n); };
      setBadge('abb-leads-count', num('leads-count'));
      setBadge('abb-more-count', num('requests-count') + num('sell-count'));
    };
    quick.forEach((b) => b.addEventListener('click', () => { const t = sideTab(b.dataset.go); if (t) { t.click(); window.scrollTo({ top: 0 }); } }));
    more.addEventListener('click', () => { burger.click(); });
    new MutationObserver(sync).observe(side, { subtree: true, attributes: true, attributeFilter: ['class'], childList: true, characterData: true });
    burger.addEventListener('click', () => setTimeout(() => more.setAttribute('aria-expanded', side.classList.contains('open') ? 'true' : 'false'), 0));
    sync();
  }
  window.matchMedia('(min-width: 861px)').addEventListener('change', (m) => { if (m.matches) setOpen(false); });
})();
