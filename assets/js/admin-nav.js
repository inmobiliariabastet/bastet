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
  window.matchMedia('(min-width: 861px)').addEventListener('change', (m) => { if (m.matches) setOpen(false); });
})();
