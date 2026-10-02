/* Pestaña "Clientes interesados": tablero por etapas con los contactos que dejan los visitantes en el landing.
   Autónomo (como credits.js): usa el cliente global `supabaseClient`; admin.js ya muestra/oculta el panel por data-tab.
   Privacidad: el tablero NO descarga el WhatsApp ni el mensaje; solo se piden al abrir el detalle de un cliente.
   RLS en Supabase garantiza que cada agente solo reciba sus leads (el admin recibe todos). */
(function () {
  'use strict';

  const STAGES = [
    { key: 'new', label: 'Nuevos' },
    { key: 'contacted', label: 'Contactados' },
    { key: 'visit', label: 'Visita agendada' },
    { key: 'closed', label: 'Cierre' },
    { key: 'lost', label: 'Perdidos' },
  ];
  const board = () => document.getElementById('leads-board');
  const modal = document.getElementById('lead-modal');
  const modalPanel = document.getElementById('lead-modal-panel');
  const state = { leads: [], isAdmin: false, busy: false };

  const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const fdate = (d) => new Date(d).toLocaleDateString('es-BO', { day: '2-digit', month: 'short', year: 'numeric' });
  const code = (p) => (p && p.code_number ? 'BST-' + p.code_number : 'Propiedad');

  function setCount(n) {
    const el = document.getElementById('leads-count');
    if (!el) return;
    el.textContent = n > 99 ? '99+' : String(n);
    el.classList.toggle('hidden', !n);
  }

  async function refreshCount() {
    const { count, error } = await supabaseClient.from('property_leads').select('id', { count: 'exact', head: true }).eq('status', 'new');
    if (!error) setCount(count || 0);
  }

  async function load() {
    const host = board();
    if (!host || state.busy) return;
    state.busy = true;
    try {
      const { data: auth } = await supabaseClient.auth.getUser();
      const uid = auth && auth.user && auth.user.id;
      if (!uid) { host.innerHTML = '<p class="property-empty">Inicia sesión para ver tus clientes.</p>'; return; }
      const me = await supabaseClient.from('profiles').select('role').eq('id', uid).single();
      state.isAdmin = !!(me.data && me.data.role === 'admin');
      document.getElementById('leads-hint').textContent = state.isAdmin
        ? 'Personas que pidieron que las contacten desde la ficha de una propiedad (todos los agentes). Toca un cliente para ver su WhatsApp.'
        : 'Personas interesadas en tus propiedades. Toca un cliente para ver su WhatsApp y darle seguimiento.';

      const { data, error } = await supabaseClient
        .from('property_leads')
        .select('id,status,created_at,agent_id,property_id,full_name,properties(title,code_number)')
        .order('created_at', { ascending: false })
        .limit(500);
      if (error) throw error;
      state.leads = data || [];
      render();
      setCount(state.leads.filter((l) => l.status === 'new').length);
    } catch (e) {
      host.innerHTML = '<p class="form-error">No se pudieron cargar los clientes interesados. ' + esc((e && e.message) || '') + '</p>';
    } finally {
      state.busy = false;
    }
  }

  function render() {
    const host = board();
    if (!state.leads.length) {
      host.innerHTML = '<p class="property-empty">Todavía no hay clientes interesados. Aparecerán aquí cuando alguien use "Quiero que me contacten" en una de tus propiedades.</p>';
      return;
    }
    host.innerHTML = STAGES.map((st) => {
      const list = state.leads.filter((l) => l.status === st.key);
      return '<section class="lead-col lead-col--' + st.key + '"><h2 class="lead-col-title">' + st.label + '<span>' + list.length + '</span></h2>' +
        (list.map((l) =>
          '<button type="button" class="lead-card" data-lead="' + l.id + '">' +
            '<b>' + esc(l.full_name) + '</b>' +
            '<small>' + esc(code(l.properties)) + (l.properties && l.properties.title ? ' · ' + esc(l.properties.title) : '') + '</small>' +
            '<small class="lead-card-date">' + fdate(l.created_at) + '</small>' +
          '</button>').join('') || '<p class="lead-col-empty">—</p>') +
        '</section>';
    }).join('');
  }

  function waLink(lead) {
    const digits = String(lead.whatsapp || '').replace(/[^0-9]/g, '');
    const first = String(lead.full_name || '').trim().split(/\s+/)[0];
    const p = lead.properties || {};
    const text = 'Hola ' + first + ', te escribo de UNO · Bastet por tu interés en la propiedad ' + code(p) +
      (p.title ? ' (' + p.title + ')' : '') + '. ¿Cómo puedo ayudarte?';
    return 'https://wa.me/' + digits + '?text=' + encodeURIComponent(text);
  }

  async function openLead(id) {
    modalPanel.innerHTML = '<p class="credits-muted">Cargando…</p>';
    modal.classList.remove('hidden');
    const { data: lead, error } = await supabaseClient
      .from('property_leads')
      .select('id,status,created_at,agent_id,full_name,whatsapp,message,agent_notes,properties(title,code_number)')
      .eq('id', id).single();
    if (error || !lead) {
      modalPanel.innerHTML = '<p class="form-error">No se pudo abrir este cliente.</p><div class="modal-form-actions"><button type="button" class="btn btn-ghost" data-lead-close>Cerrar</button></div>';
      return;
    }

    let agentLine = '';
    if (state.isAdmin) {
      let label = 'Sin agente asignado';
      if (lead.agent_id) {
        const a = await supabaseClient.from('profiles').select('display_name,email').eq('id', lead.agent_id).maybeSingle();
        label = (a.data && (a.data.display_name || a.data.email)) || 'Agente';
      }
      agentLine = '<div><p class="detail-label">Agente</p><p class="detail-value">' + esc(label) + '</p></div>';
    }
    const p = lead.properties || {};
    modalPanel.innerHTML =
      '<div class="detail-header"><h2>' + esc(lead.full_name) + '</h2><button type="button" class="btn btn-ghost btn-sm" data-lead-close>Cerrar</button></div>' +
      '<div class="detail-grid">' +
        '<div><p class="detail-label">WhatsApp</p><p class="detail-value">' + esc(lead.whatsapp) + '</p></div>' +
        '<div><p class="detail-label">Propiedad</p><p class="detail-value">' + esc(code(p)) + (p.title ? ' · ' + esc(p.title) : '') + '</p></div>' +
        '<div><p class="detail-label">Fecha</p><p class="detail-value">' + fdate(lead.created_at) + '</p></div>' +
        agentLine +
      '</div>' +
      '<p class="detail-label">Mensaje</p>' +
      '<p class="detail-desc">' + (lead.message ? esc(lead.message) : 'No dejó mensaje.') + '</p>' +
      '<div class="detail-contact" style="margin-bottom:22px;">' +
        '<a class="btn btn-accent btn-sm" target="_blank" rel="noopener" href="' + esc(waLink(lead)) + '">Abrir WhatsApp</a>' +
        '<button type="button" class="btn btn-ghost btn-sm" data-lead-copy>Copiar número</button>' +
      '</div>' +
      '<div class="field"><label for="lead-stage">Etapa</label><select id="lead-stage">' +
        STAGES.map((s) => '<option value="' + s.key + '"' + (s.key === lead.status ? ' selected' : '') + '>' + s.label + '</option>').join('') +
      '</select></div>' +
      '<div class="field"><label for="lead-notes">Notas del agente</label><textarea id="lead-notes" rows="4" maxlength="2000" placeholder="Ej: Le interesa financiamiento, llamar el viernes">' + esc(lead.agent_notes || '') + '</textarea></div>' +
      '<p id="lead-feedback" class="form-error hidden"></p>' +
      '<div class="modal-form-actions"><button type="button" class="btn btn-ghost" data-lead-close>Cancelar</button><button type="button" class="btn btn-accent" id="lead-save">Guardar</button></div>';

    modalPanel.querySelector('[data-lead-copy]').addEventListener('click', async (e) => {
      const btn = e.currentTarget;
      try { await navigator.clipboard.writeText(lead.whatsapp); }
      catch (err) {
        const ta = document.createElement('textarea');
        ta.value = lead.whatsapp;
        document.body.appendChild(ta);
        ta.select();
        try { document.execCommand('copy'); } catch (e2) { /* sin portapapeles */ }
        ta.remove();
      }
      btn.textContent = '¡Copiado!';
      setTimeout(() => { btn.textContent = 'Copiar número'; }, 1800);
    });
    modalPanel.querySelector('#lead-save').addEventListener('click', async (e) => {
      const btn = e.currentTarget;
      const fb = modalPanel.querySelector('#lead-feedback');
      btn.disabled = true;
      fb.classList.add('hidden');
      const { error: upErr } = await supabaseClient.from('property_leads')
        .update({ status: modalPanel.querySelector('#lead-stage').value, agent_notes: modalPanel.querySelector('#lead-notes').value.trim() || null })
        .eq('id', lead.id);
      if (upErr) {
        btn.disabled = false;
        fb.textContent = 'No se pudo guardar: ' + upErr.message;
        fb.classList.remove('hidden');
        return;
      }
      closeModal();
      await load();
    });
  }

  function closeModal() { modal.classList.add('hidden'); modalPanel.innerHTML = ''; }

  document.addEventListener('click', (e) => {
    const card = e.target.closest('.lead-card');
    if (card) { openLead(Number(card.dataset.lead)); return; }
    if (e.target.closest('[data-lead-close]') || e.target === modal) { closeModal(); return; }
    if (e.target.closest('.admin-tab[data-tab="leads"]')) load();
  });
  document.addEventListener('keydown', (e) => { if (e.key === 'Escape' && !modal.classList.contains('hidden')) closeModal(); });

  // El contador "Nuevos" del menú se carga apenas hay sesión.
  supabaseClient.auth.onAuthStateChange((event, session) => { if (session && session.user) setTimeout(refreshCount, 0); });
})();
