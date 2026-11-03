/* Perfil público del agente (Flujo A del rediseño móvil): se abre desde la tarjeta «Publicado por» de la ficha de propiedad.
 * Solo muestra datos reales que el agente ya hizo públicos (nombre, foto, WhatsApp, redes) y sus propiedades activas.
 * No inventa calificaciones, años de experiencia ni «verificado»: eso se agrega cuando existan los datos.
 * Autónomo: main.js lo usa como window.AgentProfile.open({ agent, properties, current, helpers, onOpenProperty }). */
(function () {
  'use strict';
  const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const OP = { venta: 'Venta', alquiler: 'Alquiler', anticretico: 'Anticrético', temporal: 'Estadía temporal' };
  const SOCIAL = [['facebook_url', 'facebook', 'Facebook'], ['instagram_url', 'instagram', 'Instagram'], ['tiktok_url', 'tiktok', 'TikTok']];
  let root = null, keyHandler = null;

  function close() {
    if (!root) return;
    root.remove(); root = null;
    if (keyHandler) { document.removeEventListener('keydown', keyHandler, true); keyHandler = null; }
  }

  function open(o) {
    close();
    const a = o.agent, h = o.helpers;
    const list = (o.properties || []).filter((p) => p.owner_id === a.id);
    const cities = [...new Set(list.map((p) => String(p.location || '').split(',')[0].trim()).filter(Boolean))];
    const ops = [...new Set(list.map((p) => OP[p.operation]).filter(Boolean))];
    const initial = (a.display_name || '?').trim().charAt(0).toUpperCase();
    const avatar = a.avatar_url
      ? '<img class="ap-avatar" src="' + esc(a.avatar_url) + '" alt="">'
      : '<span class="ap-avatar ap-avatar--ph">' + esc(initial) + '</span>';
    const msg = 'Hola ' + (a.display_name || '') + ', vi tu perfil en Bastet (bastet.uno) y quisiera consultarte por una propiedad.';
    const socials = SOCIAL.map(([k, kind, label]) => a[k]
      ? '<a class="ap-social" href="' + esc(a[k]) + '" target="_blank" rel="noopener" aria-label="' + label + '"><img src="assets/img/social-' + kind + '.svg" alt="' + label + '"></a>' : '').join('');

    root = document.createElement('div');
    root.className = 'ap-screen';
    root.setAttribute('role', 'dialog');
    root.setAttribute('aria-modal', 'true');
    root.setAttribute('aria-label', 'Perfil de ' + (a.display_name || 'agente'));
    root.innerHTML =
      '<div class="ap-top"><button type="button" class="ps-icon" data-ap-close aria-label="Volver"><svg viewBox="0 0 24 24" aria-hidden="true"><path d="M14.500 5.500L8 12l6.500 6.500"/></svg></button><span class="ap-top-title">Agente</span></div>' +
      '<div class="ap-body">' +
        '<div class="ap-head">' + avatar + '<h2>' + esc(a.display_name || 'Agente') + '</h2>' +
          '<p class="ap-sub">' + (list.length ? list.length + (list.length === 1 ? ' propiedad activa' : ' propiedades activas') : 'Sin propiedades activas por ahora') +
          (cities.length ? ' · ' + esc(cities.slice(0, 3).join(', ')) : '') + '</p>' +
          ((a.agent_verified || a.owner_verified) ? '<p class="vf-agent">' + (a.agent_verified ? '✓ Agente verificado por Bastet' : '') + (a.agent_verified && a.owner_verified ? ' · ' : '') + (a.owner_verified ? '✓ Propietario verificado' : '') + (a.public_code ? ' · código ' + esc(a.public_code) : '') + '</p>' : '') +
          '<div id="ap-rep" class="ap-rep"></div>' +
          (ops.length ? '<p class="ap-tags">' + ops.map((t) => '<span>' + esc(t) + '</span>').join('') + '</p>' : '') +
        '</div>' +
        '<div class="ap-actions">' + (window.Connections && window.Connections.isOn()
          ? '<p class="ap-note">Para contactar a este agente, solicita contacto desde una de sus propiedades.</p>'
          : '<a class="ap-wa" id="ap-wa" href="#" data-wa-agent="' + esc(a.id) + '" data-wa-msg="' + esc(msg) + '">Escribir por WhatsApp</a>') + (socials ? '<span class="ap-socials">' + socials + '</span>' : '') + '</div>' +
        '<p class="ap-note">Bastet publica solo anuncios revisados. Para tu seguridad, coordina visitas y pagos a través de Bastet.</p>' +
        (list.length ? '<h3 class="ap-h">Propiedades de ' + esc((a.display_name || '').split(' ')[0] || 'este agente') + '</h3><ul class="ap-list">' +
          list.map((p, i) => {
            const photo = (p.photos && p.photos[0]) || '';
            const here = o.current && p.id === o.current.id;
            return '<li><button type="button" class="ap-item" data-ap-i="' + i + '"' + (here ? ' aria-current="true"' : '') + '>' +
              (photo ? '<img src="' + esc(photo) + '" alt="" loading="lazy">' : '<span class="ap-noimg"></span>') +
              '<span class="ap-item-text"><b>' + h.price(p.price, p.currency, p.operation) + '</b><span>' + esc(p.title) + '</span><small>' + esc(OP[p.operation] || '') + (p.location ? ' · ' + esc(p.location) : '') + (here ? ' · estás viendo esta' : '') + '</small></span></button></li>';
          }).join('') + '</ul>' : '') +
      '</div>';
    document.body.appendChild(root);
    // Reputación: promedio y reseñas de quienes concretaron una operación con una conexión de Bastet (supabase/verification.sql)
    (async () => {
      try {
        const rep = await supabaseClient.rpc('profile_reputation', { p_ids: [a.id] });
        const r = rep.data && rep.data[0]; if (!r || !root) return;
        const box = root.querySelector('#ap-rep'); if (!box) return;
        const lst = r.review_count ? await supabaseClient.rpc('list_profile_reviews', { p_profile: a.id, p_limit: 5 }) : { data: [] };
        box.innerHTML = '<p class="ap-rep-line">' + (r.review_count ? '<b>★ ' + String(r.avg_rating).replace('.', ',') + '</b> · ' + r.review_count + (r.review_count === 1 ? ' reseña verificada' : ' reseñas verificadas') : 'Todavía sin reseñas') +
          (r.verified_operations ? ' · ' + r.verified_operations + (r.verified_operations === 1 ? ' operación verificada' : ' operaciones verificadas') : '') + '</p>' +
          ((lst.data || []).length ? '<ul class="ap-reviews">' + lst.data.map((v) => '<li><b>' + '★'.repeat(v.rating) + '☆'.repeat(5 - v.rating) + '</b> <span>' + esc(v.reviewer_name) + '</span>' + (v.comment ? '<p>' + esc(v.comment) + '</p>' : '') + (v.reply ? '<p class="ap-reply">Respuesta: ' + esc(v.reply) + '</p>' : '') + '</li>').join('') + '</ul>' : '');
      } catch (e) { /* sin el SQL de verificación no se muestra nada */ }
    })();
    root.querySelector('[data-ap-close]').addEventListener('click', close);
    const apWa = root.querySelector('#ap-wa'); if (apWa) apWa.addEventListener('click', () => { if (o.onContact) o.onContact(); });
    root.addEventListener('click', (e) => {
      const it = e.target.closest('[data-ap-i]'); if (!it) return;
      const p = list[Number(it.dataset.apI)];
      close();
      if (o.current && p.id === o.current.id) return;
      if (o.onOpenProperty) o.onOpenProperty(p);
    });
    // Escape cierra solo el perfil, no la ficha de abajo
    keyHandler = (e) => { if (e.key === 'Escape') { e.stopPropagation(); close(); } };
    document.addEventListener('keydown', keyHandler, true);
    const first = root.querySelector('[data-ap-close]'); if (first) first.focus();
  }

  window.AgentProfile = { open, close, isOpen: () => !!root };
})();
