/* Registro de nuevos usuarios: la primera vez que alguien entra al panel (y todavía no se registró) ve un formulario obligatorio
 * con nombre, WhatsApp, ciudad, empresa y tipo de cuenta. Los datos quedan en su perfil y se ven en el panel > Usuarios.
 * Ya no hay planes ni prueba gratuita (2026-11-03): al guardar, la persona sigue directo al panel.
 * Las reglas las aplica la base de datos (supabase/registration.sql); aquí solo se muestra y se envía el formulario.
 * Escucha el evento `uno:account` que publica publications.js. */
(function () {
  'use strict';

  const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  let overlay = null;
  // Ciudades de Bolivia (assets/js/bolivia-cities.js) + una opción para quien está en otra
  const cityOptions = () => ((typeof BOLIVIA_CITIES !== 'undefined' ? BOLIVIA_CITIES : []).concat(['Otra ciudad'])).map((c) => '<option value="' + esc(c) + '">' + esc(c) + '</option>').join('');

  function close() {
    if (overlay) { overlay.remove(); overlay = null; document.body.classList.remove('ob-open'); }
  }

  async function open() {
    if (overlay) { return; }
    let meta = {};
    try { const { data } = await supabaseClient.auth.getUser(); meta = (data && data.user && data.user.user_metadata) || {}; } catch (e) { /* sin datos de Google: el formulario queda vacío */ }
    if (overlay) return;
    overlay = document.createElement('div');
    overlay.className = 'modal-overlay ob-overlay';
    overlay.innerHTML =
      '<div class="modal-panel ob-panel" role="dialog" aria-modal="true" aria-labelledby="ob-title">' +
        '<h2 id="ob-title">Bienvenido a Bastet</h2>' +
        '<p class="ob-lead">Cuéntanos quién eres para crear tu cuenta. Si buscas un inmueble o una estadía, elige «Cliente»: verás tus solicitudes y reservas en un solo lugar.</p>' +
        '<form id="ob-form" novalidate>' +
          '<div class="field"><label for="ob-name">Nombre completo</label><input type="text" id="ob-name" maxlength="120" autocomplete="name" required value="' + esc(meta.full_name || meta.name || '') + '"></div>' +
          '<div class="field"><label for="ob-wa">WhatsApp</label><input type="tel" id="ob-wa" maxlength="30" autocomplete="tel" placeholder="Ej: 77123456 o +591 77123456" required></div>' +
          '<div class="ob-row">' +
            '<div class="field"><label for="ob-city">Ciudad</label><select id="ob-city" required><option value="">Selecciona…</option>' + cityOptions() + '</select></div>' +
            '<div class="field" id="ob-company-field"><label for="ob-company">Inmobiliaria o empresa (opcional)</label><input type="text" id="ob-company" maxlength="120"></div>' +
          '</div>' +
          '<div class="field"><label for="ob-interest">¿Cómo usarás Bastet? Define el tipo de cuenta que recibirás</label><select id="ob-interest" required><option value="">Selecciona…</option>' +
            '<option value="cliente">Cliente: busco comprar, alquilar o reservar una estadía</option>' +'<option value="propietario">Propietario: quiero publicar mis inmuebles</option>' +
            '<option value="agente">Agente inmobiliario</option>' +
            '<option value="empresa">Empresa o inmobiliaria</option></select></div>' +
          '<label class="ob-consent"><input type="checkbox" id="ob-adult"> <span>Confirmo que tengo <b>18 años o más</b>. Bastet no está dirigido a menores de edad.</span></label>' +
          '<label class="ob-consent"><input type="checkbox" id="ob-consent"> <span>Acepto que Bastet use estos datos para gestionar mi cuenta y contactarme. <a href="../privacidad.html" target="_blank" rel="noopener">Política de privacidad</a> y <a href="../terminos.html" target="_blank" rel="noopener">Términos de uso</a></span></label>' +
          '<p id="ob-error" class="form-error" role="alert" hidden></p>' +
          '<div class="ob-actions"><button type="submit" class="btn btn-accent">Guardar y continuar</button></div>' +
          '<button type="button" class="ob-logout" id="ob-logout">Salir de esta cuenta</button>' +
        '</form>' +
      '</div>';
    document.body.appendChild(overlay);
    document.body.classList.add('ob-open');

    const form = overlay.querySelector('#ob-form');
    const err = overlay.querySelector('#ob-error');
    overlay.querySelector('#ob-logout').addEventListener('click', async () => {
      close();                                         // el formulario se cierra al instante; el panel vuelve a la pantalla de acceso
      try { await supabaseClient.auth.signOut(); } catch (e) { /* si falla, la recarga de abajo limpia la sesión local */ }
      setTimeout(() => location.reload(), 300);
    });
    // Llegó desde «Regístrate como anfitrión» en el Inicio: se propone la cuenta de propietario (publica estadías temporales)
    let hostHint = false; try { hostHint = localStorage.getItem('bastet-signup-hint') === 'anfitrion'; } catch (e) { /* sin almacenamiento */ }
    let coHint = false; try { coHint = localStorage.getItem('bastet-signup-hint') === 'empresa'; } catch (e) { /* sin almacenamiento */ }
    if (coHint) {
      form.querySelector('#ob-interest').value = 'empresa';
      const note = document.createElement('p'); note.className = 'ob-lead'; note.textContent = 'Para el alojamiento de tus trabajadores elige una cuenta de empresa: después solicitas la afiliación corporativa desde «Mi empresa».';
      form.insertBefore(note, form.firstChild);
    }
    if (hostHint) {
      form.querySelector('#ob-interest').value = 'propietario';
      const note = document.createElement('p'); note.className = 'ob-lead'; note.textContent = 'Para ser anfitrión elige una cuenta de propietario: después publicas tu casa, departamento o habitación como estadía temporal.';
      form.insertBefore(note, form.firstChild);
    }
    // Un cliente no necesita indicar empresa
    const interestSel = form.querySelector('#ob-interest'), companyField = form.querySelector('#ob-company-field');
    interestSel.addEventListener('change', () => { companyField.hidden = interestSel.value === 'cliente'; });
    form.addEventListener('submit', async (e) => {
      e.preventDefault();
      const fail = (m) => { err.textContent = m; err.hidden = false; };
      err.hidden = true;
      const val = (id) => form.querySelector('#' + id).value.trim();
      if (val('ob-name').length < 3) return fail('Escribe tu nombre completo.');
      if (!/^\+?[0-9 ()-]{7,30}$/.test(val('ob-wa'))) return fail('Escribe un WhatsApp válido (solo números).');
      if (!val('ob-city')) return fail('Elige tu ciudad.');
      if (!val('ob-interest')) return fail('Elige cómo usarás Bastet: cliente, propietario, agente o empresa.');
      if (!form.querySelector('#ob-adult').checked) return fail('Debes confirmar que tienes 18 años o más para crear una cuenta.');
      if (!form.querySelector('#ob-consent').checked) return fail('Debes aceptar el uso de tus datos para continuar.');
      const buttons = form.querySelectorAll('button[type="submit"]');
      buttons.forEach((b) => { b.disabled = true; });
      const { error } = await supabaseClient.rpc('complete_registration', {
        p_full_name: val('ob-name'), p_whatsapp: val('ob-wa'), p_city: val('ob-city'), p_company: val('ob-interest') === 'cliente' ? '' : val('ob-company'),
        p_interest: val('ob-interest') || null, p_consent: true, p_adult: true,
      });
      if (error) { buttons.forEach((b) => { b.disabled = false; }); return fail(error.message || 'No se pudo guardar tu registro.'); }
      close();
      try { localStorage.removeItem('bastet-signup-hint'); } catch (e) { /* ignorar */ }
      if (window.UnoPublications) await window.UnoPublications.refresh();
    });
    const first = form.querySelector('#ob-name'); if (first) first.focus();
  }

  // Solo se exige a quien NO es administrador y la base de datos dice expresamente que aún no se registró
  document.addEventListener('uno:account', (e) => {
    const a = e.detail;
    if (a && a.exempt !== true && a.registered === false) open(); else close();
  });
  // Si la sesión se cierra por cualquier motivo, el formulario no debe quedar abierto sobre la pantalla de acceso
  supabaseClient.auth.onAuthStateChange((event) => { if (event === 'SIGNED_OUT') close(); });
  // Si la cuenta ya se cargó antes de que este archivo se ejecutara, no esperar al próximo evento
  const early = window.UnoPublications && window.UnoPublications.account;
  if (early && early.exempt !== true && early.registered === false) open();
})();
