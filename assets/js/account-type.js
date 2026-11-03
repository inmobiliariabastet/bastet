/* Muestra qué tipo de cuenta tiene la persona (cliente, propietario, agente o empresa; administrador si lo es):
 * una tarjeta al inicio de «Mi cuenta» y la etiqueta junto al correo en el menú lateral.
 * Escucha el evento `uno:account` de publications.js (my_account.interest / exempt). */
(function () {
  'use strict';
  const TYPES = {
    cliente: ['Cliente', 'Buscas inmuebles, pides contactos y reservas estadías.'],
    propietario: ['Propietario', 'Publicas tus propios inmuebles y estadías.'],
    agente: ['Agente', 'Publicas inmuebles de terceros y usas las herramientas de agente, como los contratos.'],
    empresa: ['Empresa', 'Publicas y gestionas inmuebles a nombre de tu empresa.'],
    admin: ['Administrador', 'Acceso completo al panel de Bastet.'],
  };
  document.addEventListener('uno:account', (e) => {
    const a = e.detail || {};
    const key = a.exempt === true ? 'admin' : a.interest;
    const t = TYPES[key];
    const card = document.getElementById('account-type-card');
    if (card) {
      card.classList.toggle('hidden', !t);
      if (t) { card.querySelector('[data-at-name]').textContent = t[0]; card.querySelector('[data-at-desc]').textContent = t[1]; }
    }
    const badge = document.getElementById('admin-role-badge');
    if (badge && t) badge.textContent = t[0];
  });
})();
