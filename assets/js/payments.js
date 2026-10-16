/* Sección «Pagos» del panel de administración: pagos de suscripción por confirmar (con el comprobante que subió la persona),
 * confirmar o rechazar, y los últimos pagos resueltos. Las reglas las aplica la base de datos (admin_resolve_subscription_request);
 * aquí solo se muestra. Los comprobantes están en una carpeta privada: se abren con enlaces firmados de 10 minutos. */
(function () {
  'use strict';

  const root = () => document.getElementById('payments-root');
  const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const bs = (n) => 'Bs ' + Number(n).toLocaleString('es-BO', { minimumFractionDigits: 0, maximumFractionDigits: 2 });
  const fdate = (d) => new Date(d).toLocaleDateString('es-BO', { day: '2-digit', month: 'short', year: 'numeric' });
  const METHOD = { transferencia: 'Transferencia', qr: 'QR', efectivo: 'Efectivo' };
  const PLAN = { propietario: 'Propietario', agente: 'Agente', empresa: 'Empresa' };
  const STATUS = { approved: 'Confirmado', rejected: 'Rechazado', pending: 'Pendiente' };
  const isImage = (p) => /\.(png|jpe?g|webp)$/i.test(p || '');
  let busy = false;

  function flash(msg, isError) {
    const el = document.getElementById('payments-flash');
    if (!el) return;
    el.textContent = msg;
    el.className = isError ? 'form-error' : 'auth-banner';
    el.hidden = false;
    clearTimeout(flash.t);
    flash.t = setTimeout(() => { el.hidden = true; }, 6000);
  }

  async function signedUrl(path) {
    const { data, error } = await supabaseClient.storage.from('payment-proofs').createSignedUrl(path, 600);
    if (error || !data) return null;
    return data.signedUrl;
  }

  function setCount(n) {
    const el = document.getElementById('payments-count');
    if (!el) return;
    el.textContent = n > 0 ? String(n) : '';
    el.classList.toggle('hidden', !(n > 0));
  }

  async function refreshCount() {
    try {
      const { count, error } = await supabaseClient.from('subscription_requests').select('id', { count: 'exact', head: true }).eq('status', 'pending');
      if (!error) setCount(count || 0);
    } catch (e) { /* sin el SQL de suscripciones el contador no se muestra */ }
  }

  function card(r, who, urls) {
    const w = who[r.user_id] || {};
    const name = w.full_name || w.display_name || w.email || 'Usuario';
    const digits = String(w.whatsapp || '').replace(/[^0-9]/g, '');
    const wa = digits ? 'https://wa.me/' + (digits.length === 8 ? '591' + digits : digits) : null;
    const url = urls[r.id];
    let proof;
    if (!r.proof_path) proof = '<p class="pay-noproof">Sin comprobante adjunto' + (r.method === 'efectivo' ? ' (pago en efectivo)' : '') + '.</p>';
    else if (!url) proof = '<p class="pay-noproof">No se pudo abrir el comprobante.</p>';
    else if (isImage(r.proof_path)) proof = '<a class="pay-proof" href="' + esc(url) + '" target="_blank" rel="noopener"><img src="' + esc(url) + '" alt="Comprobante de pago de ' + esc(name) + '"><span>Abrir comprobante</span></a>';
    else proof = '<a class="btn btn-ghost btn-sm" href="' + esc(url) + '" target="_blank" rel="noopener">Ver comprobante (PDF)</a>';
    return '<article class="pay-card">' +
      '<div class="pay-main">' +
        '<h3>' + esc(name) + '</h3>' +
        '<p class="credits-muted">' + esc(w.email || '') + (wa ? ' · <a href="' + esc(wa) + '" target="_blank" rel="noopener">WhatsApp ' + esc(w.whatsapp) + '</a>' : '') + '</p>' +
        '<p class="pay-line"><b>' + esc(PLAN[r.plan_code] || r.plan_code) + '</b> · ' + bs(r.price_bs) + ' · ' + (METHOD[r.method] || esc(r.method)) + (r.reference ? ' · ref. ' + esc(r.reference) : '') + ' · ' + fdate(r.created_at) + '</p>' +
        '<div class="pay-actions"><button type="button" class="btn btn-accent btn-sm" data-pay="' + r.id + '" data-approve="1">Confirmar pago</button><button type="button" class="btn btn-ghost btn-sm" data-pay="' + r.id + '" data-approve="0">Rechazar</button></div>' +
      '</div><div class="pay-proofbox">' + proof + '</div></article>';
  }

  async function load() {
    const host = root();
    if (!host || busy) return;
    busy = true;
    try {
      const [pend, done] = await Promise.all([
        supabaseClient.from('subscription_requests').select('*').eq('status', 'pending').order('created_at'),
        supabaseClient.from('subscription_requests').select('*').neq('status', 'pending').order('resolved_at', { ascending: false }).limit(20),
      ]);
      if (pend.error) throw pend.error;
      const rows = (pend.data || []).concat(done.data || []);
      const ids = [...new Set(rows.map((r) => r.user_id))];
      const who = {};
      if (ids.length) {
        const { data } = await supabaseClient.from('profiles').select('id,email,display_name,full_name,whatsapp').in('id', ids);
        (data || []).forEach((p) => { who[p.id] = p; });
      }
      const urls = {};
      await Promise.all((pend.data || []).filter((r) => r.proof_path).map(async (r) => { urls[r.id] = await signedUrl(r.proof_path); }));
      setCount((pend.data || []).length);
      const finished = done.data || [];
      host.innerHTML = '<div id="payments-flash" hidden></div>' +
        '<h2 class="admin-subheading">Por confirmar</h2>' +
        ((pend.data || []).length ? '<div class="pay-list">' + pend.data.map((r) => card(r, who, urls)).join('') + '</div>' : '<p class="credits-empty">No hay pagos pendientes.</p>') +
        '<h2 class="admin-subheading">Resueltos recientemente</h2>' +
        (finished.length ? '<div class="credits-table-wrap"><table class="credits-table"><thead><tr><th>Fecha</th><th>Persona</th><th>Plan</th><th>Monto</th><th>Estado</th><th>Comprobante</th></tr></thead><tbody>' +
          finished.map((r) => {
            const w = who[r.user_id] || {};
            return '<tr><td>' + fdate(r.resolved_at || r.created_at) + '</td><td>' + esc(w.full_name || w.display_name || w.email || 'Usuario') + '</td><td>' + esc(PLAN[r.plan_code] || r.plan_code) + '</td><td>' + bs(r.price_bs) + '</td><td>' + (STATUS[r.status] || esc(r.status)) + (r.note ? ' · ' + esc(r.note) : '') + '</td><td>' + (r.proof_path ? '<button type="button" class="ct-link" data-proof="' + esc(r.proof_path) + '">Ver</button>' : '—') + '</td></tr>';
          }).join('') + '</tbody></table></div>' : '<p class="credits-empty">Todavía no hay pagos resueltos.</p>');
      bind(host);
    } catch (e) {
      host.innerHTML = '<p class="form-error">No se pudieron cargar los pagos. ' + esc((e && e.message) || '') + '</p>';
    } finally {
      busy = false;
    }
  }

  function bind(host) {
    host.querySelectorAll('[data-pay]').forEach((b) => b.addEventListener('click', async () => {
      const approve = b.dataset.approve === '1';
      let note = null;
      if (approve) { if (!confirm('¿Confirmar este pago y activar el plan por 30 días?')) return; }
      else { note = prompt('Motivo del rechazo (opcional):'); if (note === null) return; }
      b.disabled = true;
      const { error } = await supabaseClient.rpc('admin_resolve_subscription_request', { p_id: Number(b.dataset.pay), p_approve: approve, p_note: note || null });
      await load();
      flash(error ? ((error && error.message) || 'No se pudo resolver el pago.') : (approve ? 'Pago confirmado y plan activado.' : 'Solicitud rechazada.'), !!error);
    }));
    host.querySelectorAll('[data-proof]').forEach((b) => b.addEventListener('click', async () => {
      const url = await signedUrl(b.dataset.proof);
      if (url) window.open(url, '_blank', 'noopener'); else flash('No se pudo abrir el comprobante.', true);
    }));
  }

  // Contador en el menú: solo para administradores (un usuario común no puede listar las solicitudes de otros)
  document.addEventListener('uno:subscription', (e) => { if (e.detail && e.detail.exempt === true) refreshCount(); });
  document.addEventListener('click', (e) => { if (e.target.closest('.admin-tab[data-tab="payments"]')) load(); });
  window.UnoPayments = { reload: load };
})();
