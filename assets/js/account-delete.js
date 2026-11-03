/* Eliminar mi cuenta (pestaña «Mi cuenta»). SQL: supabase/account-deletion.sql.
 * Solo se puede eliminar si no hay pagos pendientes ni disputas abiertas: la base de datos lo comprueba (my_account_deletion_check) y lo vuelve a exigir al eliminar.
 * Antes de eliminar se intentan borrar los documentos de verificación de la propia persona; luego se anonimiza la cuenta, se cierra el acceso y se cierra la sesión. */
(function () {
  'use strict';
  const esc = (s) => String(s == null ? '' : s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

  function ensureCard() {
    const panel = document.getElementById('tab-panel-account');
    if (!panel || document.getElementById('account-delete-card')) return;
    const card = document.createElement('section');
    card.id = 'account-delete-card'; card.className = 'invite-admin-card ad-card';
    card.innerHTML = '<h2>Eliminar mi cuenta</h2>' +
      '<p class="field-hint">Puedes eliminar tu cuenta cuando no tengas pagos pendientes ni disputas abiertas. Se retiran tus inmuebles disponibles, se borran tus datos personales y se cierra tu acceso. Bastet conserva, por obligación contractual y como prueba, los registros de conexiones, operaciones, reservas e investigaciones. <a href="../privacidad.html" target="_blank" rel="noopener">Más información</a>.</p>' +
      '<button type="button" class="btn btn-ghost ad-danger" id="account-delete-btn">Eliminar mi cuenta…</button>';
    panel.appendChild(card);
    card.querySelector('#account-delete-btn').addEventListener('click', openFlow);
  }

  function modal(html) {
    const prev = document.getElementById('ad-overlay'); if (prev) prev.remove();
    const o = document.createElement('div'); o.className = 'modal-overlay'; o.id = 'ad-overlay';
    o.innerHTML = '<div class="modal-panel ad-panel" role="dialog" aria-modal="true" aria-labelledby="ad-title">' + html + '</div>';
    document.body.appendChild(o);
    o.addEventListener('click', (e) => { if (e.target === o || e.target.closest('[data-close]')) o.remove(); });
    return o;
  }

  async function openFlow() {
    const o = modal('<h2 id="ad-title">Eliminar mi cuenta</h2><p>Comprobando si tu cuenta puede eliminarse…</p>');
    const { data, error } = await supabaseClient.rpc('my_account_deletion_check');
    if (error) {
      const missing = /function|schema cache/i.test(error.message || '');
      o.querySelector('.ad-panel').innerHTML = '<h2 id="ad-title">Eliminar mi cuenta</h2><p class="form-error">' + (missing ? 'Esta opción todavía no está activa. Escríbenos a inmobiliaria@bastet.uno y la gestionamos.' : esc(error.message)) + '</p><div class="modal-form-actions"><button type="button" class="btn btn-ghost" data-close>Cerrar</button></div>';
      return;
    }
    if (!data.can_delete) {
      o.querySelector('.ad-panel').innerHTML = '<h2 id="ad-title">Todavía no puedes eliminar tu cuenta</h2><p>Primero resuelve estos pendientes:</p><ul class="ad-list">' +
        (data.blockers || []).map((b) => '<li>' + esc(b) + '</li>').join('') + '</ul><p class="field-hint">Cuando estén resueltos, vuelve aquí. Si necesitas ayuda, escríbenos a inmobiliaria@bastet.uno.</p><div class="modal-form-actions"><button type="button" class="btn btn-ghost" data-close>Entendido</button></div>';
      return;
    }
    o.querySelector('.ad-panel').innerHTML = '<h2 id="ad-title">¿Eliminar tu cuenta?</h2>' +
      '<p>Esta acción <b>no se puede deshacer</b>. Al eliminarla:</p><ul class="ad-list"><li>Tus inmuebles disponibles dejan de publicarse.</li><li>Se borran tu perfil, favoritos, búsquedas, datos legales y solicitudes de verificación con sus documentos.</li><li>Se cierra tu acceso y tu correo queda libre.</li><li>Bastet conserva los registros de operaciones ya realizadas, como constancias, actas y reservas, según la política de privacidad.</li></ul>' +
      '<label class="ad-confirm">Para confirmar, escribe <b>ELIMINAR</b><input type="text" id="ad-word" autocomplete="off" maxlength="12"></label>' +
      '<p id="ad-err" class="form-error hidden"></p>' +
      '<div class="modal-form-actions"><button type="button" class="btn btn-ghost" data-close>Cancelar</button><button type="button" class="btn ad-danger-fill" id="ad-go" disabled>Eliminar mi cuenta</button></div>';
    const word = o.querySelector('#ad-word'), go = o.querySelector('#ad-go'), er = o.querySelector('#ad-err');
    word.addEventListener('input', () => { go.disabled = word.value.trim().toUpperCase() !== 'ELIMINAR'; });
    go.addEventListener('click', async () => {
      go.disabled = true; go.textContent = 'Eliminando…'; er.classList.add('hidden');
      await purgeOwnFiles();
      const { error: e2 } = await supabaseClient.rpc('delete_my_account', { p_confirm: word.value });
      if (e2) { er.textContent = e2.message || 'No se pudo eliminar la cuenta.'; er.classList.remove('hidden'); go.disabled = false; go.textContent = 'Eliminar mi cuenta'; return; }
      o.querySelector('.ad-panel').innerHTML = '<h2 id="ad-title">Tu cuenta fue eliminada</h2><p>Gracias por haber usado Bastet. Te llevamos al inicio.</p>';
      try { await supabaseClient.auth.signOut(); } catch (e) { /* la sesión ya no es válida */ }
      setTimeout(() => { location.href = '../index.html'; }, 1800);
    });
  }

  // Borra, si la política de almacenamiento lo permite, los documentos de verificación de la propia persona (carpeta con su id)
  async function purgeOwnFiles() {
    try {
      const { data: s } = await supabaseClient.auth.getSession();
      const uid = s && s.session && s.session.user && s.session.user.id; if (!uid) return;
      const bucket = supabaseClient.storage.from('verification-docs');
      const { data: files } = await bucket.list(uid, { limit: 200 });
      if (files && files.length) await bucket.remove(files.map((f) => uid + '/' + f.name));
    } catch (e) { /* mejor esfuerzo: un fallo aquí no impide eliminar la cuenta */ }
  }

  document.addEventListener('DOMContentLoaded', ensureCard);
  if (document.readyState !== 'loading') ensureCard();
})();
