/* Auditor de responsividad (herramienta de pruebas; ver HANDOFF: «Auditoría de responsividad»): busca elementos que se salen de la pantalla, texto que no cabe en su caja
   o hijos que sobresalen de su contenedor. window.__aud() devuelve la lista. */
window.__aud = function () {
  const W = window.innerWidth, out = [];
  const vis = (e) => { const cs = getComputedStyle(e); return cs.display !== 'none' && cs.visibility !== 'hidden' && e.getClientRects().length > 0; };
  const path = (e) => { let s = e.tagName.toLowerCase(); if (e.id) s += '#' + e.id; else if (typeof e.className === 'string' && e.className.trim()) s += '.' + e.className.trim().split(/\s+/).slice(0, 2).join('.'); return s; };
  const scroller = (e) => { for (let p = e.parentElement; p; p = p.parentElement) { const cs = getComputedStyle(p); if (/(auto|scroll)/.test(cs.overflowX) && p.scrollWidth > p.clientWidth + 1) return p; } return null; };
  const boxy = (p) => { const cs = getComputedStyle(p); return (cs.backgroundColor !== 'rgba(0, 0, 0, 0)' || parseFloat(cs.borderTopWidth) > 0 || parseFloat(cs.borderLeftWidth) > 0 || cs.backgroundImage !== 'none') && p.tagName !== 'BODY' && p.tagName !== 'HTML'; };
  const seen = new Set();
  const push = (o) => { const k = o.t + o.el + o.txt; if (seen.has(k) || out.length >= 40) return; seen.add(k); out.push(o); };
  document.querySelectorAll('body *').forEach((e) => {
    if (e instanceof SVGElement && e.tagName.toLowerCase() !== 'svg') return;
    if (e instanceof SVGElement || ['SCRIPT', 'STYLE', 'OPTION'].includes(e.tagName)) return;
    if (!vis(e)) return;
    const drawer = e.closest('.admin-side'); if (drawer && drawer.getBoundingClientRect().right <= 1) return;   // menú lateral cerrado (cajón fuera de pantalla): es normal
    const cs = getComputedStyle(e), r = e.getBoundingClientRect(); if (r.width === 0 || r.height === 0) return;
    const txt = (e.textContent || '').trim().replace(/\s+/g, ' ').slice(0, 28);
    if ((r.right > W + 1 || r.left < -1) && !scroller(e) && !e.closest('.hidden,[hidden]') && cs.position !== 'fixed' && !e.closest('.stay-slides,.prop-tile-ph,.stay-media')) push({ t: 'fuera-de-pantalla', el: path(e), r: Math.round(r.right), l: Math.round(r.left), txt });
    const hasText = [...e.childNodes].some((n) => n.nodeType === 3 && n.textContent.trim());
    if (hasText && cs.display !== 'inline' && e.scrollWidth > e.clientWidth + 2 && !/(auto|scroll)/.test(cs.overflowX) && cs.textOverflow !== 'ellipsis' && e.tagName !== 'SELECT' && e.tagName !== 'INPUT') push({ t: 'texto-no-cabe', el: path(e), sw: e.scrollWidth, cw: e.clientWidth, txt });
    const p = e.parentElement;
    if (p && boxy(p) && cs.position !== 'absolute' && cs.position !== 'fixed' && !scroller(e) && !/(hidden|auto|scroll)/.test(getComputedStyle(p).overflowX)) { const pr = p.getBoundingClientRect(); if (r.right > pr.right + 2 && pr.width > 0) push({ t: 'sale-de-su-caja', el: path(e) + ' en ' + path(p), over: Math.round(r.right - pr.right), txt }); }
  });
  if (document.documentElement.scrollWidth > W + 16) push({ t: 'scroll-horizontal-de-pagina', el: 'html', sw: document.documentElement.scrollWidth, W, txt: '' });
  return out;
};
window.__auditPages = async function (pages, w, wait) {
  const report = {};
  for (const p of pages) {
    const f = document.createElement('iframe');
    f.style.cssText = 'position:fixed;left:0;top:0;width:' + w + 'px;height:900px;border:0;opacity:0;pointer-events:none';
    f.src = '/' + p + (p.includes('?') ? '&' : '?') + 'au=' + Math.random();
    document.body.appendChild(f);
    await new Promise((r) => { f.onload = r; });
    await new Promise((r) => setTimeout(r, wait || 1500));
    try {
      const s = f.contentDocument.createElement('script'); s.src = '/tests/responsive-audit.js'; f.contentDocument.head.appendChild(s);
      await new Promise((r) => { s.onload = r; });
      const res = f.contentWindow.__aud();
      if (res.length) report[w + 'px ' + p] = res.slice(0, 6);
    } catch (e) { report[w + 'px ' + p] = 'ERR ' + e.message; }
    f.remove();
  }
  return report;
};

window.__auditAdmin = async function (role, w) {
  const report = {};
  const f = document.createElement('iframe');
  f.style.cssText = 'position:fixed;left:0;top:0;width:' + w + 'px;height:900px;border:0;opacity:0;pointer-events:none';
  f.src = '/_stub_admin.html?role=' + role + '&au=' + Math.random();
  document.body.appendChild(f);
  await new Promise((r) => { f.onload = r; });
  await new Promise((r) => setTimeout(r, 2500));
  const s = f.contentDocument.createElement('script'); s.src = '/tests/responsive-audit.js'; f.contentDocument.head.appendChild(s);
  await new Promise((r) => { s.onload = r; });
  try { if (f.contentWindow.UnoPublications) await f.contentWindow.UnoPublications.refresh(); } catch (e) { /* sin sesión */ }
  await new Promise((r) => setTimeout(r, 700));
  const tabs = [...f.contentDocument.querySelectorAll('.admin-tab')].map((t) => t.dataset.tab);
  for (const t of ['(inicio)'].concat(tabs)) {
    if (t !== '(inicio)') { const b = f.contentDocument.querySelector('.admin-tab[data-tab="' + t + '"]'); if (!b || b.classList.contains('hidden')) continue; b.click(); await new Promise((r) => setTimeout(r, 1100)); }
    const res = f.contentWindow.__aud().filter((x) => !/testi-ring|partners-track|admin-side|admin-nav|admin-logo|^img$/.test(x.el) && !(x.l < -100));
    if (res.length) report[role + ' ' + w + 'px ' + t] = res.slice(0, 5);
  }
  f.remove();
  return report;
};
