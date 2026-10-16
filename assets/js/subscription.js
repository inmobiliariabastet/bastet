/* Pestaña "Suscripción" del panel de usuario (reemplaza a "Créditos").
 * Muestra el plan y su uso, compara los 3 planes (Propietario / Agente / Empresa), solicita un plan (pago manual: un
 * administrador confirma el pago), permite destacar propiedades dentro del cupo del plan y, para administradores,
 * confirmar pagos y dar de alta planes. Los precios y límites salen de la base de datos (subscription_plans): aquí solo se muestran.
 * Autónomo: usa el cliente global `supabaseClient` y las clases del panel. */
(function () {
  'use strict';

  const root = () => document.getElementById('subscription-root');
  const state = { uid: null, isAdmin: false, busy: false, plans: [], pickedPlan: null };
  const WHATSAPP = '59177666205';

  const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const bs = (n) => 'Bs ' + Number(n).toLocaleString('es-BO', { minimumFractionDigits: 0, maximumFractionDigits: 2 });
  const fdate = (d) => new Date(d).toLocaleDateString('es-BO', { day: '2-digit', month: 'short', year: 'numeric' });
  const METHOD = { transferencia: 'Transferencia', qr: 'QR', efectivo: 'Efectivo' };
  const STATUS = { pending: 'Pendiente', approved: 'Confirmado', rejected: 'Rechazado' };
  const SOURCE = { payment: 'Pago', grace: 'Cortesía', admin: 'Alta manual', trial: 'Prueba gratis' };
  const DAY = 86400000;
  const plural = (n, one, many) => (n === 1 ? one : many);

  // Funciones anunciadas como "Próximamente": hoy ninguna (las del plan Propietario ya existen en la pestaña "Mi gestión").
  const COMING_SOON = { propietario: [], agente: [], empresa: [] };
  // Mensaje de WhatsApp para pedir los datos de pago: incluye el plan elegido y su monto
  const waLink = (p) => 'https://api.whatsapp.com/send?phone=' + WHATSAPP + '&text=' + encodeURIComponent(p
    ? 'Hola, quiero pagar mi suscripción en Bastet. Elegí el plan ' + p.name + ' (' + bs(p.price_bs) + ' por 30 días). ¿Me envían los datos de pago?'
    : 'Hola, quiero pagar mi suscripción en Bastet. ¿Me envían los datos de pago?');
  const PLAN_LABEL = { propietario: 'Suscribirme como propietario', agente: 'Suscribirme como agente', empresa: 'Suscribirme como empresa' };

  function flash(msg, isError) {
    const el = document.getElementById('subscription-flash');
    if (!el) return;
    el.textContent = msg;
    el.className = isError ? 'form-error' : 'auth-banner';
    el.hidden = false;
    clearTimeout(flash.t);
    flash.t = setTimeout(() => { el.hidden = true; }, 6000);
  }
  const errText = (e) => (e && e.message) || 'No se pudo completar la acción.';

  async function load() {
    const host = root();
    if (!host || state.busy) return;
    state.busy = true;
    try {
      const { data: auth } = await supabaseClient.auth.getUser();
      state.uid = auth && auth.user && auth.user.id;
      if (!state.uid) { host.innerHTML = '<p class="credits-empty">Inicia sesión para ver tu suscripción.</p>'; return; }

      const [subRes, plansRes, reqsRes, propsRes, walletRes] = await Promise.all([
        supabaseClient.rpc('my_subscription'),
        supabaseClient.from('subscription_plans').select('*').eq('active', true).order('sort_order'),
        supabaseClient.from('subscription_requests').select('*').eq('user_id', state.uid).order('created_at', { ascending: false }).limit(10),
        supabaseClient.from('properties').select('id,title,code_number,status,expires_at,featured_until').eq('owner_id', state.uid).order('code_number'),
        supabaseClient.from('credit_wallets').select('balance').eq('user_id', state.uid).maybeSingle(),
      ]);
      const failed = [subRes, plansRes, reqsRes, propsRes].find((r) => r.error);
      if (failed) throw failed.error;
      const sub = subRes.data;
      state.isAdmin = !!(sub && sub.exempt);
      state.plans = plansRes.data || [];

      let admin = null;
      if (state.isAdmin) {
        const [pending, subs, people] = await Promise.all([
          supabaseClient.from('subscription_requests').select('*').eq('status', 'pending').order('created_at'),
          supabaseClient.from('subscriptions').select('*').order('current_period_end', { ascending: false }),
          supabaseClient.from('profiles').select('id,email,display_name').eq('is_active', true).order('email'),
        ]);
        if (pending.error) throw pending.error;
        admin = { pending: pending.data || [], subs: subs.data || [], people: people.data || [] };
      }
      render({ sub, plans: state.plans, reqs: reqsRes.data || [], props: propsRes.data || [], legacyCredits: (walletRes.data && walletRes.data.balance) || 0, admin });
      if (window.UnoPublications) window.UnoPublications.refresh();
    } catch (e) {
      host.innerHTML = '<p class="form-error">No se pudo cargar la suscripción. ' + esc(errText(e)) + '</p>';
    } finally {
      state.busy = false;
    }
  }

  const hasPlan = (s) => !!s && (s.status === 'active' || s.status === 'canceling');

  function meter(label, used, max) {
    const pct = max > 0 ? Math.min(100, Math.round((used / max) * 100)) : 0;
    return '<div class="sb-meter' + (used >= max ? ' is-full' : '') + '"><div class="sb-meter-top"><span>' + label + '</span><b>' + used + ' / ' + max + '</b></div><div class="sb-meter-bar"><i style="width:' + pct + '%"></i></div></div>';
  }

  function planCard(s) {
    if (s.exempt) {
      return '<section class="cr-card sb-card"><div class="cr-left"><span class="cr-eyebrow">Tu cuenta</span><div class="cr-figure"><b class="sb-plan-name">Administrador</b></div><p class="cr-sub">Sin plan ni límites de publicación o destacados.</p></div>' +
        '<div class="cr-right"><span class="cr-eyebrow cr-eyebrow--soft">Administración</span><p class="cr-sub">Abajo puedes confirmar pagos y dar de alta planes manualmente.</p></div></section>';
    }
    if (!hasPlan(s)) {
      const expired = s.status === 'expired';
      return '<section class="cr-card sb-card"><div class="cr-left"><span class="cr-eyebrow">Tu plan</span><div class="cr-figure"><b class="sb-plan-name">' + (expired ? (s.source === 'trial' ? 'Prueba terminada' : 'Vencido') : 'Sin plan') + '</b></div>' +
        '<p class="cr-sub">' + (expired ? (s.source === 'trial' ? 'Tu prueba gratuita terminó el ' : 'Tu plan ' + esc(s.plan.name) + ' terminó el ') + fdate(s.period_end) + (s.source === 'trial' ? '. Elige un plan para seguir publicando; tus propiedades dejaron de mostrarse.' : '. Tus propiedades dejaron de mostrarse.') : 'Elige un plan para publicar y destacar tus propiedades.') + '</p></div>' +
        '<div class="cr-right"><span class="cr-eyebrow cr-eyebrow--soft">Cómo funciona</span><ol class="sb-steps"><li>Elige un plan abajo y solicítalo.</li><li>Paga por transferencia, QR o efectivo.</li><li>Un administrador confirma tu pago y el plan se activa por 30 días.</li></ol>' +
        (s.trial_eligible && s.registered && s.interest === 'propietario' ? '<button type="button" class="btn btn-accent btn-sm sb-trial" data-sb="trial">Probar 7 días gratis</button><p class="cr-sub">Prueba de 7 días con el plan Propietario, solo para cuentas de propietario. Solo una vez y si aún no solicitaste un plan.</p>' : '') + '</div></section>';
    }
    const pl = s.plan, u = s.usage;
    const days = Math.max(Math.ceil((new Date(s.period_end).getTime() - Date.now()) / DAY), 0);
    const canceling = s.status === 'canceling';
    return '<section class="cr-card sb-card"><div class="cr-left"><span class="cr-eyebrow">Tu plan</span>' +
      '<div class="cr-figure"><b class="sb-plan-name">' + esc(pl.name) + '</b><span>' + bs(pl.price_bs) + ' / mes</span></div>' +
      '<p class="cr-sub">' + (canceling ? 'Cancelado: termina el ' : 'Vigente hasta el ') + '<b>' + fdate(s.period_end) + '</b> · ' + days + ' ' + plural(days, 'día', 'días') + ' restantes' + (s.source === 'grace' ? ' · <em>cortesía de transición</em>' : s.source === 'trial' ? ' · <em>prueba gratuita: elige un plan antes de que termine</em>' : '') + '</p></div>' +
      '<div class="cr-right"><span class="cr-eyebrow cr-eyebrow--soft">Uso de tu plan</span>' +
      meter('Propiedades activas', u.active_properties, pl.max_active_properties) +
      meter('Destacados de este periodo', u.featured_used, pl.max_featured_per_period) +
      '<div class="sb-actions">' +
        (s.source === 'trial' ? '' : canceling ? '<button type="button" class="btn btn-ghost btn-sm" data-sb="resume">Reanudar</button>' : '<button type="button" class="btn btn-ghost btn-sm" data-sb="cancel">No renovar</button>') +
      '</div></div></section>';
  }

  function featuresOf(p) {
    const f = [
      'Hasta <b>' + p.max_active_properties + '</b> propiedades activas publicadas',
      '<b>' + p.max_featured_per_period + '</b> ' + plural(p.max_featured_per_period, 'propiedad destacada', 'propiedades destacadas') + ' por periodo mensual',
    ];
    if (p.agent_tools) f.push('Herramientas profesionales de agente (contrato de exclusividad, clientes interesados, comisiones, analítica)');
    else {
      f.push('Panel para administrar tus propiedades, clientes interesados y analítica');
      f.push('Elige un agente registrado y ofrécele tu propiedad con un documento de oferta (borrador sujeto a validación legal)');
      f.push('Solicita asesoría y trámites a Maat Fima Legal: compra y venta, trámites, saneamiento e impuestos');
    }
    if (p.code === 'empresa') f.push('Cuenta de empresa para gestionar un inventario de hasta ' + p.max_active_properties + ' propiedades');
    return f;
  }

  function plansHtml(d) {
    const s = d.sub, pending = s.pending_request;
    const current = hasPlan(s) ? s.plan.code : (s.status === 'expired' ? s.plan.code : null);
    return '<h2 class="admin-subheading">Planes</h2><div class="credits-packs sb-plans">' + d.plans.map((p) => {
      const isCurrent = hasPlan(s) && s.plan.code === p.code;
      const label = isCurrent ? 'Renovar mi plan' : (current && hasPlan(s) ? 'Cambiar a ' + p.name : PLAN_LABEL[p.code] || 'Suscribirme');
      return '<article class="credits-pack' + (p.code === 'agente' ? ' is-top' : '') + (isCurrent ? ' is-current' : '') + '">' +
        (isCurrent ? '<span class="sb-badge">Tu plan</span>' : '') +
        '<h3>' + esc(p.name) + '</h3>' +
        '<div class="credits-pack-n sb-price">' + bs(p.price_bs) + '<small>/ mes</small></div>' +
        '<ul>' + featuresOf(p).map((x) => '<li>' + x + '</li>').join('') + '</ul>' +
        ((COMING_SOON[p.code] || []).length ? '<p class="sb-soon-title">Próximamente</p><ul class="sb-soon">' + COMING_SOON[p.code].map((x) => '<li>' + esc(x) + '</li>').join('') + '</ul>' : '') +
        (s.exempt ? '' : '<button type="button" class="btn ' + (p.code === 'agente' ? 'btn-accent' : 'btn-primary') + ' btn-sm" data-plan="' + esc(p.code) + '" ' + (pending ? 'disabled' : '') + '>' + esc(label) + '</button>') +
        '</article>';
    }).join('') + '</div>' +
    '<form id="sb-method-form" class="credits-method" hidden>' +
      '<p><b id="sb-method-title"></b></p>' +
      '<p class="credits-muted">Elige cómo pagarás. Un administrador confirmará tu pago y se activará tu plan por 30 días. No hay cobro automático: cuando quieras renovar, vuelve a solicitarlo.</p>' +
      '<div class="credits-method-row"><label><input type="radio" name="sb-method" value="transferencia" checked> Transferencia</label><label><input type="radio" name="sb-method" value="qr"> QR</label><label><input type="radio" name="sb-method" value="efectivo"> Efectivo</label></div>' +
      '<div class="field"><label for="sb-reference">N.º de transferencia o comprobante (opcional)</label><input type="text" id="sb-reference" maxlength="120" placeholder="Ej: 004512389"></div>' +
      '<p class="credits-muted">¿Necesitas los datos para pagar? Escríbenos por <a id="sb-wa-link" href="' + waLink(null) + '" target="_blank" rel="noopener">WhatsApp</a>.</p>' +
      '<div class="credits-method-row"><button type="submit" class="btn btn-accent btn-sm" id="sb-method-submit">Enviar solicitud</button><button type="button" class="btn btn-ghost btn-sm" id="sb-method-cancel">Cancelar</button></div>' +
    '</form>';
  }

  function featureHtml(d) {
    const s = d.sub;
    const planOk = s.exempt || hasPlan(s);
    const left = s.exempt ? Infinity : (hasPlan(s) ? s.plan.max_featured_per_period - s.usage.featured_used : 0);
    const featured = (p) => p.featured_until && new Date(p.featured_until) > new Date();
    const live = (p) => p.status === 'available' && (!p.expires_at || new Date(p.expires_at) > new Date());
    return '<h2 class="admin-subheading">Destacar una propiedad</h2>' +
      (planOk ? '<p class="credits-muted">' + (s.exempt ? 'Sin límite.' : 'Te ' + plural(left, 'queda', 'quedan') + ' <b>' + Math.max(left, 0) + '</b> ' + plural(left, 'destacado', 'destacados') + ' este periodo. Una propiedad ya destacada no gasta otra plaza.') + ' Cada destacado dura 30 días.</p>' : '<p class="credits-muted">Necesitas un plan activo para destacar propiedades.</p>') +
      '<div class="property-list credits-props">' + (d.props.length ? d.props.map((p) => '<div class="property-row credits-prop"><div class="credits-prop-info"><strong>' + esc(p.title) + '</strong>' +
        '<span class="credits-muted">BST-' + esc(p.code_number) + (featured(p) ? ' · destacada hasta ' + fdate(p.featured_until) : '') + (!live(p) ? ' · no está activa' : '') + '</span></div>' +
        '<div class="credits-prop-actions"><button type="button" class="btn btn-ghost btn-sm" data-feature="' + esc(p.id) + '" ' + (!planOk || left <= 0 || featured(p) || !live(p) ? 'disabled' : '') + '>' + (featured(p) ? 'Destacada' : 'Destacar') + '</button></div></div>').join('')
        : '<p class="credits-empty">Aún no tienes propiedades. Crea una en la pestaña Propiedades.</p>') + '</div>';
  }

  function historyHtml(d) {
    return '<h2 class="admin-subheading">Mis solicitudes de plan</h2><div class="credits-table-wrap">' + (d.reqs.length ?
      '<table class="credits-table"><thead><tr><th>Fecha</th><th>Plan</th><th>Monto</th><th>Pago</th><th>Estado</th></tr></thead><tbody>' +
      d.reqs.map((r) => '<tr><td>' + fdate(r.created_at) + '</td><td>' + esc(r.plan_code) + '</td><td>' + bs(r.price_bs) + '</td><td>' + (METHOD[r.method] || esc(r.method)) + (r.reference ? ' · ' + esc(r.reference) : '') + '</td><td>' + (STATUS[r.status] || esc(r.status)) + (r.note ? ' · ' + esc(r.note) : '') + '</td></tr>').join('') +
      '</tbody></table>' : '<p class="credits-empty">Todavía no hiciste ninguna solicitud.</p>') + '</div>' +
      (d.legacyCredits > 0 ? '<p class="credits-muted sb-legacy">Conservas <b>' + d.legacyCredits + '</b> créditos de la versión anterior. Ya no se usan ni se venden; tu historial se mantiene.</p>' : '');
  }

  function adminHtml(a) {
    const name = (id) => { const u = a.people.find((x) => x.id === id); return u ? (u.display_name || u.email) : 'Usuario'; };
    const planName = (code) => { const p = state.plans.find((x) => x.code === code); return p ? p.name : code; };
    return '<h2 class="admin-subheading">Administración de suscripciones</h2><div class="credits-admin"><h3>Pagos por confirmar</h3>' +
      (a.pending.length ? a.pending.map((r) => '<div class="property-row credits-prop"><div class="credits-prop-info"><strong>' + esc(name(r.user_id)) + '</strong>' +
        '<span class="credits-muted">' + esc(planName(r.plan_code)) + ' · ' + bs(r.price_bs) + ' · ' + (METHOD[r.method] || esc(r.method)) + (r.reference ? ' · ref. ' + esc(r.reference) : '') + ' · ' + fdate(r.created_at) + '</span></div>' +
        '<div class="credits-prop-actions"><button type="button" class="btn btn-accent btn-sm" data-resolve="' + r.id + '" data-approve="1">Confirmar pago</button><button type="button" class="btn btn-ghost btn-sm" data-resolve="' + r.id + '" data-approve="0">Rechazar</button></div></div>').join('')
        : '<p class="credits-empty">No hay pagos pendientes.</p>') +
      '<h3>Dar de alta o cambiar un plan</h3>' +
      '<form id="sb-grant-form" class="invite-admin-card">' +
        '<div class="field"><label for="sb-grant-user">Persona</label><select id="sb-grant-user" required><option value="">Selecciona…</option>' + a.people.map((u) => '<option value="' + esc(u.id) + '">' + esc(u.display_name || u.email) + ' (' + esc(u.email) + ')</option>').join('') + '</select></div>' +
        '<div class="field"><label for="sb-grant-plan">Plan</label><select id="sb-grant-plan" required>' + state.plans.map((p) => '<option value="' + esc(p.code) + '">' + esc(p.name) + ' · ' + bs(p.price_bs) + '</option>').join('') + '</select></div>' +
        '<div class="field"><label for="sb-grant-days">Días (vacío = 30)</label><input type="number" id="sb-grant-days" min="1" max="400" step="1" placeholder="30"></div>' +
        '<button type="submit" class="btn btn-accent" id="sb-grant-submit">Aplicar plan</button></form>' +
      '<h3>Suscripciones</h3>' +
      (a.subs.length ? '<div class="credits-table-wrap"><table class="credits-table"><thead><tr><th>Persona</th><th>Plan</th><th>Vence</th><th>Origen</th></tr></thead><tbody>' +
        a.subs.map((s) => { const on = new Date(s.current_period_end) > new Date(); return '<tr><td>' + esc(name(s.user_id)) + '</td><td>' + esc(planName(s.plan_code)) + '</td><td>' + fdate(s.current_period_end) + (on ? '' : ' · <b>vencida</b>') + '</td><td>' + (SOURCE[s.source] || esc(s.source)) + '</td></tr>'; }).join('') +
        '</tbody></table></div>' : '<p class="credits-empty">Todavía no hay suscripciones.</p>') + '</div>';
  }

  function render(d) {
    const s = d.sub;
    const pendingBanner = s.pending_request ? '<p class="auth-banner">Tu solicitud del plan <b>' + esc(s.pending_request.plan_code) + '</b> (' + bs(s.pending_request.price_bs) + ') está pendiente de confirmación de pago.</p>' : '';
    root().innerHTML = '<div id="subscription-flash" hidden></div>' + planCard(s) + pendingBanner + plansHtml(d) + featureHtml(d) + (d.admin ? adminHtml(d.admin) : '') + historyHtml(d);
    bind(d);
  }

  function bind(d) {
    const host = root();
    const form = host.querySelector('#sb-method-form');
    host.querySelectorAll('[data-plan]').forEach((b) => b.addEventListener('click', () => {
      state.pickedPlan = b.dataset.plan;
      const p = d.plans.find((x) => x.code === state.pickedPlan);
      host.querySelector('#sb-method-title').textContent = 'Plan ' + p.name + ' · ' + bs(p.price_bs) + ' por 30 días';
      host.querySelector('#sb-wa-link').href = waLink(p);
      form.hidden = false;
      form.scrollIntoView({ behavior: 'smooth', block: 'nearest' });
    }));
    host.querySelector('#sb-method-cancel').addEventListener('click', () => { form.hidden = true; });
    form.addEventListener('submit', async (e) => {
      e.preventDefault();
      const btn = host.querySelector('#sb-method-submit');
      btn.disabled = true;
      const { error } = await supabaseClient.rpc('request_subscription', {
        p_plan: state.pickedPlan,
        p_method: form.querySelector('input[name="sb-method"]:checked').value,
        p_reference: form.querySelector('#sb-reference').value,
      });
      if (error) { btn.disabled = false; return flash(errText(error), true); }
      await reload('Solicitud enviada. Un administrador confirmará tu pago y se activará tu plan.');
    });

    host.querySelectorAll('[data-feature]').forEach((b) => b.addEventListener('click', async () => {
      const prop = d.props.find((x) => String(x.id) === String(b.dataset.feature));
      if (!confirm('¿Destacar "' + (prop ? prop.title : 'esta propiedad') + '"? Usará 1 de tus destacados de este periodo y dura 30 días.')) return;
      b.disabled = true;
      const { error } = await supabaseClient.rpc('feature_property', { p_property_id: b.dataset.feature, p_service: null });
      if (error) { await reload(errText(error), true); return; }
      await reload('Propiedad destacada.');
    }));

    host.querySelectorAll('[data-sb]').forEach((b) => b.addEventListener('click', async () => {
      if (b.dataset.sb === 'trial') {
        b.disabled = true;
        const { error } = await supabaseClient.rpc('start_free_trial');
        if (error) { await reload(errText(error), true); return; }
        await reload('Tu prueba gratuita de 7 días empezó.');
        return;
      }
      const cancel = b.dataset.sb === 'cancel';
      if (cancel && !confirm('¿No renovar tu plan? Lo conservas hasta el final del periodo pagado y no se cobra nada más.')) return;
      b.disabled = true;
      const { error } = await supabaseClient.rpc(cancel ? 'cancel_subscription' : 'resume_subscription');
      if (error) { await reload(errText(error), true); return; }
      await reload(cancel ? 'Listo: tu plan no se renovará.' : 'Plan reanudado.');
    }));

    host.querySelectorAll('[data-resolve]').forEach((b) => b.addEventListener('click', async () => {
      const approve = b.dataset.approve === '1';
      let note = null;
      if (!approve) { note = prompt('Motivo del rechazo (opcional):'); if (note === null) return; }
      b.disabled = true;
      const { error } = await supabaseClient.rpc('admin_resolve_subscription_request', { p_id: Number(b.dataset.resolve), p_approve: approve, p_note: note || null });
      if (error) { await reload(errText(error), true); return; }
      await reload(approve ? 'Pago confirmado y plan activado.' : 'Solicitud rechazada.');
    }));

    const grant = host.querySelector('#sb-grant-form');
    if (grant) grant.addEventListener('submit', async (e) => {
      e.preventDefault();
      const days = parseInt(grant.querySelector('#sb-grant-days').value, 10);
      const { error } = await supabaseClient.rpc('admin_grant_subscription', {
        p_user: grant.querySelector('#sb-grant-user').value,
        p_plan: grant.querySelector('#sb-grant-plan').value,
        p_days: isNaN(days) ? null : days,
      });
      if (error) return flash(errText(error), true);
      await reload('Plan aplicado.');
    });
  }

  async function reload(msg, isError) {
    await load();
    if (msg) flash(msg, isError);
  }

  // Los planes sin herramientas de agente (Propietario) no muestran el contrato de exclusividad ni las comisiones
  document.addEventListener('uno:subscription', (e) => {
    const s = e.detail;
    const hide = !!(s && !s.exempt && (s.status === 'active' || s.status === 'canceling') && s.plan && s.plan.agent_tools === false);
    document.querySelectorAll('.admin-tab[data-tab="contracts"], .admin-tab[data-tab="collections"]').forEach((t) => t.classList.toggle('hidden', hide));
  });

  document.addEventListener('click', (e) => {
    const tab = e.target.closest('.admin-tab[data-tab="subscription"]');
    if (!tab) return;
    // Respaldo por si admin.js no maneja pestañas nuevas: mostrar nuestro panel.
    document.querySelectorAll('.tab-panel').forEach((p) => p.classList.add('hidden'));
    const panel = document.getElementById('tab-panel-subscription');
    if (panel) panel.classList.remove('hidden');
    document.querySelectorAll('.admin-tab').forEach((t) => t.classList.toggle('is-active', t === tab));
    load();
  });
})();
