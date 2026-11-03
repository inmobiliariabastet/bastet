/* Botón «Sé anfitrión» / «Registrarme como anfitrión» (menú principal de todas las páginas públicas, portada y franja de empresas).
 * Guarda una pista (bastet-signup-hint) y abre el acceso con cuenta: onboarding.js la usa para proponer la cuenta de propietario,
 * que es la que publica estadías temporales. Funciona con cualquier elemento con el atributo data-host-signup, incluso los que se crean después. */
(function () {
  'use strict';
  document.addEventListener('click', (e) => {
    if (!e.target.closest('[data-host-signup]')) return;
    try { localStorage.setItem('bastet-signup-hint', 'anfitrion'); } catch (err) { /* sin almacenamiento: se elige el tipo de cuenta a mano */ }
    const opener = document.querySelector('.navbar-links [data-agent-access]') || document.querySelector('[data-agent-access]');
    if (opener) opener.click(); else location.href = 'admin/';
  });
})();
