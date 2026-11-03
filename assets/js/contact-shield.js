/* Contacto protegido (supabase/security-hardening.sql). Los teléfonos de agentes y propiedades ya NO se descargan con la página: al tocar un botón
 * de WhatsApp (a[data-wa-prop] o a[data-wa-agent]) se pide el número a public_property_contact / public_agent_contact, que solo lo entregan si el
 * modelo vigente permite el contacto directo (con conexiones o reservas activas el contacto va por la solicitud o la reserva) y limitan los intentos
 * por IP. Sin teléfono propio se usa el número general de Bastet. Autónomo: usa el cliente global `supabaseClient`. */
(function () {
  'use strict';
  const GENERAL = '59177666205';
  const normalize = (v) => { const d = String(v || '').replace(/[^0-9]/g, ''); return /^[67][0-9]{7}$/.test(d) ? '591' + d : d; };

  function notice(msg) {
    let el = document.getElementById('cs-toast');
    if (!el) { el = document.createElement('div'); el.id = 'cs-toast'; el.setAttribute('role', 'status'); el.style.cssText = 'position:fixed;left:50%;bottom:90px;transform:translateX(-50%);max-width:min(92vw,420px);background:#1E2629;color:#fff;padding:12px 18px;border-radius:14px;font-size:14px;z-index:2000;box-shadow:0 10px 30px rgba(0,0,0,.3)'; document.body.appendChild(el); }
    el.textContent = msg; el.style.display = 'block';
    clearTimeout(notice.t); notice.t = setTimeout(() => { el.style.display = 'none'; }, 5000);
  }

  document.addEventListener('click', async (e) => {
    const a = e.target.closest('a[data-wa-prop], a[data-wa-agent]');
    if (!a) return;
    e.preventDefault();
    if (a.dataset.waBusy) return;
    a.dataset.waBusy = '1';
    const win = window.open('about:blank', '_blank');       // se abre en el clic (los navegadores bloquean ventanas abiertas después de esperar)
    if (win) { try { win.opener = null; } catch (err) { /* sin opener */ } }
    try {
      const { data, error } = a.dataset.waProp
        ? await supabaseClient.rpc('public_property_contact', { p_property: a.dataset.waProp })
        : await supabaseClient.rpc('public_agent_contact', { p_agent: a.dataset.waAgent });
      if (error) throw error;
      if (!data || data.allowed === false) {
        if (win) win.close();
        notice(data && data.via === 'solicitud' ? 'Para contactar al agente usa «Solicitar contacto» en la ficha de la propiedad.'
          : data && data.via === 'reserva' ? 'Para este alojamiento haz tu solicitud de reserva en la ficha.' : 'No pudimos obtener el contacto. Escríbenos por WhatsApp a Bastet.');
        return;
      }
      const phone = normalize(data.phone) || GENERAL;
      const url = 'https://api.whatsapp.com/send?phone=' + phone + '&text=' + encodeURIComponent(a.dataset.waMsg || '');
      if (win) win.location.href = url; else window.location.href = url;
    } catch (err) {
      // Si la base de datos aún no tiene la función (SQL sin correr), se escribe al número general de Bastet para no dejar el botón roto
      if (err && (err.code === 'PGRST202' || /Could not find the function/i.test(err.message || ''))) {
        const url = 'https://api.whatsapp.com/send?phone=' + GENERAL + '&text=' + encodeURIComponent(a.dataset.waMsg || '');
        if (win) win.location.href = url; else window.location.href = url;
        return;
      }
      if (win) win.close();
      notice(err && /Demasiados intentos/i.test(err.message || '') ? 'Demasiados intentos. Espera unos minutos e inténtalo de nuevo.' : 'No pudimos abrir WhatsApp. Inténtalo de nuevo.');
    } finally { delete a.dataset.waBusy; }
  });
})();
