/* Registro de nuevos usuarios: la primera vez que alguien entra al panel (y todavía no se registró) ve un formulario obligatorio
 * con nombre, WhatsApp, ciudad, empresa e interés. Los datos quedan en su perfil y se ven en el panel > Usuarios.
 * Luego puede empezar la PRUEBA GRATUITA de 7 días (solo si todavía no eligió ni tiene un plan) o elegir un plan desde el inicio.
 * Las reglas las aplica la base de datos (supabase/registration.sql); aquí solo se muestra y se envía el formulario.
 * Escucha el evento `uno:subscription` que publica publications.js. */
(function () {
  'use strict';

  const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  let overlay = null;
  // Ciudades de Bolivia (assets/js/bolivia-cities.js) + una opción para quien está en otra
  const cityOptions = () => ((typeof BOLIVIA_CITIES !== 'undefined' ? BOLIVIA_CITIES : []).concat(['Otra ciudad'])).map((c) => '<option value="' + esc(c) + '">' + esc(c) + '</option>').join('');

  function close() {
    if (overlay) { overlay.remove(); overlay = null; document.body.classList.remove('ob-open'); }
  }

  async function open(s) {
    if (overlay) { return; }
    let meta = {};
    try { const { data } = await supabaseClient.auth.getUser(); meta = (data && data.user && data.user.user_metadata) || {}; } catch (e) { /* sin datos de Google: el formulario queda vacío */ }
    if (overlay) return;
    const canTrial = !!s.trial_eligible;
    overlay = document.createElement('div');
    overlay.className = 'modal-overlay ob-overlay';
    overlay.innerHTML =
      '<div class="modal-panel ob-panel" role="dialog" aria-modal="true" aria-labelledby="ob-title">' +
        '<h2 id="ob-title">Bienvenido a Bastet</h2>' +
        '<p class="ob-lead">Cuéntanos quién eres para crear tu cuenta. ' + (canTrial ? 'Si eres propietario podrás <b>probar gratis por 7 días</b>; las cuentas de agente y de empresa eligen un plan de pago.' : 'Después podrás seguir al panel.') + '</p>' +
        (canTrial ? '<div class="ob-trial" id="ob-trial" hidden><b>Prueba gratuita de 7 días · cuenta de propietario</b><span>Al aceptar con «Probar 7 días gratis», tu cuenta queda habilitada con el plan Propietario y puedes publicar por 7 días sin suscripción. Pasados los 7 días debes suscribirte a un plan; si no lo haces, tu cuenta se da de baja y tus propiedades dejan de mostrarse en el marketplace. Solo se puede usar una vez por cuenta de Google.</span></div>' : '') +
        '<div class="ob-trial ob-paid" id="ob-paid" hidden><b>Cuenta de agente o de empresa</b><span>Estas cuentas no tienen prueba gratuita: guarda tus datos y elige tu plan para empezar a publicar.</span></div>' +
        '<form id="ob-form" novalidate>' +
          '<div class="field"><label for="ob-name">Nombre completo</label><input type="text" id="ob-name" maxlength="120" autocomplete="name" required value="' + esc(meta.full_name || meta.name || '') + '"></div>' +
          '<div class="field"><label for="ob-wa">WhatsApp</label><input type="tel" id="ob-wa" maxlength="30" autocomplete="tel" placeholder="Ej: 77123456 o +591 77123456" required></div>' +
          '<div class="ob-row">' +
            '<div class="field"><label for="ob-city">Ciudad</label><select id="ob-city" required><option value="">Selecciona…</option>' + cityOptions() + '</select></div>' +
            '<div class="field"><label for="ob-company">Inmobiliaria o empresa (opcional)</label><input type="text" id="ob-company" maxlength="120"></div>' +
          '</div>' +
          '<div class="field"><label for="ob-interest">¿Cómo usarás Bastet? Define el tipo de cuenta que recibirás</label><select id="ob-interest" required><option value="">Selecciona…</option>' +
            '<option value="propietario">Cuenta de propietario: quiero vender o alquilar mi propiedad</option>' +
            '<option value="agente">Cuenta de agente: soy agente inmobiliario</option>' +
            '<option value="empresa">Cuenta de empresa: represento a una inmobiliaria</option></select></div>' +
          '<label class="ob-consent"><input type="checkbox" id="ob-consent"> <span>Acepto que Bastet use estos datos para gestionar mi cuenta y contactarme. <a href="../privacidad.html" target="_blank" rel="noopener">Política de privacidad</a></span></label>' +
          '<p id="ob-error" class="form-error" role="alert" hidden></p>' +
          '<div class="ob-actions">' +
            (canTrial
              ? '<button type="submit" class="btn btn-accent" data-ob="trial" id="ob-btn-trial" hidden>Probar 7 días gratis</button><button type="submit" class="btn btn-primary" data-ob="plan" id="ob-btn-plan">Guardar y elegir mi plan</button>'
              : '<button type="submit" class="btn btn-accent" data-ob="plan">Guardar y continuar</button>') +
          '</div>' +
          (canTrial ? '<p class="ob-fine">Si eliges un plan desde el inicio, no se aplica la prueba gratuita.</p>' : '') +
          '<button type="button" class="ob-logout" id="ob-logout">Salir de esta cuenta</button>' +
        '</form>' +
      '</div>';
    document.body.appendChild(overlay);
    document.body.classList.add('ob-open');

    const form = overlay.querySelector('#ob-form');
    const err = overlay.querySelector('#ob-error');
    let mode = 'plan';
    const sel = form.querySelector('#ob-interest');
    const syncInterest = () => {
      const v = sel.value, owner = v === 'propietario';
      const trialBox = form.querySelector('#ob-trial') || overlay.querySelector('#ob-trial');
      if (trialBox) trialBox.hidden = !(canTrial && owner);
      overlay.querySelector('#ob-paid').hidden = !(v === 'agente' || v === 'empresa');
      const bt = form.querySelector('#ob-btn-trial'); if (bt) bt.hidden = !(canTrial && owner);
      const bp = form.querySelector('#ob-btn-plan'); if (bp) bp.textContent = canTrial ? (owner ? 'Elegir un plan ahora' : 'Guardar y elegir mi plan') : 'Guardar y continuar';
    };
    sel.addEventListener('change', syncInterest); syncInterest();
    form.querySelectorAll('[data-ob]').forEach((b) => b.addEventListener('click', () => { mode = b.dataset.ob; }));
    overlay.querySelector('#ob-logout').addEventListener('click', async () => { await supabaseClient.auth.signOut(); location.reload(); });
    form.addEventListener('submit', async (e) => {
      e.preventDefault();
      const fail = (m) => { err.textContent = m; err.hidden = false; };
      err.hidden = true;
      const val = (id) => form.querySelector('#' + id).value.trim();
      if (val('ob-name').length < 3) return fail('Escribe tu nombre completo.');
      if (!/^\+?[0-9 ()-]{7,30}$/.test(val('ob-wa'))) return fail('Escribe un WhatsApp válido (solo números).');
      if (!val('ob-city')) return fail('Elige tu ciudad.');
      if (!val('ob-interest')) return fail('Elige cómo usarás Bastet: propietario, agente o empresa.');
      if (!form.querySelector('#ob-consent').checked) return fail('Debes aceptar el uso de tus datos para continuar.');
      const buttons = form.querySelectorAll('button[type="submit"]');
      buttons.forEach((b) => { b.disabled = true; });
      const { error } = await supabaseClient.rpc('complete_registration', {
        p_full_name: val('ob-name'), p_whatsapp: val('ob-wa'), p_city: val('ob-city'), p_company: val('ob-company'),
        p_interest: val('ob-interest') || null, p_consent: true, p_start_trial: mode === 'trial',
      });
      if (error) { buttons.forEach((b) => { b.disabled = false; }); return fail(error.message || 'No se pudo guardar tu registro.'); }
      close();
      if (window.UnoPublications) await window.UnoPublications.refresh();
      if (mode === 'plan' && canTrial) {
        const tab = document.querySelector('.admin-tab[data-tab="subscription"]');
        if (tab) tab.click();
      }
    });
    const first = form.querySelector('#ob-name'); if (first) first.focus();
  }

  // Solo se exige a quien NO es administrador y la base de datos dice expresamente que aún no se registró
  document.addEventListener('uno:subscription', (e) => {
    const s = e.detail;
    if (s && s.exempt !== true && s.registered === false) open(s); else close();
  });
  // Si el plan ya se cargó antes de que este archivo se ejecutara, no esperar al próximo evento
  const early = window.UnoPublications && window.UnoPublications.subscription;
  if (early && early.exempt !== true && early.registered === false) open(early);
})();
