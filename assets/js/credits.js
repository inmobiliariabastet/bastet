/* Pestaña "Créditos" del panel de usuario.
 * Autónomo: usa el cliente global `supabaseClient` y las clases del panel (.btn, .admin-toolbar…).
 * No modifica admin.js; solo reacciona al clic en la pestaña data-tab="credits". */
(function () {
  'use strict';

  const root = () => document.getElementById('credits-root');
  const state = { uid: null, isAdmin: false, loaded: false, busy: false };

  const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const usd = (n) => Number(n).toLocaleString('es-BO', { minimumFractionDigits: 0, maximumFractionDigits: 2 }) + ' USD';
  // Precios en bolivianos (4 Bs por crédito comprado). Las solicitudes antiguas, hechas en dólares, se siguen mostrando como estaban.
  const bs = (n) => Number(n).toLocaleString('es-BO', { minimumFractionDigits: 0, maximumFractionDigits: 2 }) + ' Bs';
  const priceOf = (x) => (x.price_bs != null ? bs(x.price_bs) : x.price_usd != null ? usd(x.price_usd) : '—');
  const fdate = (d) => new Date(d).toLocaleDateString('es-BO', { day: '2-digit', month: 'short', year: 'numeric' });
  const KIND = { purchase: 'Compra', spend: 'Uso', bonus: 'Bono', adjustment: 'Ajuste' };
  const METHOD = { transferencia: 'Transferencia', qr: 'QR', efectivo: 'Efectivo' };

  function flash(msg, isError) {
    const el = document.getElementById('credits-flash');
    if (!el) return;
    el.textContent = msg;
    el.className = isError ? 'form-error' : 'auth-banner';
    el.hidden = false;
    clearTimeout(flash.t);
    flash.t = setTimeout(() => { el.hidden = true; }, 5000);
  }

  // Los mensajes de las funciones SQL ya vienen en español.
  const errText = (e) => (e && e.message) || 'No se pudo completar la acción.';

  async function load() {
    const host = root();
    if (!host || state.busy) return;
    state.busy = true;
    try {
      const { data: auth } = await supabaseClient.auth.getUser();
      state.uid = auth && auth.user && auth.user.id;
      if (!state.uid) { host.innerHTML = '<p class="credits-empty">Inicia sesión para ver tus créditos.</p>'; return; }

      const me = await supabaseClient.from('profiles').select('role').eq('id', state.uid).single();
      state.isAdmin = !!(me.data && me.data.role === 'admin');

      const [wallet, ledger, packs, services, props, reqs] = await Promise.all([
        supabaseClient.from('credit_wallets').select('balance').eq('user_id', state.uid).maybeSingle(),
        supabaseClient.from('credit_ledger').select('*').eq('user_id', state.uid).order('created_at', { ascending: false }).limit(100),
        supabaseClient.from('credit_packs').select('*').eq('active', true).order('credits'),
        supabaseClient.from('credit_services').select('*').eq('active', true).order('cost'),
        supabaseClient.from('properties').select('id,title,code_number,status,featured_until').eq('owner_id', state.uid).order('code_number'),
        supabaseClient.from('credit_requests').select('*').eq('user_id', state.uid).order('created_at', { ascending: false }).limit(10),
      ]);
      const failed = [wallet, ledger, packs, services, props, reqs].find((r) => r.error);
      if (failed) throw failed.error;

      let admin = null;
      if (state.isAdmin) {
        const [pending, users] = await Promise.all([
          supabaseClient.from('credit_requests').select('*, profiles(display_name,email)').eq('status', 'pending').order('created_at'),
          supabaseClient.from('profiles').select('id,email,display_name').eq('is_active', true).order('email'),
        ]);
        if (pending.error) throw pending.error;
        admin = { pending: pending.data || [], users: (users.data || []) };
      }

      render({
        balance: (wallet.data && wallet.data.balance) || 0,
        ledger: ledger.data || [], packs: packs.data || [], services: services.data || [],
        props: props.data || [], reqs: reqs.data || [], admin,
      });
      state.loaded = true;
    } catch (e) {
      host.innerHTML = '<p class="form-error">No se pudieron cargar los créditos. ' + esc(errText(e)) + '</p>';
    } finally {
      state.busy = false;
    }
  }

  function render(d) {
    const pending = d.reqs.find((r) => r.status === 'pending');
    const activeUntil = (p) => p.featured_until && new Date(p.featured_until) > new Date();

    root().innerHTML = `
      <div id="credits-flash" hidden></div>

      <section class="cr-card" aria-label="Saldo disponible">
        <div class="cr-left">
          <span class="cr-eyebrow">Saldo disponible</span>
          <div class="cr-balance-row">
            <span class="cr-coin" aria-hidden="true"><svg viewBox="0 0 24 24"><ellipse cx="12" cy="6" rx="7" ry="3"/><path d="M5 6v6c0 1.7 3.1 3 7 3s7-1.3 7-3V6M5 12v6c0 1.7 3.1 3 7 3s7-1.3 7-3v-6"/></svg></span>
            <div>
              <div class="cr-figure"><b>${d.balance}</b><span>${d.balance === 1 ? 'Crédito' : 'Créditos'}</span></div>
              <p class="cr-sub">Disponibles para usar</p>
            </div>
          </div>
        </div>
        <div class="cr-right">
          <span class="cr-eyebrow cr-eyebrow--soft">Úsalos para:</span>
          <div class="cr-uses">
            <div class="cr-use"><span class="cr-use-ico" aria-hidden="true"><svg viewBox="0 0 24 24"><path d="M12 3.5l2.6 5.3 5.9.9-4.3 4.1 1 5.8L12 16.8 6.8 19.6l1-5.8-4.3-4.1 5.9-.9z"/></svg></span><div><b>Destacar propiedades</b><span>Mayor visibilidad para tus inmuebles.</span></div></div>
            <div class="cr-use"><span class="cr-use-ico" aria-hidden="true"><svg viewBox="0 0 24 24"><path d="M14 3H7a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V8z"/><path d="M14 3v5h5M9 13h6M9 17h4"/></svg></span><div><b>Publicar o renovar</b><span>Usa créditos cuando no tengas cupo gratuito.</span></div></div>
          </div>
          <div class="cr-foot"><div id="credits-pub-line" class="cr-free"></div><div id="credits-cost" class="cr-cost"></div></div>
        </div>
      </section>

      ${pending ? `<p class="auth-banner">Tu solicitud del pack <b>${esc(pending.pack_name)}</b> (${priceOf(pending)}) está pendiente de confirmación de pago.</p>` : ''}

      <h2 class="admin-subheading">Destacar una propiedad</h2>
      <div class="property-list credits-props">
        ${d.props.length ? d.props.map((p) => `
          <div class="property-row credits-prop">
            <div class="credits-prop-info">
              <strong>${esc(p.title)}</strong>
              <span class="credits-muted">BST-${esc(p.code_number)}${activeUntil(p) ? ' · destacada hasta ' + fdate(p.featured_until) : ''}</span>
            </div>
            <div class="credits-prop-actions">
              ${d.services.map((s) => `<button type="button" class="btn btn-ghost btn-sm" data-feature="${esc(p.id)}" data-service="${esc(s.code)}" ${d.balance < s.cost || p.status !== 'available' ? 'disabled' : ''}>${esc(s.name.replace('Destacar propiedad · ', ''))} · ${s.cost} cr.</button>`).join('')}
            </div>
          </div>`).join('') : '<p class="credits-empty">Aún no tienes propiedades. Crea una en la pestaña Propiedades.</p>'}
      </div>

      ${d.admin ? renderAdmin(d.admin) : ''}

      <h2 class="admin-subheading">Movimientos</h2>
      <div class="credits-table-wrap">
        ${d.ledger.length ? `<table class="credits-table"><thead><tr><th>Fecha</th><th>Tipo</th><th>Detalle</th><th class="r">Créditos</th></tr></thead><tbody>
          ${d.ledger.map((m) => `<tr><td>${fdate(m.created_at)}</td><td>${KIND[m.kind] || esc(m.kind)}</td><td>${esc(m.description)}</td><td class="r ${m.amount > 0 ? 'is-in' : 'is-out'}">${m.amount > 0 ? '+' : ''}${m.amount}</td></tr>`).join('')}
        </tbody></table>` : '<p class="credits-empty">Todavía no hay movimientos.</p>'}
      </div>

      <h2 class="admin-subheading">Comprar créditos</h2>
      <div class="credits-packs">
        ${d.packs.map((p) => `
          <article class="credits-pack${p.highlighted ? ' is-top' : ''}">
            <h3>${esc(p.name)}</h3>
            <div class="credits-pack-n">${p.credits}</div>
            <span class="credits-muted">créditos</span>
            <div class="credits-pack-price">${priceOf(p)}</div>
            ${p.price_bs != null && p.credits > 0 ? `<span class="credits-muted">${bs(p.price_bs / p.credits)} por crédito</span>` : ''}
            <ul>${(p.perks || []).map((x) => '<li>' + esc(x) + '</li>').join('')}</ul>
            <button type="button" class="btn ${p.highlighted ? 'btn-accent' : 'btn-primary'} btn-sm" data-pack="${esc(p.code)}" ${pending ? 'disabled' : ''}>Solicitar ${esc(p.name)}</button>
          </article>`).join('')}
      </div>
      <form id="credits-method-form" class="credits-method" hidden>
        <p class="credits-muted">Elige cómo pagarás. Un administrador confirmará tu pago y se acreditarán los créditos.</p>
        <div class="credits-method-row">
          <label><input type="radio" name="credits-method" value="transferencia" checked> Transferencia</label>
          <label><input type="radio" name="credits-method" value="qr"> QR</label>
          <label><input type="radio" name="credits-method" value="efectivo"> Efectivo</label>
        </div>
        <div class="credits-method-row">
          <button type="submit" class="btn btn-accent btn-sm" id="credits-method-submit">Enviar solicitud</button>
          <button type="button" class="btn btn-ghost btn-sm" id="credits-method-cancel">Cancelar</button>
        </div>
      </form>`;

    bind(d);
    if (window.UnoPublications) window.UnoPublications.refresh();
  }

  function renderAdmin(a) {
    return `
      <h2 class="admin-subheading">Administración de créditos</h2>
      <div class="credits-admin">
        <h3>Pagos por confirmar</h3>
        ${a.pending.length ? a.pending.map((r) => `
          <div class="property-row credits-prop">
            <div class="credits-prop-info">
              <strong>${esc((r.profiles && (r.profiles.display_name || r.profiles.email)) || 'Agente')}</strong>
              <span class="credits-muted">${esc(r.pack_name)} · ${r.credits} cr. · ${priceOf(r)} · ${METHOD[r.method] || esc(r.method)} · ${fdate(r.created_at)}</span>
            </div>
            <div class="credits-prop-actions">
              <button type="button" class="btn btn-accent btn-sm" data-resolve="${r.id}" data-approve="1">Confirmar pago</button>
              <button type="button" class="btn btn-ghost btn-sm" data-resolve="${r.id}" data-approve="0">Rechazar</button>
            </div>
          </div>`).join('') : '<p class="credits-empty">No hay pagos pendientes.</p>'}

        <h3>Bono o ajuste manual</h3>
        <form id="credits-grant-form" class="invite-admin-card">
          <div class="field"><label for="credits-grant-user">Agente</label>
            <select id="credits-grant-user" required><option value="">Selecciona…</option>
              ${a.users.map((u) => `<option value="${esc(u.id)}">${esc(u.display_name || u.email)} (${esc(u.email)})</option>`).join('')}
            </select></div>
          <div class="field"><label for="credits-grant-amount">Créditos (negativo para descontar)</label>
            <input type="number" id="credits-grant-amount" step="1" required placeholder="Ej: 10"></div>
          <div class="field"><label for="credits-grant-desc">Motivo</label>
            <input type="text" id="credits-grant-desc" maxlength="120" placeholder="Ej: Bono por cierre de venta"></div>
          <button type="submit" class="btn btn-accent" id="credits-grant-submit">Aplicar</button>
        </form>
      </div>`;
  }

  function bind(d) {
    const host = root();
    let chosenPack = null;
    const form = host.querySelector('#credits-method-form');

    host.querySelectorAll('[data-pack]').forEach((b) => b.addEventListener('click', () => {
      chosenPack = b.dataset.pack;
      form.hidden = false;
      form.scrollIntoView({ behavior: 'smooth', block: 'nearest' });
    }));
    host.querySelector('#credits-method-cancel').addEventListener('click', () => { form.hidden = true; });
    form.addEventListener('submit', async (e) => {
      e.preventDefault();
      const method = form.querySelector('input[name="credits-method"]:checked').value;
      const btn = host.querySelector('#credits-method-submit');
      btn.disabled = true;
      const { error } = await supabaseClient.rpc('request_credit_pack', { p_pack: chosenPack, p_method: method });
      if (error) { btn.disabled = false; return flash(errText(error), true); }
      await reload('Solicitud enviada. Te avisaremos cuando se confirme el pago.');
    });

    host.querySelectorAll('[data-feature]').forEach((b) => b.addEventListener('click', async () => {
      // Todo cobro en créditos pide aprobación del agente antes de descontar
      const svc = d.services.find((s) => s.code === b.dataset.service);
      const prop = d.props.find((x) => String(x.id) === String(b.dataset.feature));
      if (svc && window.UnoPublications && window.UnoPublications.confirmSpend) {
        const ok = await window.UnoPublications.confirmSpend({
          title: 'Confirmar compra', what: svc.name + (prop ? ' — ' + prop.title : ''), cost: svc.cost, balance: d.balance,
          note: 'El descuento no se devuelve una vez activada la destacada.', button: 'Destacar',
        });
        if (!ok) return;
      }
      b.disabled = true;
      const { error } = await supabaseClient.rpc('feature_property', { p_property_id: b.dataset.feature, p_service: b.dataset.service });
      if (error) { await reload(errText(error), true); return; }
      await reload('Propiedad destacada.');
    }));

    host.querySelectorAll('[data-resolve]').forEach((b) => b.addEventListener('click', async () => {
      b.disabled = true;
      const { error } = await supabaseClient.rpc('admin_resolve_credit_request', { p_id: Number(b.dataset.resolve), p_approve: b.dataset.approve === '1' });
      if (error) { await reload(errText(error), true); return; }
      await reload(b.dataset.approve === '1' ? 'Pago confirmado y créditos acreditados.' : 'Solicitud rechazada.');
    }));

    const grant = host.querySelector('#credits-grant-form');
    if (grant) grant.addEventListener('submit', async (e) => {
      e.preventDefault();
      const { error } = await supabaseClient.rpc('admin_grant_credits', {
        p_user: grant.querySelector('#credits-grant-user').value,
        p_amount: parseInt(grant.querySelector('#credits-grant-amount').value, 10),
        p_description: grant.querySelector('#credits-grant-desc').value,
      });
      if (error) return flash(errText(error), true);
      await reload('Créditos aplicados.');
    });
  }

  async function reload(msg, isError) {
    await load();
    if (msg) flash(msg, isError);
  }

  document.addEventListener('click', (e) => {
    const tab = e.target.closest('.admin-tab[data-tab="credits"]');
    if (!tab) return;
    // Respaldo por si admin.js no maneja pestañas nuevas: mostrar nuestro panel.
    document.querySelectorAll('.tab-panel').forEach((p) => p.classList.add('hidden'));
    const panel = document.getElementById('tab-panel-credits');
    if (panel) panel.classList.remove('hidden');
    document.querySelectorAll('.admin-tab').forEach((t) => t.classList.toggle('is-active', t === tab));
    load();
  });
})();
