/* Página «Empresas» (empresas.html): menú, acceso con cuenta (Google) y el botón «Crear cuenta de empresa».
 *  · El botón [data-company-signup] lo maneja host-signup.js: guarda la pista «empresa» y abre el acceso; onboarding.js propone la cuenta de empresa.
 *  · Lee corporate_public() (supabase/corporate.sql) para avisar si la afiliación aún no está abierta. */
(function () {
  'use strict';
  const $ = (id) => document.getElementById(id);

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
  const LOGO_LIGHT = LOGO_DARK.replace('bastet-logo-horizontal-color.webp', 'bastet-logo-horizontal-blanco.webp');
  if (navLogo) { const pre = new Image(); pre.src = LOGO_LIGHT; }
  function updateNavbarScroll() {
    const scrolled = window.scrollY > 40;
    navbar.classList.toggle('is-scrolled', scrolled);
    if (navLogo && LOGO_LIGHT !== LOGO_DARK) navLogo.setAttribute('src', scrolled && !navbar.classList.contains('is-menu-open') ? LOGO_LIGHT : LOGO_DARK);
  }
  window.addEventListener('scroll', updateNavbarScroll, { passive: true });
  updateNavbarScroll();

  const backdrop = $('agent-modal-backdrop');
  document.querySelectorAll('[data-agent-access]').forEach((btn) => btn.addEventListener('click', async () => {
    setMenuOpen(false);
    const { data: { session } } = await supabaseClient.auth.getSession();
    if (session) { window.location.href = 'admin/'; return; }
    backdrop.classList.remove('hidden');
    $('agent-google').focus();
  }));
  const closeAgent = () => backdrop.classList.add('hidden');
  $('agent-modal-close').addEventListener('click', closeAgent);
  backdrop.addEventListener('click', (e) => { if (e.target === backdrop) closeAgent(); });
  $('agent-google').addEventListener('click', async () => {
    const err = $('agent-login-error'); err.classList.add('hidden');
    const btn = $('agent-google'); btn.disabled = true;
    const { error } = await supabaseClient.auth.signInWithOAuth({ provider: 'google', options: { redirectTo: window.location.origin + '/admin/' } });
    if (error) { btn.disabled = false; err.textContent = 'No se pudo iniciar con Google: ' + error.message; err.classList.remove('hidden'); }
  });

  document.querySelectorAll('[data-whatsapp-generic]').forEach((el) => {
    el.href = 'https://api.whatsapp.com/send?phone=59177666205&text=' + encodeURIComponent('Hola Bastet, quiero información sobre el alojamiento corporativo para los trabajadores de mi empresa.');
  });

  (async function status() {
    try {
      const { data, error } = await supabaseClient.rpc('corporate_public');
      const note = $('co-status');
      if (error || !note) return;
      if (data && data.enabled === false) { note.textContent = 'La afiliación de empresas se está abriendo. Crea tu cuenta ahora y completa tu solicitud cuando esté disponible.'; note.hidden = false; }
    } catch (e) { /* sin el SQL no se muestra el aviso */ }
  })();
})();
