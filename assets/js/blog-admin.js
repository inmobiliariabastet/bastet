/* Panel «Blog» (solo administración): escribir, editar, publicar y borrar entradas, y subir fotos.
 * Datos: tabla blog_posts y bucket público blog-images (SQL: supabase/blog.sql). El texto se escribe en Markdown sencillo
 * (## título, **negrita**, listas, enlaces, fotos) con barra de botones y vista previa. La página pública (/blog/) se genera con
 * tools/gen_property_pages.py: sola cada día a las 5:00 (Bolivia) o al instante con «Run workflow» en GitHub → Actions. */
(function () {
  'use strict';
  const root = () => document.getElementById('blog-root');
  const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const BUCKET = 'blog-images';
  const CATS = { 'compra-segura': 'Compra segura', anticretico: 'Anticrético', verificacion: 'Verificación de títulos', general: 'General' };
  const ACTIONS_URL = 'https://github.com/inmobiliariabastet/bastet/actions/workflows/inmuebles.yml';
  let posts = [], editing = null, busy = false;

  function css() {
    if (document.getElementById('blog-admin-style')) return;
    const s = document.createElement('style');
    s.id = 'blog-admin-style';
    s.textContent =
      '.bg-row{display:flex;gap:10px;flex-wrap:wrap;align-items:center}.bg-grid{display:grid;gap:14px;grid-template-columns:1fr 1fr}@media(max-width:760px){.bg-grid{grid-template-columns:1fr}}' +
      '.bg-field{display:flex;flex-direction:column;gap:5px;margin-bottom:14px}.bg-field>span{font-weight:600;font-size:14px}.bg-field small{color:#6b7570;font-size:12.5px}' +
      '.bg-field input,.bg-field select,.bg-field textarea{font:inherit;padding:10px 12px;border:1px solid rgba(30,38,41,.22);border-radius:10px;background:#fff;color:#1E2629;width:100%}' +
      '.bg-field textarea{line-height:1.55;min-height:120px;resize:vertical}#bg-body{min-height:380px;font-family:ui-monospace,Menlo,Consolas,monospace;font-size:14px}' +
      '.bg-tools{display:flex;gap:6px;flex-wrap:wrap;margin-bottom:6px}.bg-tools button{min-height:36px;padding:0 12px;border:1px solid rgba(30,38,41,.22);border-radius:8px;background:#fff;cursor:pointer;font:inherit;font-size:14px}' +
      '.bg-tools button:hover{background:#EFF8E7}.bg-count{font-size:12.5px;color:#6b7570}.bg-count.ok{color:#2f7a35}.bg-count.bad{color:#b3261e}' +
      '.bg-preview{border:1px dashed rgba(30,38,41,.3);border-radius:12px;padding:16px 20px;background:#fff;line-height:1.7}.bg-preview h2{font-size:22px;margin:22px 0 8px}.bg-preview h3{font-size:18px;margin:16px 0 6px}' +
      '.bg-preview img{max-width:100%;border-radius:10px}.bg-preview table{border-collapse:collapse}.bg-preview td,.bg-preview th{border:1px solid #ccc;padding:6px 10px}.bg-preview blockquote{border-left:4px solid #F1BF46;margin:12px 0;padding:6px 14px;background:#FFFBEF}' +
      '.bg-cover{max-width:340px;border-radius:12px;border:1px solid rgba(30,38,41,.15);display:block;margin-top:8px}' +
      '.bg-badge{display:inline-block;padding:2px 10px;border-radius:999px;font-size:12.5px;background:#EEE6E0}.bg-badge.pub{background:#EFF8E7;color:#2f7a35}' +
      '.bg-note{background:#FBE6AB;border-radius:12px;padding:12px 16px;margin:0 0 16px;font-size:14.5px}';
    document.head.appendChild(s);
  }

  function toast(msg, bad) {
    let el = document.getElementById('bg-toast');
    if (!el) { el = document.createElement('div'); el.id = 'bg-toast'; el.setAttribute('role', 'status'); el.style.cssText = 'position:fixed;left:50%;bottom:24px;transform:translateX(-50%);z-index:99999;padding:12px 18px;border-radius:12px;color:#fff;font-size:15px;max-width:90vw;box-shadow:0 10px 30px rgba(0,0,0,.25)'; document.body.appendChild(el); }
    el.style.background = bad ? '#b3261e' : '#3D4C3A'; el.textContent = msg; el.style.display = 'block';
    clearTimeout(toast.t); toast.t = setTimeout(() => { el.style.display = 'none'; }, 5200);
  }

  function slugify(s) {
    return String(s || '').normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 100);
  }

  /* ───────── Markdown sencillo → HTML (vista previa; el sitio usa el mismo subconjunto en tools/blog_md.py) ───────── */
  function safeUrl(u) {
    u = String(u || '').trim();
    if (u.indexOf('//') === 0) return '#';
    return /^(https?:\/\/|mailto:|\/|#)[^\s]*$/.test(u) || /^[A-Za-z0-9_.\/-][^\s:]*$/.test(u) ? u : '#';
  }
  function inline(s) {
    s = esc(s);
    s = s.replace(/`([^`]+)`/g, '<code>$1</code>');
    s = s.replace(/!\[([^\]]*)\]\(([^)\s]+)\)/g, (m, alt, url) => '<img src="' + esc(safeUrl(url.replace(/&amp;/g, '&'))) + '" alt="' + alt + '">');
    s = s.replace(/\[([^\]]+)\]\(([^)\s]+)\)/g, (m, t, url) => '<a href="' + esc(safeUrl(url.replace(/&amp;/g, '&'))) + '">' + t + '</a>');
    s = s.replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>');
    s = s.replace(/(^|[^*\w])\*([^*\n]+)\*(?![*\w])/g, '$1<em>$2</em>');
    return s;
  }
  function render(md) {
    const L = String(md || '').replace(/\r\n/g, '\n').split('\n'), out = [];
    let i = 0;
    const isList = (t) => /^\s*([-*]|\d+\.)\s+/.test(t);
    while (i < L.length) {
      const ln = L[i];
      if (!ln.trim()) { i++; continue; }
      let m = ln.match(/^(#{2,4})\s+(.+)$/);
      if (m) { out.push('<h' + m[1].length + '>' + inline(m[2].trim()) + '</h' + m[1].length + '>'); i++; continue; }
      if (/^-{3,}\s*$/.test(ln)) { out.push('<hr>'); i++; continue; }
      if (ln.charAt(0) === '>') { const b = []; while (i < L.length && L[i].charAt(0) === '>') { b.push(L[i].replace(/^>\s?/, '')); i++; } out.push('<blockquote>' + inline(b.join(' ')) + '</blockquote>'); continue; }
      if (ln.trim().charAt(0) === '|' && i + 1 < L.length && /^\s*\|?\s*:?-{2,}/.test(L[i + 1])) {
        const rows = []; while (i < L.length && L[i].trim().charAt(0) === '|') { rows.push(L[i].trim().replace(/^\||\|$/g, '').split('|').map((c) => c.trim())); i++; }
        out.push('<table><thead><tr>' + rows[0].map((c) => '<th>' + inline(c) + '</th>').join('') + '</tr></thead><tbody>' + rows.slice(2).map((r) => '<tr>' + r.map((c) => '<td>' + inline(c) + '</td>').join('') + '</tr>').join('') + '</tbody></table>');
        continue;
      }
      if (isList(ln)) { const ord = /^\s*\d+\./.test(ln), it = []; while (i < L.length && isList(L[i])) { it.push(L[i].replace(/^\s*([-*]|\d+\.)\s+/, '')); i++; } out.push('<' + (ord ? 'ol' : 'ul') + '>' + it.map((x) => '<li>' + inline(x) + '</li>').join('') + '</' + (ord ? 'ol' : 'ul') + '>'); continue; }
      const b = [];
      while (i < L.length && L[i].trim() && !/^(#{2,4}\s|>|-{3,}\s*$|\s*\|)/.test(L[i]) && !isList(L[i])) { b.push(L[i].trim()); i++; }
      if (!b.length) { b.push(ln.trim()); i++; }
      out.push('<p>' + inline(b.join(' ')) + '</p>');
    }
    return out.join('\n');
  }

  /* ───────── Fotos: se reducen a 1600 px y se pasan a WebP antes de subir ───────── */
  function prepareImage(file) {
    return new Promise((resolve) => {
      if (!/^image\/(jpeg|png|webp)$/.test(file.type)) return resolve({ error: 'Usa una foto JPG, PNG o WebP.' });
      if (file.size > 12 * 1024 * 1024) return resolve({ error: 'La foto pesa más de 12 MB.' });
      const img = new Image(), url = URL.createObjectURL(file);
      img.onload = () => {
        const max = 1600, k = Math.min(1, max / Math.max(img.naturalWidth, img.naturalHeight));
        const c = document.createElement('canvas'); c.width = Math.round(img.naturalWidth * k); c.height = Math.round(img.naturalHeight * k);
        c.getContext('2d').drawImage(img, 0, 0, c.width, c.height);
        c.toBlob((blob) => { URL.revokeObjectURL(url); resolve(blob && blob.size < file.size ? { blob, type: 'image/webp', ext: 'webp' } : { blob: file, type: file.type, ext: (file.type.split('/')[1] || 'jpg').replace('jpeg', 'jpg') }); }, 'image/webp', 0.82);
      };
      img.onerror = () => { URL.revokeObjectURL(url); resolve({ error: 'No se pudo leer la foto.' }); };
      img.src = url;
    });
  }
  async function uploadPhoto(file) {
    const p = await prepareImage(file);
    if (p.error) { toast(p.error, true); return null; }
    const name = new Date().toISOString().slice(0, 10) + '/' + Date.now().toString(36) + Math.random().toString(36).slice(2, 7) + '.' + p.ext;
    const { error } = await supabaseClient.storage.from(BUCKET).upload(name, p.blob, { contentType: p.type, cacheControl: '31536000' });
    if (error) { toast(/bucket|not found|policy|row-level/i.test(error.message) ? 'No se pudo subir: corre primero supabase/blog.sql en Supabase.' : error.message, true); return null; }
    return supabaseClient.storage.from(BUCKET).getPublicUrl(name).data.publicUrl;
  }

  /* ───────── Lista ───────── */
  async function load() {
    const r = root(); if (!r) return;
    css();
    r.innerHTML = '<p class="property-empty">Cargando…</p>';
    const { data, error } = await supabaseClient.from('blog_posts').select('id,slug,title,excerpt,body_md,cover_url,cover_alt,category,author_name,status,published_at,updated_at').order('created_at', { ascending: false });
    if (error) {
      r.innerHTML = '<div class="cp-card"><h2>Blog</h2><p class="cp-hint">' + (/relation|schema cache|does not exist/i.test(error.message) ? 'Falta crear el blog en la base de datos: corre <b>supabase/blog.sql</b> en el SQL Editor de Supabase (incluye 3 entradas iniciales) y vuelve a esta pestaña.' : esc(error.message)) + '</p></div>';
      return;
    }
    posts = data || []; draw();
  }

  const fdate = (d) => (d ? new Date(d).toLocaleDateString('es-BO', { day: '2-digit', month: 'short', year: 'numeric' }) : '—');

  function draw() {
    const r = root(); if (!r) return;
    editing = null;
    r.innerHTML =
      '<div class="bg-note">Las entradas <b>publicadas</b> aparecen en <a target="_blank" rel="noopener" href="/blog/">bastet.uno/blog</a> solas cada día a las 5:00 (hora de Bolivia). Para verlas <b>ya</b>: <a target="_blank" rel="noopener" href="' + ACTIONS_URL + '">GitHub → Actions → «Páginas de inmuebles» → Run workflow</a> (tarda ~2 minutos).</div>' +
      '<div class="bg-row" style="margin-bottom:14px"><button type="button" class="btn btn-accent" id="bg-new">Nueva entrada</button></div>' +
      '<div class="cp-card"><h2>Entradas (' + posts.length + ')</h2>' + (posts.length ? '<div class="cp-list">' + posts.map((p) =>
        '<article class="cp-item" data-id="' + esc(p.id) + '"><div class="cp-item-top"><b>' + esc(p.title) + '</b> <span class="bg-badge' + (p.status === 'published' ? ' pub' : '') + '">' + (p.status === 'published' ? 'Publicada' : 'Borrador') + '</span> <span class="bg-badge">' + esc(CATS[p.category] || p.category) + '</span></div>' +
        '<p class="cp-hint">/blog/' + esc(p.slug) + '/ · publicada: ' + fdate(p.published_at) + ' · editada: ' + fdate(p.updated_at) + '</p>' +
        '<div class="bg-row"><button type="button" class="btn btn-sm btn-accent" data-act="edit">Editar</button>' +
        (p.status === 'published' ? '<a class="btn btn-sm btn-ghost" target="_blank" rel="noopener" href="/blog/' + esc(p.slug) + '/">Ver en el sitio</a>' : '') +
        '<button type="button" class="btn btn-sm btn-ghost" data-act="del">Borrar</button></div></article>').join('') + '</div>' : '<p class="cp-hint">Aún no hay entradas. Pulsa «Nueva entrada».</p>') + '</div>';
  }

  /* ───────── Editor ───────── */
  const blank = () => ({ id: null, slug: '', title: '', excerpt: '', body_md: '', cover_url: '', cover_alt: '', category: 'general', author_name: 'Equipo Bastet', status: 'draft', published_at: null });
  const toLocal = (d) => { if (!d) return ''; const x = new Date(d); x.setMinutes(x.getMinutes() - x.getTimezoneOffset()); return x.toISOString().slice(0, 16); };

  function openEditor(p) {
    editing = p; const r = root();
    r.innerHTML =
      '<form class="cp-card" id="bg-form" novalidate><h2>' + (p.id ? 'Editar entrada' : 'Nueva entrada') + '</h2>' +
      '<label class="bg-field"><span>Título *</span><input id="bg-title" maxlength="150" value="' + esc(p.title) + '" placeholder="Ej. Cómo comprar una casa en Bolivia de forma segura"></label>' +
      '<div class="bg-grid"><label class="bg-field"><span>Dirección (slug) *</span><input id="bg-slug" maxlength="100" value="' + esc(p.slug) + '"><small id="bg-slugurl">bastet.uno/blog/' + esc(p.slug || '…') + '/</small></label>' +
      '<label class="bg-field"><span>Categoría</span><select id="bg-cat">' + Object.keys(CATS).map((k) => '<option value="' + k + '"' + (k === p.category ? ' selected' : '') + '>' + esc(CATS[k]) + '</option>').join('') + '</select></label></div>' +
      '<label class="bg-field"><span>Extracto (es la descripción que se ve en Google) *</span><textarea id="bg-excerpt" rows="3" maxlength="320">' + esc(p.excerpt) + '</textarea><span class="bg-count" id="bg-excount"></span></label>' +
      '<div class="bg-field"><span>Foto de portada</span><div class="bg-row"><input type="file" id="bg-cover-file" accept="image/jpeg,image/png,image/webp"><span class="bg-count" id="bg-cover-state"></span></div>' +
      '<input id="bg-cover" placeholder="Dirección de la foto (se llena sola al subirla)" value="' + esc(p.cover_url) + '" maxlength="600"><img id="bg-cover-img" class="bg-cover" alt=""' + (p.cover_url ? ' src="' + esc(p.cover_url.indexOf('http') === 0 ? p.cover_url : '/' + p.cover_url.replace(/^\//, '')) + '"' : ' hidden') + '>' +
      '<label class="bg-field" style="margin-top:8px"><span>Descripción de la portada (texto alternativo)</span><input id="bg-cover-alt" maxlength="200" value="' + esc(p.cover_alt) + '" placeholder="Ej. Familia revisando documentos de una casa"></label></div>' +
      '<div class="bg-field"><span>Texto de la entrada *</span><div class="bg-tools">' +
      '<button type="button" data-fmt="h2">Título ##</button><button type="button" data-fmt="h3">Subtítulo ###</button><button type="button" data-fmt="b"><b>Negrita</b></button><button type="button" data-fmt="i"><i>Cursiva</i></button>' +
      '<button type="button" data-fmt="ul">• Lista</button><button type="button" data-fmt="ol">1. Lista</button><button type="button" data-fmt="quote">Cita</button><button type="button" data-fmt="link">Enlace</button>' +
      '<button type="button" data-fmt="photo">Subir foto</button><input type="file" id="bg-photo-file" accept="image/jpeg,image/png,image/webp" hidden><button type="button" data-fmt="prev" id="bg-prev-btn">Vista previa</button></div>' +
      '<textarea id="bg-body" placeholder="Escribe aquí. Usa ## para los títulos de sección. Para preguntas frecuentes: una sección «## Preguntas frecuentes» con cada pregunta como «### ¿Pregunta?» y la respuesta debajo.">' + esc(p.body_md) + '</textarea>' +
      '<small>Mínimo 200 caracteres. <span id="bg-words"></span></small><div class="bg-preview" id="bg-preview" hidden></div></div>' +
      '<div class="bg-grid"><label class="bg-field"><span>Autor</span><input id="bg-author" maxlength="80" value="' + esc(p.author_name) + '"></label>' +
      '<label class="bg-field"><span>Estado</span><select id="bg-status"><option value="draft"' + (p.status === 'draft' ? ' selected' : '') + '>Borrador (no se ve en el sitio)</option><option value="published"' + (p.status === 'published' ? ' selected' : '') + '>Publicada</option></select></label></div>' +
      '<label class="bg-field"><span>Fecha de publicación (opcional: si la dejas vacía y publicas, se usa hoy)</span><input type="datetime-local" id="bg-date" value="' + toLocal(p.published_at) + '"></label>' +
      '<div class="bg-row"><button type="submit" class="btn btn-accent" id="bg-save">Guardar</button><button type="button" class="btn btn-ghost" id="bg-cancel">Cancelar</button></div></form>';
    counters();
  }

  function counters() {
    const ex = document.getElementById('bg-excerpt'), c = document.getElementById('bg-excount'), b = document.getElementById('bg-body'), w = document.getElementById('bg-words');
    if (!ex) return;
    const n = ex.value.trim().length;
    c.textContent = n + ' caracteres · ideal 140 a 160'; c.className = 'bg-count ' + (n >= 140 && n <= 160 ? 'ok' : (n < 40 || n > 320 ? 'bad' : ''));
    const words = (b.value.match(/\S+/g) || []).length; w.textContent = words + ' palabras · ~' + Math.max(1, Math.ceil(words / 200)) + ' min de lectura';
  }

  function wrap(ta, before, after, ph) {
    const s = ta.selectionStart, e = ta.selectionEnd, sel = ta.value.slice(s, e) || ph;
    ta.setRangeText(before + sel + after, s, e, 'end'); ta.focus(); counters();
  }
  function linePrefix(ta, prefix) {
    const s = ta.selectionStart, start = ta.value.lastIndexOf('\n', s - 1) + 1, end = (ta.value.indexOf('\n', ta.selectionEnd) + 1 || ta.value.length + 1) - 1;
    const block = ta.value.slice(start, end).split('\n').map((l, i) => (prefix === '1. ' ? (i + 1) + '. ' : prefix) + l).join('\n');
    ta.setRangeText(block, start, end, 'end'); ta.focus(); counters();
  }

  async function save(form) {
    if (busy) return;
    const g = (id) => document.getElementById(id).value;
    const row = {
      title: g('bg-title').trim(), slug: slugify(g('bg-slug')), excerpt: g('bg-excerpt').trim(), body_md: g('bg-body').trim(), category: g('bg-cat'),
      author_name: g('bg-author').trim() || 'Equipo Bastet', status: g('bg-status'), cover_url: g('bg-cover').trim() || null, cover_alt: g('bg-cover-alt').trim() || null,
      published_at: g('bg-date') ? new Date(g('bg-date')).toISOString() : (editing && editing.published_at) || null,
    };
    if (row.title.length < 5) return toast('Escribe un título de al menos 5 letras.', true);
    if (row.slug.length < 3) return toast('La dirección (slug) necesita al menos 3 letras o números.', true);
    if (row.excerpt.length < 40) return toast('El extracto necesita al menos 40 caracteres.', true);
    if (row.body_md.length < 200) return toast('El texto necesita al menos 200 caracteres.', true);
    if (row.status === 'draft' && !g('bg-date')) row.published_at = editing && editing.published_at ? editing.published_at : null;
    busy = true; const btn = document.getElementById('bg-save'); btn.disabled = true; btn.textContent = 'Guardando…';
    const q = editing && editing.id ? supabaseClient.from('blog_posts').update(row).eq('id', editing.id) : supabaseClient.from('blog_posts').insert(row);
    const { error } = await q;
    busy = false;
    if (error) { btn.disabled = false; btn.textContent = 'Guardar'; return toast(/duplicate|unique/i.test(error.message) ? 'Ya existe una entrada con esa dirección (slug). Cambia la dirección.' : error.message, true); }
    toast(row.status === 'published' ? 'Guardada. Se publicará en el sitio en la próxima actualización (diaria, o al correr «Páginas de inmuebles» en GitHub).' : 'Borrador guardado.');
    await load();
  }

  function bind() {
    const r = root(); if (!r || r.dataset.bound) return; r.dataset.bound = '1';
    r.addEventListener('click', async (e) => {
      if (e.target.id === 'bg-new') return openEditor(blank());
      if (e.target.id === 'bg-cancel') return draw();
      const act = e.target.closest('[data-act]'), card = e.target.closest('[data-id]');
      if (act && card) {
        const p = posts.find((x) => x.id === card.dataset.id); if (!p) return;
        if (act.dataset.act === 'edit') return openEditor(p);
        if (act.dataset.act === 'del') {
          if (!confirm('¿Borrar la entrada «' + p.title + '»? No se puede deshacer. (Su página desaparece del sitio en la próxima actualización.)')) return;
          const { error } = await supabaseClient.from('blog_posts').delete().eq('id', p.id);
          if (error) return toast(error.message, true);
          toast('Entrada borrada.'); return load();
        }
      }
      const f = e.target.closest('[data-fmt]');
      if (f) {
        const ta = document.getElementById('bg-body'), k = f.dataset.fmt;
        if (k === 'h2') linePrefix(ta, '## '); else if (k === 'h3') linePrefix(ta, '### ');
        else if (k === 'b') wrap(ta, '**', '**', 'texto en negrita'); else if (k === 'i') wrap(ta, '*', '*', 'texto en cursiva');
        else if (k === 'ul') linePrefix(ta, '- '); else if (k === 'ol') linePrefix(ta, '1. '); else if (k === 'quote') linePrefix(ta, '> ');
        else if (k === 'link') { const u = prompt('Dirección del enlace (https://… o /blog/…):', 'https://'); if (u) wrap(ta, '[', '](' + u.trim() + ')', 'texto del enlace'); }
        else if (k === 'photo') document.getElementById('bg-photo-file').click();
        else if (k === 'prev') {
          const pv = document.getElementById('bg-preview'); pv.hidden = !pv.hidden;
          if (!pv.hidden) pv.innerHTML = render(ta.value) || '<p style="color:#888">Escribe algo para ver la vista previa.</p>';
          f.textContent = pv.hidden ? 'Vista previa' : 'Ocultar vista previa';
        }
      }
    });
    r.addEventListener('input', (e) => {
      if (e.target.id === 'bg-title' && editing && !editing.id) { const s = document.getElementById('bg-slug'); if (!s.dataset.touched) { s.value = slugify(e.target.value); } }
      if (e.target.id === 'bg-slug') { e.target.dataset.touched = '1'; }
      if (['bg-title', 'bg-slug'].includes(e.target.id)) { const u = document.getElementById('bg-slugurl'); if (u) u.textContent = 'bastet.uno/blog/' + (slugify(document.getElementById('bg-slug').value) || '…') + '/'; }
      if (['bg-excerpt', 'bg-body'].includes(e.target.id)) { counters(); const pv = document.getElementById('bg-preview'); if (e.target.id === 'bg-body' && pv && !pv.hidden) pv.innerHTML = render(e.target.value); }
    });
    r.addEventListener('submit', (e) => { e.preventDefault(); save(e.target); });
    r.addEventListener('change', async (e) => {
      if (e.target.id === 'bg-cover-file' && e.target.files[0]) {
        const st = document.getElementById('bg-cover-state'); st.textContent = 'Subiendo…';
        const url = await uploadPhoto(e.target.files[0]); e.target.value = '';
        if (url) { document.getElementById('bg-cover').value = url; const im = document.getElementById('bg-cover-img'); im.src = url; im.hidden = false; st.textContent = 'Foto subida'; } else st.textContent = '';
      }
      if (e.target.id === 'bg-photo-file' && e.target.files[0]) {
        const ta = document.getElementById('bg-body'); const alt = prompt('Describe la foto (texto alternativo, ayuda al SEO y a la accesibilidad):', '') || '';
        toast('Subiendo foto…'); const url = await uploadPhoto(e.target.files[0]); e.target.value = '';
        if (url) { ta.setRangeText('\n\n![' + alt.replace(/[\[\]]/g, '') + '](' + url + ')\n\n', ta.selectionStart, ta.selectionEnd, 'end'); counters(); toast('Foto insertada en el texto.'); }
      }
    });
  }

  const tab = document.querySelector('.admin-tab[data-tab="blog"]');
  if (tab) tab.addEventListener('click', () => { bind(); load(); });
})();
