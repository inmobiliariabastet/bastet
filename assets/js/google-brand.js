/* Identidad de Google donde se nombra a Google: la palabra «Google» se muestra con sus colores (G azul, o roja, o amarilla, g azul, l verde, e roja)
 * para que se reconozca de un vistazo qué significa «Entrar con Google». Recorre el texto visible de la página (y el que se agrega después) y envuelve
 * la palabra en <span class="g-word">. No toca scripts, estilos, campos de formulario ni textos dentro de atributos. */
(function () {
  'use strict';
  const COLORS = ['#4285F4', '#EA4335', '#FBBC05', '#4285F4', '#34A853', '#EA4335'];
  const style = document.createElement('style');
  style.textContent = '.g-word{font-weight:inherit;white-space:nowrap}.g-word i{font-style:normal}';
  document.head.appendChild(style);
  const html = 'Google'.split('').map((ch, i) => '<i style="color:' + COLORS[i] + '">' + ch + '</i>').join('');
  const SKIP = new Set(['SCRIPT', 'STYLE', 'TEXTAREA', 'INPUT', 'OPTION', 'SELECT', 'CODE', 'PRE', 'TITLE', 'NOSCRIPT']);
  const RE = /Google/;

  function wrap(root) {
    const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
      acceptNode(n) {
        if (!RE.test(n.nodeValue)) return NodeFilter.FILTER_REJECT;
        const p = n.parentElement;
        if (!p || SKIP.has(p.tagName) || p.closest('.g-word')) return NodeFilter.FILTER_REJECT;
        return NodeFilter.FILTER_ACCEPT;
      },
    });
    const nodes = []; while (walker.nextNode()) nodes.push(walker.currentNode);
    nodes.forEach((n) => {
      const frag = document.createDocumentFragment();
      n.nodeValue.split(/(Google)/).forEach((part) => {
        if (part === 'Google') { const s = document.createElement('span'); s.className = 'g-word'; s.setAttribute('aria-label', 'Google'); s.innerHTML = html; frag.appendChild(s); }
        else if (part) frag.appendChild(document.createTextNode(part));
      });
      n.parentNode.replaceChild(frag, n);
    });
  }

  let timer = null;
  const run = () => { if (document.body) wrap(document.body); };
  const schedule = () => { clearTimeout(timer); timer = setTimeout(run, 120); };
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', run); else run();
  if (window.MutationObserver) new MutationObserver((muts) => { if (muts.some((m) => [...m.addedNodes].some((n) => !(n.nodeType === 1 && n.classList.contains('g-word'))))) schedule(); }).observe(document.documentElement, { childList: true, subtree: true });
})();
