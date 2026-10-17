/* Panel: reseñas de huéspedes de una estadía temporal. El anfitrión crea un enlace personal por huésped (se copia o se envía por
 * WhatsApp), ve los enlaces pendientes y las reseñas publicadas, y puede responderlas; el administrador también puede ocultarlas.
 * Funciones SQL en supabase/stays.sql. Autónomo: usa el cliente global `supabaseClient`. Expone window.StayReviewsAdmin.open(property). */
(function () {
  'use strict';
  const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const stars = (n) => '★'.repeat(n) + '☆'.repeat(5 - n);
  const isAdmin = () => typeof currentProfile !== 'undefined' && currentProfile && currentProfile.role === 'admin';
  const linkOf = (token) => location.origin + '/estadias.html?resena=' + token;
  const fmt = (iso) => { const d = new Date(iso); return isNaN(d) ? '' : d.toLocaleDateString('es-BO', { day: '2-digit', month: 'short', year: 'numeric' }); };

  function toast(msg, bad) {
    let el = document.getElementById('ct-toast');
    if (!el) { el = document.createElement('div'); el.id = 'ct-toast'; el.setAttribute('role', 'status'); document.body.appendChild(el); }
    el.textContent = msg; el.className = 'ct-toast show' + (bad ? ' is-error' : '');
    clearTimeout(toast.t); toast.t = setTimeout(() => { el.className = 'ct-toast'; }, 4200);
  }

  async function open(property) {
    const prev = document.getElementById('sra-overlay'); if (prev) prev.remove();
    const o = document.createElement('div');
    o.className = 'modal-overlay'; o.id = 'sra-overlay';
    o.innerHTML = '<div class="modal-panel sra-panel" role="dialog" aria-modal="true"><div id="sra-body"><p>Cargando…</p></div></div>';
    document.body.appendChild(o);
    o.addEventListener('click', (e) => { if (e.target === o || e.target.closest('[data-sra-close]')) o.remove(); });
    const body = o.querySelector('#sra-body');

    async function render() {
      const { data, error } = await supabaseClient.rpc('host_stay_reviews', { p_property: String(property.id) });
      if (error) {
        body.innerHTML = '<h2>Reseñas</h2><p class="form-error">' + (/function|schema cache/i.test(error.message || '') ? 'Las reseñas todavía no están activadas en la base de datos (falta correr supabase/stays.sql).' : esc(error.message)) + '</p><div class="modal-form-actions"><button type="button" class="btn btn-ghost" data-sra-close>Cerrar</button></div>';
        return;
      }
      const reviews = data.reviews || [], invites = data.invites || [];
      const shown = reviews.filter((r) => r.status === 'published');
      const avg = shown.length ? shown.reduce((a, r) => a + r.rating, 0) / shown.length : 0;
      body.innerHTML =
        '<h2>Reseñas de huéspedes</h2><p class="sra-sub"><b>' + esc(property.title) + '</b>' + (shown.length ? ' · ★ ' + avg.toFixed(1).replace('.', ',') + ' (' + shown.length + ')' : ' · sin reseñas todavía') + '</p>' +
        '<section class="sra-sec"><h3>Pedir una reseña</h3><p class="sra-hint">Crea un enlace personal por cada huésped que se alojó. Sirve una sola vez y no necesita cuenta: así solo reseñan quienes realmente estuvieron.</p>' +
          '<form id="sra-new" class="sra-new"><input id="sra-guest" type="text" maxlength="60" placeholder="Nombre del huésped (opcional)"><button class="btn btn-primary btn-sm" type="submit">Crear enlace</button></form>' +
          '<p id="sra-err" class="form-error hidden"></p>' +
          (invites.length ? '<ul class="sra-list">' + invites.map((v) => '<li data-token="' + esc(v.token) + '"><div><b>' + esc(v.guest_name || 'Sin nombre') + '</b><small>Creado ' + esc(fmt(v.created_at)) + ' · pendiente</small></div>' +
            '<div class="sra-btns"><button type="button" class="btn btn-ghost btn-sm" data-copy>Copiar</button><button type="button" class="btn btn-ghost btn-sm" data-wa>WhatsApp</button><button type="button" class="btn btn-ghost btn-sm" data-revoke>Quitar</button></div></li>').join('') + '</ul>' : '') +
        '</section>' +
        '<section class="sra-sec"><h3>Reseñas recibidas</h3>' + (reviews.length ? reviews.map((r) =>
          '<article class="sra-rev' + (r.status === 'hidden' ? ' is-hidden' : '') + '" data-id="' + esc(r.id) + '"><header><b>' + esc(r.guest_name) + '</b><span class="sra-stars">' + stars(r.rating) + '</span><time>' + esc(fmt(r.created_at)) + '</time>' + (r.status === 'hidden' ? '<em>Oculta</em>' : '') + '</header>' +
          (r.comment ? '<p>' + esc(r.comment) + '</p>' : '') +
          '<textarea rows="2" maxlength="800" placeholder="Responde a este huésped (se muestra públicamente)">' + esc(r.host_reply || '') + '</textarea>' +
          '<div class="sra-btns"><button type="button" class="btn btn-ghost btn-sm" data-reply>Guardar respuesta</button>' + (isAdmin() ? '<button type="button" class="btn btn-ghost btn-sm" data-toggle="' + (r.status === 'hidden' ? 'published' : 'hidden') + '">' + (r.status === 'hidden' ? 'Volver a publicar' : 'Ocultar') + '</button>' : '') + '</div></article>').join('') : '<p class="sra-hint">Aún no hay reseñas.</p>') + '</section>' +
        '<div class="modal-form-actions"><button type="button" class="btn btn-ghost" data-sra-close>Cerrar</button></div>';
    }

    body.addEventListener('submit', async (e) => {
      if (e.target.id !== 'sra-new') return;
      e.preventDefault();
      const err = body.querySelector('#sra-err'); err.classList.add('hidden');
      const { data, error } = await supabaseClient.rpc('create_review_invite', { p_property: String(property.id), p_guest: body.querySelector('#sra-guest').value.trim() || null });
      if (error) { err.textContent = error.message; err.classList.remove('hidden'); return; }
      try { await navigator.clipboard.writeText(linkOf(data)); toast('Enlace creado y copiado.'); } catch (x) { toast('Enlace creado.'); }
      render();
    });
    body.addEventListener('click', async (e) => {
      const li = e.target.closest('li[data-token]');
      if (li) {
        const token = li.dataset.token;
        if (e.target.closest('[data-copy]')) { try { await navigator.clipboard.writeText(linkOf(token)); toast('Enlace copiado.'); } catch (x) { window.prompt('Copia el enlace:', linkOf(token)); } }
        else if (e.target.closest('[data-wa]')) { window.open('https://api.whatsapp.com/send?text=' + encodeURIComponent('Hola, gracias por alojarte en «' + property.title + '». ¿Nos cuentas cómo te fue? Deja tu reseña aquí: ' + linkOf(token)), '_blank', 'noopener'); }
        else if (e.target.closest('[data-revoke]')) { const { error } = await supabaseClient.rpc('revoke_review_invite', { p_token: token }); if (error) toast(error.message, true); else render(); }
        return;
      }
      const rev = e.target.closest('.sra-rev'); if (!rev) return;
      if (e.target.closest('[data-reply]')) {
        const { error } = await supabaseClient.rpc('reply_stay_review', { p_review: rev.dataset.id, p_reply: rev.querySelector('textarea').value });
        toast(error ? error.message : 'Respuesta guardada.', !!error);
      } else if (e.target.closest('[data-toggle]')) {
        const { error } = await supabaseClient.rpc('admin_set_review_status', { p_review: rev.dataset.id, p_status: e.target.closest('[data-toggle]').dataset.toggle });
        if (error) toast(error.message, true); else render();
      }
    });
    render();
  }
  window.StayReviewsAdmin = { open };
})();
