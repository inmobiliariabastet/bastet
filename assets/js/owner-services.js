/* Servicios del plan Propietario y bandeja del agente.
 *  · Pestaña "Mi gestión" (plan Propietario): resumen, directorio de agentes registrados, ofertas de colaboración (con su documento en PDF)
 *    y solicitudes a Maat Fima Legal (asesoramiento, trámites, saneamiento, impuestos…).
 *  · Pestaña "Ofertas recibidas" (planes con herramientas de agente, y administradores): aceptar o rechazar las ofertas de propietarios.
 *  · Pestaña "Asesoría legal" (administradores): atender las solicitudes de los propietarios.
 * Todas las reglas las aplica la base de datos (supabase/owner-services.sql); aquí solo se muestran y se envían los datos.
 * Los documentos son BORRADORES sujetos a validación legal (así lo dicen en el PDF). Autónomo: usa el cliente global `supabaseClient`. */
(function () {
  'use strict';

  const SCRIPT_V = (() => { try { return new URL(document.currentScript.src).searchParams.get('v') || ''; } catch (e) { return ''; } })();
  const asset = (p) => '../assets/' + p + (SCRIPT_V ? '?v=' + SCRIPT_V : '');
  const state = { uid: null, sub: null, busy: {}, colabTpl: null };

  const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const fdate = (d) => new Date(d).toLocaleDateString('es-BO', { day: '2-digit', month: 'short', year: 'numeric' });
  const plural = (n, one, many) => (n === 1 ? one : many);
  const errText = (e) => (e && e.message) || 'No se pudo completar la acción.';
  const OFFER_STATUS = { pending: 'Pendiente', accepted: 'Aceptada', rejected: 'Rechazada', canceled: 'Cancelada' };
  const OP_TEXT = { venta: 'Venta', alquiler: 'Alquiler', anticretico: 'Anticrético', temporal: 'Temporal' };
  const LEGAL_STATUS = { pending: 'Pendiente', in_review: 'En revisión', in_progress: 'En gestión', completed: 'Completada', cancelled: 'Cancelada' };
  const hasPlan = (s) => !!s && (s.status === 'active' || s.status === 'canceling');
  const priceText = (p) => {
    const digits = String((p && p.price) || '').replace(/[^0-9]/g, '');
    if (!digits) return '';
    const n = digits.replace(/\B(?=(\d{3})+(?!\d))/g, '.');
    return (p.currency === 'BOB' ? 'Bs ' + n : n + ' USD') + (p.operation === 'temporal' ? ' por día' : '');
  };

  /* ───────── Utilidades de interfaz ───────── */
  function flash(rootId, msg, isError) {
    const el = document.getElementById(rootId + '-flash');
    if (!el) return;
    el.textContent = msg;
    el.className = isError ? 'form-error' : 'auth-banner';
    el.hidden = false;
    clearTimeout(flash.t);
    flash.t = setTimeout(() => { el.hidden = true; }, 6000);
  }

  const closeOverlay = () => { const o = document.getElementById('os-overlay'); if (o) o.remove(); };
  function openOverlay(html) {
    closeOverlay();
    const o = document.createElement('div');
    o.className = 'modal-overlay'; o.id = 'os-overlay';
    o.innerHTML = '<div class="modal-panel os-modal" role="dialog" aria-modal="true">' + html + '</div>';
    document.body.appendChild(o);
    o.addEventListener('click', (e) => { if (e.target === o || e.target.closest('[data-os-close]')) closeOverlay(); });
    return o;
  }
  document.addEventListener('keydown', (e) => { if (e.key === 'Escape') closeOverlay(); });

  async function currentUser() {
    const { data } = await supabaseClient.auth.getUser();
    state.uid = data && data.user && data.user.id;
    return state.uid;
  }
  async function loadSub() {
    const { data, error } = await supabaseClient.rpc('my_subscription');
    state.sub = error ? null : data;
    return state.sub;
  }

  /* ───────── Documento de la oferta (PDF) ───────── */
  async function downloadOffer(offer, btn) {
    const P = window.ContractPdf, T = window.ContractTemplate;
    if (!P || !T) { flash('owner', 'No se pudo preparar el PDF (faltan las bibliotecas de contratos).', true); return; }
    const label = btn ? btn.textContent : '';
    if (btn) { btn.disabled = true; btn.innerHTML = '<span class="ct-spin"></span>'; }
    try {
      await P.ensureLibs(asset('js/contracts/contract-fonts.js'));
      const letterhead = await P.fetchDataUrl(asset('img/membrete-bastet.jpg'));
      if (!state.colabTpl) {
        const r = await fetch(asset('contracts/colaboracion-v1.md'));
        if (!r.ok) throw new Error('No se pudo cargar la plantilla del documento');
        state.colabTpl = await r.text();
      }
      const blocks = T.renderCollaborationBlocks(state.colabTpl, offer);
      const doc = P.build({
        blocks, number: offer.doc_number, code: null, agentName: (offer.owner_data && offer.owner_data.nombre) || 'Propietario', letterheadDataUrl: letterhead,
        issuedAt: offer.created_at, docTitle: 'OFERTA DE COLABORACIÓN', docSubject: 'Oferta de colaboración propietario-agente (borrador sujeto a validación legal)',
      });
      await P.download(doc, 'Oferta-Colaboracion-' + offer.doc_number + '-' + P.surnameForFile(offer.owner_data && offer.owner_data.nombre) + '.pdf');
    } catch (e) {
      flash(document.getElementById('owner-root') ? 'owner' : 'offers', 'No se pudo preparar el PDF: ' + errText(e), true);
    } finally { if (btn) { btn.disabled = false; btn.textContent = label || 'Descargar documento'; } }
  }

  /* ═════════ Pestaña "Mi gestión" (plan Propietario) ═════════ */
  const ownerRoot = () => document.getElementById('owner-root');

  async function loadOwner() {
    const host = ownerRoot();
    if (!host || state.busy.owner) return;
    state.busy.owner = true;
    try {
      if (!(await currentUser())) { host.innerHTML = '<p class="credits-empty">Inicia sesión para continuar.</p>'; return; }
      const sub = await loadSub();
      if (!hasPlan(sub) || sub.plan.code !== 'propietario') {
        host.innerHTML = '<div class="os-lock"><h2>Esta sección es del plan Propietario</h2><p class="credits-muted">Con el plan Propietario puedes ofrecer tus propiedades a agentes registrados, pedir asesoría y trámites a Maat Fima Legal y administrar todo desde aquí.</p><button type="button" class="btn btn-accent" data-os-go="subscription">Ver planes</button></div>';
        return;
      }
      const nowIso = new Date().toISOString();
      const [dirRes, offersRes, propsRes, typesRes, reqsRes] = await Promise.all([
        supabaseClient.rpc('list_agent_directory'),
        supabaseClient.from('owner_offers').select('*').eq('owner_id', state.uid).order('created_at', { ascending: false }).limit(100),
        supabaseClient.from('properties').select('id,title,code_number,status,expires_at,featured_until,owner_whatsapp').eq('owner_id', state.uid).eq('status', 'available').or('expires_at.is.null,expires_at.gt.' + nowIso).order('code_number'),
        supabaseClient.from('legal_service_types').select('*').eq('active', true).order('sort_order'),
        supabaseClient.from('legal_requests').select('*').eq('user_id', state.uid).order('created_at', { ascending: false }).limit(50),
      ]);
      const failed = [dirRes, offersRes, propsRes, typesRes, reqsRes].find((r) => r.error);
      if (failed) throw failed.error;
      renderOwner({ sub, agents: dirRes.data || [], offers: offersRes.data || [], props: propsRes.data || [], types: typesRes.data || [], reqs: reqsRes.data || [] });
    } catch (e) {
      host.innerHTML = '<p class="form-error">No se pudo cargar esta sección. ' + esc(errText(e)) + ' (¿ya se corrió supabase/owner-services.sql?)</p>';
    } finally { state.busy.owner = false; }
  }

  function summaryHtml(d) {
    const s = d.sub, pl = s.plan, u = s.usage;
    const pendingOffers = d.offers.filter((o) => o.status === 'pending').length;
    const acceptedOffers = d.offers.filter((o) => o.status === 'accepted').length;
    const openReqs = d.reqs.filter((r) => ['pending', 'in_review', 'in_progress'].includes(r.status)).length;
    const featuredNow = d.props.filter((p) => p.featured_until && new Date(p.featured_until) > new Date());
    const days = Math.max(Math.ceil((new Date(s.period_end).getTime() - Date.now()) / 86400000), 0);
    const card = (label, big, sub) => '<div class="os-stat"><span>' + label + '</span><b>' + big + '</b><small>' + sub + '</small></div>';
    return '<div class="os-summary">' +
      card('Propiedades activas', u.active_properties + ' / ' + pl.max_active_properties, u.active_properties >= pl.max_active_properties ? 'Cupo lleno' : (pl.max_active_properties - u.active_properties) + ' ' + plural(pl.max_active_properties - u.active_properties, 'cupo libre', 'cupos libres')) +
      card('Propiedad destacada', u.featured_used + ' / ' + pl.max_featured_per_period, featuredNow.length ? esc(featuredNow[0].title) + ' (hasta ' + fdate(featuredNow[0].featured_until) + ')' : 'Este periodo') +
      card('Ofertas a agentes', pendingOffers + ' pend.', acceptedOffers + ' ' + plural(acceptedOffers, 'aceptada', 'aceptadas')) +
      card('Solicitudes legales', openReqs + ' ' + plural(openReqs, 'abierta', 'abiertas'), 'Maat Fima Legal') +
      card('Tu plan', esc(pl.name), 'Vence en ' + days + ' ' + plural(days, 'día', 'días') + ' · <button type="button" class="ct-link" data-os-go="subscription">Suscripción</button>') +
      '</div>';
  }

  function agentCard(a) {
    const initial = (a.display_name || 'A').trim().charAt(0).toUpperCase();
    const soc = [['facebook', a.facebook_url, 'Facebook'], ['instagram', a.instagram_url, 'Instagram'], ['tiktok', a.tiktok_url, 'TikTok']]
      .filter((x) => x[1]).map((x) => '<a class="os-soc" href="' + esc(x[1]) + '" target="_blank" rel="noopener" aria-label="' + x[2] + '"><img src="../assets/img/social-' + x[0] + '.svg" alt="' + x[2] + '"></a>').join('');
    return '<article class="os-agent" data-name="' + esc((a.display_name || '').toLowerCase()) + '">' +
      (a.avatar_url ? '<img class="os-avatar" src="' + esc(a.avatar_url) + '" alt="" loading="lazy">' : '<span class="os-avatar os-avatar--initial">' + esc(initial) + '</span>') +
      '<div class="os-agent-info"><strong>' + esc(a.display_name) + '</strong><span class="credits-muted">Plan ' + esc(a.plan_name) + ' · ' + a.active_properties + ' ' + plural(a.active_properties, 'propiedad activa', 'propiedades activas') + '</span><span class="os-socs">' + soc + '</span></div>' +
      '<button type="button" class="btn btn-accent btn-sm" data-os-offer="' + esc(a.id) + '">Ofrecer una propiedad</button></article>';
  }

  function offersHtml(d) {
    return '<h2 class="admin-subheading">Mis ofertas a agentes</h2>' + (d.offers.length ? '<div class="property-list">' + d.offers.map((o) =>
      '<div class="property-row credits-prop"><div class="credits-prop-info"><strong>' + esc(o.property_data.title) + ' → ' + esc((o.agent_data && o.agent_data.nombre) || 'Agente') + '</strong>' +
      '<span class="credits-muted">' + esc(o.doc_number) + ' · ' + fdate(o.created_at) + ' · comisión ' + esc(o.terms.comision_porcentaje) + '% · ' + esc(o.terms.plazo_dias) + ' días · ' + (o.terms.exclusividad ? 'con exclusividad' : 'sin exclusividad') + '</span>' +
      '<span class="os-status os-status--' + esc(o.status) + '">' + (OFFER_STATUS[o.status] || esc(o.status)) + '</span>' +
      (o.response_note ? '<span class="credits-muted">Nota del agente: ' + esc(o.response_note) + '</span>' : '') + '</div>' +
      '<div class="credits-prop-actions"><button type="button" class="btn btn-ghost btn-sm" data-os-doc="' + esc(o.id) + '">Descargar documento</button>' +
      (o.status === 'pending' ? '<button type="button" class="btn btn-ghost btn-sm" data-os-cancel-offer="' + esc(o.id) + '">Cancelar</button>' : '') + '</div></div>').join('') + '</div>'
      : '<p class="credits-empty">Todavía no ofreciste ninguna propiedad a un agente. Elige uno del directorio de arriba.</p>') +
      '<p class="credits-muted os-fine">Los documentos son borradores generados por la plataforma: requieren validación legal y la firma de ambas partes antes de producir efectos entre ustedes. Bastet no es parte de la oferta.</p>';
  }

  function legalHtml(d) {
    const propOpts = '<option value="">Sin propiedad en particular</option>' + d.props.map((p) => '<option value="' + esc(p.id) + '">' + esc(p.title) + ' (BST-' + esc(p.code_number) + ')</option>').join('');
    return '<h2 class="admin-subheading">Asesoría y trámites con Maat Fima Legal</h2>' +
      '<p class="credits-muted">Maat Fima Legal respalda las operaciones de compra y venta de Bastet. Cuéntanos qué necesitas y el equipo se pondrá en contacto contigo por los canales de tu cuenta. Aquí verás el estado de cada solicitud.</p>' +
      '<form id="os-legal-form" class="invite-admin-card">' +
        '<div class="field"><label for="os-legal-service">Servicio</label><select id="os-legal-service" required>' + d.types.map((t) => '<option value="' + esc(t.code) + '">' + esc(t.name) + '</option>').join('') + '</select></div>' +
        '<div class="field"><label for="os-legal-prop">Propiedad relacionada (opcional)</label><select id="os-legal-prop">' + propOpts + '</select></div>' +
        '<div class="field"><label for="os-legal-desc">¿Qué necesitas?</label><textarea id="os-legal-desc" rows="4" minlength="10" maxlength="2000" required placeholder="Describe tu caso con el mayor detalle posible"></textarea></div>' +
        '<button type="submit" class="btn btn-accent" id="os-legal-submit">Enviar solicitud</button></form>' +
      (d.reqs.length ? '<div class="property-list">' + d.reqs.map((r) => {
        const t = d.types.find((x) => x.code === r.service_code);
        return '<div class="property-row credits-prop"><div class="credits-prop-info"><strong>' + esc(t ? t.name : r.service_code) + (r.property_title ? ' · ' + esc(r.property_title) : '') + '</strong>' +
          '<span class="credits-muted">' + fdate(r.created_at) + ' · ' + esc(r.description.length > 160 ? r.description.slice(0, 160) + '…' : r.description) + '</span>' +
          '<span class="os-status os-status--' + esc(r.status) + '">' + (LEGAL_STATUS[r.status] || esc(r.status)) + '</span>' +
          (r.admin_note ? '<span class="credits-muted">Respuesta del equipo: ' + esc(r.admin_note) + '</span>' : '') + '</div>' +
          '<div class="credits-prop-actions">' + (r.status === 'pending' ? '<button type="button" class="btn btn-ghost btn-sm" data-os-cancel-legal="' + r.id + '">Cancelar</button>' : '') + '</div></div>';
      }).join('') + '</div>' : '<p class="credits-empty">Todavía no hiciste ninguna solicitud.</p>');
  }

  function renderOwner(d) {
    ownerRoot().innerHTML = '<div id="owner-flash" hidden></div>' + summaryHtml(d) +
      '<h2 class="admin-subheading">Elegir un agente</h2>' +
      '<p class="credits-muted">Agentes registrados en Bastet con un plan vigente. Ofrece una de tus propiedades con tus condiciones: el agente puede aceptar o rechazar.</p>' +
      (d.agents.length ? '<div class="field os-search"><label for="os-agent-search">Buscar por nombre</label><input type="search" id="os-agent-search" placeholder="Ej. Ana"></div><div class="os-agents" id="os-agents">' + d.agents.map(agentCard).join('') + '</div><p class="credits-empty hidden" id="os-agents-empty">Ningún agente coincide con la búsqueda.</p>'
        : '<p class="credits-empty">Todavía no hay agentes con plan vigente para mostrar.</p>') +
      offersHtml(d) + legalHtml(d);
    bindOwner(d);
  }

  function offerForm(d, agent) {
    const p0 = d.props[0];
    const prof = d.sub;
    const o = openOverlay('<h2>Ofrecer una propiedad a ' + esc(agent.display_name) + '</h2>' +
      (d.props.length ? '<form id="os-offer-form">' +
        '<div class="field"><label for="os-of-prop">Propiedad</label><select id="os-of-prop" required>' + d.props.map((p) => '<option value="' + esc(p.id) + '" data-phone="' + esc(p.owner_whatsapp || '') + '">' + esc(p.title) + ' (BST-' + esc(p.code_number) + ')</option>').join('') + '</select></div>' +
        '<div class="os-grid2"><div class="field"><label for="os-of-com">Comisión (%)</label><input type="number" id="os-of-com" min="0.5" max="15" step="0.5" value="3" required></div>' +
        '<div class="field"><label for="os-of-plazo">Plazo (días)</label><input type="number" id="os-of-plazo" min="15" max="365" step="1" value="90" required></div></div>' +
        '<label class="checkbox-label"><input type="checkbox" id="os-of-exc" checked> Con exclusividad (no ofrecerás la propiedad a otros agentes durante el plazo)</label>' +
        '<p class="credits-muted os-fine">Tus datos para el documento:</p>' +
        '<div class="field"><label for="os-of-name">Nombre completo</label><input type="text" id="os-of-name" minlength="3" maxlength="120" required autocomplete="name"></div>' +
        '<div class="os-grid2"><div class="field"><label for="os-of-ci">C.I.</label><input type="text" id="os-of-ci" maxlength="20" required placeholder="Ej. 4567890 LP"></div>' +
        '<div class="field"><label for="os-of-phone">Teléfono / WhatsApp</label><input type="tel" id="os-of-phone" maxlength="30" required autocomplete="tel"></div></div>' +
        '<div class="field"><label for="os-of-msg">Mensaje para el agente (opcional)</label><textarea id="os-of-msg" rows="3" maxlength="500"></textarea></div>' +
        '<p class="credits-muted os-fine">Al enviar, el agente verá estos datos y los de la propiedad. El documento que se genera es un borrador sujeto a validación legal.</p>' +
        '<p id="os-of-error" class="form-error hidden"></p>' +
        '<div class="modal-form-actions"><button type="button" class="btn btn-ghost" data-os-close>Cancelar</button><button type="submit" class="btn btn-accent" id="os-of-submit">Enviar oferta</button></div></form>'
        : '<p class="credits-muted">No tienes propiedades activas para ofrecer. Publica una en la pestaña Propiedades.</p><div class="modal-form-actions"><button type="button" class="btn btn-ghost" data-os-close>Cerrar</button></div>'));
    if (!d.props.length) return;
    const form = o.querySelector('#os-offer-form');
    const phone = form.querySelector('#os-of-phone');
    const syncPhone = () => { const sel = form.querySelector('#os-of-prop'); const ph = sel.selectedOptions[0] && sel.selectedOptions[0].dataset.phone; if (ph && !phone.value) phone.value = ph; };
    syncPhone();
    form.querySelector('#os-of-prop').addEventListener('change', syncPhone);
    form.addEventListener('submit', async (e) => {
      e.preventDefault();
      const btn = form.querySelector('#os-of-submit'), err = form.querySelector('#os-of-error');
      err.classList.add('hidden'); btn.disabled = true; btn.textContent = 'Enviando…';
      const { error } = await supabaseClient.rpc('create_owner_offer', {
        p_property: form.querySelector('#os-of-prop').value, p_agent: agent.id,
        p_terms: {
          comision_porcentaje: Number(form.querySelector('#os-of-com').value), plazo_dias: Number(form.querySelector('#os-of-plazo').value),
          exclusividad: form.querySelector('#os-of-exc').checked, owner_nombre: form.querySelector('#os-of-name').value.trim(),
          owner_ci: form.querySelector('#os-of-ci').value.trim(), owner_telefono: phone.value.trim(), mensaje: form.querySelector('#os-of-msg').value.trim(),
        },
      });
      if (error) { err.textContent = errText(error); err.classList.remove('hidden'); btn.disabled = false; btn.textContent = 'Enviar oferta'; return; }
      closeOverlay();
      await loadOwner();
      flash('owner', 'Oferta enviada a ' + agent.display_name + '. Te avisará si la acepta; aquí verás su respuesta.', false);
    });
    return prof;
  }

  function bindOwner(d) {
    const host = ownerRoot();
    const search = host.querySelector('#os-agent-search');
    if (search) search.addEventListener('input', () => {
      const q = search.value.trim().toLowerCase();
      let shown = 0;
      host.querySelectorAll('.os-agent').forEach((el) => { const ok = !q || el.dataset.name.includes(q); el.classList.toggle('hidden', !ok); if (ok) shown++; });
      host.querySelector('#os-agents-empty').classList.toggle('hidden', shown > 0);
    });
    host.querySelectorAll('[data-os-offer]').forEach((b) => b.addEventListener('click', () => offerForm(d, d.agents.find((a) => a.id === b.dataset.osOffer))));
    host.querySelectorAll('[data-os-doc]').forEach((b) => b.addEventListener('click', () => downloadOffer(d.offers.find((o) => o.id === b.dataset.osDoc), b)));
    host.querySelectorAll('[data-os-cancel-offer]').forEach((b) => b.addEventListener('click', async () => {
      if (!confirm('¿Cancelar esta oferta? El agente ya no podrá aceptarla.')) return;
      b.disabled = true;
      const { error } = await supabaseClient.rpc('cancel_owner_offer', { p_id: b.dataset.osCancelOffer });
      await loadOwner(); flash('owner', error ? errText(error) : 'Oferta cancelada.', !!error);
    }));
    host.querySelectorAll('[data-os-cancel-legal]').forEach((b) => b.addEventListener('click', async () => {
      if (!confirm('¿Cancelar esta solicitud?')) return;
      b.disabled = true;
      const { error } = await supabaseClient.rpc('cancel_legal_request', { p_id: Number(b.dataset.osCancelLegal) });
      await loadOwner(); flash('owner', error ? errText(error) : 'Solicitud cancelada.', !!error);
    }));
    const form = host.querySelector('#os-legal-form');
    if (form) form.addEventListener('submit', async (e) => {
      e.preventDefault();
      const btn = form.querySelector('#os-legal-submit'); btn.disabled = true;
      const { error } = await supabaseClient.rpc('create_legal_request', {
        p_service: form.querySelector('#os-legal-service').value, p_property: form.querySelector('#os-legal-prop').value || null, p_description: form.querySelector('#os-legal-desc').value,
      });
      if (error) { btn.disabled = false; flash('owner', errText(error), true); return; }
      await loadOwner(); flash('owner', 'Solicitud enviada. El equipo de Maat Fima Legal la revisará y verás aquí el avance.', false);
    });
  }

  /* ═════════ Pestaña "Ofertas recibidas" (agentes) ═════════ */
  const offersRoot = () => document.getElementById('offers-root');

  async function loadOffers() {
    const host = offersRoot();
    if (!host || state.busy.offers) return;
    state.busy.offers = true;
    try {
      if (!(await currentUser())) { host.innerHTML = '<p class="credits-empty">Inicia sesión para continuar.</p>'; return; }
      const sub = await loadSub();
      const allowed = sub && (sub.exempt || (hasPlan(sub) && sub.plan.agent_tools));
      if (!allowed) { host.innerHTML = '<div class="os-lock"><h2>Las ofertas de propietarios llegan a los planes Agente y Empresa</h2><p class="credits-muted">Suscríbete para recibir ofertas de propietarios que buscan un agente.</p><button type="button" class="btn btn-accent" data-os-go="subscription">Ver planes</button></div>'; return; }
      let q = supabaseClient.from('owner_offers').select('*').order('created_at', { ascending: false }).limit(200);
      if (!sub.exempt) q = q.eq('agent_id', state.uid);
      const { data, error } = await q;
      if (error) throw error;
      renderOffers(data || [], !!sub.exempt);
    } catch (e) {
      host.innerHTML = '<p class="form-error">No se pudieron cargar las ofertas. ' + esc(errText(e)) + '</p>';
    } finally { state.busy.offers = false; }
  }

  function renderOffers(list, isAdmin) {
    const pending = list.filter((o) => o.status === 'pending').length;
    offersRoot().innerHTML = '<div id="offers-flash" hidden></div>' +
      '<p class="credits-muted">' + (isAdmin ? 'Todas las ofertas de propietarios (vista de administrador).' : 'Propietarios que te ofrecen una propiedad para comercializar. Acepta o rechaza cada oferta; al aceptar verás sus datos de contacto.') + ' ' + (pending ? '<b>' + pending + ' ' + plural(pending, 'pendiente', 'pendientes') + '.</b>' : '') + '</p>' +
      (list.length ? '<div class="property-list">' + list.map((o) => {
        const p = o.property_data, ow = o.owner_data, t = o.terms;
        const wa = String(ow.telefono || '').replace(/[^0-9]/g, '');
        return '<div class="property-row credits-prop os-offer"><div class="credits-prop-info"><strong>' + esc(p.title) + '</strong>' +
          '<span class="credits-muted">' + esc(o.doc_number) + ' · ' + fdate(o.created_at) + ' · ' + esc(OP_TEXT[p.operation] || '') + ' · ' + esc(p.location) + (priceText(p) ? ' · ' + priceText(p) : '') + '</span>' +
          '<span class="credits-muted">Propietario: <b>' + esc(ow.nombre) + '</b> · comisión ' + esc(t.comision_porcentaje) + '% · ' + esc(t.plazo_dias) + ' días · ' + (t.exclusividad ? 'con exclusividad' : 'sin exclusividad') + '</span>' +
          (t.mensaje ? '<span class="credits-muted">Mensaje: “' + esc(t.mensaje) + '”</span>' : '') +
          (o.status === 'accepted' || isAdmin ? '<span class="credits-muted">Contacto: ' + esc(ow.telefono) + (ow.email ? ' · ' + esc(ow.email) : '') + (wa ? ' · <a href="https://api.whatsapp.com/send?phone=' + wa + '" target="_blank" rel="noopener">WhatsApp</a>' : '') + '</span>' : '') +
          '<span class="os-status os-status--' + esc(o.status) + '">' + (OFFER_STATUS[o.status] || esc(o.status)) + '</span></div>' +
          '<div class="credits-prop-actions"><button type="button" class="btn btn-ghost btn-sm" data-os-doc="' + esc(o.id) + '">Descargar documento</button>' +
          (o.status === 'pending' && !isAdmin ? '<button type="button" class="btn btn-accent btn-sm" data-os-respond="' + esc(o.id) + '" data-accept="1">Aceptar</button><button type="button" class="btn btn-ghost btn-sm" data-os-respond="' + esc(o.id) + '" data-accept="0">Rechazar</button>' : '') + '</div></div>';
      }).join('') + '</div>' : '<p class="credits-empty">Todavía no recibiste ofertas de propietarios.</p>') +
      '<p class="credits-muted os-fine">Los documentos son borradores generados por la plataforma: requieren validación legal y la firma de ambas partes. Bastet no es parte de la oferta.</p>';
    const host = offersRoot();
    host.querySelectorAll('[data-os-doc]').forEach((b) => b.addEventListener('click', () => downloadOffer(list.find((o) => o.id === b.dataset.osDoc), b)));
    host.querySelectorAll('[data-os-respond]').forEach((b) => b.addEventListener('click', async () => {
      const accept = b.dataset.accept === '1';
      const note = prompt(accept ? 'Nota para el propietario (opcional):' : 'Motivo del rechazo (opcional):');
      if (note === null) return;
      b.disabled = true;
      const { error } = await supabaseClient.rpc('respond_owner_offer', { p_id: b.dataset.osRespond, p_accept: accept, p_note: note || null });
      await loadOffers(); flash('offers', error ? errText(error) : (accept ? 'Oferta aceptada. Ya puedes contactar al propietario.' : 'Oferta rechazada.'), !!error);
    }));
  }

  /* ═════════ Pestaña "Asesoría legal" (administradores) ═════════ */
  const legalRoot = () => document.getElementById('legal-root');

  async function loadLegal() {
    const host = legalRoot();
    if (!host || state.busy.legal) return;
    state.busy.legal = true;
    try {
      const [reqs, types, people] = await Promise.all([
        supabaseClient.from('legal_requests').select('*').order('created_at', { ascending: false }).limit(300),
        supabaseClient.from('legal_service_types').select('*'),
        supabaseClient.from('profiles').select('id,email,display_name'),
      ]);
      if (reqs.error) throw reqs.error;
      renderLegal(reqs.data || [], types.data || [], people.data || []);
    } catch (e) {
      host.innerHTML = '<p class="form-error">No se pudieron cargar las solicitudes. ' + esc(errText(e)) + '</p>';
    } finally { state.busy.legal = false; }
  }

  function renderLegal(list, types, people) {
    const name = (id) => { const u = people.find((x) => x.id === id); return u ? (u.display_name || u.email) : 'Usuario'; };
    const typeName = (c) => { const t = types.find((x) => x.code === c); return t ? t.name : c; };
    const open = list.filter((r) => ['pending', 'in_review', 'in_progress'].includes(r.status)).length;
    legalRoot().innerHTML = '<div id="legal-flash" hidden></div><p class="credits-muted">Solicitudes de los propietarios a Maat Fima Legal. <b>' + open + '</b> ' + plural(open, 'abierta', 'abiertas') + '. Cambia el estado y deja una respuesta: el propietario la ve en su panel. Una solicitud cerrada no se reabre.</p>' +
      (list.length ? '<div class="property-list">' + list.map((r) => {
        const closed = ['completed', 'cancelled'].includes(r.status);
        return '<div class="property-row credits-prop os-legal"><div class="credits-prop-info"><strong>' + esc(typeName(r.service_code)) + ' · ' + esc(name(r.user_id)) + '</strong>' +
          '<span class="credits-muted">' + fdate(r.created_at) + (r.property_title ? ' · ' + esc(r.property_title) : '') + '</span>' +
          '<span class="os-desc">' + esc(r.description) + '</span>' +
          '<span class="os-status os-status--' + esc(r.status) + '">' + (LEGAL_STATUS[r.status] || esc(r.status)) + '</span>' +
          (r.admin_note ? '<span class="credits-muted">Respuesta: ' + esc(r.admin_note) + '</span>' : '') + '</div>' +
          (closed ? '' : '<div class="credits-prop-actions os-legal-actions"><select data-os-lstatus="' + r.id + '">' + ['pending', 'in_review', 'in_progress', 'completed', 'cancelled'].map((s) => '<option value="' + s + '"' + (s === r.status ? ' selected' : '') + '>' + LEGAL_STATUS[s] + '</option>').join('') + '</select>' +
            '<input type="text" data-os-lnote="' + r.id + '" maxlength="1000" placeholder="Respuesta para el propietario (opcional)"><button type="button" class="btn btn-accent btn-sm" data-os-lsave="' + r.id + '">Guardar</button></div>') + '</div>';
      }).join('') + '</div>' : '<p class="credits-empty">Todavía no hay solicitudes.</p>');
    legalRoot().querySelectorAll('[data-os-lsave]').forEach((b) => b.addEventListener('click', async () => {
      const id = b.dataset.osLsave;
      b.disabled = true;
      const { error } = await supabaseClient.rpc('admin_update_legal_request', {
        p_id: Number(id), p_status: legalRoot().querySelector('[data-os-lstatus="' + id + '"]').value, p_note: legalRoot().querySelector('[data-os-lnote="' + id + '"]').value || null,
      });
      await loadLegal(); flash('legal', error ? errText(error) : 'Solicitud actualizada.', !!error);
    }));
  }

  /* ═════════ Navegación y visibilidad por plan ═════════ */
  document.addEventListener('click', (e) => {
    const go = e.target.closest('[data-os-go]');
    if (go) { const tab = document.querySelector('.admin-tab[data-tab="' + go.dataset.osGo + '"]'); if (tab) tab.click(); return; }
    const tab = e.target.closest('.admin-tab[data-tab="owner"], .admin-tab[data-tab="offers"], .admin-tab[data-tab="legal"]');
    if (!tab) return;
    setTimeout(() => { ({ owner: loadOwner, offers: loadOffers, legal: loadLegal })[tab.dataset.tab](); }, 0);
  });

  // "Mi gestión" solo para el plan Propietario; "Ofertas recibidas" para los planes con herramientas de agente y para el administrador
  document.addEventListener('uno:subscription', (e) => {
    const s = e.detail;
    const owner = hasPlan(s) && s.plan && s.plan.code === 'propietario';
    const agent = !!s && (s.exempt || (hasPlan(s) && s.plan && s.plan.agent_tools));
    document.querySelectorAll('.admin-tab[data-tab="owner"]').forEach((t) => t.classList.toggle('hidden', !owner));
    document.querySelectorAll('.admin-tab[data-tab="offers"]').forEach((t) => t.classList.toggle('hidden', !agent));
    // La barra inferior del celular sigue a las pestañas: "Mi gestión" solo con plan Propietario; "Contratos" solo si la pestaña está visible
    const bar = document.getElementById('admin-bottombar');
    if (bar) {
      const side = document.getElementById('admin-side');
      bar.querySelectorAll('.abb-item[data-go]').forEach((b) => {
        const tab = side && side.querySelector('.admin-tab[data-tab="' + b.dataset.go + '"]');
        if (b.dataset.go === 'owner') b.classList.toggle('hidden', !owner);
        else if (b.dataset.go === 'contracts') b.classList.toggle('hidden', !!tab && tab.classList.contains('hidden'));
      });
    }
  });
})();
