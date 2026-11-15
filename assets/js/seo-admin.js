/* Panel «SEO» (solo administración): indicadores VERIFICABLES de visibilidad, calculados con los datos reales del sitio.
 *  · Calidad del inventario: qué inmuebles cumplen las reglas para tener página propia indexable y cuáles faltan por completar.
 *  · Páginas publicadas: se cuentan desde el sitemap.xml en vivo (inmuebles, categorías, institucionales).
 *  · Rendimiento por ciudad y operación: vistas y clics a WhatsApp (tabla property_events), no impresiones de Google.
 *  · Herramientas: enlaces a Search Console, Bing, PageSpeed y pruebas de datos estructurados.
 * Lo que NO se puede medir desde aquí (posiciones, impresiones y clics orgánicos de Google, indexación) se ve en Search Console. */
(function () {
  'use strict';
  const root = () => document.getElementById('seo-root');
  const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const MIN_DESC = 100;
  const OPS = ['venta', 'alquiler', 'anticretico'];
  const TYPES = ['casa', 'departamento', 'habitacion', 'terreno'];
  const OP_LABEL = { venta: 'Venta', alquiler: 'Alquiler', anticretico: 'Anticrético', temporal: 'Estadía' };
  const SITE = 'https://bastet.uno';
  const cityOf = (p) => String(p.location || '').split(',')[0].trim();

  // Mismas reglas que tools/gen_property_pages.py
  function missing(p) {
    const m = [];
    if (!OPS.concat('temporal').includes(p.operation)) m.push('operación');
    if (!TYPES.includes(p.property_type)) m.push('tipo de inmueble');
    if (!cityOf(p)) m.push('ciudad');
    if (!String(p.price || '').replace(/\D/g, '')) m.push('precio');
    if (!(p.photos && p.photos.length)) m.push('foto');
    const len = String(p.description || '').replace(/\s+/g, ' ').trim().length;
    if (len < MIN_DESC) m.push('descripción de ' + MIN_DESC + '+ caracteres (tiene ' + len + ')');
    return m;
  }
  const classifiable = (p) => OPS.includes(p.operation) && TYPES.includes(p.property_type) && cityOf(p) && String(p.price || '').replace(/\D/g, '') && p.photos && p.photos.length;

  async function loadSitemap() {
    try {
      const r = await fetch('/sitemap.xml?t=' + Date.now(), { cache: 'no-store' });
      if (!r.ok) return null;
      const txt = await r.text();
      const locs = [...txt.matchAll(/<loc>([^<]+)<\/loc>/g)].map((m) => m[1]);
      const inm = locs.filter((u) => u.includes('/inmueble/') && !u.endsWith('/inmueble/'));
      const cats = locs.filter((u) => /^https:\/\/bastet\.uno\/[a-z0-9-]+\/$/.test(u) && !u.endsWith('/inmueble/') && !u.endsWith('/sobre-bastet/'));
      return { total: locs.length, inm, cats, locs };
    } catch (e) { return null; }
  }

  async function load() {
    const r = root(); if (!r) return;
    r.innerHTML = '<p class="property-empty">Calculando…</p>';
    const [props, events, sm] = await Promise.all([
      supabaseClient.from('properties').select('id,title,location,price,currency,description,photos,operation,property_type,status,code_number,expires_at').eq('status', 'available'),
      supabaseClient.from('property_events').select('property_id,event_type').limit(20000),
      loadSitemap(),
    ]);
    if (props.error) { r.innerHTML = '<p class="property-empty">' + esc(props.error.message) + '</p>'; return; }
    const now = Date.now();
    const list = (props.data || []).filter((p) => !p.expires_at || new Date(p.expires_at).getTime() > now);
    const complete = list.filter((p) => !missing(p).length);
    const incomplete = list.filter((p) => missing(p).length);
    const cls = list.filter(classifiable);

    // vistas y clics por ciudad/operación
    const byId = Object.fromEntries(list.map((p) => [p.id, p]));
    const agg = {};
    (events.data || []).forEach((e) => {
      const p = byId[e.property_id]; if (!p) return;
      const k = cityOf(p) + '|' + (p.operation || 'sin operación');
      (agg[k] = agg[k] || { v: 0, w: 0, n: 0 });
      if (e.event_type === 'view') agg[k].v++; else agg[k].w++;
    });
    list.forEach((p) => { const k = cityOf(p) + '|' + (p.operation || 'sin operación'); (agg[k] = agg[k] || { v: 0, w: 0, n: 0 }).n++; });
    const rows = Object.entries(agg).sort((a, b) => (b[1].v + b[1].w) - (a[1].v + a[1].w));

    const card = (n, label, hint) => '<div class="analytics-stat-card"><p class="analytics-stat-value">' + n + '</p><p class="analytics-stat-label">' + esc(label) + (hint ? '<br><small>' + esc(hint) + '</small>' : '') + '</p></div>';
    const link = (href, text) => '<a class="btn btn-sm btn-ghost" target="_blank" rel="noopener" href="' + esc(href) + '">' + esc(text) + '</a>';
    const enc = encodeURIComponent;

    r.innerHTML =
      '<div class="analytics-stats">' +
        card(list.length, 'Inmuebles disponibles') +
        card(complete.length, 'Con ficha completa', 'tienen página propia indexable') +
        card(incomplete.length, 'Incompletos', 'solo se ven dentro del listado') +
        card(cls.length, 'Clasificables', 'cuentan para las páginas de categoría') +
        card(sm ? sm.inm.length : '—', 'Fichas en el sitemap') +
        card(sm ? sm.cats.length : '—', 'Categorías en el sitemap') +
      '</div>' +
      '<div class="cp-card"><h2>Qué falta para que un inmueble tenga su propia página</h2>' +
      '<p class="cp-hint">Reglas: operación, tipo, ciudad, precio, al menos 1 foto y una descripción propia de ' + MIN_DESC + ' caracteres o más (sin repetir la de otro inmueble). Completa estos datos desde «Propiedades» y la página aparece sola al día siguiente (o al correr la tarea «Páginas de inmuebles» en GitHub → Actions).</p>' +
      (incomplete.length ? '<div class="cp-list">' + incomplete.map((p) => '<article class="cp-item"><div class="cp-item-top"><b>' + esc(p.code_number ? 'BST-' + p.code_number : '') + '</b> · ' + esc(p.title) + '</div><p class="cp-hint">Falta: ' + esc(missing(p).join(', ')) + '</p></article>').join('') + '</div>' : '<p class="cp-hint">Todos los inmuebles disponibles tienen la ficha completa.</p>') +
      '</div>' +
      '<div class="cp-card"><h2>Páginas de categoría publicadas</h2>' + (sm && sm.cats.length ? '<div class="cp-list">' + sm.cats.map((u) => '<article class="cp-item"><a target="_blank" rel="noopener" href="' + esc(u) + '">' + esc(u.replace(SITE, '')) + '</a></article>').join('') + '</div>' : '<p class="cp-hint">No se pudo leer el sitemap.</p>') +
      '<p class="cp-hint">Una categoría aparece sola cuando hay inventario real suficiente (3 o más inmuebles; las páginas nacionales de operación, desde 1).</p></div>' +
      '<div class="cp-card"><h2>Vistas y contactos por ciudad y operación</h2>' +
      (rows.length ? '<div class="analytics-table-wrap"><table class="analytics-table"><thead><tr><th>Ciudad</th><th>Operación</th><th>Inmuebles</th><th>Vistas</th><th>Clics a WhatsApp</th></tr></thead><tbody>' +
        rows.map(([k, v]) => { const [c, o] = k.split('|'); return '<tr><td>' + esc(c) + '</td><td>' + esc(OP_LABEL[o] || o) + '</td><td>' + v.n + '</td><td>' + v.v + '</td><td>' + v.w + '</td></tr>'; }).join('') + '</tbody></table></div>' : '<p class="cp-hint">Sin eventos todavía.</p>') +
      '<p class="cp-hint">Son visitas y clics registrados por el propio sitio. No incluyen impresiones ni posiciones de Google: esas están en Search Console.</p></div>' +
      '<div class="cp-card"><h2>Medición externa (cuentas de la dueña)</h2><p class="cp-hint">Estado: Search Console con sitemap enviado el 30-oct; Google Analytics 4 <b>no está configurado</b> (falta el ID de medición); Bing Webmaster Tools sin verificar.</p>' +
      '<div class="cp-row">' + link('https://search.google.com/search-console?resource_id=' + enc(SITE + '/'), 'Search Console') + link('https://www.bing.com/webmasters', 'Bing Webmaster Tools') +
      link('https://pagespeed.web.dev/analysis?url=' + enc(SITE + '/') + '&form_factor=mobile', 'PageSpeed (móvil)') + link('https://search.google.com/test/rich-results?url=' + enc(SITE + '/'), 'Prueba de resultados enriquecidos') +
      link('https://validator.schema.org/#url=' + enc(SITE + '/'), 'Validador Schema.org') + link(SITE + '/sitemap.xml', 'sitemap.xml') + link(SITE + '/robots.txt', 'robots.txt') + link(SITE + '/llms.txt', 'llms.txt') + '</div></div>';
  }

  const tab = document.querySelector('.admin-tab[data-tab="seo"]');
  if (tab) tab.addEventListener('click', load);
})();
